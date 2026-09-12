import XCTest
@testable import QuotioDomain

final class RemoteQuotaSourceGroupOrderingTests: XCTestCase {
    func testKeyIsBuiltFromStableIdsNotLabels() {
        XCTAssertEqual(
            RemoteQuotaSourceGroupIdentity.key(sourceId: "src-1", provider: .codex),
            "src-1::codex"
        )
    }

    func testPrecedesRanksByPersistedPosition() {
        let order = ["b", "a", "c"]
        XCTAssertEqual(RemoteQuotaSourceGroupOrdering.precedes("b", "a", order: order), true)
        XCTAssertEqual(RemoteQuotaSourceGroupOrdering.precedes("a", "b", order: order), false)
    }

    func testPrecedesPrefersRankedKeyOverUnranked() {
        let order = ["a"]
        XCTAssertEqual(RemoteQuotaSourceGroupOrdering.precedes("a", "z", order: order), true)
        XCTAssertEqual(RemoteQuotaSourceGroupOrdering.precedes("z", "a", order: order), false)
    }

    /// Neither key has an opinion: caller's own tie-breaker must decide, not this function.
    func testPrecedesReturnsNilWhenNeitherKeyIsRanked() {
        XCTAssertNil(RemoteQuotaSourceGroupOrdering.precedes("x", "y", order: ["a", "b"]))
    }

    func testMovedSwapsWithinSiblingScope() {
        let order = ["a", "b", "c"]
        let moved = RemoteQuotaSourceGroupOrdering.moved(
            key: "c", direction: .up, order: order, siblingKeys: ["a", "b", "c"]
        )
        XCTAssertEqual(moved, ["a", "c", "b"])
    }

    /// A key with no persisted rank yet can still be moved — it's materialized (appended)
    /// before the swap.
    func testMovedMaterializesUnrankedSiblingBeforeSwapping() {
        let moved = RemoteQuotaSourceGroupOrdering.moved(
            key: "new", direction: .up, order: ["old"], siblingKeys: ["old", "new"]
        )
        XCTAssertEqual(moved, ["new", "old"])
    }

    func testMovedNoOpsAtTheBoundary() {
        let order = ["a", "b"]
        XCTAssertEqual(
            RemoteQuotaSourceGroupOrdering.moved(key: "a", direction: .up, order: order, siblingKeys: order),
            order
        )
        XCTAssertEqual(
            RemoteQuotaSourceGroupOrdering.moved(key: "b", direction: .down, order: order, siblingKeys: order),
            order
        )
    }

    /// Swapping two sibling keys must never disturb another scope's keys interleaved
    /// between them in the same persisted (global) order list.
    func testMovedLeavesInterleavedOtherScopeKeysUndisturbed() {
        let order = ["a1", "x1", "a2", "x2"]
        let moved = RemoteQuotaSourceGroupOrdering.moved(
            key: "a2", direction: .up, order: order, siblingKeys: ["a1", "a2"]
        )
        XCTAssertEqual(moved, ["a2", "x1", "a1", "x2"])
    }

    /// A key present in `order` but missing from `siblingKeys` (a hidden/re-enabled
    /// source) must keep its persisted rank untouched.
    func testMovedPreservesRankOfKeyMissingFromCurrentSiblings() {
        let order = ["a", "hidden", "b"]
        let moved = RemoteQuotaSourceGroupOrdering.moved(
            key: "b", direction: .up, order: order, siblingKeys: ["a", "b"]
        )
        XCTAssertEqual(moved, ["b", "hidden", "a"])
        XCTAssertTrue(moved.contains("hidden"))
    }

    /// A key that isn't among `siblingKeys` at all (not just unranked) is never
    /// materialized, so it's a true no-op — the persisted order comes back unchanged.
    func testMovedReturnsUnchangedOrderWhenKeyNotAmongSiblings() {
        let order = ["a", "b"]
        XCTAssertEqual(
            RemoteQuotaSourceGroupOrdering.moved(key: "missing", direction: .up, order: order, siblingKeys: ["a", "b"]),
            order
        )
    }

    // MARK: - orderedSelectedItems (status bar icon pin ordering)

