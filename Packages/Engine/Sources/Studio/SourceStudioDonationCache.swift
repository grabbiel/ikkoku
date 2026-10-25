import Foundation
import Scene

/// R7 phase 2 item 6 follow-up: the converted assemblies of source character
/// previews the Studio dropped without a rebuild waiting for them, such as a
/// deleted character, kept so that the build that brings one back (the undo
/// of the delete) borrows it instead of reading and decoding its files again.
///
/// A `SourceStudioCharacterPreview.Donation` holds immutable CPU values only
/// (the prepared Maker assembly, the assembled source rig and the shape
/// contract), never a store resource, so keeping one keeps no mesh, texture
/// or buffer alive. Its charge is the assembled rig's logical payload
/// (`SourceRig.decodedCacheLogicalByteCount`): array elements and strings,
/// without allocation headers or spare capacity. The prepared assembly
/// shares that rig's storage, and the contract is not counted.
///
/// Bounded: at most `maximumEntries` donations and `maximumBytes` of charge.
/// Keeping one evicts the oldest entries until it fits; a donation that
/// cannot be charged, or is larger than the whole budget, is not kept. A
/// newer donation of the same character and outfit replaces the older one.
/// `take` removes what it returns: the build that borrows it holds the same
/// values from then on.
///
/// Not thread-safe; the Studio's main actor owns it.
public final class SourceStudioDonationCache {
    public struct Counts: Sendable, Equatable {
        /// Donations kept, evicted to make room, refused (uncharged or over
        /// the budget), replaced by a newer one, and taken by a build.
        public var kept = 0, evicted = 0, refused = 0, replaced = 0, taken = 0
        public init(kept: Int = 0, evicted: Int = 0, refused: Int = 0, replaced: Int = 0, taken: Int = 0) {
            self.kept = kept; self.evicted = evicted; self.refused = refused; self.replaced = replaced; self.taken = taken
        }
    }
    /// 192 MiB: three to four of the reference scene's characters
    /// (docs/reference/performance.md, phase 2 item 6 follow-up).
    public static let defaultMaximumBytes = 192 << 20
    public static let defaultMaximumEntries = 8

    public let maximumBytes: Int, maximumEntries: Int
    /// Oldest first.
    private var entries: [(donation: SourceStudioCharacterPreview.Donation, charge: Int)] = []
    public private(set) var bytes = 0
    public private(set) var counts = Counts()

    public init(maximumBytes: Int = SourceStudioDonationCache.defaultMaximumBytes,
                maximumEntries: Int = SourceStudioDonationCache.defaultMaximumEntries) {
        self.maximumBytes = max(0, maximumBytes); self.maximumEntries = max(0, maximumEntries)
    }

    public var count: Int { entries.count }

    /// The logical bytes keeping `donation` retains (see the type), or nil
    /// when its rig cannot be charged.
    public static func charge(_ donation: SourceStudioCharacterPreview.Donation) -> Int? {
        donation.source.decodedCacheLogicalByteCount
    }

    /// Keeps `donation`, evicting the oldest entries until it fits. Returns
    /// whether it was kept.
    @discardableResult
    public func keep(_ donation: SourceStudioCharacterPreview.Donation) -> Bool {
        guard maximumEntries > 0, let charge = Self.charge(donation), charge <= maximumBytes else {
            counts.refused += 1
            return false
        }
        if let index = entries.firstIndex(where: { Self.sameCharacter($0.donation, donation) }) {
            bytes -= entries.remove(at: index).charge
            counts.replaced += 1
        }
        while !entries.isEmpty, entries.count >= maximumEntries || bytes + charge > maximumBytes {
            bytes -= entries.removeFirst().charge
            counts.evicted += 1
        }
        entries.append((donation, charge))
        bytes += charge
        counts.kept += 1
        return true
    }

    /// Removes and returns the newest donation `matches` accepts.
    public func take(where matches: (SourceStudioCharacterPreview.Donation) -> Bool) -> SourceStudioCharacterPreview.Donation? {
        guard let index = entries.lastIndex(where: { matches($0.donation) }) else { return nil }
        let entry = entries.remove(at: index)
        bytes -= entry.charge
        counts.taken += 1
        return entry.donation
    }

    /// Drops every donation (memory pressure, or the owner's reset).
    public func removeAll() {
        counts.evicted += entries.count
        entries.removeAll()
        bytes = 0
    }

    /// The same character in the same outfit on the same store: a later
    /// build would accept either donation.
    private static func sameCharacter(_ a: SourceStudioCharacterPreview.Donation, _ b: SourceStudioCharacterPreview.Donation) -> Bool {
        a.reference == b.reference && a.coordinate == b.coordinate && a.resources == b.resources
            && a.rigURL == b.rigURL && a.directory == b.directory
    }
}
