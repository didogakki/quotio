import Foundation

/// Pure ranking logic shared by every user-customizable display order that is persisted
/// as a plain ordered `[String]` of opaque keys — position in the array is the rank.
/// Deliberately never consults live quota data (percentage, staleness, error state): an
/// order only ever changes because the user moved something.
///
/// Two orders are built on this today: `RemoteQuotaSourceGroupOrdering` (one remote
/// source's accounts under one provider) and the per-account order inside one of those
/// groups (`MenuBarPreferences.accountOrder`, keyed by `MenuBarQuotaItem.id`). Keeping
/// the mechanics here means both behave identically — including how a never-ranked entry
/// falls back, and how a hidden entry keeps its rank.
public enum DisplayOrderRanking {
    public enum Direction {
        case up
        case down
    }

    /// Compares two keys purely by their position in `order`. Returns `nil` when neither
    /// key has a persisted rank (or both share one), signaling "no opinion" so the
    /// caller's own tie-breaker (e.g. alphabetical by name) decides — this is what makes
    /// a never-ranked entry fall back to the pre-existing sort instead of being pinned to
    /// a default position.
    public static func precedes(_ lhsKey: String, _ rhsKey: String, order: [String]) -> Bool? {
        let lhsRank = order.firstIndex(of: lhsKey)
        let rhsRank = order.firstIndex(of: rhsKey)
        switch (lhsRank, rhsRank) {
        case let (l?, r?):
            return l == r ? nil : l < r
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return nil
        }
    }

    /// Returns a new order list with `key` swapped one position earlier/later relative
    /// to its `siblingKeys` — the other keys currently visible in the same scope (e.g.
    /// every remote-source group under one provider, or every account inside one of
    /// those groups). Any sibling missing from `order` is appended (in `siblingKeys`'
    /// own order) before the swap, so a never-before-ranked entry can still be moved —
    /// and so its whole scope becomes ranked in exactly the order it was already being
    /// displayed in, which is what keeps the first move from reshuffling anything else.
    /// A key present in `order` but not currently in `siblingKeys` (a hidden/disabled
    /// entry) keeps its rank untouched rather than being dropped, satisfying
    /// "hidden/re-enabled entries retain rank". Swapping the two keys' array *values* —
    /// wherever they physically sit — rather than adjacent indices keeps every other
    /// scope's relative order (their keys may be interleaved in the same global list)
    /// unaffected.
    public static func moved(
        key: String,
        direction: Direction,
        order: [String],
        siblingKeys: [String]
    ) -> [String] {
        var materialized = order
        var seen = Set(order)
        for candidate in siblingKeys where seen.insert(candidate).inserted {
            materialized.append(candidate)
        }

        let siblingSet = Set(siblingKeys)
        let logical = materialized.enumerated().filter { siblingSet.contains($0.element) }
        guard let position = logical.firstIndex(where: { $0.element == key }) else { return order }
        let swapPosition = direction == .up ? position - 1 : position + 1
        guard logical.indices.contains(swapPosition) else { return materialized }

        materialized.swapAt(logical[position].offset, logical[swapPosition].offset)
        return materialized
    }

    /// Sorts one scope's elements by their persisted rank, falling back to
    /// `isOrderedBefore` — and, when that reports no preference either, to the elements'
    /// original relative order, so the result is always stable. Ranked elements sort
    /// ahead of unranked ones, which only ever happens when an element appeared *after*
    /// the user last reordered this scope (`moved` materializes every sibling it is
    /// given): a brand new account therefore lands at the end of a scope the user has
    /// already arranged, instead of silently displacing it.
    public static func sorted<Element>(
        _ elements: [Element],
        order: [String],
        key: (Element) -> String,
        isOrderedBefore: (Element, Element) -> Bool = { _, _ in false }
    ) -> [Element] {
        // Deliberately no `order.isEmpty` shortcut: `isOrderedBefore` is the caller's
        // own baseline sort (e.g. alphabetical by email), which must still be applied
        // when nothing has been ranked yet.
        guard elements.count > 1 else { return elements }
        return elements.enumerated().sorted { lhs, rhs in
            if let ranked = precedes(key(lhs.element), key(rhs.element), order: order) {
                return ranked
            }
            if isOrderedBefore(lhs.element, rhs.element) { return true }
            if isOrderedBefore(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
