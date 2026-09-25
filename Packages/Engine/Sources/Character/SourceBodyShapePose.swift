import Foundation
import simd
import CoreMath
import Scene

/// The 32-record little-endian table read by ShapeBodyInfoFemale.LoadCorrectInfo.
/// Scale fields are additive corrections, not multiplicative scale factors.
public struct SourceBodyShapeCorrectionTable: Sendable {
    public let entries: [SourceShapeTransform]
    public var neck: SourceShapeTransform { entries[1] }
    public var head: SourceShapeTransform { entries[2] }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count == 4 + 32 * 9 * 4 else {
            throw RigError.invalid("Body correction table must contain exactly 32 TRS records.")
        }
        let bytes = [UInt8](data)
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        guard word(0) == 32 else { throw RigError.invalid("Unsupported body correction record count.") }
        let entries = try (0..<32).map { index -> SourceShapeTransform in
            let values = (0..<9).map { Float(bitPattern: word(4 + index * 36 + $0 * 4)) }
            guard values.allSatisfy(\.isFinite) else { throw RigError.invalid("Nonfinite body correction record.") }
            return SourceShapeTransform(position: Float3(values[0], values[1], values[2]),
                rotationDegrees: Float3(values[3], values[4], values[5]), scale: Float3(values[6], values[7], values[8]))
        }
        return Self(entries: entries)
    }
}

/// Complete local destination setters from the recovered body shape controller.
/// `Update` runs mask 4, then 1, then 2; `UpdateAlways` runs after those static writes.
/// Missing destination transforms are skipped as in the source, and exposed by coverage.
public enum SourceBodyShapePose {
    public enum Sex: Int, Sendable { case male = 0, female = 1 }
    public enum BoneType: Sendable {
        case standard
        /// Any nonzero source typeBone uses the same additive correction table.
        case corrected(SourceBodyShapeCorrectionTable)
    }
    public struct Options: Sendable {
        public var sex: Sex
        public var boneType: BoneType
        public var updateMask: UInt8
        public var applyAlways: Bool
        public init(sex: Sex = .female, boneType: BoneType = .standard,
                    updateMask: UInt8 = 7, applyAlways: Bool = true) {
            self.sex = sex; self.boneType = boneType
            self.updateMask = updateMask; self.applyAlways = applyAlways
        }
    }
    public struct SlotCoverage: Sendable {
        public let index: Int
        public let boundDestinations: [String]
        public let missingDestinations: [String]
        public var isBound: Bool { !boundDestinations.isEmpty }
        public var isComplete: Bool { isBound && missingDestinations.isEmpty }
    }
    public struct Coverage: Sendable {
        public let boundDestinations: [String]
        public let missingDestinations: [String]
        public let slots: [SlotCoverage]
        public var boundSlots: [Int] { slots.filter(\.isBound).map(\.index) }
        public var completeSlots: [Int] { slots.filter(\.isComplete).map(\.index) }
    }

    public static let supportedSlots = Array(0..<44)

    /// Rates are controller rates after any caller-side low-detail/male-height remapping.
    /// Every destination replaces only its source-written components, starting from basePose or rest.
    public static func make(rig: RigDefinition, domain: SourceShapeDomain, values: [Float]? = nil,
                            options: Options = Options(), basePose: RigPose? = nil) throws -> RigPose {
        try validate(domain: domain)
        return try make(rig: rig, state: domain.makeState(values: values), options: options, basePose: basePose)
    }

    public static func make(rig: RigDefinition, state: [String: SourceShapeTransform],
                            options: Options = Options(), basePose: RigPose? = nil) throws -> RigPose {
        try validate(options: options)
        let operations = selectedOperations(options)
        let names = operations.map { destinationNames[$0] }
            + (options.applyAlways ? Array(alwaysDestinationNames.dropFirst()) : [])
        let indices = try bind(names: names, rig: rig)
        var source = Array(repeating: SourceShapeTransform(), count: sourceNames.count)
        let required = Set(operations.filter { indices[destinationNames[$0]] != nil }
            .flatMap { dependencies[$0, default: []].map { $0 / 9 } })
        for index in required {
            let name = sourceNames[index]
            guard let value = state[name], finite(value) else { throw SourceShapeError.incompleteState(name) }
            source[index] = value
        }
        let zero = SourceShapeTransform(scale: .zero)
        let corrections: [SourceShapeTransform]
        switch options.boneType {
        case .standard: corrections = Array(repeating: zero, count: 32)
        case .corrected(let table): corrections = table.entries
        }
        var pose = basePose ?? rig.restPose
        guard pose.localMatrices.count == rig.nodes.count else { throw RigError.invalid("Body shape baseline does not match rig.") }
        let size: Float = options.sex == .male ? 0.91 : 1
        for operation in operations {
            guard let index = indices[destinationNames[operation]] else { continue }
            var components = try components(rig: rig, pose: pose, index: index, incoming: basePose != nil)
            if operation == 38 {
                components.position.z = -source[39].position.z
            } else {
                apply(operation: operation, source: source, corrections: corrections, sizeFactor: size,
                      position: &components.position, rotation: &components.rotation, scale: &components.scale)
            }
            try store(components, name: rig.nodes[index].name, index: index, pose: &pose)
        }
        if options.applyAlways {
            for (side, name) in alwaysDestinationNames.dropFirst().enumerated() {
                guard let index = indices[name] else { continue }
                var components = try components(rig: rig, pose: pose, index: index, incoming: basePose != nil)
                switch options.boneType {
                case .standard: components.position.x = side == 0 ? -0.01563369 : 0.01560147
                case .corrected: components.position.x = corrections[30 + side].position.x
                }
                try store(components, name: name, index: index, pose: &pose)
            }
        }
        return pose
    }

