import Foundation
import QuotioDomain

/// Pure mapping from a remote quota pool's plan groups to menu bar display items.
/// Pulled out of `CompositionRoot` so the "always show a plan label, respect the total
/// item cap" behavior is unit-testable without a UI snapshot.
public enum RemoteQuotaPoolDisplayMapper {
    public struct PlanGroup {
        public let planKey: String
        public let quota: ProviderQuota

        public init(planKey: String, quota: ProviderQuota) {
            self.planKey = planKey
            self.quota = quota
        }
    }

    /// Builds one `MenuBarQuotaDisplayItem` per plan group, sorted by plan key for a
    /// stable order. Every item carries a `groupLabel` — even when there is exactly one
    /// group — so a single-plan pool still identifies itself (e.g. "Codex Business")
    /// next to the provider icon instead of reading as an anonymous account.
    public static func displayItems(
        itemId: String,
        provider: QuotaProvider,
        groups: [PlanGroup],
        stackPairedQuotaMetrics: Bool,
        totalUsagePercent: ([(name: String, percentage: Double)]) -> Double
    ) -> [MenuBarQuotaDisplayItem] {
        groups.sorted { $0.planKey < $1.planKey }.map { group in
            var displayPercent: Double = -1
            var quotaPair: MenuBarQuotaPair?
            if !group.quota.models.isEmpty {
                let models = group.quota.models.map { (name: $0.name, percentage: $0.percentage) }
                displayPercent = totalUsagePercent(models)
                if stackPairedQuotaMetrics {
                    quotaPair = MenuBarQuotaPair.resolve(for: provider, from: group.quota.models)
                }
            }
            // `accountDisplayName` is populated with the remote source's name by
            // `RemoteQuotaSourceScreenModel.visibleProviderQuotas`; never fall back to
            // the internal `RemoteQuotaPoolIdentity.accountKey` sentinel here.
            let accountShort = group.quota.accountDisplayName ?? provider.displayName
            return MenuBarQuotaDisplayItem(
                id: "\(itemId):\(group.planKey)",
                providerSymbol: provider.menuBarSymbol,
                accountShort: accountShort,
                percentage: displayPercent,
                provider: provider,
                isForbidden: group.quota.isForbidden,
                quotaPair: quotaPair,
                groupLabel: QuotaPolicy.planGroupDisplayLabel(
                    provider: provider,
                    planKey: group.planKey,
                    rawPlanType: group.quota.planType
                )
            )
        }
    }
}
