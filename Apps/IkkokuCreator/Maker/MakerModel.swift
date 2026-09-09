import SwiftUI
import AppKit
import simd
import CoreMath
import Scene
import Renderer
import Character
import ShaderTypes

enum MakerTab: String, CaseIterable, Identifiable {
    case face = "Face", body = "Body", hair = "Hair", clothes = "Clothes", accessories = "Accessories", profile = "Profile"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .face: return "face.smiling"; case .body: return "figure.stand"; case .hair: return "comb"
        case .clothes: return "tshirt"; case .accessories: return "sparkles"; case .profile: return "person.text.rectangle"
        }
    }
}

enum CameraPreset: String, CaseIterable, Identifiable {
    case full = "Full", upper = "Upper", face = "Face"
    var id: String { rawValue }
}

/// Character Maker state: one character, an orbit camera, and the card being edited.
@MainActor @Observable
final class MakerModel: ViewportInputHandler {
    let host: EngineHost
    @ObservationIgnored let character: CharacterInstance
    var card: CharacterCard { didSet { character.card = card; refresh() } }
    var camera = OrbitCamera() { didSet { refresh() } }
    var effects = SceneEffects() { didSet { refresh() } }
    var mainLight = MainLight() { didSet { refresh() } }
    var tab: MakerTab = .face
    var showBones = false { didSet { refresh() } }
    var showGrid = true { didSet { effects.showGrid = showGrid } }
    var selectedAccessory = 0
    var viewportSize = SIMD2<Float>(1600, 1200)
    var lastLoadedURL: URL?
    var status = ""
    var liveAnimation = true { didSet { refresh() } }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startTime = CFAbsoluteTimeGetCurrent()

