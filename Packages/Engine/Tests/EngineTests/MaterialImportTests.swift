import Testing
import Assets
@testable import Character
import Renderer
import ShaderTypes

@Test func importedMaskPreservesCutoffAndSidednessAcrossToonKinds() {
    for kind in [MaterialKindSkin, MaterialKindHair, MaterialKindCloth, MaterialKindEye, MaterialKindEyelash, MaterialKindItem] {
        var state = MaterialState(uniforms: .make(kind: kind))
        let source = MaterialData(name: "source", alphaMode: "MASK", alphaCutoff: 0.23, doubleSided: true)
        MaterialBuilder.applySurfaceProperties(source, to: &state)
        #expect(state.uniforms.params.w == 0.23)
        #expect(state.uniforms.flags & MaterialFlagAlphaTest.rawValue != 0)
        #expect(state.uniforms.flags & MaterialFlagAlphaBlend.rawValue == 0)
        #expect(state.uniforms.flags & MaterialFlagDoubleSided.rawValue != 0)
        #expect(!state.transparent)
        #expect(state.uniforms.kind == UInt32(kind.rawValue))
    }
}

@Test func importedBlendIsTransparentWithoutHardAlphaCutoff() {
    var state = MaterialState(uniforms: .make(kind: MaterialKindEyelash))
    MaterialBuilder.applySurfaceProperties(MaterialData(name: "source", alphaMode: "BLEND"), to: &state)
    #expect(state.transparent)
    #expect(state.uniforms.flags & MaterialFlagAlphaBlend.rawValue != 0)
    #expect(state.uniforms.flags & MaterialFlagAlphaTest.rawValue == 0)
    #expect(state.uniforms.flags & MaterialFlagDoubleSided.rawValue == 0)
    #expect(state.uniforms.flags & MaterialFlagNoOutline.rawValue != 0)
}

@Test func importedOpaqueOverridesCategoryAlphaDefaultsWithoutChangingStyle() {
    var state = MaterialState(uniforms: .make(kind: MaterialKindEyelash))
    let color = state.uniforms.baseColor
    let outline = state.uniforms.outline
    MaterialBuilder.applySurfaceProperties(MaterialData(name: "source"), to: &state)
    #expect(!state.transparent)
    #expect(state.uniforms.flags & MaterialFlagAlphaTest.rawValue == 0)
    #expect(state.uniforms.flags & MaterialFlagAlphaBlend.rawValue == 0)
    #expect(state.uniforms.flags & MaterialFlagDoubleSided.rawValue == 0)
    #expect(state.uniforms.baseColor == color)
    #expect(state.uniforms.outline == outline)
    #expect(state.uniforms.flags & MaterialFlagNoOutline.rawValue != 0)
}
