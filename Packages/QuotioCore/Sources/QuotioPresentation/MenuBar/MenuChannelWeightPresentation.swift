//
//  MenuChannelWeightPresentation.swift
//  QuotioPresentation
//
//  Pure per-group display model for the A4 menu-bar weight redesign
//  (docs/handoff/menubar-weight-a4) — computed once from a
//  `StatusBarMenuAccountGroup`'s accounts so the subheader, distribution bar, and every
//  account card's own footer in that group agree on the same numbers. No route/data
//  changes: this only reshapes values the renderer already reads.
//

import QuotioDomain
import SwiftUI

struct MenuChannelWeightPresentation: Equatable {
    /// A group of one account never shows a channel or account weight, regardless of
    /// whether that account happens to carry a routing-weight reading.
    let isMultiAccount: Bool
    /// `QuotaPolicy.reconciledChannelWeight` across the group's accounts — `nil` when
    /// no account carries a reading or the latest readings disagree. Always `nil` for a
    /// single-account group.
    let channelWeight: Int?
    /// Positive account weights, in the same order as `accounts`. An account with no
    /// routing-weight reading or a `0` reading is excluded here (though `0` still
    /// renders on that account's own card footer, in a neutral color) — always empty
    /// for a single-account group.
    let segments: [Int]

    init(accounts: [StatusBarMenuAccountSnapshot]) {
        isMultiAccount = accounts.count > 1
        channelWeight = isMultiAccount
            ? QuotaPolicy.reconciledChannelWeight(from: accounts.compactMap(\.quota.routingWeight))
            : nil
        segments = isMultiAccount
            ? accounts.compactMap { $0.quota.routingWeight?.accountWeight }.filter { $0 > 0 }
            : []
    }

    /// Assigns each group's channel-weight color in render order, restarting per
    /// provider — a color from `MenuBarPalette.channelColor` is only consumed for a
    /// multi-account group, so a single-account group interleaved between multi-account
    /// groups doesn't shift the indigo/teal/pink/sky cycle. Pure so it can be tested
    /// directly and so `StatusBarMenuRenderer.buildMenu` uses the same sequencing it's
    /// tested against.
    static func channelAccents(forMultiAccountFlags flags: [Bool]) -> [Color?] {
        var index = 0
        return flags.map { isMultiAccount in
            guard isMultiAccount else { return nil }
            let color = MenuBarPalette.channelColor(at: index)
            index += 1
            return color
        }
    }
}
