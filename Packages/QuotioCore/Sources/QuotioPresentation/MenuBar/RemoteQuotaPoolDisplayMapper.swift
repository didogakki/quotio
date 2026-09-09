import Foundation
import QuotioDomain

/// Pure mapping used only to keep a **legacy** pinned selection working: before
/// per-account remote pins existed, pinning a remote source's pool persisted a
/// `MenuBarQuotaItem` with `accountKey == RemoteQuotaPoolIdentity.accountKey` scoped to
/// one source+provider. That old selection must keep showing something meaningful
/// instead of silently vanishing or collapsing into a synthetic aggregate, so it is
/// expanded here into one display item per **real** remote account currently present
/// for that source/provider — never a plan-level or pool-level aggregate. New pins
/// target one real account's own storage key directly and never go through this path.
public enum RemoteQuotaPoolDisplayMapper {
    public struct AccountEntry {
        public let accountKey: String
        public let quota: ProviderQuota

        public init(accountKey: String, quota: ProviderQuota) {
            self.accountKey = accountKey
            self.quota = quota
        }
    }

    /// Builds one `MenuBarQuotaDisplayItem` per real remote account, sorted by display
    /// name for a stable order. Every item carries a `groupLabel` set to that account's
    /// own display name (never a plan label, never the internal pool sentinel), so a
    /// legacy pool pin with several accounts still distinguishes each one in the compact
    /// menu bar row instead of reading as duplicate anonymous entries.
    public static func displayItems(
        itemId: String,
        provider: QuotaProvider,
        accounts: [AccountEntry],
        stackPairedQuotaMetrics: Bool,
        totalUsagePercent: ([(name: String, percentage: Double)]) -> Double
    ) -> [MenuBarQuotaDisplayItem] {
        accounts
            .sorted { ($0.quota.accountDisplayName ?? $0.accountKey) < ($1.quota.accountDisplayName ?? $1.accountKey) }
            .map { entry in
                var displayPercent: Double = -1
                var quotaPair: MenuBarQuotaPair?
                if !entry.quota.models.isEmpty {
                    let models = entry.quota.models.map { (name: $0.name, percentage: $0.percentage) }
                    displayPercent = totalUsagePercent(models)
                    if stackPairedQuotaMetrics {
                        quotaPair = MenuBarQuotaPair.resolve(for: provider, from: entry.quota.models)
                    }
                }
                // `accountDisplayName` is the remote account's own email/name, set by the
                // fetcher; never fall back to the internal `RemoteQuotaPoolIdentity`/
                // `RemoteQuotaAccountIdentity` sentinel or raw storage key here.
                let accountShort = entry.quota.accountDisplayName ?? provider.displayName
                return MenuBarQuotaDisplayItem(
                    id: "\(itemId):\(entry.accountKey)",
                    providerSymbol: provider.menuBarSymbol,
                    accountShort: accountShort,
                    percentage: displayPercent,
                    provider: provider,
                    isForbidden: entry.quota.isForbidden,
                    quotaPair: quotaPair,
                    groupLabel: accountShort
                )
            }
    }
}
