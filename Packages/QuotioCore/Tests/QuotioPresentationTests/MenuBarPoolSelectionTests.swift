import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

/// A legacy remote pin (`accountKey == "__pool__"`) covers whatever real accounts its
/// source currently reports, so the accounts screen has to show those accounts as
/// selected, let one of them be turned off individually, and keep that choice across a
/// relaunch — none of which a plain `selectedItems.contains` can express.
@MainActor
final class MenuBarPoolSelectionTests: XCTestCase {
    private let poolPin = MenuBarQuotaItem(
        provider: "codex",
        accountKey: RemoteQuotaPoolIdentity.accountKey,
        sourceConfigId: "src-1"
    )

    func testAccountsCoveredByALegacyPoolPinReadAsSelected() {
        let manager = makeManager(selectedItems: [poolPin])

        XCTAssertTrue(manager.isSelected(account("a")))
        XCTAssertTrue(manager.isSelected(account("b")))
    }

    /// Coverage is scoped to the pool pin's own source and provider — never to another
    /// source's accounts, and never to a different provider on the same source.
    func testPoolPinNeverCoversAnotherSourceOrProvider() {
        let manager = makeManager(selectedItems: [poolPin])

        XCTAssertFalse(manager.isSelected(account("a", sourceId: "src-2")))
        XCTAssertFalse(manager.isSelected(account("a", provider: "claude")))
        XCTAssertFalse(manager.isSelected(
            MenuBarQuotaItem(provider: "codex", accountKey: "local@example.com")
        ))
    }

    func testTurningOffOneCoveredAccountKeepsTheRestSelected() {
        let manager = makeManager(selectedItems: [poolPin])

        manager.toggleItem(account("a"))

        XCTAssertFalse(manager.isSelected(account("a")))
        XCTAssertTrue(manager.isSelected(account("b")))
        XCTAssertTrue(manager.isSelected(account("c")))
        XCTAssertEqual(
            manager.selectedItems, [poolPin],
            "the pool pin itself must survive so it still covers accounts that appear later"
        )
    }

    /// The whole point of persisting the exclusion separately: it has to come back after
    /// a relaunch, and the account must not then be rendered twice (once through the
    /// pool expansion, once through a stray individual pin).
    func testTurnedOffAccountStaysOffAcrossRelaunchWithoutDuplicating() {
        let repository = MemoryMenuBarPreferencesRepository()
        let manager = MenuBarSettingsManager(repository: repository)
        manager.selectedItems = [poolPin]
        manager.toggleItem(account("a"))

        let relaunched = MenuBarSettingsManager(repository: repository)

        XCTAssertFalse(relaunched.isSelected(account("a")))
        XCTAssertTrue(relaunched.isSelected(account("b")))
        XCTAssertFalse(relaunched.poolExpansionIncludes(account("a")))
        XCTAssertTrue(relaunched.poolExpansionIncludes(account("b")))
        XCTAssertEqual(relaunched.selectedItems, [poolPin])
    }

    func testTurningACoveredAccountBackOnRestoresIt() {
        let manager = makeManager(selectedItems: [poolPin])

        manager.toggleItem(account("a"))
        manager.toggleItem(account("a"))

        XCTAssertTrue(manager.isSelected(account("a")))
        XCTAssertTrue(manager.poolExpansionIncludes(account("a")))
        XCTAssertTrue(manager.deselectedPoolAccounts.isEmpty)
    }

    /// An account already covered by a pool pin must never also be added individually —
    /// that is what used to render the same account twice in the menu bar.
    func testCoveredAccountIsNeverAddedAsADuplicateIndividualPin() {
        let manager = makeManager(selectedItems: [poolPin])

        manager.addItem(account("a"))

        XCTAssertEqual(manager.selectedItems, [poolPin])
    }

    /// Exclusions live outside `selectedItems`, so shrinking the menu bar to a single
    /// item can never silently re-select an account the user turned off.
    func testLoweringTheItemCapNeverResurrectsATurnedOffAccount() {
        let manager = makeManager(selectedItems: [poolPin])
        manager.toggleItem(account("a"))

        manager.menuBarMaxItems = 1

        XCTAssertFalse(manager.isSelected(account("a")))
        XCTAssertTrue(manager.isSelected(account("b")))
    }