    /// The user's example: two sources ("plus", "business") interleaved by provider,
    /// pinned/inserted in an unrelated order — the persisted group order must fully
    /// determine the display order, matching the same order the dropdown already uses.
    func testOrderedSelectedItemsAppliesGroupRankAcrossProviders() {
        let claude = MenuBarQuotaItem(provider: "claude", accountKey: "a", sourceConfigId: "plus")
        let codexPlus = MenuBarQuotaItem(provider: "codex", accountKey: "a", sourceConfigId: "plus")
        let codexBusiness = MenuBarQuotaItem(provider: "codex", accountKey: "b", sourceConfigId: "business")
        let grok = MenuBarQuotaItem(provider: "grok", accountKey: "a", sourceConfigId: "plus")
        let order = [
            RemoteQuotaSourceGroupIdentity.key(sourceId: "plus", provider: .claude),
            RemoteQuotaSourceGroupIdentity.key(sourceId: "plus", provider: .codex),
            RemoteQuotaSourceGroupIdentity.key(sourceId: "business", provider: .codex),
            RemoteQuotaSourceGroupIdentity.key(sourceId: "plus", provider: .grok),
        ]

        let ordered = RemoteQuotaSourceGroupOrdering.orderedSelectedItems(
            [codexBusiness, grok, claude, codexPlus],
            order: order
        )

        XCTAssertEqual(ordered, [claude, codexPlus, codexBusiness, grok])
    }

    /// A local pin (no `sourceConfigId`) and a remote pin whose group has no persisted
    /// rank must keep their original relative position rather than being pinned to a
    /// default slot.
    func testOrderedSelectedItemsLeavesLocalAndUnrankedItemsInOriginalRelativeOrder() {
        let local = MenuBarQuotaItem(provider: "claude", accountKey: "local@example.com")
        let unranked = MenuBarQuotaItem(provider: "codex", accountKey: "x", sourceConfigId: "unranked")
        let ranked = MenuBarQuotaItem(provider: "grok", accountKey: "a", sourceConfigId: "plus")
        let order = [RemoteQuotaSourceGroupIdentity.key(sourceId: "plus", provider: .grok)]

        let ordered = RemoteQuotaSourceGroupOrdering.orderedSelectedItems([local, ranked, unranked], order: order)

        XCTAssertEqual(ordered, [local, ranked, unranked])
    }

    /// Reordering only the two Codex sources (the user's very first source reorder,
    /// before any other group has a persisted rank) must never let a ranked Codex
    /// group jump ahead of the still-unranked Claude group, or push it past the
    /// still-unranked Grok group — the provider hierarchy the dropdown establishes
    /// must survive a reorder scoped to a single provider.
    func testOrderedSelectedItemsPreservesProviderHierarchyAfterFirstSourceReorder() {
        let claude = MenuBarQuotaItem(provider: "claude", accountKey: "a", sourceConfigId: "plus")
        let codexPlus = MenuBarQuotaItem(provider: "codex", accountKey: "a", sourceConfigId: "plus")
        let codexBusiness = MenuBarQuotaItem(provider: "codex", accountKey: "b", sourceConfigId: "business")
        let grok = MenuBarQuotaItem(provider: "grok", accountKey: "a", sourceConfigId: "plus")
        // Only the two Codex groups have ever been reordered; Claude and Grok have no
        // persisted rank yet.
        let order = [
            RemoteQuotaSourceGroupIdentity.key(sourceId: "business", provider: .codex),
            RemoteQuotaSourceGroupIdentity.key(sourceId: "plus", provider: .codex),
        ]

        let ordered = RemoteQuotaSourceGroupOrdering.orderedSelectedItems(
            [claude, codexPlus, codexBusiness, grok],
            order: order
        )

        XCTAssertEqual(ordered, [claude, codexBusiness, codexPlus, grok])
    }

    /// An empty persisted order (no custom order yet) must never mutate/reorder pins —
    /// the pre-existing pin/insertion order stays exactly as-is.
    func testOrderedSelectedItemsIsANoOpWhenNoCustomOrderIsPersisted() {
        let items = [
            MenuBarQuotaItem(provider: "codex", accountKey: "b", sourceConfigId: "business"),
            MenuBarQuotaItem(provider: "claude", accountKey: "a", sourceConfigId: "plus"),
        ]

        XCTAssertEqual(RemoteQuotaSourceGroupOrdering.orderedSelectedItems(items, order: []), items)
    }
}
