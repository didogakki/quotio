import Foundation
import QuotioDomain

/// Pure mapping for a pinned plan aggregate (`selectedItem.isRemote && selectedItem.isAggregate`).
/// The plan name (e.g. "Plus"/"Pro"/the localized "Unknown") is never the account's own
/// identity, so it goes in `groupLabel` — the field the compact menu bar row actually
/// renders next to the provider icon — mirroring how `RemoteQuotaPoolDisplayMapper` puts
/// each legacy pool account's own display name there instead. `accountShort` falls back to
/// the provider's own display name, matching that same mapper's pattern for an item with no
/// account identity of its own.
public enum RemoteQuotaAggregatePinDisplayMapper {
    /// Explicit, localized label for accounts that report no recognizable plan — never a
    /// guessed plan name — matching the same `planKey == "unknown"` handling `ProvidersScreen`
    /// applies for this aggregate.
    @MainActor
    public static func planLabel(
        provider: QuotaProvider,
        planKey: String,
        rawPlanType: String?
    ) -> String {
        planKey == "unknown"
            ? "providers.aggregate.planUnknown".localizedStatic()
            : QuotaPolicy.planGroupDisplayLabel(
                provider: provider,
                planKey: planKey,
                rawPlanType: rawPlanType
            )
    }

    @MainActor
    public static func displayItem(
        itemId: String,
        provider: QuotaProvider,
        planKey: String,
        aggregate: RemoteQuotaPlanAggregate,
        totalUsagePercent: ([(name: String, percentage: Double)]) -> Double
    ) -> MenuBarQuotaDisplayItem {
        var displayPercent: Double = -1
        if !aggregate.quota.models.isEmpty {
            let models = aggregate.quota.models.map { (name: $0.name, percentage: $0.percentage) }
            displayPercent = totalUsagePercent(models)
        }

        let label = planLabel(provider: provider, planKey: planKey, rawPlanType: aggregate.quota.planType)

        return MenuBarQuotaDisplayItem(
            id: itemId,
            providerSymbol: provider.menuBarSymbol,
            accountShort: provider.displayName,
            percentage: displayPercent,
            provider: provider,
            isForbidden: aggregate.quota.isForbidden,
            quotaPair: nil,
            groupLabel: label
        )
    }
}
