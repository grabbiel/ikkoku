import Foundation
import Metal
import CoreGraphics
import CoreMath
import simd

public extension OriginalFrameProbe {
    /// Geometry-only raster comparison. Matches Unity's Unlit/Color and built-in
    /// depth-normal replacement passes: ignores alpha masks, stencil and outline.
    /// Uses the same imported frozen pose as `frame`, not a second evaluator.
    func captureGeometry(resources: ResourceStore, queue: any MTLCommandQueue, depthNormals: Bool) throws -> CGImage {
        let device = resources.device
        let library = try device.makeLibrary(source: Self.diagnosticMSL, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "probe_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: depthNormals ? "probe_depth_normals" : "probe_geometry")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm; descriptor.depthAttachmentPixelFormat = .depth32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget]; colorDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = .renderTarget; depthDescriptor.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDescriptor), let depth = device.makeTexture(descriptor: depthDescriptor),
              let command = queue.makeCommandBuffer() else { throw ProbeError.gpu("Diagnostic targets") }
        let stateDescriptor = MTLDepthStencilDescriptor(); stateDescriptor.depthCompareFunction = .greater; stateDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: stateDescriptor) else { throw ProbeError.gpu("Diagnostic depth state") }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = depthNormals ? MTLClearColorMake(1, 1, 1, 1) : MTLClearColorMake(0, 0, 0, 1)
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 0
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw ProbeError.gpu("Diagnostic encoder") }
        var endedEncoding = false
        defer { if !endedEncoding { encoder.endEncoding() } }
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState)
        encoder.setFrontFacing(.counterClockwise); encoder.setCullMode(.back)
        var view = frame.camera.viewMatrix(); var projection = frame.camera.projectionMatrix(aspect: Float(width) / Float(height))
        var far = sourceFar
        encoder.setVertexBytes(&view, length: MemoryLayout<float4x4>.stride, index: 1)
        encoder.setVertexBytes(&projection, length: MemoryLayout<float4x4>.stride, index: 2)
        encoder.setFragmentBytes(&far, length: MemoryLayout<Float>.stride, index: 0)
        for item in frame.items {
            guard let mesh = resources.mesh(item.mesh), !mesh.needsDeform else { throw ProbeError.invalid("Expected frozen source geometry") }
            encoder.setVertexBuffer(mesh.baseVertices, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        }
        encoder.endEncoding(); endedEncoding = true; command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw ProbeError.gpu(error.localizedDescription) }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ProbeError.gpu("Diagnostic image") }
        return image
    }

    private static let diagnosticMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position, normal, tangent; };
    struct Out { float4 position [[position]]; float3 normal; float eyeDepth; };
    vertex Out probe_vertex(uint index [[vertex_id]], device const Vertex *vertices [[buffer(0)]],
                           constant float4x4 &view [[buffer(1)]], constant float4x4 &projection [[buffer(2)]]) {
        Out out; float4 p = view * float4(vertices[index].position.xyz, 1);
        out.position = projection * p; out.eyeDepth = -p.z;
        out.normal = float3x3(view[0].xyz, view[1].xyz, view[2].xyz) * vertices[index].normal.xyz;
        return out;
    }
    fragment float4 probe_geometry(Out in [[stage_in]]) { return float4(1); }
    fragment float4 probe_depth_normals(Out in [[stage_in]], constant float &far [[buffer(0)]]) {
        // Original Unity 5.6 Internal-DepthNormalsTexture DXBC encodes the
        // interpolated vertex normal directly; renormalizing here changes the
        // reference on curved triangles (confirmed against the source program).
        float3 n = in.normal;
        float2 encodedNormal = n.xy / (n.z + 1.0) / 1.7777 * 0.5 + 0.5;
        float2 depth = fract(in.eyeDepth / far * float2(1.0, 255.0));
        depth.x -= depth.y / 255.0;
        return float4(encodedNormal, depth);
    }
    """
}
