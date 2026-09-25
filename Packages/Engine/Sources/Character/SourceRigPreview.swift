import Foundation
import simd
import CoreMath
import Scene
import Renderer
import ShaderTypes

/// Original rig geometry with explicit source assembly, shape curves and preview materials.
public final class SourceRigPreview {
    public let source: SourceRig
    public let contract: SourceShapeContract?
    public let expressionContract: SourceExpressionContract?
    public let supportsExpressions: Bool
    public let supportsHeightScale: Bool
    public let supportsBodyCustomization: Bool
    public let supportsFaceCustomization: Bool
    public let hasSourceAppearance: Bool
    public let bodyOptions: SourceBodyShapePose.Options
    public let bodyCoverage: SourceBodyShapePose.Coverage?
    private let appearance: SourcePreviewAppearance?
    private let resources: ResourceStore
    private let meshes: [MeshHandle]
    private let keyBase: UInt64
    private var liveBounds: SourceRigBounds

    public init(source: SourceRig, contract: SourceShapeContract?, resources: ResourceStore, appearance: SourcePreviewAppearance? = nil,
                expressionContract: SourceExpressionContract? = nil,
                bodyOptions: SourceBodyShapePose.Options = .init()) throws {
        self.source = source; self.contract = contract
        liveBounds = SourceRigBounds(source: source)
        self.expressionContract = expressionContract
        self.bodyOptions = bodyOptions
        bodyCoverage = try contract?.domain("body").map { try SourceBodyShapePose.coverage(rig: source.rig, domain: $0, options: bodyOptions) }
        self.supportsExpressions = try expressionContract.map { try !$0.weights(source: source, inputs: $0.defaults).isEmpty } ?? false
        self.appearance = appearance; self.hasSourceAppearance = appearance?.materials.isEmpty == false
        self.resources = resources
        supportsHeightScale = contract.map { (try? SourceRigCustomization.heightPose(source: source, contract: $0, rate: 0.5)) != nil } ?? false
        supportsBodyCustomization = bodyCoverage?.boundSlots.isEmpty == false
            && (contract?.domain("body").map { (try? SourceBodyShapePose.make(rig: source.rig, domain: $0, options: bodyOptions)) != nil } ?? false)
        supportsFaceCustomization = contract?.domain("face").map { (try? SourceFaceShapePose.make(rig: source.rig, domain: $0)) != nil } ?? false
        // Validate the entire pose before registering resources.
        let rest = try source.rig.evaluate(source.rig.restPose)
        _ = try Self.previewBounds(source: source, evaluation: rest)
        var registered: [MeshHandle] = []
        do {
            for part in source.parts {
                if appearance?.materials[part.mesh.name]?.contains(where: { ($0.uniforms.flags & MaterialFlagSourceIrisHighlights.rawValue) != 0 }) == true {
                    guard part.mesh.uvs1.count == part.mesh.vertexCount, part.mesh.uvs2.count == part.mesh.vertexCount else {
                        throw RigError.invalid("Source iris highlights require the original UV1 and UV2 sets in '\(part.mesh.name)'.")
                    }
                }
                registered.append(try resources.register(mesh: part.mesh))
            }
        } catch {
            for mesh in registered { resources.unregister(mesh: mesh) }
            throw error
        }
        meshes = registered
        keyBase = UInt64(meshes.first?.id ?? 0) << 32
    }

    deinit {
        for mesh in meshes { resources.unregister(mesh: mesh) }
        resources.releaseDeformBuffers(keys: meshes.indices.map { keyBase | UInt64($0) })
        // Prepared frames keep GPUMesh/buffer references, and Metal command buffers
        // retain encoded resources until completion. Queued handle-only frames may
        // skip a released mesh; they never dereference its former storage.
    }

