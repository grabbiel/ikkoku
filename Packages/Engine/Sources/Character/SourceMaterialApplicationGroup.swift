import Foundation
import Metal
import Renderer
import Scene

/// Logical retained GPU pixel storage only. Raw CPU snapshots, metadata, older
/// completed outputs, heap alignment and driver allocations are not this charge.
struct SourceMaterialGroupCharge: Equatable {
    let inputBytes: Int, outputBytes: Int
    static let zero = Self(inputBytes: 0, outputBytes: 0)

    init(inputBytes: Int, outputBytes: Int) { self.inputBytes = inputBytes; self.outputBytes = outputBytes }
    init?(recipes: [SourceMaterialCompositionRecipe]) {
        var input = 0, output = 0, white = false, zero = false
        func add(_ amount: Int, to value: inout Int) -> Bool {
            let next = value.addingReportingOverflow(amount)
            guard amount >= 0, !next.overflow else { return false }
            value = next.partialValue; return true
        }
        for recipe in recipes {
            for (index, image) in recipe.inputImages.enumerated() {
                if let image {
                    guard let bytes = try? SourceMaterialMetalInputBudget.logicalBytes(width: image.width, height: image.height),
                          image.bytes.count == bytes, add(bytes, to: &input) else { return nil }
                } else if index == 0 {
                    if !white { guard add(4, to: &input) else { return nil }; white = true }
                } else if !zero { guard add(4, to: &input) else { return nil }; zero = true }
            }
            guard let bytes = try? SourceMaterialMetalInputBudget.logicalBytes(width: recipe.width, height: recipe.height),
                  add(bytes, to: &output) else { return nil }
        }
        self.init(inputBytes: input, outputBytes: output)
    }

    func adding(_ other: Self) -> Self? {
        let input = inputBytes.addingReportingOverflow(other.inputBytes)
        let output = outputBytes.addingReportingOverflow(other.outputBytes)
        guard inputBytes >= 0, outputBytes >= 0, other.inputBytes >= 0, other.outputBytes >= 0,
              !input.overflow, !output.overflow else { return nil }
        return .init(inputBytes: input.partialValue, outputBytes: output.partialValue)
    }
}

/// This is a grouping policy, not another admission limit. A valid oversized
/// call runs through the existing standalone path with its original 128 MiB caps.
struct SourceMaterialGroupCapacity {
    static let clothes = Self(inputBytes: 32 * 1024 * 1024, outputBytes: 32 * 1024 * 1024)
    let inputBytes: Int, outputBytes: Int
    enum Action: Equatable { case append, flushThenAppend, standalone }
    func action(pending: SourceMaterialGroupCharge, next: SourceMaterialGroupCharge?) -> Action {
        guard let next, next.inputBytes >= 0, next.outputBytes >= 0,
              next.inputBytes <= inputBytes, next.outputBytes <= outputBytes else { return .standalone }
        guard let combined = pending.adding(next), combined.inputBytes <= inputBytes,
              combined.outputBytes <= outputBytes else { return .flushThenAppend }
        return .append
    }
}

struct SourceClothesComponentIdentity: Equatable, Sendable {
    let index: Int, slot: Int, prefix: String
}

/// A combined buffer has one execution result. Its error belongs to the atomic
/// group, not an inferred original per-component GPU failure order.
struct SourceMaterialGroupExecutionError: Error, LocalizedError {
    let components: [SourceClothesComponentIdentity]
    let underlying: any Error
    var errorDescription: String? {
        "Clothes composition group [\(components.map { "\($0.index):\($0.prefix)" }.joined(separator: ", "))] failed: \(underlying.localizedDescription)"
    }
}

