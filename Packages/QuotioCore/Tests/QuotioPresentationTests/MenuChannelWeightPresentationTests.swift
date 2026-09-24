import Foundation
import QuotioDomain
import SwiftUI
import XCTest

@testable import QuotioPresentation

@MainActor
final class MenuChannelWeightPresentationTests: XCTestCase {
    private func makeAccount(
        accountKey: String,
        accountWeight: Int?,
        channelWeight: Int,
        updatedAt: Date,
        origin: StatusBarMenuAccountOrigin = .local
    ) -> StatusBarMenuAccountSnapshot {
        let routingWeight = accountWeight.map {
            AccountRoutingWeight(accountWeight: $0, channelWeight: channelWeight, updatedAt: updatedAt)
        }
        return StatusBarMenuAccountSnapshot(
            id: QuotaAccountID(provider: .codex, accountKey: accountKey),
            email: accountKey,
            quota: ProviderQuota(routingWeight: routingWeight),
            subscription: nil,
            isActiveInIDE: false,
            isRefreshing: false,
            isRefreshBlocked: false,
            origin: origin
        )
    }

    func testSingleAccountGroupNeverShowsAnyWeight() {
        let now = Date()
        let accounts = [makeAccount(accountKey: "a", accountWeight: 37, channelWeight: 75, updatedAt: now)]

        let presentation = MenuChannelWeightPresentation(accounts: accounts)

        XCTAssertFalse(presentation.isMultiAccount)
        XCTAssertNil(presentation.channelWeight)
        XCTAssertEqual(presentation.segments, [])
    }

    func testMultiAccountGroupWithAllWeightsZeroOrMissingHasNoSegments() {
        let now = Date()
        let accounts = [
            makeAccount(accountKey: "a", accountWeight: 0, channelWeight: 75, updatedAt: now),
            makeAccount(accountKey: "b", accountWeight: nil, channelWeight: 75, updatedAt: now),
        ]

        let presentation = MenuChannelWeightPresentation(accounts: accounts)

        XCTAssertTrue(presentation.isMultiAccount)
        XCTAssertEqual(presentation.segments, [])
    }

    func testMultiAccountGroupExcludesZeroWeightAccountsButKeepsOrder() {
        let now = Date()
        let accounts = [
            makeAccount(accountKey: "a", accountWeight: 37, channelWeight: 75, updatedAt: now),
            makeAccount(accountKey: "b", accountWeight: 0, channelWeight: 75, updatedAt: now),
            makeAccount(accountKey: "c", accountWeight: 35, channelWeight: 75, updatedAt: now),
            makeAccount(accountKey: "d", accountWeight: 30, channelWeight: 75, updatedAt: now),
        ]

        let presentation = MenuChannelWeightPresentation(accounts: accounts)

        XCTAssertEqual(presentation.segments, [37, 35, 30])
    }

    func testChannelWeightCanShowWithoutAnySegments() {
        let now = Date()
        let accounts = [
            makeAccount(accountKey: "a", accountWeight: 0, channelWeight: 25, updatedAt: now),
            makeAccount(accountKey: "b", accountWeight: 0, channelWeight: 25, updatedAt: now),
        ]

        let presentation = MenuChannelWeightPresentation(accounts: accounts)

        XCTAssertEqual(presentation.channelWeight, 25)
        XCTAssertEqual(presentation.segments, [])
    }

    func testDisagreeingChannelWeightsAtTheSameTimestampHideTheChannelWeight() {
        let now = Date()
        let accounts = [
            makeAccount(accountKey: "a", accountWeight: 37, channelWeight: 75, updatedAt: now),
            makeAccount(accountKey: "b", accountWeight: 35, channelWeight: 25, updatedAt: now),
        ]

        let presentation = MenuChannelWeightPresentation(accounts: accounts)

        XCTAssertNil(presentation.channelWeight)
        XCTAssertEqual(presentation.segments, [37, 35])
    }

    // MARK: - channelAccents sequencing

    func testChannelAccentsOnlyAdvanceForMultiAccountGroups() {
        // Single, multi, single, multi, multi: the two singles must not consume a color,
        // so the three multis land on indigo(0), teal(1), pink(2) in order.
        let flags = [false, true, false, true, true]

        let accents = MenuChannelWeightPresentation.channelAccents(forMultiAccountFlags: flags)

        XCTAssertEqual(accents.count, flags.count)
        XCTAssertNil(accents[0])
        XCTAssertNotNil(accents[1])
        XCTAssertNil(accents[2])
        XCTAssertNotNil(accents[3])
        XCTAssertNotNil(accents[4])
        XCTAssertEqual(accents[1], MenuBarPalette.channelColor(at: 0))
        XCTAssertEqual(accents[3], MenuBarPalette.channelColor(at: 1))
        XCTAssertEqual(accents[4], MenuBarPalette.channelColor(at: 2))
    }