    public func pose(heightScale: Float? = nil, bodyValues: [Float]? = nil, faceValues: [Float]? = nil,
                     boneModifiers: SourceBoneModifiers? = nil, coordinate: Int = 0, basePose: RigPose? = nil) throws -> RigPose {
        guard heightScale == nil || bodyValues == nil else { throw RigError.invalid("Choose direct height scale or body customization.") }
        var pose: RigPose
        if let bodyValues {
            guard supportsBodyCustomization, let domain = contract?.domain("body") else { throw RigError.invalid("This rig does not support body customization.") }
            pose = try SourceBodyShapePose.make(rig: source.rig, domain: domain, values: bodyValues, options: bodyOptions, basePose: basePose)
        } else if let heightScale {
            guard supportsHeightScale, let contract, basePose == nil else { throw RigError.invalid("This rig has no supported source height operation or an incompatible animation baseline.") }
            pose = try SourceRigCustomization.heightPose(source: source, contract: contract, rate: heightScale)
        } else { pose = basePose ?? source.rig.restPose }
        if let faceValues {
            guard supportsFaceCustomization, let domain = contract?.domain("face") else { throw RigError.invalid("This rig does not support face customization.") }
            let type: Int, correction: Float
            switch bodyOptions.boneType {
            case .standard: type = 0; correction = 1
            case .corrected(let table): type = 1; correction = 1 / (1 + table.head.scale.y)
            }
            pose = try SourceFaceShapePose.make(rig: source.rig, domain: domain, values: faceValues, basePose: pose,
                boneType: type, headCorrection: correction)
            // ChaControl.UpdateShapeFace also updates the head DynamicBone collider.
            // Source head-only exports legitimately omit this body-master transform.
            if source.rig.nodes.contains(where: { $0.name == "cf_hit_head" }) {
                let index = try source.rig.uniqueNode(named: "cf_hit_head")
                let current = try SourceShapePoseBaseline.components(pose.localMatrices[index])
                pose.localMatrices[index] = Transform.trs(current.position, current.rotation,
                    Float3(repeating: SourceMakerAssemblyOptions.headColliderScale(boneType: type)))
            }
        }
        if let boneModifiers { pose = try boneModifiers.applying(to: source.rig, baseline: pose, coordinate: coordinate) }
        return pose
    }

    public func evaluation(heightScale: Float? = nil, bodyValues: [Float]? = nil, faceValues: [Float]? = nil,
                           boneModifiers: SourceBoneModifiers? = nil, coordinate: Int = 0) throws -> RigEvaluation {
        try source.rig.evaluate(pose(heightScale: heightScale, bodyValues: bodyValues, faceValues: faceValues,
                                    boneModifiers: boneModifiers, coordinate: coordinate))
    }

    public func bounds(heightScale: Float? = nil, bodyValues: [Float]? = nil, faceValues: [Float]? = nil,
                       expression: SourceExpressionInputs? = nil, boneModifiers: SourceBoneModifiers? = nil, coordinate: Int = 0) throws -> AABB {
        let evaluation = try evaluation(heightScale: heightScale, bodyValues: bodyValues, faceValues: faceValues, boneModifiers: boneModifiers, coordinate: coordinate)
        return try Self.previewBounds(source: source, evaluation: evaluation, morphWeights: expressionWeights(expression))
    }

    private func bounds(evaluation: RigEvaluation) throws -> AABB {
        try Self.previewBounds(source: source, evaluation: evaluation)
    }

    private static func previewBounds(source: SourceRig, evaluation: RigEvaluation, morphWeights: [String: [(index: Int, weight: Float)]] = [:]) throws -> AABB {
        let meshBounds = try source.bounds(evaluation: evaluation, morphWeights: morphWeights)
        let result = meshBounds.isEmpty
            ? AABB.of(points: source.rig.order.filter { source.rig.activeNodes[$0] }.map { evaluation.worldMatrices[$0].translation }) : meshBounds
        guard !result.isEmpty, result.radius.isFinite, (0..<3).allSatisfy({ result.center[$0].isFinite }) else {
            throw RigError.invalid("Rig has no active geometry or nodes with finite preview bounds.")
        }
        return result
    }