    /// Re-including an account inside a pool pin's coverage neither frees nor takes a
    /// menu bar slot, so it must still work when the selection is already at the cap.
    func testTurningACoveredAccountBackOnWorksAtTheItemCap() {
        let manager = makeManager(selectedItems: [poolPin])
        manager.menuBarMaxItems = 1
        manager.toggleItem(account("a"))
        XCTAssertTrue(manager.isAtMaxItems)

        manager.toggleItem(account("a"))

        XCTAssertTrue(manager.isSelected(account("a")))
    }

    /// Legacy state can have both a pool pin and a stray explicit per-account pin
    /// covering the same account at once. Removing only the explicit entry used to leave
    /// the pool pin's expansion covering it again immediately, so a single toggle
    /// silently failed to turn the account off.
    func testTogglingOffAnAccountWithBothAnExplicitPinAndPoolCoverageStaysOff() {
        let manager = makeManager(selectedItems: [poolPin, account("a")])

        manager.toggleItem(account("a"))

        XCTAssertFalse(manager.isSelected(account("a")))
        XCTAssertTrue(manager.isSelected(account("b")))
    }

    /// The exclusion recorded for the dually-covered case above must survive a relaunch
    /// just like the ordinary pool-only case does.
    func testTogglingOffADuallyCoveredAccountStaysOffAcrossRelaunch() {
        let repository = MemoryMenuBarPreferencesRepository()
        let manager = MenuBarSettingsManager(repository: repository)
        manager.selectedItems = [poolPin, account("a")]
        manager.toggleItem(account("a"))

        let relaunched = MenuBarSettingsManager(repository: repository)

        XCTAssertFalse(relaunched.isSelected(account("a")))
        XCTAssertTrue(relaunched.isSelected(account("b")))
    }

    /// Without a covering pool pin the ordinary per-account path still applies: toggling
    /// adds and removes a real entry rather than recording an exclusion.
    func testIndividualRemotePinStillTogglesNormallyWithoutAPoolPin() {
        let manager = makeManager(selectedItems: [])

        manager.toggleItem(account("a"))
        XCTAssertEqual(manager.selectedItems, [account("a")])
        XCTAssertTrue(manager.deselectedPoolAccounts.isEmpty)

        manager.toggleItem(account("a"))
        XCTAssertTrue(manager.selectedItems.isEmpty)
        XCTAssertTrue(manager.deselectedPoolAccounts.isEmpty)
    }

    /// Regression: three stale legacy pool pins whose every covered account has been
    /// individually turned off (or whose sources now report none at all) render
    /// nothing — the menu bar shows no accounts for them — but used to still occupy all
    /// three `menuBarMaxItems` slots forever, via raw `selectedItems.count`, blocking
    /// every future selection. Once `syncKnownRemoteAccountItems` reports those sources
    /// have zero real accounts, the empty pins must stop reserving capacity.
    func testFullyEmptyLegacyPoolPinsDoNotOccupyMenuBarCapacity() {
        let manager = makeManager(selectedItems: [
            MenuBarQuotaItem(provider: "claude", accountKey: RemoteQuotaPoolIdentity.accountKey, sourceConfigId: "src-1"),
            MenuBarQuotaItem(provider: "codex", accountKey: RemoteQuotaPoolIdentity.accountKey, sourceConfigId: "src-2"),
            MenuBarQuotaItem(provider: "codex", accountKey: RemoteQuotaPoolIdentity.accountKey, sourceConfigId: "src-3"),
        ])
        manager.menuBarMaxItems = 3

        // Every source these pools cover now reports no real accounts at all.
        manager.syncKnownRemoteAccountItems([])

        XCTAssertFalse(manager.isAtMaxItems, "three empty pools must not permanently block every future selection")

        let newPin = aggregate("pro", sourceId: "src-4")
        manager.addItem(newPin)

        XCTAssertTrue(manager.isSelected(newPin), "capacity freed by the empty pools must be usable")
    }