    /// Reports actual exact-name bindings and the slider axes they consume. A slot can
    /// bind only partly on a reduced rig; callers must not label it fully supported.
    public static func coverage(rig: RigDefinition, domain: SourceShapeDomain,
                                options: Options = Options()) throws -> Coverage {
        try validate(domain: domain); try validate(options: options)
        let operations = selectedOperations(options)
        let names = operations.map { destinationNames[$0] }
            + (options.applyAlways ? Array(alwaysDestinationNames.dropFirst()) : [])
        let indices = try bind(names: names, rig: rig)
        let slots = domain.slots.map { slot in
            let used = Set(slot.bindings.flatMap { binding in
                (binding.positionMask + binding.rotationMask + binding.scaleMask).enumerated()
                    .compactMap { $0.element ? binding.sourceIndex * 9 + $0.offset : nil }
            })
            let affected = operations.filter { !dependencies[$0, default: []].isDisjoint(with: used) }.map { destinationNames[$0] }
            return SlotCoverage(index: slot.index,
                boundDestinations: affected.filter { indices[$0] != nil },
                missingDestinations: affected.filter { indices[$0] == nil })
        }
        return Coverage(boundDestinations: names.filter { indices[$0] != nil },
                        missingDestinations: names.filter { indices[$0] == nil }, slots: slots)
    }

    private static func selectedOperations(_ options: Options) -> [Int] {
        operationOrder.filter { operation in
            let bit: UInt8 = operation < 39 || operation > 66 ? 4 : (operation < 53 ? 1 : 2)
            return options.updateMask & bit != 0
        } + (options.applyAlways ? [38] : [])
    }
    private static func bind(names: [String], rig: RigDefinition) throws -> [String: Int] {
        let candidates = Set(names)
        var indices: [String: Int] = [:]
        for (index, node) in rig.nodes.enumerated() where candidates.contains(node.name) {
            guard indices.updateValue(index, forKey: node.name) == nil else {
                throw RigError.invalid("Ambiguous body shape destination '\(node.name)'.")
            }
            guard node.authoredMatrix == nil else {
                throw RigError.invalid("Body shape destinations require authored TRS.")
            }
        }
        return indices
    }
    private typealias Components = (position: Float3, rotation: simd_quatf, scale: Float3)
    private static func components(rig: RigDefinition, pose: RigPose, index: Int, incoming: Bool) throws -> Components {
        let node = rig.nodes[index]
        if incoming { return try SourceShapePoseBaseline.components(pose.localMatrices[index]) }
        return (node.translation, node.rotation, node.scale)
    }
    private static func store(_ value: Components, name: String, index: Int, pose: inout RigPose) throws {
        let matrix = Transform.trs(value.position, value.rotation, value.scale)
        guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { matrix[column][$0].isFinite } }) else {
            throw RigError.invalid("Nonfinite body shape matrix for '\(name)'.")
        }
        pose.localMatrices[index] = matrix
    }
    private static func finite(_ value: SourceShapeTransform) -> Bool {
        (0..<3).allSatisfy { value.position[$0].isFinite && value.rotationDegrees[$0].isFinite && value.scale[$0].isFinite }
    }
    private static func validate(options: Options) throws {
        guard options.updateMask <= 7 else { throw RigError.invalid("Unsupported body shape update mask.") }
    }
    private static func validate(domain: SourceShapeDomain) throws {
        guard domain.id == "body", domain.valueCount == 44,
              domain.sourceNames == sourceNames, domain.destinationNames == destinationNames else {
            throw RigError.invalid("Shape domain differs from the recovered body controller.")
        }
        let signatures = domain.slots.map { slot in
            slot.bindings.map { binding in
                binding.sourceIndex * 512 + (binding.positionMask + binding.rotationMask + binding.scaleMask)
                    .enumerated().reduce(0) { $0 + ($1.element ? 1 << $1.offset : 0) }
            }
        }
        guard signatures == bindingSignatures else {
            throw RigError.invalid("Body shape bindings differ from the recovered source axis masks.")
        }
    }
}
