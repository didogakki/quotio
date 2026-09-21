import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class MenuBarSelectionOrderTests: XCTestCase {
    private func pin(_ plan: String) -> MenuBarQuotaItem {
        let provider: QuotaProvider = plan == "pro" ? .claude : .codex
        let sourceId = plan == "team" ? "business" : "plus"
        return MenuBarQuotaItem(
            provider: provider.rawValue,
            accountKey: RemoteQuotaAggregateIdentity.storageKey(sourceId: sourceId, planKey: plan),
            sourceConfigId: sourceId
        )
    }

    private func enablePins(_ manager: MenuBarSettingsManager) {
        manager.menuBarMaxItems = 3
        for plan in ["pro", "plus", "team"] {
            manager.toggleItem(pin(plan))
        }
    }

    func testProPlusTeamFollowSignalToggleOrder() {
        let manager = MenuBarSettingsManager(repository: OrderPreferencesRepository())
        enablePins(manager)

        XCTAssertEqual(manager.statusBarSelectedItems, [pin("pro"), pin("plus"), pin("team")])
    }

    func testTurningProOffAndBackOnAppendsItToTheEnd() {
        let manager = MenuBarSettingsManager(repository: OrderPreferencesRepository())
        enablePins(manager)
        manager.toggleItem(pin("pro"))
        XCTAssertEqual(manager.statusBarSelectedItems, [pin("plus"), pin("team")])
        manager.toggleItem(pin("pro"))

        XCTAssertEqual(manager.statusBarSelectedItems, [pin("plus"), pin("team"), pin("pro")])
    }

    func testReenabledPinOrderSurvivesPreferencesReload() {
        let repository = OrderPreferencesRepository()
        let manager = MenuBarSettingsManager(repository: repository)
        enablePins(manager)
        manager.toggleItem(pin("pro"))
        manager.toggleItem(pin("pro"))

        let reloaded = MenuBarSettingsManager(repository: repository)
        XCTAssertEqual(reloaded.statusBarSelectedItems, [pin("plus"), pin("team"), pin("pro")])
    }

    func testSourceGroupMovementDoesNotReorderStatusBarEvenAfterReload() {
        let repository = OrderPreferencesRepository()
        let manager = MenuBarSettingsManager(repository: repository)
        enablePins(manager)
        let keys = ["pro", "plus", "team"].map { plan in
            let item = pin(plan)
            return RemoteQuotaSourceGroupIdentity.key(
                sourceId: item.sourceConfigId!, provider: item.aiProvider!
            )
        }
        manager.moveSourceGroup(
            sourceId: "business", provider: .codex, direction: .up,
            siblingKeys: [keys[1], keys[2]]
        )

        XCTAssertEqual(manager.sourceGroupOrder, [keys[2], keys[1]])
        XCTAssertFalse(manager.sourceGroupOrder.contains(keys[0]))
        XCTAssertEqual(manager.statusBarSelectedItems.first, pin("pro"), "Codex source movement must not move Claude Pro")
        XCTAssertEqual(manager.statusBarSelectedItems, [pin("pro"), pin("plus"), pin("team")])
        let reloaded = MenuBarSettingsManager(repository: repository)
        XCTAssertEqual(reloaded.sourceGroupOrder, manager.sourceGroupOrder)
        XCTAssertEqual(reloaded.statusBarSelectedItems.first, pin("pro"))
        XCTAssertEqual(reloaded.statusBarSelectedItems, [pin("pro"), pin("plus"), pin("team")])
    }

    /// The first `moveAccount` in a scope must materialize every sibling it was given —
    /// in the order they were displayed — so the moved account swaps with exactly one
    /// neighbour and nothing else in that group shifts. The result must survive a
    /// preferences reload, and must leave pins untouched.
    func testMovingAnAccountUpMaterializesItsGroupOrderAndPersists() {
        let repository = OrderPreferencesRepository()
        let manager = MenuBarSettingsManager(repository: repository)
        enablePins(manager)
        let ids = ["a", "b", "c"].map { key in
            MenuBarQuotaItem(
                provider: QuotaProvider.codex.rawValue,
                accountKey: RemoteQuotaAccountIdentity.storageKey(sourceId: "plus", accountKey: key),
                sourceConfigId: "plus"
            ).id
        }

        manager.moveAccount(itemId: ids[2], direction: .up, siblingIds: ids)

        XCTAssertEqual(manager.accountOrder, [ids[0], ids[2], ids[1]])
        XCTAssertEqual(manager.statusBarSelectedItems, [pin("pro"), pin("plus"), pin("team")])
        XCTAssertEqual(MenuBarSettingsManager(repository: repository).accountOrder, manager.accountOrder)
    }

    /// Moving past either end is a no-op rather than a wrap-around.
    func testMovingTheFirstAccountUpDoesNothing() {
        let manager = MenuBarSettingsManager(repository: OrderPreferencesRepository())
        let ids = ["a", "b"].map { key in
            MenuBarQuotaItem(provider: QuotaProvider.claude.rawValue, accountKey: key).id
        }

        manager.moveAccount(itemId: ids[0], direction: .up, siblingIds: ids)

        XCTAssertEqual(manager.accountOrder, ids)
    }
}

/// Isolated storage shared only by the test's manager instances; never uses real preferences.
private final class OrderPreferencesRepository: MenuBarPreferencesRepository, @unchecked Sendable {
    private var stored = MenuBarPreferences()

    func load() -> MenuBarPreferences { stored }
    func save(_ preferences: MenuBarPreferences) { stored = preferences }
}
