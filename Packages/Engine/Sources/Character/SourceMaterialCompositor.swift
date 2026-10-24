import Foundation
import Metal
import CoreMath
import Scene

/// The same recovered albedo equations have CPU and MSL implementations. The
/// Recipes explicitly select the measured source material color conversion.
/// Original texture filtering and full lighting remain separate contracts.
public enum SourceAppearanceCompositionBackend: Sendable { case cpu, metal }

/// Logical retained input pixel bytes for one Metal applying batch. This is not
/// Metal heap size or process RSS; each real upload and each first-time fallback
/// texel counts separately even when source pixels are reused.
enum SourceMaterialMetalInputBudget {
    static let defaultMaximumBytes = 128 * 1024 * 1024

    static func validateMaximumBytes(_ value: Int) throws {
        guard (0...defaultMaximumBytes).contains(value) else {
            throw RigError.invalid("Invalid Metal appearance input byte limit.")
        }
    }

    static func logicalBytes(width: Int, height: Int) throws -> Int {
        let pixels = width.multipliedReportingOverflow(by: height)
        guard (1...4096).contains(width), (1...4096).contains(height),
              !pixels.overflow, pixels.partialValue <= 4_194_304 else {
            throw RigError.invalid("Invalid bounded appearance texture.")
        }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard !bytes.overflow, bytes.partialValue > 0 else {
            throw RigError.invalid("Invalid bounded appearance texture.")
        }
        return bytes.partialValue
    }

    static func accumulate(_ total: inout Int, adding bytes: Int, maximum: Int) throws {
        let next = total.addingReportingOverflow(bytes)
        guard bytes >= 0, total >= 0, !next.overflow, next.partialValue <= maximum else {
            throw RigError.invalid("Composed appearance Metal inputs exceed \(maximum) bytes.")
        }
        total = next.partialValue
    }
}

struct SourceMaterialImage {
    let width: Int, height: Int, repeating: Bool, bytes: [UInt8]
}
struct SourceMaterialPattern {
    let channel: Int, image: SourceMaterialImage, color: Float4, tiling: Float2
}
struct SourceMaterialLayer {
    let kind: String, image: SourceMaterialImage, color: Float4
    let layout: Float4?, transform: [Float]?, mask: SourceMaterialImage?
}

final class SourceMaterialCompositor {
    let device: any MTLDevice, pipeline: any MTLComputePipelineState, queue: any MTLCommandQueue
    // Written only at creation, then bound read-only for this compositor's recipes.
    // Each optional is filled lazily; absent non-main slots all share zero.
    private var fallbackWhite: (any MTLTexture)?, fallbackZero: (any MTLTexture)?
    init(device: any MTLDevice) throws {
        self.device = device
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let library = try device.makeLibrary(source: Self.msl, options: options)
        guard let function = library.makeFunction(name: "source_material_compose"), let queue = device.makeCommandQueue() else {
            throw SourceCharacterCardError.invalid("Metal material compositor is unavailable.")
        }
        self.pipeline = try device.makeComputePipelineState(function: function); self.queue = queue
    }

    func makeBatch(maximumLogicalInputBytes: Int, timings: SourceAppearanceTimings?) throws -> SourceMaterialMetalBatch {
        try SourceMaterialMetalBatch(compositor: self, maximumLogicalInputBytes: maximumLogicalInputBytes, timings: timings)
    }