/// Synchronous owner-local plans. Nothing here is sent to another executor or
/// published to the renderer. Every input/output is strongly held until the
/// group's completion and ordered view checks finish.
final class SourceClothesMaterialGroup {
    struct Completed {
        let identity: SourceClothesComponentIdentity
        let application: SourcePreviewAppearance.CardApplication
    }
    private struct Pending {
        let identity: SourceClothesComponentIdentity
        let plan: SourcePreparedMetalCardApplication
    }
    private let resources: ResourceStore, timings: SourceAppearanceTimings?
    private let capacity: SourceMaterialGroupCapacity
    private let hooks: SourceMaterialMetalCompletionHooks?
    private var pending: [Pending] = []
    private var charge = SourceMaterialGroupCharge.zero

    init(resources: ResourceStore, timings: SourceAppearanceTimings?, capacity: SourceMaterialGroupCapacity = .clothes,
         hooks: SourceMaterialMetalCompletionHooks? = nil) {
        self.resources = resources; self.timings = timings; self.capacity = capacity; self.hooks = hooks
    }

    func append(_ plan: SourcePreparedMetalCardApplication, identity: SourceClothesComponentIdentity) throws -> [Completed] {
        let next = plan.groupingCharge
        var completed: [Completed] = []
        switch capacity.action(pending: charge, next: next) {
        case .standalone:
            completed = try finish()
            // No group error wrapper or silent retry: retain the existing call.
            let application = try SourceAppearanceTimings.scoped(timings, .clothesCompositionGroup(indices: [identity.index])) {
                try plan.complete(resources: resources, timings: timings)
            }
            completed.append(.init(identity: identity, application: application))
            return completed
        case .flushThenAppend: completed = try finish()
        case .append: break
        }
        // The checked policy above proved this sum and each next charge.
        charge = charge.adding(next!)!
        pending.append(.init(identity: identity, plan: plan))
        return completed
    }

    /// Call outside a component timing scope. If later CPU loading/resolution
    /// fails, earlier work still completes first. Its failure wins; otherwise
    /// the original later error is rethrown without changing type or payload.
    func preparing<Value>(_ body: () throws -> Value) throws -> Value {
        do { return try body() }
        catch {
            _ = try finish()
            throw error
        }
    }

    func finish() throws -> [Completed] {
        guard !pending.isEmpty else { return [] }
        let items = pending
        pending.removeAll(keepingCapacity: true); charge = .zero
        return try SourceAppearanceTimings.scoped(timings, .clothesCompositionGroup(indices: items.map { $0.identity.index })) {
            var batches: [SourceMaterialMetalBatch] = [], batchIndices: [Int] = []
            for (index, item) in items.enumerated() {
                do {
                    if let batch = try item.plan.prepare(resources: resources, timings: timings) {
                        batches.append(batch); batchIndices.append(index)
                    }
                } catch {
                    // Later allocation failure must not hide earlier execution
                    // failure. Prefix views remain private and are discarded.
                    _ = try execute(batches, components: batchIndices.map { items[$0].identity })
                    throw error
                }
            }
            let views = try execute(batches, components: items.map(\.identity))
            var byItem = [[any MTLTexture]](repeating: [], count: items.count)
            for (offset, index) in batchIndices.enumerated() { byItem[index] = views[offset] }
            // Check every cardinality before any registered output handle exists.
            guard zip(items, byItem).allSatisfy({ item, views in item.plan.recipes.count == views.count }) else {
                throw RigError.invalid("Incomplete clothes composition group views.")
            }
            return try zip(items, byItem).map { item, textures in
                .init(identity: item.identity, application: try item.plan.materialize(views: textures, resources: resources))
            }
        }
    }

    private func execute(_ batches: [SourceMaterialMetalBatch], components: [SourceClothesComponentIdentity]) throws -> [[any MTLTexture]] {
        guard !batches.isEmpty else { return [] }
        do {
            return try SourceAppearanceTimings.measure(timings, .composeEncodeWait) {
                try SourceMaterialMetalBatch.complete(batches, timings: timings, hooks: hooks)
            }
        } catch {
            throw SourceMaterialGroupExecutionError(components: components, underlying: error)
        }
    }
}
