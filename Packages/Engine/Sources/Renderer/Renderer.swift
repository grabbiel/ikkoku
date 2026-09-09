import Foundation
import Metal
import QuartzCore
import CoreGraphics
import simd
import CoreMath
import GPU
import Assets
import Scene
import ShaderTypes

/// Frame graph: deform → shadow → toon+outline → transparent → post → overlay.
public final class Renderer: @unchecked Sendable {
    public static let shadowMapSize = 2048

    public let gpu: GPUContext
    public let resources: ResourceStore
    let pipelines: Pipelines
    let frameRing: FrameRing
    let shadowMap: any MTLTexture

    private let renderLock = NSLock()
    private let frameLock = NSLock()
    private var pendingFrame = RenderFrame()
    private var targets: RenderTargets?
    private var frameIndex = 0
    public private(set) var lastFrameGPUTime: Double = 0

    public init(gpu: GPUContext) throws {
        self.gpu = gpu
        self.resources = ResourceStore(device: gpu.device)
        self.pipelines = try Pipelines(gpu: gpu)
        guard let ring = FrameRing(device: gpu.device) else { throw RendererError.frameRingCreationFailed }
        self.frameRing = ring
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Pipelines.depthFormat, width: Renderer.shadowMapSize, height: Renderer.shadowMapSize, mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        sd.storageMode = .private
        guard let sm = gpu.device.makeTexture(descriptor: sd) else { throw RendererError.textureCreationFailed }
        sm.label = "ShadowMap"
        self.shadowMap = sm
    }

    // MARK: - Frame hand-off

    public func submit(_ frame: RenderFrame) { frameLock.lock(); pendingFrame = frame; frameLock.unlock() }
    public func currentFrame() -> RenderFrame { frameLock.lock(); defer { frameLock.unlock() }; return pendingFrame }

    // MARK: - Drawing to the swapchain

    public func draw(to drawable: any CAMetalDrawable, timestamp: CFTimeInterval) {
        let tex = drawable.texture
        guard tex.width > 0, tex.height > 0 else { return }
        var frame = currentFrame()
        frame.time = timestamp
        gpu.waitForFrameSlot()
        guard let cb = gpu.commandQueue.makeCommandBuffer() else { gpu.releaseFrameSlot(); return }
        cb.label = "Frame"
        renderLock.lock()
        let targets = ensureTargets(width: tex.width, height: tex.height)
        if let targets {
            frameRing.beginFrame(frameIndex); frameIndex &+= 1
            encode(frame: frame, target: tex, targets: targets, commandBuffer: cb)
        }
        renderLock.unlock()
        cb.addCompletedHandler { [weak self] c in
            self?.lastFrameGPUTime = c.gpuEndTime - c.gpuStartTime
        }
        gpu.releaseFrameSlot(onCompletionOf: cb)
        cb.present(drawable)
        cb.commit()
    }

    private func ensureTargets(width: Int, height: Int) -> RenderTargets? {
        if let t = targets, t.width == width, t.height == height { return t }
        targets = try? RenderTargets(device: gpu.device, width: width, height: height)
        return targets
    }

    // MARK: - Picking