    /// The inverse: once an empty pool's source reports a real, non-excluded account
    /// again, it must resume occupying a slot — freed capacity is never permanent, it
    /// tracks the latest known state.
    func testPoolRegainingARealAccountReinstatesTheCap() {
        let poolPin = MenuBarQuotaItem(
            provider: "codex", accountKey: RemoteQuotaPoolIdentity.accountKey, sourceConfigId: "src-1"
        )
        let manager = makeManager(selectedItems: [poolPin])
        manager.menuBarMaxItems = 1
        manager.syncKnownRemoteAccountItems([])
        XCTAssertFalse(manager.isAtMaxItems, "the pool covers nothing yet, so the single slot is free")

        let newPin = aggregate("pro", sourceId: "src-4")
        manager.addItem(newPin)
        XCTAssertTrue(manager.isSelected(newPin))

        // The source behind the pool pin now reports a real, non-excluded account.
        manager.syncKnownRemoteAccountItems([account("a", sourceId: "src-1")])

        XCTAssertTrue(manager.isAtMaxItems, "the pool covering a real account again must reinstate the cap")
        let anotherPin = aggregate("team", sourceId: "src-5")
        manager.addItem(anotherPin)
        XCTAssertFalse(manager.isSelected(anotherPin), "capacity must stay blocked once the pool is non-empty again")
    }

    /// End-to-end regression for the persistence fix: three legacy pool pins that
    /// currently report zero real accounts, plus one freshly-pinned plan aggregate, is
    /// four raw pins against a `menuBarMaxItems` of 3. The aggregate must survive both an
    /// in-memory `menuBarMaxItems` change (which runs `enforceMaxItems`) and a simulated
    /// relaunch (which round-trips through the repository) without being dropped, since
    /// it never actually exceeds *effective* capacity.
    func testNewAggregateSurvivesRestartAlongsideThreeEmptyPoolPins() {
        let repository = MemoryMenuBarPreferencesRepository()
        let manager = MenuBarSettingsManager(repository: repository)
        manager.selectedItems = [
            MenuBarQuotaItem(provider: "claude", accountKey: RemoteQuotaPoolIdentity.accountKey, sourceConfigId: "src-1"),
            MenuBarQuotaItem(provider: "codex", accountKey: RemoteQuotaPoolIdentity.accountKey, sourceConfigId: "src-2"),
            MenuBarQuotaItem(provider: "codex", accountKey: RemoteQuotaPoolIdentity.accountKey, sourceConfigId: "src-3"),
        ]
        manager.menuBarMaxItems = 3
        manager.syncKnownRemoteAccountItems([])

        let newPin = aggregate("pro", sourceId: "src-4")
        manager.addItem(newPin)
        XCTAssertTrue(manager.isSelected(newPin))
        XCTAssertEqual(manager.selectedItems.count, 4, "all three empty pools plus the new pin must be kept")

        let relaunched = MenuBarSettingsManager(repository: repository)
        XCTAssertTrue(relaunched.isSelected(newPin), "the new pin must survive a relaunch, not just stay in memory")
        XCTAssertEqual(relaunched.selectedItems.count, 4)
    }

    /// Restoring an account inside a pool pin that is currently empty must be rejected
    /// once the effective selection is already at capacity — and, critically, must leave
    /// the exclusion in `deselectedPoolAccounts` untouched rather than clearing it and
    /// then silently failing to restore, which would let a *later* capacity change
    /// re-include the account without the user ever having chosen to.
    func testRestoringAnExcludedAccountInAnEmptyPoolIsRejectedAtCapacityWithoutClearingTheExclusion() {
        let manager = makeManager(selectedItems: [poolPin, aggregate("pro", sourceId: "src-9")])
        manager.menuBarMaxItems = 2
        manager.toggleItem(account("a"))
        manager.syncKnownRemoteAccountItems([])
        XCTAssertFalse(manager.isAtMaxItems, "the pool is empty, so only the aggregate occupies a slot")

        // Fill the freed slot, so restoring "a" would need a third slot.
        manager.addItem(account("z", sourceId: "src-9"))
        XCTAssertTrue(manager.isAtMaxItems)

        manager.toggleItem(account("a"))

        XCTAssertFalse(manager.isSelected(account("a")), "restoring must be rejected once at capacity")
        XCTAssertTrue(
            manager.deselectedPoolAccounts.contains(account("a").id),
            "the exclusion must survive the rejected restore attempt"
        )
    }

    /// Restoring a previously-excluded account never adds a duplicate entry to
    /// `selectedItems` — the pool's dynamic expansion (not a stored per-account pin) is
    /// still what covers it, exactly as before the exclusion. Must hold even alongside an
    /// independent aggregate pin for a different source.
    func testRestoringAnExcludedAccountNeverAddsADuplicateSelectedItemsEntry() {
        let manager = makeManager(selectedItems: [poolPin, aggregate("pro", sourceId: "src-9")])
        manager.toggleItem(account("a"))
        XCTAssertEqual(manager.selectedItems.count, 2)

        manager.toggleItem(account("a"))

        XCTAssertTrue(manager.isSelected(account("a")))
        XCTAssertEqual(
            manager.selectedItems, [poolPin, aggregate("pro", sourceId: "src-9")],
            "restoring must never insert a duplicate per-account pin"
        )
    }

