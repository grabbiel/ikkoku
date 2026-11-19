import Metal
import ShaderTypes
@testable import Renderer

// ST-A11 maps, slice 5: map_fragment reads FrameUniforms (the view vector),
// MapLightingUniforms and the map shadow map besides the slice 2-4 inputs.
// Test draws that build toon_vertex + map_fragment by hand bind them here.
// The defaults keep the older branches' output: no sun (sunDirection.w 0), no
// probe ambient flag, and a 1×1 depth placeholder that nothing samples.

/// A 1×1 depth32Float texture for TextureIndexMapShadow.
func mapShadowPlaceholder(_ device: any MTLDevice) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1, mipmapped: false)
    descriptor.usage = .shaderRead; descriptor.storageMode = .private
    guard let texture = device.makeTexture(descriptor: descriptor) else { throw MapLightingTestError.noTexture }
    return texture
}

enum MapLightingTestError: Error { case noTexture }

/// Binds map_fragment's slice-5 inputs on `encoder`.
func bindMapLighting(_ encoder: any MTLRenderCommandEncoder, frame: FrameUniforms, lighting: MapLightingUniforms = MapLightingUniforms(),
                     shadow: any MTLTexture) {
    var frame = frame, lighting = lighting
    encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Int(BufferIndexFrameUniforms.rawValue))
    encoder.setFragmentBytes(&lighting, length: MemoryLayout<MapLightingUniforms>.stride, index: Int(BufferIndexMapLighting.rawValue))
    encoder.setFragmentTexture(shadow, index: Int(TextureIndexMapShadow.rawValue))
}