    /// Returns the object id under a pixel (0 = nothing). Synchronous; a few milliseconds.
    public func pick(frame: RenderFrame, pixel: Float2, size: (Int, Int)) -> UInt32 {
        gpu.waitForFrameSlot()
        defer { gpu.releaseFrameSlot() }
        guard let cb = gpu.commandQueue.makeCommandBuffer() else { return 0 }
        renderLock.lock()
        guard let targets = ensureTargets(width: size.0, height: size.1) else { renderLock.unlock(); return 0 }
        frameRing.beginFrame(frameIndex); frameIndex &+= 1
        let ctx = prepare(frame: frame, targets: targets)
        encodeDeform(ctx, cb)
        encodePick(ctx, targets: targets, cb)
        let readback = gpu.device.makeBuffer(length: 16, options: .storageModeShared)!
        let x = min(max(Int(pixel.x), 0), size.0 - 1), y = min(max(Int(pixel.y), 0), size.1 - 1)
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: targets.pick, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                      sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: readback, destinationOffset: 0, destinationBytesPerRow: 4, destinationBytesPerImage: 4)
            blit.endEncoding()
        }
        renderLock.unlock()
        cb.commit()
        cb.waitUntilCompleted()
        return readback.contents().load(as: UInt32.self)
    }

    // MARK: - Offscreen capture

    public func capture(frame: RenderFrame, width: Int, height: Int) -> CGImage? {
        gpu.waitForFrameSlot()
        defer { gpu.releaseFrameSlot() }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Pipelines.ldrFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = gpu.device.makeTexture(descriptor: d), let cb = gpu.commandQueue.makeCommandBuffer() else { return nil }
        renderLock.lock()
        guard let targets = try? RenderTargets(device: gpu.device, width: width, height: height) else { renderLock.unlock(); return nil }
        frameRing.beginFrame(frameIndex); frameIndex &+= 1
        encode(frame: frame, target: tex, targets: targets, commandBuffer: cb)
        renderLock.unlock()
        cb.commit()
        cb.waitUntilCompleted()
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { tex.getBytes($0.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: cs,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Frame preparation

    struct DrawRecord {
        let item: RenderItem
        let mesh: GPUMesh
        let vertexBuffer: any MTLBuffer
        let hiddenBuffer: (any MTLBuffer)?
        let drawOffset: Int
        let materialOffset: Int
        let distance: Float
    }

    struct FrameContext {
        let frame: RenderFrame
        let frameOffset: Int
        let lightsOffset: Int
        let postOffset: Int
        let opaque: [DrawRecord]
        let transparent: [DrawRecord]
        let shadowCasters: [DrawRecord]
        let deforms: [(key: UInt64, mesh: GPUMesh, buffer: any MTLBuffer, skinOffset: Int?, morphOffset: Int, morphCount: Int)]
        let width: Int
        let height: Int
    }

    private func prepare(frame: RenderFrame, targets: RenderTargets) -> FrameContext {
        let W = targets.width, H = targets.height
        let fw = Float(W), fh = Float(H)
        let cam = frame.camera
        let view = cam.viewMatrix()
        let proj = cam.projectionMatrix(aspect: fw / fh)
        let vp = proj * view
        let fx = frame.effects

        var fu = FrameUniforms()
        fu.viewProjection = vp
        fu.view = view
        fu.projection = proj
        fu.inverseView = view.inverse
        fu.inverseViewProjection = vp.inverse
        let toLight = -frame.mainLight.direction(camera: cam)
        let b = frame.sceneBounds
        let center = b.isEmpty ? Float3(0, 1, 0) : b.center
        let r = max(b.isEmpty ? 1.5 : b.radius, 1.0)
        let lview = Projection.lookAt(eye: center + toLight * (r * 3), center: center, up: Float3(0, 1, 0))
        let lproj = Projection.orthographicReverseZ(left: -r, right: r, bottom: -r, top: r, near: 0.05, far: r * 6)
        fu.shadowViewProjection = lproj * lview
        let cp = cam.position
        fu.cameraPosition = Float4(cp.x, cp.y, cp.z, 1)
        fu.viewport = Float4(fw, fh, 1 / fw, 1 / fh)
        fu.mainLightDirection = Float4(toLight.x, toLight.y, toLight.z, frame.mainLight.castsShadow ? frame.mainLight.shadowStrength : 0)
        let lc = frame.mainLight.color * frame.mainLight.intensity
        fu.mainLightColor = Float4(lc.x, lc.y, lc.z, 1)
        fu.ambientSky = Float4(fx.ambientSky.x, fx.ambientSky.y, fx.ambientSky.z, 1)
        fu.ambientGround = Float4(fx.ambientGround.x, fx.ambientGround.y, fx.ambientGround.z, 1)
        fu.shadowParams = Float4(1 / Float(Renderer.shadowMapSize), 0.0012, 0.0025, fx.shadowSoftness)
        fu.fogColor = Float4(fx.fogColor.x, fx.fogColor.y, fx.fogColor.z, fx.fogEnabled ? 1 : 0)
        fu.fogRange = Float4(fx.fogStart, fx.fogEnd, 0, 0)
        let resScale = fh / 1080
        fu.outlineParams = Float4(fx.outlineWidth * resScale, 0, 10 * resScale, 0)
        fu.time = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        fu.nearPlane = cam.near
        fu.exposure = fx.exposure
        let frameOffset = frameRing.allocate(fu)

        var lu = LightsUniforms()
        var count = 0
        withUnsafeMutableBytes(of: &lu.lights) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: LightUniform.self)
            for l in frame.lights where l.enabled && count < IK_MAX_LIGHTS {
                var u = LightUniform()
                let type: Float = l.kind == .directional ? 0 : (l.kind == .point ? 1 : 2)
                u.position = Float4(l.position.x, l.position.y, l.position.z, type)
                let d = l.direction
                u.direction = Float4(d.x, d.y, d.z, l.range)
                let c = l.color * l.intensity
                let outer = cos(l.spotAngle.degreesToRadians * 0.5)
                let inner = cos(l.spotAngle.degreesToRadians * 0.5 * (1 - l.spotBlend * 0.9))
                u.color = Float4(c.x, c.y, c.z, outer)
                u.params = Float4(inner, 1, 0, 0)
                p[count] = u
                count += 1
            }
        }
        lu.count = UInt32(count)
        let lightsOffset = frameRing.allocate(lu)

        var pp = PostParams()
        pp.bloom = Float4(fx.bloomThreshold, fx.bloomIntensity, fx.bloomRadius, 0)
        pp.vignette = Float4(fx.vignetteEnabled ? fx.vignetteIntensity : 0, fx.vignetteSmoothness, fw / fh, 0)
        pp.grade = Float4(fx.exposure, fx.contrast, fx.saturation, fx.temperature)
        pp.texel = Float4(1 / fw, 1 / fh, fw, fh)
        pp.flags = (fx.fxaa ? 1 : 0) | (fx.bloomEnabled ? 2 : 0) | (fx.vignetteEnabled ? 4 : 0) | 8
        let postOffset = frameRing.allocate(pp)

        // Skin sets: upload once per character.
        var skinOffsets: [UInt64: Int] = [:]
        for (key, mats) in frame.skinSets {
            var m = mats
            if m.count > IK_MAX_BONES { m = Array(m.prefix(Int(IK_MAX_BONES))) }
            skinOffsets[key] = frameRing.allocate(array: m)
        }

        var opaque: [DrawRecord] = []
        var transparent: [DrawRecord] = []
        var casters: [DrawRecord] = []
        var deforms: [(key: UInt64, mesh: GPUMesh, buffer: any MTLBuffer, skinOffset: Int?, morphOffset: Int, morphCount: Int)] = []
        var deformSeen = Set<UInt64>()

        for item in frame.items where item.visible {
            guard let mesh = resources.mesh(item.mesh) else { continue }
            var vb: any MTLBuffer = mesh.baseVertices
            if let key = item.deformKey, mesh.needsDeform {
                let buf = resources.deformBuffer(for: key, vertexCount: mesh.vertexCount)
                vb = buf
                if !deformSeen.contains(key) {
                    deformSeen.insert(key)
                    let entries = item.morphWeights.filter { $0.index < mesh.morphNames.count && abs($0.weight) > 1e-4 }
                        .prefix(Int(IK_MAX_ACTIVE_MORPHS)).map { MorphWeightEntry(index: UInt32($0.index), weight: $0.weight) }
                    let mo = frameRing.allocate(array: Array(entries))
                    let so = item.skinSet.flatMap { skinOffsets[$0] }
                    deforms.append((key, mesh, buf, mesh.skin != nil ? so : nil, mo, entries.count))
                }
            }
            let hb = item.hiddenKey.flatMap { resources.hiddenBuffer(key: $0) }.flatMap { $0.length >= mesh.vertexCount ? $0 : nil }
            var du = DrawUniforms()
            du.model = item.model
            du.normalMatrix = Transform.normalMatrix(from: item.model)
            du.objectID = item.objectID
            du.flags = hb != nil ? DrawFlagHasHiddenBuffer : item.hiddenRegions
            du.outlineScale = item.outlineScale
            du.depthBias = item.material.depthBias
            let doff = frameRing.allocate(du)
            var mu = item.material.uniforms
            if resources.texture(item.material.base) == nil { mu.flags &= ~MaterialFlagHasBaseTexture.rawValue }
            if resources.texture(item.material.bodyMask) == nil { mu.flags &= ~MaterialFlagHasBodyMask.rawValue }
            if mesh.colors != nil { mu.flags |= MaterialFlagHasVertexColor.rawValue } else { mu.flags &= ~MaterialFlagHasVertexColor.rawValue }
            let moff = frameRing.allocate(mu)
            let c = item.model.transformPoint(mesh.bounds.center)
            let rec = DrawRecord(item: item, mesh: mesh, vertexBuffer: vb, hiddenBuffer: hb, drawOffset: doff, materialOffset: moff, distance: length(c - cp))
            if item.material.transparent { transparent.append(rec) } else { opaque.append(rec) }
            if item.castsShadow && !item.material.transparent { casters.append(rec) }
        }
        opaque.sort { a, b in
            if a.item.order != b.item.order { return a.item.order < b.item.order }
            if a.item.material.uniforms.kind != b.item.material.uniforms.kind { return a.item.material.uniforms.kind < b.item.material.uniforms.kind }
            return a.item.mesh.id < b.item.mesh.id
        }
        transparent.sort { $0.distance > $1.distance }
        return FrameContext(frame: frame, frameOffset: frameOffset, lightsOffset: lightsOffset, postOffset: postOffset,
                            opaque: opaque, transparent: transparent, shadowCasters: casters, deforms: deforms, width: W, height: H)
    }

    // MARK: - Encoding

    private func encode(frame: RenderFrame, target: any MTLTexture, targets: RenderTargets, commandBuffer cb: any MTLCommandBuffer) {
        let ctx = prepare(frame: frame, targets: targets)
        encodeDeform(ctx, cb)
        encodeShadow(ctx, cb)
        encodeMain(ctx, targets: targets, cb)
        encodePost(ctx, targets: targets, target: target, cb)
        encodeOverlay(ctx, targets: targets, target: target, cb)
    }

    private func encodeDeform(_ ctx: FrameContext, _ cb: any MTLCommandBuffer) {
        guard !ctx.deforms.isEmpty, let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "Deform"
        enc.setComputePipelineState(pipelines.deform)
        let dummy = resources.dummyBuffer
        for d in ctx.deforms {
            var params = DeformParams(vertexCount: UInt32(d.mesh.vertexCount), activeMorphCount: UInt32(d.morphCount),
                                      hasSkin: d.skinOffset != nil ? 1 : 0, hasMorphNormals: d.mesh.morphNormals != nil ? 1 : 0)
            enc.setBuffer(d.mesh.baseVertices, offset: 0, index: Int(BufferIndexBaseVertices.rawValue))
            enc.setBuffer(d.buffer, offset: 0, index: Int(BufferIndexVertices.rawValue))
            enc.setBuffer(d.mesh.skin ?? dummy, offset: 0, index: Int(BufferIndexSkinData.rawValue))
            if let so = d.skinOffset { enc.setBuffer(frameRing.buffer, offset: so, index: Int(BufferIndexSkinMatrices.rawValue)) }
            else { enc.setBuffer(dummy, offset: 0, index: Int(BufferIndexSkinMatrices.rawValue)) }
            enc.setBuffer(frameRing.buffer, offset: d.morphOffset, index: Int(BufferIndexMorphWeights.rawValue))
            enc.setBuffer(d.mesh.morphDeltas ?? dummy, offset: 0, index: Int(BufferIndexMorphDeltas.rawValue))
            enc.setBuffer(d.mesh.morphNormals ?? dummy, offset: 0, index: Int(BufferIndexMorphNormals.rawValue))
            enc.setBytes(&params, length: MemoryLayout<DeformParams>.stride, index: Int(BufferIndexDeformParams.rawValue))
            let w = min(pipelines.deform.maxTotalThreadsPerThreadgroup, 64)
            enc.dispatchThreads(MTLSize(width: d.mesh.vertexCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        }
        enc.endEncoding()
    }

    private func bindCommon(_ enc: any MTLRenderCommandEncoder, _ ctx: FrameContext) {
        enc.setVertexBuffer(frameRing.buffer, offset: ctx.frameOffset, index: Int(BufferIndexFrameUniforms.rawValue))
        enc.setFragmentBuffer(frameRing.buffer, offset: ctx.frameOffset, index: Int(BufferIndexFrameUniforms.rawValue))
        enc.setFragmentBuffer(frameRing.buffer, offset: ctx.lightsOffset, index: Int(BufferIndexLights.rawValue))
        enc.setFragmentTexture(shadowMap, index: Int(TextureIndexShadowMap.rawValue))
        enc.setFrontFacing(.counterClockwise)
    }

    private func bindDraw(_ enc: any MTLRenderCommandEncoder, _ rec: DrawRecord) {
        enc.setVertexBuffer(rec.vertexBuffer, offset: 0, index: Int(BufferIndexVertices.rawValue))
        enc.setVertexBuffer(rec.mesh.texcoords, offset: 0, index: Int(BufferIndexTexcoords.rawValue))
        enc.setVertexBuffer(rec.mesh.colors ?? resources.dummyBuffer, offset: 0, index: Int(BufferIndexVertexColors.rawValue))
        enc.setVertexBuffer(frameRing.buffer, offset: rec.drawOffset, index: Int(BufferIndexDrawUniforms.rawValue))
        enc.setVertexBuffer(frameRing.buffer, offset: rec.materialOffset, index: Int(BufferIndexMaterial.rawValue))
        enc.setVertexBuffer(rec.hiddenBuffer ?? resources.dummyBuffer, offset: 0, index: Int(BufferIndexVertexHidden.rawValue))
        enc.setFragmentBuffer(frameRing.buffer, offset: rec.drawOffset, index: Int(BufferIndexDrawUniforms.rawValue))
        enc.setFragmentBuffer(frameRing.buffer, offset: rec.materialOffset, index: Int(BufferIndexMaterial.rawValue))
    }

    private func bindTextures(_ enc: any MTLRenderCommandEncoder, _ m: MaterialState) {
        let white = resources.whiteTexture, black = resources.blackTexture
        enc.setFragmentTexture(resources.texture(m.base) ?? white, index: Int(TextureIndexBase.rawValue))
        enc.setFragmentTexture(resources.texture(m.colorMask) ?? black, index: Int(TextureIndexColorMask.rawValue))
        let isEye = m.uniforms.kind == UInt32(MaterialKindEye.rawValue)
        enc.setFragmentTexture(resources.texture(m.detail) ?? (isEye ? black : white), index: Int(TextureIndexDetail.rawValue))
        enc.setFragmentTexture(resources.texture(m.line) ?? black, index: Int(TextureIndexLine.rawValue))
        enc.setFragmentTexture(resources.texture(m.normal) ?? resources.flatNormalTexture, index: Int(TextureIndexNormal.rawValue))
        enc.setFragmentTexture(resources.texture(m.overlay0) ?? black, index: Int(TextureIndexOverlay0.rawValue))
        enc.setFragmentTexture(resources.texture(m.overlay1) ?? black, index: Int(TextureIndexOverlay1.rawValue))
        enc.setFragmentTexture(resources.texture(m.overlay2) ?? black, index: Int(TextureIndexOverlay2.rawValue))
        enc.setFragmentTexture(resources.texture(m.hairGloss) ?? white, index: Int(TextureIndexHairGloss.rawValue))
        enc.setFragmentTexture(resources.texture(m.pattern) ?? white, index: Int(TextureIndexPattern.rawValue))
        enc.setFragmentTexture(resources.texture(m.bodyMask) ?? black, index: Int(TextureIndexBodyMask.rawValue))
    }

    private func drawIndexed(_ enc: any MTLRenderCommandEncoder, _ mesh: GPUMesh) {
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
    }

    private func encodeShadow(_ ctx: FrameContext, _ cb: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = shadowMap
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Shadow"
        if ctx.frame.mainLight.castsShadow {
            enc.setRenderPipelineState(pipelines.shadow)
            enc.setDepthStencilState(pipelines.depthWrite)
            enc.setCullMode(.none)
            enc.setDepthBias(1.0, slopeScale: 1.5, clamp: 0.01)
            bindCommon(enc, ctx)
            for rec in ctx.shadowCasters {
                bindDraw(enc, rec)
                enc.setFragmentTexture(resources.texture(rec.item.material.base) ?? resources.whiteTexture, index: Int(TextureIndexBase.rawValue))
                enc.setFragmentTexture(resources.texture(rec.item.material.bodyMask) ?? resources.blackTexture, index: Int(TextureIndexBodyMask.rawValue))
                drawIndexed(enc, rec.mesh)
            }
        }
        enc.endEncoding()
    }

    private func encodeMain(_ ctx: FrameContext, targets: RenderTargets, _ cb: any MTLCommandBuffer) {
        let fx = ctx.frame.effects
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.msaaColor
        pass.colorAttachments[0].resolveTexture = targets.hdr
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = fx.transparentBackground ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            : MTLClearColor(red: Double(fx.backgroundBottom.x), green: Double(fx.backgroundBottom.y), blue: Double(fx.backgroundBottom.z), alpha: 1)
        pass.depthAttachment.texture = targets.msaaDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 0
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Main"
        bindCommon(enc, ctx)

        if !fx.transparentBackground {
            enc.pushDebugGroup("Background")
            enc.setRenderPipelineState(pipelines.background)
            enc.setDepthStencilState(pipelines.depthNone)
            enc.setCullMode(.none)
            var bgFrame = FrameUniforms()
            bgFrame.ambientSky = Float4(fx.backgroundTop.x, fx.backgroundTop.y, fx.backgroundTop.z, 1)
            bgFrame.ambientGround = Float4(fx.backgroundBottom.x, fx.backgroundBottom.y, fx.backgroundBottom.z, 1)
            let off = frameRing.allocate(bgFrame)
            enc.setFragmentBuffer(frameRing.buffer, offset: off, index: Int(BufferIndexFrameUniforms.rawValue))
            enc.setFragmentBuffer(frameRing.buffer, offset: ctx.postOffset, index: Int(BufferIndexPostParams.rawValue))
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.setFragmentBuffer(frameRing.buffer, offset: ctx.frameOffset, index: Int(BufferIndexFrameUniforms.rawValue))
            enc.popDebugGroup()
        }
        if fx.showGrid {
            enc.pushDebugGroup("Grid")
            enc.setRenderPipelineState(pipelines.grid)
            enc.setDepthStencilState(pipelines.depthTest)
            enc.setCullMode(.none)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.popDebugGroup()
        }

        enc.pushDebugGroup("Opaque")
        let outlinesOn = fx.outlineWidth > 0.001
        for rec in ctx.opaque {
            let m = rec.item.material
            bindDraw(enc, rec)
            bindTextures(enc, m)
            if outlinesOn && rec.item.outline && (m.uniforms.flags & MaterialFlagNoOutline.rawValue) == 0 {
                enc.setRenderPipelineState(pipelines.outline)
                enc.setDepthStencilState(pipelines.depthWrite)
                enc.setCullMode(.front)
                drawIndexed(enc, rec.mesh)
            }
            enc.setRenderPipelineState(m.uniforms.kind == UInt32(MaterialKindEye.rawValue) ? pipelines.eye : pipelines.toonOpaque)
            enc.setDepthStencilState(pipelines.depthWrite)
            enc.setCullMode((m.uniforms.flags & MaterialFlagDoubleSided.rawValue) != 0 ? .none : .back)
            drawIndexed(enc, rec.mesh)
        }
        enc.popDebugGroup()

        if !ctx.transparent.isEmpty {
            enc.pushDebugGroup("Transparent")
            enc.setRenderPipelineState(pipelines.toonBlend)
            enc.setDepthStencilState(pipelines.depthTest)
            for rec in ctx.transparent {
                bindDraw(enc, rec)
                bindTextures(enc, rec.item.material)
                enc.setCullMode((rec.item.material.uniforms.flags & MaterialFlagDoubleSided.rawValue) != 0 ? .none : .back)
                drawIndexed(enc, rec.mesh)
            }
            enc.popDebugGroup()
        }

        let depthGizmos = ctx.frame.gizmos.filter { $0.depthTest && !$0.vertices.isEmpty }
        if !depthGizmos.isEmpty {
            enc.pushDebugGroup("GizmosDepth")
            enc.setRenderPipelineState(pipelines.gizmoHDR)
            enc.setDepthStencilState(pipelines.depthTest)
            enc.setCullMode(.none)
            encodeGizmos(enc, depthGizmos)
            enc.popDebugGroup()
        }
        enc.endEncoding()
    }

    private func encodeGizmos(_ enc: any MTLRenderCommandEncoder, _ batches: [GizmoBatch]) {
        for g in batches {
            let voff = frameRing.allocate(array: g.vertices)
            var du = DrawUniforms()
            du.model = g.model
            du.normalMatrix = matrix_identity_float4x4
            du.objectID = g.objectID
            let doff = frameRing.allocate(du)
            enc.setVertexBuffer(frameRing.buffer, offset: voff, index: Int(BufferIndexGizmoVertices.rawValue))
            enc.setVertexBuffer(frameRing.buffer, offset: doff, index: Int(BufferIndexDrawUniforms.rawValue))
            enc.setFragmentBuffer(frameRing.buffer, offset: doff, index: Int(BufferIndexDrawUniforms.rawValue))
            enc.drawPrimitives(type: g.primitive == .lines ? .line : .triangle, vertexStart: 0, vertexCount: g.vertices.count)
        }
    }

    private func fullscreen(_ cb: any MTLCommandBuffer, label: String, target: any MTLTexture, load: MTLLoadAction = .dontCare,
                            pipeline: any MTLRenderPipelineState, postOffset: Int, textures: [(any MTLTexture, TextureIndex)]) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = label
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBuffer(frameRing.buffer, offset: postOffset, index: Int(BufferIndexPostParams.rawValue))
        for (t, i) in textures { enc.setFragmentTexture(t, index: Int(i.rawValue)) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func encodePost(_ ctx: FrameContext, targets: RenderTargets, target: any MTLTexture, _ cb: any MTLCommandBuffer) {
        let fx = ctx.frame.effects
        let po = ctx.postOffset
        if fx.bloomEnabled {
            fullscreen(cb, label: "BloomThreshold", target: targets.bloom[0], pipeline: pipelines.bloomThreshold, postOffset: po, textures: [(targets.hdr, TextureIndexSceneColor)])
            for i in 0..<(targets.bloom.count - 1) {
                fullscreen(cb, label: "BloomDown\(i)", target: targets.bloom[i + 1], pipeline: pipelines.bloomDown, postOffset: po, textures: [(targets.bloom[i], TextureIndexSceneColor)])
            }
            for i in stride(from: targets.bloom.count - 2, through: 0, by: -1) {
                fullscreen(cb, label: "BloomUp\(i)", target: targets.bloom[i], load: .load, pipeline: pipelines.bloomUp, postOffset: po, textures: [(targets.bloom[i + 1], TextureIndexSceneColor)])
            }
        }
        let bloomTex = fx.bloomEnabled ? targets.bloom[0] : resources.blackTexture
        if fx.fxaa {
            fullscreen(cb, label: "Composite", target: targets.ldr, pipeline: pipelines.composite, postOffset: po, textures: [(targets.hdr, TextureIndexSceneColor), (bloomTex, TextureIndexBloom)])
            fullscreen(cb, label: "FXAA", target: target, pipeline: pipelines.fxaa, postOffset: po, textures: [(targets.ldr, TextureIndexSceneColor)])
        } else {
            fullscreen(cb, label: "Composite", target: target, pipeline: pipelines.composite, postOffset: po, textures: [(targets.hdr, TextureIndexSceneColor), (bloomTex, TextureIndexBloom)])
        }
    }

    private func encodeOverlay(_ ctx: FrameContext, targets: RenderTargets, target: any MTLTexture, _ cb: any MTLCommandBuffer) {
        let overlays = ctx.frame.gizmos.filter { !$0.depthTest && !$0.vertices.isEmpty }
        guard !overlays.isEmpty else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = targets.overlayDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 0
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Overlay"
        enc.setRenderPipelineState(pipelines.gizmoLDR)
        enc.setDepthStencilState(pipelines.depthWrite)
        enc.setCullMode(.none)
        enc.setVertexBuffer(frameRing.buffer, offset: ctx.frameOffset, index: Int(BufferIndexFrameUniforms.rawValue))
        encodeGizmos(enc, overlays)
        enc.endEncoding()
    }

    private func encodePick(_ ctx: FrameContext, targets: RenderTargets, _ cb: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.pick
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = targets.pickDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 0
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Pick"
        enc.setFrontFacing(.counterClockwise)
        enc.setVertexBuffer(frameRing.buffer, offset: ctx.frameOffset, index: Int(BufferIndexFrameUniforms.rawValue))
        enc.setRenderPipelineState(pipelines.pick)
        enc.setDepthStencilState(pipelines.depthWrite)
        enc.setCullMode(.none)
        for rec in ctx.opaque + ctx.transparent where rec.item.objectID != 0 {
            enc.setVertexBuffer(rec.vertexBuffer, offset: 0, index: Int(BufferIndexVertices.rawValue))
            enc.setVertexBuffer(frameRing.buffer, offset: rec.drawOffset, index: Int(BufferIndexDrawUniforms.rawValue))
            enc.setFragmentBuffer(frameRing.buffer, offset: rec.drawOffset, index: Int(BufferIndexDrawUniforms.rawValue))
            drawIndexed(enc, rec.mesh)
        }
        // Pickable gizmos draw on top (depth cleared so handles always win).
        let pickable = ctx.frame.gizmos.filter { $0.objectID != 0 && !$0.vertices.isEmpty }
        if !pickable.isEmpty {
            enc.setRenderPipelineState(pipelines.pickGizmo)
            enc.setDepthStencilState(pipelines.depthNone)
            encodeGizmos(enc, pickable)
        }
        enc.endEncoding()
    }
}