    /// Before any remote sync has happened yet, a pool pin is assumed non-empty — "not
    /// yet known" must never be mistaken for "confirmed empty" — so restoring an
    /// excluded account under it claims no new slot. Once a sync confirms the pool is
    /// genuinely empty, the same restore now would occupy a new slot: the two states must
    /// read differently even though neither currently renders any account for this pool.
    func testToggleWouldOccupyNewSlotDistinguishesUnsyncedFromConfirmedEmptyPool() {
        let manager = makeManager(selectedItems: [poolPin])
        manager.toggleItem(account("a"))
        XCTAssertTrue(manager.deselectedPoolAccounts.contains(account("a").id))

        XCTAssertFalse(
            manager.toggleWouldOccupyNewSlot(account("a")),
            "no sync has happened yet, so the pool is assumed non-empty"
        )

        manager.syncKnownRemoteAccountItems([])

        XCTAssertTrue(
            manager.toggleWouldOccupyNewSlot(account("a")),
            "a sync confirming the pool covers nothing real must change the answer"
        )
    }

    // MARK: - Helpers

    /// One real remote account's pin, keyed exactly as the accounts screen keys it: the
    /// `RemoteQuotaAccountIdentity` storage key plus the owning source id.
    private func account(
        _ rawKey: String,
        sourceId: String = "src-1",
        provider: String = "codex"
    ) -> MenuBarQuotaItem {
        MenuBarQuotaItem(
            provider: provider,
            accountKey: RemoteQuotaAccountIdentity.storageKey(sourceId: sourceId, accountKey: rawKey),
            sourceConfigId: sourceId
        )
    }

    /// One plan aggregate's own pin, keyed with `RemoteQuotaAggregateIdentity` — never
    /// with `RemoteQuotaAccountIdentity` or the legacy `"__pool__"` sentinel.
    private func aggregate(
        _ planKey: String,
        sourceId: String = "src-1",
        provider: String = "codex"
    ) -> MenuBarQuotaItem {
        MenuBarQuotaItem(
            provider: provider,
            accountKey: RemoteQuotaAggregateIdentity.storageKey(sourceId: sourceId, planKey: planKey),
            sourceConfigId: sourceId
        )
    }

    private func makeManager(selectedItems: [MenuBarQuotaItem]) -> MenuBarSettingsManager {
        let manager = MenuBarSettingsManager(repository: MemoryMenuBarPreferencesRepository())
        manager.selectedItems = selectedItems
        return manager
    }
}

/// Regression coverage for the new plan-aggregate pin: it must behave as an ordinary,
/// independent pin — coexisting with per-account pins, never mistaken for coverage by a
/// legacy pool pin, and never appearing as one more account in the pool's expansion.
@MainActor
final class MenuBarAggregatePinTests: XCTestCase {
    private func account(
        _ rawKey: String,
        sourceId: String = "src-1",
        provider: String = "codex"
    ) -> MenuBarQuotaItem {
        MenuBarQuotaItem(
            provider: provider,
            accountKey: RemoteQuotaAccountIdentity.storageKey(sourceId: sourceId, accountKey: rawKey),
            sourceConfigId: sourceId
        )
    }

    private func aggregate(
        _ planKey: String,
        sourceId: String = "src-1",
        provider: String = "codex"
    ) -> MenuBarQuotaItem {
        MenuBarQuotaItem(
            provider: provider,
            accountKey: RemoteQuotaAggregateIdentity.storageKey(sourceId: sourceId, planKey: planKey),
            sourceConfigId: sourceId
        )
    }

    private func makeManager(selectedItems: [MenuBarQuotaItem] = []) -> MenuBarSettingsManager {
        let manager = MenuBarSettingsManager(repository: MemoryMenuBarPreferencesRepository())
        manager.selectedItems = selectedItems
        return manager
    }

    /// An aggregate pin and a real account pin for the same source/provider must be able
    /// to coexist — pinning one never implies or excludes the other.
    func testAggregatePinCoexistsWithAnIndependentAccountPin() {
        let manager = makeManager()

        manager.addItem(aggregate("pro"))
        manager.addItem(account("a"))

        XCTAssertTrue(manager.isSelected(aggregate("pro")))
        XCTAssertTrue(manager.isSelected(account("a")))
        XCTAssertEqual(manager.selectedItems.count, 2)
    }