    func testChannelAccentsCycleAfterFourthMultiAccountGroup() {
        // A 5th multi-account group must cycle back to the first (indigo) color rather
        // than index out of the four-color palette.
        let flags = [true, true, true, true, true]

        let accents = MenuChannelWeightPresentation.channelAccents(forMultiAccountFlags: flags)

        XCTAssertEqual(accents[4], accents[0])
        XCTAssertEqual(accents[4], MenuBarPalette.channelColor(at: 0))
    }

    func testChannelAccentsAssignIndigoToLocalNoWeightGroupThenTealToRemoteGroup() {
        // First group: local, multi-account, but no routing weight at all — it must
        // still consume the first accent slot (indigo) despite having no segments.
        let now = Date()
        let localNoWeightGroup = [
            makeAccount(accountKey: "a", accountWeight: nil, channelWeight: 0, updatedAt: now, origin: .local),
            makeAccount(accountKey: "b", accountWeight: nil, channelWeight: 0, updatedAt: now, origin: .local),
        ]
        // Second group: a different remote source, multi-account, with weights — it
        // must land on the next accent slot (teal), not restart at indigo.
        let remoteOrigin = StatusBarMenuAccountOrigin.remote(sourceId: "src-1", sourceName: "Remote")
        let remoteGroup = [
            makeAccount(accountKey: "c", accountWeight: 60, channelWeight: 80, updatedAt: now, origin: remoteOrigin),
            makeAccount(accountKey: "d", accountWeight: 40, channelWeight: 80, updatedAt: now, origin: remoteOrigin),
        ]

        let presentations = [localNoWeightGroup, remoteGroup].map { MenuChannelWeightPresentation(accounts: $0) }
        let accents = MenuChannelWeightPresentation.channelAccents(forMultiAccountFlags: presentations.map(\.isMultiAccount))

        XCTAssertTrue(presentations[0].isMultiAccount)
        XCTAssertEqual(presentations[0].segments, [])
        XCTAssertEqual(accents[0], MenuBarPalette.channelColor(at: 0))
        XCTAssertEqual(accents[1], MenuBarPalette.channelColor(at: 1))
    }

    func testChannelAccentsAllNilWhenNoGroupIsMultiAccount() {
        let accents = MenuChannelWeightPresentation.channelAccents(forMultiAccountFlags: [false, false])

        XCTAssertEqual(accents, [nil, nil])
    }

    // MARK: - WeightDistributionBar.widths

    func testSegmentWidthsSumToContentWidthMinusSpacing() {
        // Original A4 handoff values: three accounts at 37/35/30, which sum to 102
        // (not a 100 total) — widths() normalizes by that actual sum, not by 100.
        let segments = [37, 35, 30]
        let contentWidth: CGFloat = 360 - 14 * 2

        let widths = WeightDistributionBar.widths(segments: segments, contentWidth: contentWidth)

        XCTAssertEqual(widths.count, segments.count)
        let spacing = WeightDistributionBar.segmentSpacing * CGFloat(segments.count - 1)
        let sum = widths.reduce(0, +)
        XCTAssertEqual(sum, contentWidth - spacing, accuracy: 0.001)
        // Proportional ordering matches the input weight ordering.
        XCTAssertGreaterThan(widths[0], widths[1])
        XCTAssertGreaterThan(widths[1], widths[2])
        // Ratio is computed against the true sum (102), not a silently assumed 100:
        // the first segment must be available * 37 / 102, not available * 37 / 100.
        let available = contentWidth - spacing
        let expectedFirstWidth = available * 37 / 102
        XCTAssertEqual(widths[0], expectedFirstWidth, accuracy: 0.001)
        let widthIfNormalizedTo100 = available * 37 / 100
        XCTAssertNotEqual(widths[0], widthIfNormalizedTo100, accuracy: 0.001)
    }

    func testSegmentWidthsEmptyWhenTotalIsZero() {
        let widths = WeightDistributionBar.widths(segments: [0, 0], contentWidth: 332)

        XCTAssertEqual(widths, [])
    }

    func testSegmentWidthsEmptyForNoSegments() {
        let widths = WeightDistributionBar.widths(segments: [], contentWidth: 332)

        XCTAssertEqual(widths, [])
    }
}
