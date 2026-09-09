import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Character
import CoreMath
import simd
import Scene
import Studio
import Renderer

enum AppMode: String, CaseIterable, Identifiable {
    case maker = "Maker", studio = "Studio"
    var id: String { rawValue }
}

/// Top-level app state: the engine, the two editors and document commands.
@MainActor @Observable
final class AppState {
    var mode: AppMode = .maker { didSet { maker?.isActiveMode = mode == .maker; studio?.isActiveMode = mode == .studio } }
    let host: EngineHost?
    var maker: MakerModel?
    var studio: StudioModel?
    var errorMessage: String?
    nonisolated(unsafe) static var sharedStudio: StudioModel?

    init() {
        do {
            let host = try EngineHost()
            self.host = host
            self.maker = MakerModel(host: host)
            self.studio = StudioModel(host: host)
            AppState.sharedStudio = studio
            AppState.uiCaptureState = self
            AppState.runAutoCapture(host: host, maker: maker)
        } catch {
            self.host = nil
            self.errorMessage = "\(error)"
        }
    }

    /// Development aid: IKKOKU_AUTOCAPTURE=<png path> renders the maker scene offscreen and exits.
    /// IKKOKU_CAPTURE_PRESET=face|upper|full picks the camera; IKKOKU_CARD=<png> loads a card first.
    static func runAutoCapture(host: EngineHost, maker: MakerModel?) {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["IKKOKU_RENDER_THUMBS"], let maker { renderThumbnails(host: host, maker: maker, dir: URL(fileURLWithPath: dir)); exit(0) }
        guard let out = env["IKKOKU_AUTOCAPTURE"], let maker else { return }
        if let cardPath = env["IKKOKU_CARD"], let data = try? Data(contentsOf: URL(fileURLWithPath: cardPath)),
           let card = try? CardIO.decode(CharacterCard.self, keyword: CardIO.cardKeyword, from: data) { maker.load(card: card) }
        if env["IKKOKU_CAPTURE_SEX"] == "m" { maker.newCharacter(sex: .male) }
        if let sl = env["IKKOKU_CAPTURE_SLIDERS"] {          // "eye.size=80,body.height=-50"
            var c = maker.card
            for pair in sl.split(separator: ",") {
                let kv = pair.split(separator: "="); if kv.count == 2, let v = Float(kv[1]) { c.setSlider(String(kv[0]), v) }
            }
            maker.card = c
        }
        if let ex = env["IKKOKU_CAPTURE_EXPR"] {              // "eyes=1,mouth=3,brows=2"
            var c = maker.card
            for pair in ex.split(separator: ",") {
                let kv = pair.split(separator: "="); guard kv.count == 2, let v = Int(kv[1]) else { continue }
                switch kv[0] { case "eyes": c.expression.eyes = v; case "mouth": c.expression.mouth = v; case "brows": c.expression.eyebrows = v
                case "head": c.expression.headLook = v != 0; case "gaze": c.expression.gazeMode = v; default: break }
            }
            maker.card = c
        }
        if let o = env["IKKOKU_CAPTURE_OUTFIT"], let i = Int(o) { maker.card.currentOutfit = i }
        if let hair = env["IKKOKU_CAPTURE_HAIR"] { maker.card.hair.parts[.back] = HairPart(styleID: hair) }
        if let preset = env["IKKOKU_CAPTURE_PRESET"].flatMap({ CameraPreset(rawValue: $0.capitalized) }) { maker.apply(preset: preset) }
        if let yaw = env["IKKOKU_CAPTURE_YAW"].flatMap({ Float($0) }) { var c = maker.camera; c.yaw = yaw * .pi / 180; maker.camera = c }
        if let ticks = Int(env["IKKOKU_CAPTURE_TICKS"] ?? "") {      // advance idle/hair simulation
            for i in 0..<ticks {
                // nudge the head sideways for a few ticks so hair chains get a push
                var c = maker.camera; c.target.x = i < ticks / 2 ? 0.05 : -0.05; maker.camera = c
                maker.character.transform = Transform.translation(Float3(sin(Float(i) * 0.4) * 0.15, 0, 0))
                maker.character.stepHairDynamics(dt: 1.0 / 30.0)
            }
            maker.character.transform = matrix_identity_float4x4
            maker.refresh()
        }
        let w = Int(env["IKKOKU_CAPTURE_W"] ?? "") ?? 1200, h = Int(env["IKKOKU_CAPTURE_H"] ?? "") ?? 1600
        var frame = host.renderer.currentFrame()
        if env["IKKOKU_CAPTURE_STUDIO"] != nil, let studio = AppState.sharedStudio {
            studio.addCharacter(maker.card)
            if let pose = env["IKKOKU_CAPTURE_POSE"], let id = studio.selection { studio.update(id) { $0.animationPreset = pose; $0.handGestureL = 4; $0.handGestureR = 2 } }
            if let items = env["IKKOKU_CAPTURE_ITEMS"] {           // "chair,room_classroom"
                for (k, id) in items.split(separator: ",").enumerated() {
                    studio.addItem(id: String(id))
                    if let sel = studio.selection, !String(id).hasPrefix("room"), !String(id).hasPrefix("sky") {
                        studio.update(sel) { $0.transform.position = Float3(0.9 + Float(k) * 0.8, 0, -0.3) }
                    }
                }
                if let first = studio.doc.objects.first { studio.selection = first.id }
            }
            if env["IKKOKU_CAPTURE_TIMELINE"] != nil, let id = studio.selection {
                studio.update(id) { $0.animationPreset = "apose"; $0.transform.position = Float3(-0.4, 0, 0) }
                studio.timelineTime = 0; studio.addKeyframe()
                studio.update(id) { $0.animationPreset = "wave"; $0.transform.position = Float3(0.4, 0, 0); $0.transform.rotation = Float3(0, 40, 0) }
                studio.timelineTime = 2; studio.addKeyframe()
                studio.timelineTime = Float(env["IKKOKU_CAPTURE_TIMELINE"] ?? "1") ?? 1
            }
            studio.addLight(.point)
            if let id = studio.doc.objects.first?.id { studio.selection = id; studio.poseMode = .fk; studio.selectedBone = studio.selectedInstance?.skeleton?["upperarm_L"] }
            studio.doc.camera.yaw = 0.4; studio.doc.camera.pitch = 0.15
            studio.refresh()
            frame = studio.frame
        }
        if let savePath = env["IKKOKU_SAVE_CARD"] {                 // exercise the real card writer (thumbnail + JSON)
            do { try maker.saveCard(to: URL(fileURLWithPath: savePath)); print("[ikkoku] card saved to \(savePath)") }
            catch { print("[ikkoku] card save failed: \(error)") }
        }
        if let scenePath = env["IKKOKU_SAVE_SCENE"], let studio = AppState.sharedStudio {
            do { try studio.saveScene(to: URL(fileURLWithPath: scenePath)); print("[ikkoku] scene saved to \(scenePath)") }
            catch { print("[ikkoku] scene save failed: \(error)") }
        }
        if let scenePath = env["IKKOKU_LOAD_SCENE"], let studio = AppState.sharedStudio {
            do { try studio.loadScene(from: URL(fileURLWithPath: scenePath)); frame = studio.frame; print("[ikkoku] scene loaded: \(studio.doc.objects.count) objects") }
            catch { print("[ikkoku] scene load failed: \(error)") }
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        if let img = host.renderer.capture(frame: frame, width: w, height: h) {
            try? ImageIO.writePNG(img, to: URL(fileURLWithPath: out))
            print("[ikkoku] autocapture written to \(out) (\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms, \(frame.items.count) items)")
        } else { print("[ikkoku] autocapture failed") }
        if env["IKKOKU_CAPTURE_UI"] != nil {
            // Real window snapshot after layout; handled by `snapshotWindowIfRequested` once the window exists.
            for line in host.library.log { print("[ikkoku] \(line)") }
            return
        }
        for line in host.library.log { print("[ikkoku] \(line)") }
        exit(0)
    }
    nonisolated(unsafe) static var uiCaptureState: AppState?

    /// `IKKOKU_RENDER_THUMBS=<dir>`: renders one 256×256 preview per catalog entry (hair, clothes, accessories, items).
    static func renderThumbnails(host: EngineHost, maker: MakerModel, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cat = host.library.catalog
        let base = CharacterCard.defaultFemale()
        var plain = base
        plain.hair.parts = [:]
        for i in plain.outfits.indices { plain.outfits[i].items = [:] }
        plain.outfits[0].items[.bra] = ClothItem(itemID: "bra_plain"); plain.outfits[0].items[.underwear] = ClothItem(itemID: "underwear_plain")
        plain.accessories = (0..<20).map { _ in AccessoryDefinition() }
        // Hair
        for h in cat.hair {
            var c = plain
            c.sex = (h.sex == "m") ? .male : .female; c.body.bodyID = c.sex == .male ? "body_m" : "body_f"
            c.hair.parts = [.back: HairPart(styleID: h.id)]
            maker.card = c
            maker.apply(preset: .face)
            var cam = maker.camera; cam.yaw = 22 * .pi / 180; cam.pitch = 0.08; cam.target = Float3(0, maker.character.eyeHeight - 0.02, 0); cam.distance *= 1.9; maker.camera = cam
            var f = host.renderer.currentFrame(); f.effects.showGrid = false
            if let img = host.renderer.capture(frame: f, width: 256, height: 256) { try? ImageIO.writePNG(img, to: dir.appendingPathComponent("hair_\(h.id).png")) }
        }
        // Clothes
        for cl in cat.clothes {
            var c = plain
            c.sex = (cl.sex == "m") ? .male : .female; c.body.bodyID = c.sex == .male ? "body_m" : "body_f"
            if let slot = ClothSlot(rawValue: cl.slot) { c.outfits[0].items[slot] = ClothItem(itemID: cl.id) }
            maker.card = c
            let lower = ["bottom", "socks", "shoes_in", "shoes_out", "pantyhose", "underwear"].contains(cl.slot)
            let hands = cl.slot == "gloves"
            maker.apply(preset: .full)
            var cam = maker.camera
            cam.yaw = 18 * .pi / 180
            if lower { cam.target = Float3(0, 0.5, 0); cam.distance *= 0.55 } else if hands { cam.target = Float3(0.38, 0.95, 0); cam.distance *= 0.32 } else { cam.target = Float3(0, 1.15, 0); cam.distance *= 0.6 }
            maker.camera = cam
            var f = host.renderer.currentFrame(); f.effects.showGrid = false
            if let img = host.renderer.capture(frame: f, width: 256, height: 256) { try? ImageIO.writePNG(img, to: dir.appendingPathComponent("cloth_\(cl.id).png")) }
        }
        // Accessories
        for a in cat.accessories {
            var c = plain
            c.hair.parts = [.back: HairPart(styleID: "bob")]
            c.accessories[0] = AccessoryDefinition(itemID: a.id)
            if let p = a.parent { c.accessories[0].parent = p }
            maker.card = c
            maker.apply(preset: .face)
            var cam = maker.camera; cam.yaw = 28 * .pi / 180; cam.pitch = 0.12; cam.target = Float3(0, maker.character.eyeHeight, 0); cam.distance *= 1.7; maker.camera = cam
            var f = host.renderer.currentFrame(); f.effects.showGrid = false
            if let img = host.renderer.capture(frame: f, width: 256, height: 256) { try? ImageIO.writePNG(img, to: dir.appendingPathComponent("acc_\(a.id).png")) }
        }
        // Items: a static prop alone in the frame
        for it in cat.items {
            guard let asset = host.library.asset(it.file) else { continue }
            var items: [RenderItem] = []
            var bounds = AABB.empty
            for part in asset.parts {
                items.append(RenderItem(mesh: part.mesh, material: MaterialBuilder.itemMaterial(for: part, asset: asset, tint: nil), model: part.worldMatrix, objectID: 1))
                bounds.expand(part.bounds.transformed(by: part.worldMatrix))
            }
            var cam = OrbitCamera()
            cam.target = bounds.center; cam.distance = max(bounds.radius, 0.2) * 2.6; cam.yaw = 0.6; cam.pitch = 0.35
            var fx = SceneEffects(); fx.showGrid = it.category != "Rooms" && it.category != "Sky"
            var f = RenderFrame(camera: cam, items: items, effects: fx, sceneBounds: bounds)
            if it.category == "Sky" || it.category == "Rooms" { cam.distance = max(bounds.radius, 0.2) * 0.9; f.camera = cam }
            if let img = host.renderer.capture(frame: f, width: 256, height: 256) { try? ImageIO.writePNG(img, to: dir.appendingPathComponent("item_\(it.id).png")) }
        }
        print("[ikkoku] thumbnails written to \(dir.path)")
    }

    /// `IKKOKU_CAPTURE_UI=<png>`: snapshot the main window's AppKit/SwiftUI content (no screen-recording permission needed), then quit.
    func snapshotWindowIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["IKKOKU_CAPTURE_UI"] else { return }
        if let tab = env["IKKOKU_CAPTURE_UI_TAB"].flatMap({ MakerTab(rawValue: $0.capitalized) }) { maker?.tab = tab }
        if env["IKKOKU_CAPTURE_UI_MODE"] == "studio" {
            mode = .studio
            if let studio, studio.doc.objects.isEmpty, let card = maker?.card { studio.addCharacter(card); studio.inspectorTab = .pose }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView else { print("[ikkoku] no window"); exit(1) }
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let cg = rep.cgImage { try? ImageIO.writePNG(cg, to: URL(fileURLWithPath: out)); print("[ikkoku] ui snapshot written to \(out)") }
            }
            exit(0)
        }
    }

    // MARK: Document commands

    func openCard() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.message = "Open an Ikkoku character card (PNG)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let card = try CardIO.decode(CharacterCard.self, keyword: CardIO.cardKeyword, from: data)
            if mode == .studio { studio?.addCharacter(card) } else { maker?.load(card: card) }
        } catch { errorMessage = "Could not open card: \(error)" }
    }

    func saveCard() {
        guard let maker else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(maker.card.profile.name).png"
        panel.message = "Save character card (PNG with embedded data)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try maker.saveCard(to: url) } catch { errorMessage = "Could not save card: \(error)" }
    }

    func openScene(importing: Bool) {
        guard let studio else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.message = importing ? "Import an Ikkoku scene (PNG) into the current scene" : "Open an Ikkoku scene (PNG)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { if importing { try studio.importScene(from: url) } else { try studio.loadScene(from: url) }; mode = .studio }
        catch { errorMessage = "Could not open scene: \(error)" }
    }

    func saveScene() {
        guard let studio else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(studio.doc.name).png"
        panel.message = "Save scene (PNG with embedded data)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try studio.saveScene(to: url) } catch { errorMessage = "Could not save scene: \(error)" }
    }

    func captureScreenshot() {
        guard let host else { return }
        let frame = mode == .studio ? (studio?.frame ?? host.renderer.currentFrame()) : host.renderer.currentFrame()
        let size = mode == .studio ? (studio?.captureSize ?? (1920, 1080)) : (1600, 1600)
        guard let image = host.renderer.capture(frame: frame, width: size.0, height: size.1) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "ikkoku_capture.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ImageIO.writePNG(image, to: url)
    }

    func resetCamera() {
        if mode == .studio { studio?.resetCamera() } else { maker?.resetCamera() }
    }
}

enum ImageIO {
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