    /// A legacy pool pin's coverage must never "accidentally" select an aggregate pin
    /// just because both are unpinned items under the same source and provider — the
    /// pool's dynamic expansion only ever produces real accounts.
    func testLegacyPoolPinDoesNotCoverAnAggregateIdentity() {
        let poolPin = MenuBarQuotaItem(
            provider: "codex",
            accountKey: RemoteQuotaPoolIdentity.accountKey,
            sourceConfigId: "src-1"
        )
        let manager = makeManager(selectedItems: [poolPin])

        XCTAssertFalse(manager.isCoveredByPoolPin(aggregate("pro")))
        XCTAssertFalse(manager.isSelected(aggregate("pro")))
    }

    /// Toggling an aggregate pin on/off behaves like any ordinary pin — it must not fall
    /// into the pool-coverage exclusion bookkeeping (`deselectedPoolAccounts`), since it
    /// was never covered by a pool pin to begin with.
    func testTogglingAnAggregatePinAddsAndRemovesItDirectly() {
        let poolPin = MenuBarQuotaItem(
            provider: "codex",
            accountKey: RemoteQuotaPoolIdentity.accountKey,
            sourceConfigId: "src-1"
        )
        let manager = makeManager(selectedItems: [poolPin])

        manager.toggleItem(aggregate("pro"))
        XCTAssertTrue(manager.isSelected(aggregate("pro")))
        XCTAssertTrue(manager.deselectedPoolAccounts.isEmpty)

        manager.toggleItem(aggregate("pro"))
        XCTAssertFalse(manager.isSelected(aggregate("pro")))
        XCTAssertTrue(manager.deselectedPoolAccounts.isEmpty)
    }
}

/// The dropdown-visibility toggle (`hiddenDropdownKeys`) is purely a display
/// filter: it must never touch `selectedItems`/pins, and must persist and default
/// correctly like every other menu bar preference.
@MainActor
final class MenuBarDropdownVisibilityTests: XCTestCase {
    func testHidingAnAccountDoesNotAffectItsPin() {
        let manager = MenuBarSettingsManager(repository: MemoryMenuBarPreferencesRepository())
        let key = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "a")
        let pin = MenuBarQuotaItem(provider: "codex", accountKey: key, sourceConfigId: "src-1")
        manager.addItem(pin)

        manager.toggleDropdownVisibility(key)

        XCTAssertTrue(manager.isHiddenFromDropdown(key))
        XCTAssertTrue(manager.isSelected(pin), "hiding must never unpin the account")
    }

    func testToggleDropdownVisibilityIsReversible() {
        let manager = MenuBarSettingsManager(repository: MemoryMenuBarPreferencesRepository())
        let key = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "a")

        XCTAssertFalse(manager.isHiddenFromDropdown(key))
        manager.toggleDropdownVisibility(key)
        XCTAssertTrue(manager.isHiddenFromDropdown(key))
        manager.toggleDropdownVisibility(key)
        XCTAssertFalse(manager.isHiddenFromDropdown(key))
    }

    func testHiddenKeysPersistAcrossRelaunch() {
        let repository = MemoryMenuBarPreferencesRepository()
        let key = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "a")
        let manager = MenuBarSettingsManager(repository: repository)
        manager.toggleDropdownVisibility(key)

        let relaunched = MenuBarSettingsManager(repository: repository)

        XCTAssertTrue(relaunched.isHiddenFromDropdown(key))
    }

    /// Pre-existing persisted preferences (written before this feature existed) have no
    /// `hiddenDropdownKeys` value at all — that must decode to "nothing hidden", not a
    /// crash or a spurious default.
    func testMissingHiddenKeysFieldDefaultsToEmpty() {
        let preferences = MenuBarPreferences()
        XCTAssertTrue(preferences.hiddenDropdownKeys.isEmpty)
    }
}

// MARK: - Test doubles

/// Persists across manager instances so a "relaunch" can be simulated by constructing a
/// second manager over the same storage.
private final class MemoryMenuBarPreferencesRepository: MenuBarPreferencesRepository, @unchecked Sendable {
    private var stored = MenuBarPreferences()

    func load() -> MenuBarPreferences { stored }
    func save(_ preferences: MenuBarPreferences) { stored = preferences }
}