    init(host: EngineHost) {
        self.host = host
        let card = CharacterCard.defaultFemale()
        self.card = card
        self.character = CharacterInstance(instanceID: 1, library: host.library, card: card)
        self.effects.showGrid = true
        resetCamera()
        refresh()
        status = host.library.catalog.bodies.isEmpty ? "No catalog found at \(host.assetsRoot.path)" : "Loaded \(host.library.catalog.bodies.count) bodies"
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Idle animation tick (blink + breathing). Cheap: only rebuilds the frame when something moves.
    private func tick() {
        guard liveAnimation, isActiveMode else { return }
        let t = CFAbsoluteTimeGetCurrent() - startTime
        let blink = card.expression.blink ? LiveAnimation.blinkWeight(time: t, seed: 1) : 0
        character.extraMorphs = ["exp.blink_L": blink, "exp.blink_R": blink]
        character.poseDelta = LiveAnimation.breathing(time: t, seed: 1)
        character.stepHairDynamics(dt: 1.0 / 30.0)
        refresh()
    }
    /// Set by the app when the maker is the visible mode, so the timer is idle otherwise.
    var isActiveMode = true

    var library: AssetLibrary { host.library }

    // MARK: Frame

    func refresh() {
        switch card.expression.gazeMode {
        case 1: character.gazeTarget = camera.position
        case 2: character.gazeTarget = camera.position + Float3(0.9, 0.35, 0)
        case 3: character.gazeTarget = card.expression.gazeTarget
        default: character.gazeTarget = nil
        }
        let r = character.build(objectID: 1)
        var frame = RenderFrame(camera: camera, mainLight: mainLight, lights: [], items: r.items,
                                gizmos: showBones ? boneGizmos(r) : [], effects: effects, sceneBounds: r.bounds)
        frame.skinSets = [character.instanceID: r.skinSet]
        host.renderer.submit(frame)
    }

    private func boneGizmos(_ r: CharacterInstance.BuildResult) -> [GizmoBatch] {
        guard let skel = character.skeleton else { return [] }
        let root = character.rootMatrix
        var verts: [GizmoVertex] = []
        for (i, b) in skel.bones.enumerated() where i < r.worldMatrices.count {
            let p = (root * r.worldMatrices[i]).translation
            let color = SIMD4<Float>(0.2, 0.9, 1.0, 1)
            if let pi = b.parent {
                let pp = (root * r.worldMatrices[pi]).translation
                verts.append(GizmoVertex(position: pp, color: color))
                verts.append(GizmoVertex(position: p, color: color))
            }
        }
        return [GizmoBatch(primitive: .lines, vertices: verts, depthTest: false)]
    }

    // MARK: Commands

    func newCharacter(sex: Sex) {
        card = sex == .female ? .defaultFemale() : .defaultMale()
        resetCamera()
    }

    func load(card: CharacterCard) { self.card = card }

    func saveCard(to url: URL) throws {
        var frame = host.renderer.currentFrame()
        frame.effects.showGrid = false
        // Card thumbnails frame the face and upper body, like Koikatsu cards.
        var cam = camera
        cam.fovDegrees = 26
        cam.target = Float3(0, character.eyeHeight - 0.27, 0)
        cam.distance = character.height * 0.86
        cam.pitch = 0.04
        frame.camera = cam
        let thumb = host.renderer.capture(frame: frame, width: 504, height: 704)
        let data = try CardIO.encode(card, keyword: CardIO.cardKeyword, thumbnail: thumb)
        try data.write(to: url)
        lastLoadedURL = url
        status = "Saved \(url.lastPathComponent)"
    }

    func apply(preset: SliderPreset) {
        var c = card
        if preset.tab == .face { c.face.sliders = preset.values } else { c.body.sliders = preset.values }
        card = c
    }

    func resetSliders(tab: SliderTab) {
        if tab == .face { card.face.sliders = [:] } else { card.body.sliders = [:] }
    }

    func randomize() {
        var c = card
        var rng = SystemRandomNumberGenerator()
        for def in SliderRegistry.shared.sliders {
            let v = Float.random(in: -55...55, using: &rng)
            if def.tab == .face { c.face.sliders[def.id] = v } else { c.body.sliders[def.id] = v }
        }
        let hairs = library.catalog.hair(for: c.sex)
        if let h = hairs.randomElement(using: &rng) { c.hair.parts[.back] = HairPart(styleID: h.id) }
        let palette: [RGB] = [RGB(hex: 0x3B2A2A), RGB(hex: 0x6A4A3F), RGB(hex: 0xC48A5A), RGB(hex: 0xE8C9A0), RGB(hex: 0x2E2E48),
                              RGB(hex: 0x7A3E5C), RGB(hex: 0xB5485A), RGB(hex: 0x4C7A9D), RGB(hex: 0x5D8C6E), RGB(hex: 0xF2E6D8)]
        let base = palette.randomElement(using: &rng)!
        c.hair.baseColor = base
        c.hair.shadeColor = base.scaled(0.6)
        c.hair.highlightColor = base.mixed(.white, 0.7)
        c.hair.outlineColor = base.scaled(0.35)
        let eyes: [RGB] = [RGB(hex: 0x4E8FD9), RGB(hex: 0x5C4A3C), RGB(hex: 0x3E9A6B), RGB(hex: 0xC85A7A), RGB(hex: 0x8D6BC7), RGB(hex: 0xD9A34E)]
        let e = eyes.randomElement(using: &rng)!
        c.face.irisColorLeft = e; c.face.irisColorRight = e
        for slot in [ClothSlot.top, .bottom, .socks, .shoesIn] {
            let opts = library.catalog.clothes(slot: slot.rawValue, sex: c.sex)
            if let o = opts.randomElement(using: &rng) {
                var item = c.outfit.items[slot] ?? ClothItem()
                item.itemID = o.id
                c.outfit.items[slot] = item
            }
        }
        card = c
    }

    // MARK: Camera

    func resetCamera() { apply(preset: .full) }

    func apply(preset: CameraPreset) {
        var cam = camera
        let h = character.height, eye = character.eyeHeight
        switch preset {
        case .full: cam.target = Float3(0, h * 0.53, 0); cam.distance = h * 1.85; cam.fovDegrees = 30
        case .upper: cam.target = Float3(0, eye - h * 0.17, 0); cam.distance = h * 0.95; cam.fovDegrees = 28
        case .face: cam.target = Float3(0, eye - 0.03, 0.03); cam.distance = h * 0.42; cam.fovDegrees = 24
        }
        cam.yaw = 0; cam.pitch = 0.03
        camera = cam
    }

    // MARK: ViewportInputHandler

    private var dragButton = -1
    func mouseDown(at p: SIMD2<Float>, button: Int, modifiers: NSEvent.ModifierFlags) { dragButton = button }
    func mouseDragged(to p: SIMD2<Float>, delta: SIMD2<Float>, button: Int, modifiers: NSEvent.ModifierFlags) {
        var cam = camera
        if button == 0 && !modifiers.contains(.shift) && !modifiers.contains(.option) {
            cam.orbit(dx: delta.x * 0.005, dy: delta.y * 0.005)
        } else {
            cam.pan(dx: delta.x, dy: delta.y)
        }
        camera = cam
    }
    func mouseUp(at p: SIMD2<Float>, button: Int, modifiers: NSEvent.ModifierFlags) { dragButton = -1 }
    func mouseMoved(to p: SIMD2<Float>) {}
    func scrolled(delta: SIMD2<Float>, modifiers: NSEvent.ModifierFlags) {
        var cam = camera
        if modifiers.contains(.shift) { cam.pan(dx: -delta.x * 4, dy: delta.y * 4) } else { cam.dolly(delta.y * 0.5) }
        camera = cam
    }
    func magnified(by amount: Float) { var cam = camera; cam.dolly(amount * 10); camera = cam }
    func keyDown(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers {
        case "f": apply(preset: .face); return true
        case "b": apply(preset: .full); return true
        case "u": apply(preset: .upper); return true
        default: return false
        }
    }
}
