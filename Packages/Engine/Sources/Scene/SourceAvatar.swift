import Foundation
import CoreMath
import simd

/// Explicit local files for the observed normal female/male Maker assembly. All paths are
/// relative to this manifest; original game data stays outside the app bundle.
public struct SourceAvatarManifest: Decodable, Sendable {
    public struct Component: Decodable, Sendable {
        public let file: String
        public let meshNames: [String]?
        public let slot: Int?
    }
    public let schemaVersion: Int
    public let kind: String
    public let name: String
    public let sex: Int?
    public let headID: Int?
    public let boneType: Int?
    public let defaultCard: String?
    public let bodyCorrection: String?
    public let bodySkeleton: String
    public let headSkeleton: String
    public let body: Component
    public let head: Component
    public let clothes: [Component]
    public let hair: [Component]
}

/// Reproduces the observed parenting, local-transform copy and palette rebind
/// stages. Skin inverse binds and per-vertex palette indices are never rewritten.
public enum SourceAvatar {
    public struct Accessory: Sendable {
        public let source: SourceRig, parent: String, slot: Int
        public let meshNames: [String]?
        public let overrides: [String: RigDefinition.Node]
        public init(source: SourceRig, parent: String, slot: Int, meshNames: [String]? = nil,
                    overrides: [String: RigDefinition.Node] = [:]) {
            self.source = source; self.parent = parent; self.slot = slot
            self.meshNames = meshNames; self.overrides = overrides
        }
    }
    public static func load(url: URL) throws -> SourceRig {
        let manifest = try JSONDecoder().decode(SourceAvatarManifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == 1, ["koikatsu-female-avatar", "koikatsu-male-avatar"].contains(manifest.kind),
              manifest.sex == nil || manifest.sex == (manifest.kind == "koikatsu-male-avatar" ? 0 : 1) else {
            throw RigError.invalid("Unsupported source avatar manifest.")
        }
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        func read(_ path: String) throws -> SourceRig {
            guard !path.hasPrefix("/"), !path.isEmpty else { throw RigError.invalid("Avatar asset paths must be relative.") }
            let file = directory.appendingPathComponent(path).resolvingSymlinksInPath()
            guard file.path.hasPrefix(directory.path + "/") else { throw RigError.invalid("Avatar asset path escapes its folder.") }
            return try SourceRig.load(url: file)
        }
        return try assemble(name: manifest.name, bodySkeleton: read(manifest.bodySkeleton), headSkeleton: read(manifest.headSkeleton),
            body: read(manifest.body.file), head: read(manifest.head.file), clothes: manifest.clothes.map { try read($0.file) },
            hair: manifest.hair.map { try read($0.file) }, bodyMeshNames: manifest.body.meshNames, headMeshNames: manifest.head.meshNames,
            clothingMeshNames: manifest.clothes.map(\.meshNames), hairMeshNames: manifest.hair.map(\.meshNames))
    }

    public static func assemble(name: String, bodySkeleton: SourceRig, headSkeleton: SourceRig,
                                body: SourceRig, head: SourceRig, clothes: [SourceRig], hair: [SourceRig],
                                bodyMeshNames: [String]?, headMeshNames: [String]? = nil,
                                clothingMeshNames: [[String]?]? = nil, hairMeshNames: [[String]?]? = nil,
                                accessories: [Accessory] = []) throws -> SourceRig {
        guard bodySkeleton.parts.isEmpty, headSkeleton.parts.isEmpty, !body.parts.isEmpty, !head.parts.isEmpty,
              bodyMeshNames?.isEmpty == false,
              clothingMeshNames.map({ $0.count == clothes.count }) ?? true,
              hairMeshNames.map({ $0.count == hair.count }) ?? true else {
            throw RigError.invalid("Avatar needs skeleton-only masters, explicit body mesh selection, head, and clothing.")
        }
        var builder = Builder(name: name)
        let bodyMap = try builder.append(bodySkeleton, prefix: "body-master", parent: 0)
        let bodyRoot = try bodySkeleton.rig.uniqueNode(named: "cf_j_root")
        let bodyTargets = try builder.targets(source: bodySkeleton, indices: bodyMap, root: bodyRoot)
        guard let headParent = bodyTargets["cf_s_head"], let hips = bodyTargets["cf_j_hips"] else { throw RigError.invalid("Body master lacks the source head parent or hips.") }

        // CommonLib.CopySameNameTransform(dst=head bones, src=head mesh prefab).
        var overrides: [String: RigDefinition.Node] = [:]
        for node in head.rig.nodes {
            guard overrides.updateValue(node, forKey: node.name) == nil else { throw RigError.invalid("Head mesh has ambiguous transform name '\(node.name)'.") }
        }
        let headMap = try builder.append(headSkeleton, prefix: "head-master", parent: headParent, localOverrides: overrides)
        let headRoot = try soleRoot(headSkeleton.rig)
        let headTargets = try builder.targets(source: headSkeleton, indices: headMap, root: headRoot)
        guard let headContainer = headMap[headRoot], let hairParent = headTargets["cf_J_FaceUp_ty"] else {
            throw RigError.invalid("Head master lacks its container or source hair parent.")
        }
        _ = try builder.append(body, prefix: "body", parent: 0, removeBranch: "cf_j_root", paletteTargets: bodyTargets, selectedMeshes: bodyMeshNames, forcedRootJoint: hips)
        _ = try builder.append(head, prefix: "head", parent: headContainer, removeBranch: "cf_J_N_FaceRoot", paletteTargets: headTargets, selectedMeshes: headMeshNames, forcedRootJoint: hips)
        for (index, item) in clothes.enumerated() {
            _ = try builder.append(item, prefix: "clothes-\(index)", parent: 0, removeBranch: "cf_j_root", paletteTargets: bodyTargets,
                                   selectedMeshes: clothingMeshNames?[index] ?? nil, forcedRootJoint: hips)
        }
        // copyWeights=0: original hair keeps its own hierarchy and palette.
        for (index, item) in hair.enumerated() {
            _ = try builder.append(item, prefix: "hair-\(index)", parent: hairParent, selectedMeshes: hairMeshNames?[index] ?? nil)
        }
        guard accessories.count <= 20, Set(accessories.map(\.slot)).count == accessories.count else {
            throw RigError.invalid("Accessory slots must be unique within the original 20-slot limit.")
        }
        for accessory in accessories {
            guard (0..<20).contains(accessory.slot) else { throw RigError.invalid("Invalid source accessory slot.") }
            let parent: Int
            if accessory.parent == "none" { parent = 0 }
            else {
                // Source GetReferenceInfo addresses master attachment nodes, not
                // similarly named accessory/hair children added later.
                let matches = [bodyTargets[accessory.parent], headTargets[accessory.parent]].compactMap { $0 }
                guard matches.count == 1, let target = matches.first else {
                    throw RigError.invalid("Accessory parent is absent or ambiguous: \(accessory.parent).")
                }
                parent = target
            }
            _ = try builder.append(accessory.source, prefix: "accessory-\(accessory.slot)", parent: parent,
                localOverrides: accessory.overrides, selectedMeshes: accessory.meshNames)
        }
        let rig = try RigDefinition(nodes: builder.nodes, skins: builder.skins)
        _ = try rig.evaluate(rig.restPose)
        return SourceRig(sourcePrefab: name, rig: rig, parts: builder.parts, morphChannelCount: builder.morphCount)
    }

    private static func soleRoot(_ rig: RigDefinition) throws -> Int {
        let roots = rig.nodes.indices.filter { rig.nodes[$0].parent == nil }
        guard roots.count == 1 else { throw RigError.invalid("A source avatar component must have exactly one root.") }
        return roots[0]
    }

    private struct Builder {
        var nodes: [RigDefinition.Node]
        var skins: [RigDefinition.Skin] = []
        var parts: [SourceRig.Part] = []
        var morphCount = 0
        init(name: String) { nodes = [.init(name: name, sourceID: "avatar:root", parent: nil)] }

        func targets(source: SourceRig, indices: [Int: Int], root: Int) throws -> [String: Int] {
            var result: [String: Int] = [:], included = Set<Int>()
            for index in source.rig.order where index == root || source.rig.nodes[index].parent.map({ included.contains($0) }) == true {
                included.insert(index)
                guard let mapped = indices[index], result.updateValue(mapped, forKey: source.rig.nodes[index].name) == nil else {
                    throw RigError.invalid("Source master has duplicate or missing bone '\(source.rig.nodes[index].name)'.")
                }
            }
            return result
        }

        mutating func append(_ source: SourceRig, prefix: String, parent: Int, removeBranch: String? = nil,
                             paletteTargets: [String: Int]? = nil, localOverrides: [String: RigDefinition.Node] = [:],
                             selectedMeshes: [String]? = nil, forcedRootJoint: Int? = nil) throws -> [Int: Int] {
            _ = try SourceAvatar.soleRoot(source.rig)
            let removedRoot = try removeBranch.map { try source.rig.uniqueNode(named: $0) }
            var removed = Set<Int>(), map: [Int: Int] = [:]
            for index in source.rig.order {
                let original = source.rig.nodes[index]
                if index == removedRoot || original.parent.map({ removed.contains($0) }) == true { removed.insert(index); continue }
                let local = localOverrides[original.name] ?? original
                let targetParent = original.parent.flatMap { map[$0] } ?? parent
                map[index] = nodes.count
                nodes.append(.init(name: original.name, sourceID: "\(prefix)/\(original.sourceID)", parent: targetParent,
                    translation: local.translation, rotation: local.rotation, scale: local.scale,
                    authoredMatrix: local.authoredMatrix, active: original.active))
            }
            let selected: Set<String>? = selectedMeshes.map(Set.init)
            if let selected {
                let available = Set(source.parts.map { source.rig.skins[$0.skin].name })
                guard !selected.isEmpty, selected.count == selectedMeshes?.count, selected.isSubset(of: available) else {
                    throw RigError.invalid("Component \(prefix) selects missing or duplicate mesh names.")
                }
            }
            let sourceParts = source.parts.filter { selected?.contains(source.rig.skins[$0.skin].name) ?? true }
            guard sourceParts.allSatisfy({ !$0.hasCloth }) else {
                throw RigError.invalid("Unity Cloth assembly is not supported for component \(prefix).")
            }
            var skinMap: [Int: Int] = [:]
            for part in sourceParts {
                guard let node = map[part.node] else { throw RigError.invalid("Removed source skeleton branch contains a selected renderer.") }
                if skinMap[part.skin] == nil {
                    let binding = source.rig.skins[part.skin]
                    func resolve(_ sourceIndex: Int) throws -> Int {
                        let target: Int?
                        if let paletteTargets { target = paletteTargets[source.rig.nodes[sourceIndex].name] }
                        else { target = map[sourceIndex] }
                        guard let target else { throw RigError.invalid("Unresolved \(prefix) bone '\(source.rig.nodes[sourceIndex].name)'.") }
                        return target
                    }
                    let joints = try binding.joints.map(resolve)
                    let rootJoint = try forcedRootJoint ?? binding.rootJoint.map(resolve)
                    skinMap[part.skin] = skins.count
                    skins.append(.init(name: binding.name, meshNode: node, joints: joints, inverseBindMatrices: binding.inverseBindMatrices, rootJoint: rootJoint))
                }
                guard let skin = skinMap[part.skin] else { throw RigError.invalid("Missing assembled skin binding.") }
                parts.append(.init(mesh: part.mesh, node: node, skin: skin, rendererEnabled: part.rendererEnabled))
            }
            morphCount += source.morphChannelCount
            return map
        }
    }
}

public extension SourceRig {
    /// Detect the explicit avatar manifest without interpreting ordinary rig JSON as one.
    static func loadModel(url: URL) throws -> SourceRig {
        struct Header: Decodable { let kind: String? }
        let data = try Data(contentsOf: url)
        if try JSONDecoder().decode(Header.self, from: data).kind != nil { return try SourceAvatar.load(url: url) }
        return try decode(data)
    }
}
