import Foundation
import Metal
import CoreGraphics
import simd
import CoreMath
import GPU
import ShaderTypes

/// What the last prepared frame did with live source-shader items.
public struct SourceShaderLiveFrameReport: Sendable, Equatable {
    /// Items drawn with translated programs (one per material slot).
    public var draws = 0
    /// Items that carried a live draw but returned to their native toon draw
    /// at render time, with the reason.
    public var fallbacks: [String] = []
    public init() {}
}

extension Renderer {
    /// One live draw: the native draw record (also used by the shadow and pick
    /// passes), its live material, and its converted vertex input per layout.
    struct LiveRecord {
        let record: DrawRecord
        let draw: SourceShaderLiveDraw
        let inputs: [[UInt32]: any MTLBuffer]
        let jobs: [LiveInputJob]
    }

    /// One vertex-input conversion dispatch.
    struct LiveInputJob {
        let layout: [UInt32]
        let output: any MTLBuffer
        let mesh: GPUMesh
        let deformed: any MTLBuffer
        let skinBuffer: (any MTLBuffer)?
        let boneCount: Int
        /// The deformation's morph entries (nil for a static mesh).
        let morphs: FrameAllocation?
        let morphCount: Int
        let streams: SourceVertexStreams?
    }

    /// Splits live candidates into drawable live records and render-time
    /// fallbacks (returned to the native lists with a reason).
    func prepareLive(_ candidates: [DrawRecord], deforms: [DeformRecord],
                     report: inout SourceShaderLiveFrameReport, opaque: inout [DrawRecord], transparent: inout [DrawRecord]) -> [LiveRecord] {
        func fallBack(_ record: DrawRecord, _ reason: String) {
            report.fallbacks.append("\(record.item.sourceShader?.material.label ?? record.mesh.name): \(reason); drawn toon")
            if record.item.material.transparent { transparent.append(record) } else { opaque.append(record) }
        }
        if liveEncoder == nil, liveEncoderError == nil {
            do { liveEncoder = try SourceShaderLiveEncoder(device: gpu.device) }
            catch { liveEncoderError = "\(error)" }
        }
        guard let encoder = liveEncoder else {
            for record in candidates { fallBack(record, "live vertex-input kernel unavailable (\(liveEncoderError ?? "unknown"))") }
            return []
        }
        let deformByKey = Dictionary(deforms.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var records: [LiveRecord] = [], seen: [SourceShaderLiveEncoder.BufferKey: any MTLBuffer] = [:]
        for record in candidates {
            guard let draw = record.item.sourceShader else { continue }
            let mesh = record.mesh
            if let streams = draw.streams, streams.vertexCount != mesh.vertexCount {
                fallBack(record, "vertex streams have \(streams.vertexCount) vertices, mesh \(mesh.vertexCount)"); continue
            }
            let deform = record.item.deformKey.flatMap { mesh.needsDeform ? deformByKey[$0] : nil }
            if mesh.needsDeform && deform == nil { fallBack(record, "deformed mesh has no deformation this frame"); continue }
            // Converted inputs are keyed by the vertex source: a deformation
            // key (per character mesh instance) or the static mesh.
            let source = mesh.needsDeform ? (record.item.deformKey ?? 0) : (UInt64(1) << 63 | UInt64(record.item.mesh.id))
            var inputs: [[UInt32]: any MTLBuffer] = [:], jobs: [LiveInputJob] = [], failure: String?
            for program in draw.material.passes {
                guard let layout = SourceShaderLiveEncoder.layout(program) else { failure = "\(program.name) reads an unsupported vertex input"; break }
                // TEXCOORD3/COLOR come from the source mesh's stream record; a
                // channel the source mesh lacks is bound as the capture
                // fixture's default (UV3 zero, COLOR white), which the
                // assembly reports as a convention.
                if (layout.contains(6) || layout.contains(7)) && draw.streams == nil {
                    failure = "\(program.name) reads TEXCOORD3/COLOR and the mesh has no source vertex stream record"; break
                }
                // A converted mesh without UV1/UV2 aliases UV0: never bind
                // that as the source channel.
                if let set = [1, 2].first(where: { layout.contains(UInt32(3 + $0)) && SourceShaderLiveEncoder.uvSource(set: $0, mesh: mesh, streams: draw.streams) == nil }) {
                    failure = "\(program.name) reads TEXCOORD\(set); the converted mesh carries no UV\(set) (it would alias UV0) and there is no source vertex stream record"; break
                }
                if inputs[layout] != nil { continue }
                let key = SourceShaderLiveEncoder.BufferKey(vertices: source, layout: layout)
                if let existing = seen[key] { inputs[layout] = existing; continue }
                guard let output = encoder.inputBuffer(key, vertexCount: mesh.vertexCount) else { failure = "vertex input buffer allocation failed"; break }
                seen[key] = output; inputs[layout] = output
                jobs.append(LiveInputJob(layout: layout, output: output, mesh: mesh, deformed: record.vertexBuffer,
                                         skinBuffer: deform?.skinBuffer, boneCount: deform?.boneCount ?? 0,
                                         morphs: deform?.morphs, morphCount: deform?.morphCount ?? 0, streams: draw.streams))
            }
            if let failure { fallBack(record, failure); continue }
            records.append(LiveRecord(record: record, draw: draw, inputs: inputs, jobs: jobs))
        }
        report.draws = records.count
        // Source queue order (outline before forward inside a material, as the
        // probe), then character, then the binding set's renderer order. Unity's
        // per-queue distance sort is not reproduced (the probe's R1 rule).
        return records.sorted {
            if $0.draw.material.queue != $1.draw.material.queue { return $0.draw.material.queue < $1.draw.material.queue }
            if $0.record.item.objectID != $1.record.item.objectID { return $0.record.item.objectID < $1.record.item.objectID }
            return $0.draw.sourceOrder < $1.draw.sourceOrder
        }
    }

    func encodeLiveInputs(_ ctx: FrameContext, _ cb: any MTLCommandBuffer) {
        guard let encoder = liveEncoder, let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "SourceShaderLiveInputs"
        enc.setComputePipelineState(encoder.convert)
        let dummy = resources.dummyBuffer
        for job in ctx.live.flatMap(\.jobs) {
            var params = SourceShaderLiveEncoder.Params()
            params.vertexCount = UInt32(job.mesh.vertexCount); params.registerCount = UInt32(job.layout.count)
            params.hasSkin = job.skinBuffer != nil && job.mesh.skin != nil ? 1 : 0; params.boneCount = UInt32(job.boneCount)
            params.activeMorphCount = job.morphs != nil ? UInt32(job.morphCount) : 0; params.hasMorphNormals = job.mesh.morphNormals != nil ? 1 : 0
            params.hasUV3 = job.streams?.uv3 != nil ? 1 : 0; params.hasColors = job.streams?.colors != nil ? 1 : 0
            let uv1 = SourceShaderLiveEncoder.uvSource(set: 1, mesh: job.mesh, streams: job.streams) ?? .zero
            let uv2 = SourceShaderLiveEncoder.uvSource(set: 2, mesh: job.mesh, streams: job.streams) ?? .zero
            params.uv1Mode = uv1.rawValue; params.uv2Mode = uv2.rawValue
            withUnsafeMutableBytes(of: &params.semantics) { raw in
                let lanes = raw.bindMemory(to: UInt32.self)
                for (index, code) in job.layout.enumerated() { lanes[index] = code }
            }
            enc.setBuffer(job.mesh.baseVertices, offset: 0, index: 0)
            enc.setBuffer(job.deformed, offset: 0, index: 1)
            enc.setBuffer(job.mesh.skin ?? dummy, offset: 0, index: 2)
            enc.setBuffer(job.skinBuffer ?? dummy, offset: 0, index: 3)
            enc.setBuffer(job.morphs?.buffer ?? dummy, offset: job.morphs?.offset ?? 0, index: 4)
            enc.setBuffer(job.mesh.morphNormals ?? dummy, offset: 0, index: 5)
            enc.setBuffer(job.mesh.texcoords, offset: 0, index: 6)
            enc.setBuffer(uv1 == .stream ? job.streams?.uv1 ?? dummy : job.mesh.texcoords1, offset: 0, index: 7)
            enc.setBuffer(uv2 == .stream ? job.streams?.uv2 ?? dummy : job.mesh.texcoords2, offset: 0, index: 8)
            enc.setBuffer(job.streams?.uv3 ?? dummy, offset: 0, index: 9)
            enc.setBuffer(job.streams?.colors ?? dummy, offset: 0, index: 10)
            enc.setBuffer(job.output, offset: 0, index: 11)
            enc.setBytes(&params, length: MemoryLayout<SourceShaderLiveEncoder.Params>.stride, index: 12)
            let width = min(encoder.convert.maxTotalThreadsPerThreadgroup, 64)
            enc.dispatchThreads(MTLSize(width: job.mesh.vertexCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        }
        enc.endEncoding()
    }

    func liveFrameState(_ ctx: FrameContext) -> SourceShaderLiveEncoder.FrameState {
        let camera = ctx.frame.camera
        return SourceShaderLiveEncoder.FrameState(view: camera.viewMatrix(), projection: camera.projectionMatrix(aspect: Float(ctx.width) / Float(ctx.height)),
            cameraPosition: camera.position, lightDirection: ctx.frame.mainLight.direction(camera: camera),
            lightColor: ctx.frame.mainLight.color, lightIntensity: ctx.frame.mainLight.intensity,
            width: ctx.width, height: ctx.height, time: Float(ctx.frame.time.truncatingRemainder(dividingBy: 3600)))
    }

    /// Encodes the live draws (optionally one family set) for `target`.
    /// A draw that fails to encode is skipped and reported; it is never
    /// replaced by a different shader inside the live pass.
    func encodeLiveDraws(_ enc: any MTLRenderCommandEncoder, _ ctx: FrameContext, target: TranslatedSourceTarget, families: Set<String>? = nil) {
        guard let encoder = liveEncoder else { return }
        let state = liveFrameState(ctx)
        for live in ctx.live where families.map({ $0.contains(live.draw.material.family) }) ?? true {
            do {
                try encoder.encode(enc, draw: live.draw, mesh: live.record.mesh, model: live.record.item.model, inputs: live.inputs,
                                   target: target, state: state, cache: resources.translatedPipelines)
            } catch {
                lastSourceShaderLive.fallbacks.append("\(live.draw.material.label): live encode failed (\(error)); not drawn")
                lastSourceShaderLive.draws -= 1
            }
        }
    }
}

public extension Renderer {
    /// VALIDATION capture of the live path only: the frame's live draws
    /// (optionally one family set) in source queue order, rendered into the
    /// translated probe's target (8-bit sRGB, depth+stencil, no MSAA) with the
    /// live deformed vertices, camera and light. Native fallback items are not
    /// drawn. `clear` is the linear clear colour (alpha 0 keeps the
    /// comparator's alpha silhouette).
    func captureSourceShaderLive(frame: RenderFrame, width: Int, height: Int, families: Set<String>? = nil,
                                 clear: MTLClearColor = MTLClearColorMake(0, 0, 0, 0)) throws -> CGImage {
        guard (1...8192).contains(width), (1...8192).contains(height) else { throw RenderBenchmarkError.invalidConfiguration }
        gpu.waitForFrameSlot(); defer { gpu.releaseFrameSlot() }
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = .renderTarget; colorDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = .renderTarget; depthDescriptor.storageMode = .private
        guard let color = gpu.device.makeTexture(descriptor: colorDescriptor), let depth = gpu.device.makeTexture(descriptor: depthDescriptor),
              let cb = gpu.commandQueue.makeCommandBuffer() else { throw RendererError.textureCreationFailed }
        let targets = try RenderTargets(device: gpu.device, width: width, height: height)
        var failure: (any Error)?
        renderLockedLive {
            frameRingBegin()
            let ctx: FrameContext
            do { ctx = try prepare(frame: frame, targets: targets) } catch { failure = error; frameRing.abandonFrame(); return }
            guard lastDeformationErrors.isEmpty else { frameRing.abandonFrame(); return }
            encodeDeform(ctx, cb)
            if !ctx.live.isEmpty { encodeLiveInputs(ctx, cb) }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = clear
            pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 0
            pass.stencilAttachment.texture = depth; pass.stencilAttachment.loadAction = .clear; pass.stencilAttachment.storeAction = .dontCare; pass.stencilAttachment.clearStencil = 0
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { frameRing.abandonFrame(); failure = RenderFrameError.commandBufferUnavailable; return }
            enc.label = "SourceShaderLiveValidation"
            encodeLiveDraws(enc, ctx, target: .probe, families: families)
            enc.endEncoding()
            frameRing.endFrame(retainedUntilCompletionOf: cb)
            cb.commit()
        }
        if let failure { throw failure }
        guard lastDeformationErrors.isEmpty else { throw RenderBenchmarkError.deformation(lastDeformationErrors) }
        cb.waitUntilCompleted()
        guard cb.status == .completed else { throw RenderBenchmarkError.gpu(cb.error?.localizedDescription ?? "Command failed") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw RendererError.textureCreationFailed }
        return image
    }

    /// Geometry (`depthNormals: false`) or Unity depth-normals encoding of the
    /// frame's visible items with their LIVE deformed vertices — the same
    /// replacement passes `OriginalFrameProbe.captureGeometry` renders for
    /// frozen meshes, so `compare_original_frame.py` can gate a posed live
    /// character. `far` is the source camera far plane of the encoding.
    func captureSourceGeometry(frame: RenderFrame, width: Int, height: Int, depthNormals: Bool, far: Float) throws -> CGImage {
        guard (1...8192).contains(width), (1...8192).contains(height), far > 0 else { throw RenderBenchmarkError.invalidConfiguration }
        gpu.waitForFrameSlot(); defer { gpu.releaseFrameSlot() }
        let device = gpu.device
        let library = try device.makeLibrary(source: OriginalFrameProbe.diagnosticMSL + Self.liveGeometryMSL, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "live_probe_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: depthNormals ? "probe_depth_normals" : "probe_geometry")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm; descriptor.depthAttachmentPixelFormat = .depth32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = .renderTarget; colorDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = .renderTarget; depthDescriptor.storageMode = .private
        let stateDescriptor = MTLDepthStencilDescriptor(); stateDescriptor.depthCompareFunction = .greater; stateDescriptor.isDepthWriteEnabled = true
        guard let color = device.makeTexture(descriptor: colorDescriptor), let depth = device.makeTexture(descriptor: depthDescriptor),
              let depthState = device.makeDepthStencilState(descriptor: stateDescriptor), let cb = gpu.commandQueue.makeCommandBuffer() else { throw RendererError.textureCreationFailed }
        let targets = try RenderTargets(device: device, width: width, height: height)
        var failure: (any Error)?
        renderLockedLive {
            frameRingBegin()
            let ctx: FrameContext
            do { ctx = try prepare(frame: frame, targets: targets) } catch { failure = error; frameRing.abandonFrame(); return }
            guard lastDeformationErrors.isEmpty else { frameRing.abandonFrame(); return }
            encodeDeform(ctx, cb)
            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = depthNormals ? MTLClearColorMake(1, 1, 1, 1) : MTLClearColorMake(0, 0, 0, 1)
            pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 0
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { frameRing.abandonFrame(); failure = RenderFrameError.commandBufferUnavailable; return }
            enc.setRenderPipelineState(pipeline); enc.setDepthStencilState(depthState); enc.setCullMode(.back)
            var view = ctx.frame.camera.viewMatrix(), projection = ctx.frame.camera.projectionMatrix(aspect: Float(width) / Float(height)), farPlane = far
            enc.setVertexBytes(&view, length: MemoryLayout<float4x4>.stride, index: 1)
            enc.setVertexBytes(&projection, length: MemoryLayout<float4x4>.stride, index: 2)
            enc.setFragmentBytes(&farPlane, length: MemoryLayout<Float>.stride, index: 0)
            for record in ctx.opaque + ctx.transparent + ctx.live.map(\.record) {
                var model = record.item.model, normal = Transform.normalMatrix(from: record.item.model)
                enc.setFrontFacing(simd_determinant(model.upperLeft3x3) < 0 ? .clockwise : .counterClockwise)
                enc.setVertexBuffer(record.vertexBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&model, length: MemoryLayout<float4x4>.stride, index: 3)
                enc.setVertexBytes(&normal, length: MemoryLayout<float4x4>.stride, index: 4)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: record.mesh.indexCount, indexType: .uint32, indexBuffer: record.mesh.indices, indexBufferOffset: 0)
            }
            enc.endEncoding()
            frameRing.endFrame(retainedUntilCompletionOf: cb)
            cb.commit()
        }
        if let failure { throw failure }
        guard lastDeformationErrors.isEmpty else { throw RenderBenchmarkError.deformation(lastDeformationErrors) }
        cb.waitUntilCompleted()
        guard cb.status == .completed else { throw RenderBenchmarkError.gpu(cb.error?.localizedDescription ?? "Command failed") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { throw RendererError.textureCreationFailed }
        return image
    }

    /// Live counterpart of the probe's frozen-geometry vertex function: the
    /// deformed native vertex through the item's model and normal matrices,
    /// the per-vertex normal normalized in world space (Unity's
    /// `COMPUTE_VIEW_NORMAL`), then the same fragments.
    internal static let liveGeometryMSL = """

    struct LiveVertex { float4 position, normal, tangent; };
    vertex Out live_probe_vertex(uint index [[vertex_id]], device const LiveVertex *vertices [[buffer(0)]],
                                 constant float4x4 &view [[buffer(1)]], constant float4x4 &projection [[buffer(2)]],
                                 constant float4x4 &model [[buffer(3)]], constant float4x4 &normalMatrix [[buffer(4)]]) {
        Out out; float4 p = view * (model * float4(vertices[index].position.xyz, 1));
        out.position = projection * p; out.eyeDepth = -p.z;
        float3 n = normalize((normalMatrix * float4(vertices[index].normal.xyz, 0)).xyz);
        out.normal = float3x3(view[0].xyz, view[1].xyz, view[2].xyz) * n;
        return out;
    }
    """
}