    public func expressionWeights(_ input: SourceExpressionInputs?) throws -> [String: [(index: Int, weight: Float)]] {
        guard let input else { return [:] }
        guard supportsExpressions, let expressionContract else { throw RigError.invalid("This source model has no supported expression contract.") }
        let weights = try expressionContract.weights(source: source, inputs: input)
        for part in source.parts {
            let entries = weights[part.mesh.name] ?? []
            guard entries.count <= Int(IK_MAX_ACTIVE_MORPHS) else { throw RigError.invalid("Source expression exceeds the active morph capacity.") }
            try SourceRig.validateMorphWeights(entries, mesh: part.mesh)
        }
        return weights
    }

    public func frame(camera: OrbitCamera, mainLight: MainLight = MainLight(), effects: SceneEffects = SceneEffects(),
                      heightScale: Float? = nil, bodyValues: [Float]? = nil, faceValues: [Float]? = nil,
                      expression: SourceExpressionInputs? = nil,
                      boneModifiers: SourceBoneModifiers? = nil, coordinate: Int = 0,
                      showBones: Bool = false, poseOverride: RigPose? = nil) throws -> RenderFrame {
        guard poseOverride == nil || (heightScale == nil && bodyValues == nil && faceValues == nil && boneModifiers == nil) else {
            throw RigError.invalid("A final source pose cannot also request shape or modifier evaluation.")
        }
        let evaluation = try poseOverride.map { try source.rig.evaluate($0) }
            ?? evaluation(heightScale: heightScale, bodyValues: bodyValues, faceValues: faceValues, boneModifiers: boneModifiers, coordinate: coordinate)
        let morphWeights = try expressionWeights(expression)
        var items: [RenderItem] = []
        for (index, part) in source.parts.enumerated() where part.rendererEnabled && source.rig.activeNodes[part.node] {
            var material = MaterialState(uniforms: .make(kind: MaterialKindCloth))
            material.uniforms.baseColor = supportsFaceCustomization ? Float4(0.78, 0.75, 0.70, 1)
                : (index.isMultiple(of: 2) ? Float4(0.34, 0.50, 0.68, 1) : Float4(0.75, 0.80, 0.88, 1))
            material.uniforms.outline.w = 0.8
            for (pass, surface) in (appearance?.materials[part.mesh.name] ?? [material]).enumerated() {
                var item = RenderItem(mesh: meshes[index], material: surface, model: evaluation.worldMatrices[part.node], objectID: 1,
                                      deformKey: keyBase | UInt64(index), skinSet: keyBase | UInt64(part.skin),
                                      morphWeights: morphWeights[part.mesh.name] ?? [])
                item.order = pass
                items.append(item)
            }
        }
        var vertices: [GizmoVertex] = []
        if showBones || items.isEmpty {
            for index in source.rig.order where source.rig.activeNodes[index] {
                guard let parent = source.rig.nodes[index].parent else { continue }
                let color = Float4(0.15, 0.7, 0.95, 1)
                vertices.append(GizmoVertex(position: evaluation.worldMatrices[parent].translation, color: color))
                vertices.append(GizmoVertex(position: evaluation.worldMatrices[index].translation, color: color))
            }
        }
        var frameBounds = try liveBounds.bounds(evaluation: evaluation, morphWeights: morphWeights)
        if frameBounds.isEmpty { frameBounds = try Self.previewBounds(source: source, evaluation: evaluation, morphWeights: morphWeights) }
        var result = RenderFrame(camera: camera, mainLight: mainLight, items: items,
            gizmos: vertices.isEmpty ? [] : [GizmoBatch(primitive: .lines, vertices: vertices, depthTest: false)],
            effects: effects, sceneBounds: frameBounds)
        for (index, palette) in evaluation.palettes.enumerated() { result.skinSets[keyBase | UInt64(index)] = palette }
        result.retainTextures(from: resources)
        return result
    }
}