    fileprivate func fallbackTextureForBatch(white: Bool, logicalInputBytes: inout Int,
                                            maximum: Int, timings: SourceAppearanceTimings?) throws -> any MTLTexture {
        if let texture = white ? fallbackWhite : fallbackZero { return texture }
        try SourceMaterialMetalInputBudget.accumulate(&logicalInputBytes, adding: 4, maximum: maximum)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw SourceCharacterCardError.invalid("Unable to allocate source material input.")
        }
        timings?.recordInputAllocation(fallback: true)
        let bytes: [UInt8] = white ? [255, 255, 255, 255] : [0, 0, 0, 0]
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 4) }
        if white { fallbackWhite = texture } else { fallbackZero = texture }
        return texture
    }

    // Re-expressed from the recovered equations, with bounded texture indexing.
    // Manual bilinear reads make texel-center and wrap behavior identical to the
    // CPU reference without hardware sampler precision or mip derivatives.
    static let msl = #"""
    #include <metal_stdlib>
    using namespace metal;
    int coordinate(int n, int count, bool repeating) { return repeating ? ((n % count) + count) % count : clamp(n, 0, count - 1); }
    float4 sampleSource(texture2d<float, access::read> input, float2 uv, bool repeating) {
        int2 size = int2(input.get_width(), input.get_height());
        float2 point = float2(uv.x, 1 - uv.y) * float2(size) - 0.5f;
        int2 p = int2(floor(point)); float2 t = point - float2(p);
        int x0 = coordinate(p.x,size.x,repeating), x1 = coordinate(p.x+1,size.x,repeating);
        int y0 = coordinate(p.y,size.y,repeating), y1 = coordinate(p.y+1,size.y,repeating);
        float4 a = input.read(uint2(x0,y0)), b = input.read(uint2(x1,y0));
        float4 c = input.read(uint2(x0,y1)), d = input.read(uint2(x1,y1));
        float4 top = a + t.x * (b-a), bottom = c + t.x * (d-c);
        return top + t.y * (bottom-top);
    }
    kernel void source_material_compose(constant float4* p [[buffer(0)]],
        array<texture2d<float, access::read>,21> input [[texture(0)]],
        texture2d<float, access::write> output [[texture(21)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        float2 uv = float2((float(gid.x)+0.5f)/float(output.get_width()), 1-(float(gid.y)+0.5f)/float(output.get_height()));
        float4 main = sampleSource(input[0],uv,false), mask = sampleSource(input[1],uv,false);
        float4 colors[3] = {p[1],p[2],p[3]};
        for (uint i=0;i<3;++i) {
            float4 settings = p[5+i*2];
            if (settings.w != 0) {
                float red = sampleSource(input[2+i],uv*(20-19*settings.xy),settings.z!=0).x;
                float4 pattern = p[4+i*2]; float amount = max(red,1-pattern.w);
                colors[i].xyz = pattern.xyz + amount*(colors[i].xyz-pattern.xyz);
            }
        }
        int kind = int(p[0].x); float4 result = float4(1);
        if (kind == 0) result.xyz = main.xyz * max(float3(mask.z),(1+mask.x*(colors[0].xyz-1))*(1+mask.y*(colors[1].xyz-1)));
        else if (kind == 1) {
            float value=main.x; float3 nonlinear = value>0.5f ? colors[0].xyz/(2*(1-value)) : 1-(1-colors[0].xyz)/(2*value);
            nonlinear = select(clamp(nonlinear,0.0f,1.0f),float3(0),isnan(nonlinear));
            float3 product=colors[0].xyz*value;float alpha=main.w*colors[0].w;
            result=float4((product+p[0].z*(nonlinear-product))*alpha,alpha*alpha);
        } else if (kind == 2) result.xyz=colors[1].xyz+main.x*(colors[0].xyz-colors[1].xyz);
        else {
            float3 tint=1+mask.x*(colors[0].xyz-1);tint+=mask.y*(colors[1].xyz-tint);tint+=mask.z*(colors[2].xyz-tint);
            result=kind==4 ? float4(tint,1) : float4(clamp(main.xyz,0.0f,1.0f)*tint*main.w,main.w*main.w);
        }
        for (uint i=0;i<uint(p[0].y);++i) {
            uint start=10+i*4;float4 color=p[start],settings=p[start+1];float2 point=uv;
            if (settings.z!=0) {
                float4 layout=p[start+2];bool mole=settings.z==2;
                float2 offset=float2(.25f-.5f*layout.x,.3f-.6f*layout.y);
                float scale=mole ? .7f*layout.w : -8+8.7f*layout.w;
                point=(uv+offset-.5f)*(4*(1-scale));
                float angle=mole ? 0 : (1-2*layout.z)*6.283185f;float s=sin(angle),c=cos(angle);
                point=float2(point.x*c+point.y*s,-point.x*s+point.y*c)+.5f;
            } else if (settings.w!=0) {float4 transform=p[start+3];point=(uv+transform.xy-1)*(1-transform.zw)+.5f;}
            float attenuation=settings.y!=0 ? sampleSource(input[13+i],uv,false).x : 1;
            float4 layer=sampleSource(input[5+i],point,settings.x!=0);float amount=layer.w*color.w*attenuation;
            result=float4(result.xyz+amount*(layer.xyz*color.xyz-result.xyz),1);
        }
        if (p[0].w != 0) result.xyz = select(1.055f*pow(max(result.xyz,0.0f),float3(1.0f/2.4f))-.055f,
            result.xyz*12.92f,result.xyz<=.0031308f);
        output.write(clamp(result,0.0f,1.0f),gid);
    }
    """#
}

final class SourceMaterialMetalBatch {
    private let compositor: SourceMaterialCompositor
    private let maximumLogicalInputBytes: Int
    private let timings: SourceAppearanceTimings?
    private var logicalInputBytes = 0

    private struct PreparedRecipe {
        let parameters: [Float4]
        let inputs: [any MTLTexture]
        let output: any MTLTexture
        let width: Int
        let height: Int
    }
    private var prepared: [PreparedRecipe] = []

    init(compositor: SourceMaterialCompositor, maximumLogicalInputBytes: Int, timings: SourceAppearanceTimings?) throws {
        try SourceMaterialMetalInputBudget.validateMaximumBytes(maximumLogicalInputBytes)
        self.compositor = compositor
        self.maximumLogicalInputBytes = maximumLogicalInputBytes
        self.timings = timings
    }

    // All potentially throwing allocations finish before an encoder is opened.
    // PreparedRecipe retains every input and output until synchronous completion.
    func prepare(kind: SourceColorComposition.Kind, width: Int, height: Int,
                main: SourceMaterialImage?, mask: SourceMaterialImage?, colors: [Float4], blend: Float, encodeSRGB: Bool,
                patterns: [SourceMaterialPattern], layers: [SourceMaterialLayer]) throws {
        let allocStart = timings.map { _ in ProcessInfo.processInfo.systemUptime }
        let kinds: [SourceColorComposition.Kind] = [.head, .eye, .eyeWhite, .clothes, .hair]
        var parameters = [Float4](repeating: .zero, count: 1 + 3 + 3 * 2 + 8 * 4)
        parameters[0] = Float4(Float(kinds.firstIndex(of: kind)!), Float(layers.count), blend, encodeSRGB ? 1 : 0)
        for (index, color) in colors.enumerated() { parameters[1 + index] = color }
        var inputImages = [SourceMaterialImage?](repeating: nil, count: 21)
        inputImages[0] = main; inputImages[1] = mask
        for pattern in patterns {
            inputImages[2 + pattern.channel] = pattern.image
            parameters[4 + pattern.channel * 2] = pattern.color
            parameters[5 + pattern.channel * 2] = Float4(pattern.tiling.x, pattern.tiling.y, pattern.image.repeating ? 1 : 0, 1)
        }
        for (index, layer) in layers.enumerated() {
            inputImages[5 + index] = layer.image; inputImages[13 + index] = layer.mask
            let start = 10 + index * 4
            parameters[start] = layer.color
            parameters[start + 1] = Float4(layer.image.repeating ? 1 : 0, layer.mask == nil ? 0 : 1,
                                           layer.layout == nil ? 0 : layer.kind == "mole" ? 2 : 1,
                                           layer.transform == nil ? 0 : 1)
            parameters[start + 2] = layer.layout ?? .zero
            parameters[start + 3] = layer.transform.map(Float4.init) ?? .zero
        }
        var inputs: [any MTLTexture] = []
        for (index, optional) in inputImages.enumerated() {
            if let image = optional {
                let bytes = try SourceMaterialMetalInputBudget.logicalBytes(width: image.width, height: image.height)
                guard image.bytes.count == bytes else { throw RigError.invalid("Invalid bounded appearance texture.") }
                try SourceMaterialMetalInputBudget.accumulate(&logicalInputBytes, adding: bytes, maximum: maximumLogicalInputBytes)
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                    width: image.width, height: image.height, mipmapped: false)
                descriptor.storageMode = .shared; descriptor.usage = .shaderRead
                guard let texture = compositor.device.makeTexture(descriptor: descriptor) else {
                    throw SourceCharacterCardError.invalid("Unable to allocate source material input.")
                }
                timings?.recordInputAllocation(fallback: false)
                image.bytes.withUnsafeBytes {
                    texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: image.width * 4)
                }
                inputs.append(texture)
            } else {
                let texture = try compositor.fallbackTextureForBatch(white: index == 0,
                    logicalInputBytes: &logicalInputBytes, maximum: maximumLogicalInputBytes, timings: timings)
                timings?.recordFallbackBinding()
                inputs.append(texture)
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderWrite, .shaderRead, .pixelFormatView]
        guard let output = compositor.device.makeTexture(descriptor: descriptor) else {
            throw SourceCharacterCardError.invalid("Unable to allocate source material output.")
        }
        prepared.append(PreparedRecipe(parameters: parameters, inputs: inputs, output: output, width: width, height: height))
        if let allocStart {
            timings?.recordComposition(.allocationUpload, milliseconds: (ProcessInfo.processInfo.systemUptime - allocStart) * 1000)
        }
    }

    func complete() throws -> [any MTLTexture] {
        guard !prepared.isEmpty else { return [] }
        let encodeStart = timings.map { _ in ProcessInfo.processInfo.systemUptime }
        guard let buffer = compositor.queue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder() else {
            throw SourceCharacterCardError.invalid("Unable to allocate source material output.")
        }
        encoder.setComputePipelineState(compositor.pipeline)
        let groupWidth = compositor.pipeline.threadExecutionWidth
        for recipe in prepared {
            recipe.parameters.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
            for (index, texture) in recipe.inputs.enumerated() { encoder.setTexture(texture, index: index) }
            encoder.setTexture(recipe.output, index: 21)
            encoder.dispatchThreads(MTLSize(width: recipe.width, height: recipe.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: groupWidth,
                    height: max(1, min(8, compositor.pipeline.maxTotalThreadsPerThreadgroup / groupWidth)), depth: 1))
            timings?.recordMetalEncodeDispatch()
        }
        encoder.endEncoding()
        buffer.commit()
        if let encodeStart {
            let now = ProcessInfo.processInfo.systemUptime
            timings?.recordComposition(.encodeSubmit, milliseconds: (now - encodeStart) * 1000)
        }
        let waitStart = timings.map { _ in ProcessInfo.processInfo.systemUptime }
        buffer.waitUntilCompleted()
        timings?.recordMetalBatchCompletion()
        guard buffer.status == .completed else {
            throw SourceCharacterCardError.invalid(
                "Source material Metal dispatch failed: \(buffer.error?.localizedDescription ?? "command buffer failed").")
        }
        var views: [any MTLTexture] = []
        for recipe in prepared {
            guard let display = recipe.output.makeTextureView(pixelFormat: .rgba8Unorm_srgb) else {
                throw SourceCharacterCardError.invalid("Source material Metal dispatch failed: texture view unavailable.")
            }
            views.append(display)
        }
        if let waitStart {
            timings?.recordComposition(.waitAndView, milliseconds: (ProcessInfo.processInfo.systemUptime - waitStart) * 1000)
        }
        return views
    }
}
