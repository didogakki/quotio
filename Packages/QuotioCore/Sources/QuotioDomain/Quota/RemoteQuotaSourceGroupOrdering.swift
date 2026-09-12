import Foundation

/// Stable identity for a display group whose relative order the user can customize —
/// one configured remote quota source's accounts under one provider (e.g. "CLIProxyAPI
/// Plus" ▸ Codex). Shared by the Accounts page and the menu bar dropdown so the same
/// persisted order controls both. Built from `RemoteQuotaSourceConfig.id` and
/// `QuotaProvider.rawValue` only — never a display label — so renaming a source or
/// relocalizing a provider name never reshuffles a saved order.
public enum RemoteQuotaSourceGroupIdentity {
    private static let separator = "::"

    public static func key(sourceId: String, provider: QuotaProvider) -> String {
        "\(sourceId)\(separator)\(provider.rawValue)"
    }
}

/// Pure ordering logic for `RemoteQuotaSourceGroupIdentity` keys, persisted as a plain
/// ordered `[String]` (`MenuBarPreferences.sourceGroupOrder`) — position in the array is
/// the rank. Deliberately never consults live quota data (percentage, staleness, error
/// state): the order only ever changes because the user moved something.
public enum RemoteQuotaSourceGroupOrdering {
    public enum Direction {
        case up
        case down
    }

    /// Compares two group keys purely by their position in `order`. Returns `nil` when
    /// neither key has a persisted rank (or both share one), signaling "no opinion" so
    /// the caller's own tie-breaker (e.g. alphabetical by source name) decides — this is
    /// what makes a never-ranked group fall back to the pre-existing sort instead of
    /// being pinned to a default position.
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
    /// to its `siblingKeys` — the other group keys currently visible in the same scope
    /// (e.g. every remote-source group under one provider). Any sibling missing from
    /// `order` is appended (in `siblingKeys`' own order) before the swap, so a
    /// never-before-ranked group can still be moved, and a key present in `order` but
    /// not currently in `siblingKeys` (a hidden/disabled source) keeps its rank
    /// untouched rather than being dropped — satisfying "hidden/re-enabled groups retain
    /// rank". Swapping the two keys' array *values* — wherever they physically sit —
    /// rather than adjacent indices keeps every other scope's relative order (their keys
    /// may be interleaved in the same global list) unaffected.
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

    /// Reorders a flat list of pinned `MenuBarQuotaItem`s — the menu bar status icon's
    /// own selection — by each remote item's own `RemoteQuotaSourceGroupIdentity` rank,
    /// so the status bar icon shares one persisted order with the dropdown/Accounts
    /// page account lists (which already apply this same order at the group-subheader
    /// level) instead of staying stuck in raw pin/insertion order. Never mutates or
    /// reorders the pins themselves — this only decides render order for one call, so
    /// it never affects `menuBarMaxItems` capacity or which pins exist.
    ///
    /// A local item (no `sourceConfigId`), or a remote item whose group has no
    /// persisted rank, keeps its original slot untouched — only the items that *do*
    /// have a persisted rank are reshuffled, and strictly among themselves. Sorting the
    /// full list in one pass (ranked items compared by rank, everything else falling
    /// back to original offset) is not a valid strict weak ordering: it lets a ranked
    /// item and an unranked item compare "by offset" in one pairing while two *other*
    /// ranked items compare "by rank" in another, which can disagree about relative
    /// order across three-plus items (e.g. a ranked source's group outranking an
    /// unranked provider group it was never compared against under `sourceGroupOrder`,
    /// or worse, a non-transitive cycle) and violates the provider hierarchy the
    /// dropdown otherwise establishes. Confining the rank comparison to only the
    /// ranked subsequence — and writing the result back into exactly those slots —
    /// keeps every unranked item's position fixed, so reordering one provider's
    /// sources can never move it ahead of an untouched, unranked provider group.
    public static func orderedSelectedItems(_ items: [MenuBarQuotaItem], order: [String]) -> [MenuBarQuotaItem] {
        guard !order.isEmpty else { return items }
        let rankedSlots = items.indices.filter { index in
            guard let key = groupKey(for: items[index]) else { return false }
            return order.contains(key)
        }
        guard rankedSlots.count > 1 else { return items }
        let rankedItems = rankedSlots.map { items[$0] }.sorted { lhs, rhs in
            let lhsRank = order.firstIndex(of: groupKey(for: lhs)!)!
            let rhsRank = order.firstIndex(of: groupKey(for: rhs)!)!
            return lhsRank < rhsRank
        }
        var result = items
        for (slot, item) in zip(rankedSlots, rankedItems) {
            result[slot] = item
        }
        return result
    }

    private static func groupKey(for item: MenuBarQuotaItem) -> String? {
        guard let sourceId = item.sourceConfigId, let provider = QuotaProvider(rawValue: item.provider) else {
            return nil
        }
        return RemoteQuotaSourceGroupIdentity.key(sourceId: sourceId, provider: provider)
    }
}
