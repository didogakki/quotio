import XCTest
@testable import QuotioDomain

final class ProxyModelsTests: XCTestCase {
    func testEndpointUsesIPv4LoopbackForManagementAndLocalhostForClients() throws {
        let endpoint = try ProxyEndpoint(port: 8317)

        XCTAssertEqual(endpoint.baseURL, "http://127.0.0.1:8317")
        XCTAssertEqual(endpoint.managementURL, "http://127.0.0.1:8317/v0/management")
        XCTAssertEqual(endpoint.clientEndpoint, "http://localhost:8317/v1")
    }

    func testEndpointRejectsZeroPort() {
        XCTAssertThrowsError(try ProxyEndpoint(port: 0)) { error in
            XCTAssertEqual(error as? ProxyEndpointError, .invalidPort)
        }
    }

    func testLifecycleStateMachineAcceptsStartAndStopSequence() throws {
        var stateMachine = ProxyLifecycleStateMachine()

        try stateMachine.transition(to: .starting)
        try stateMachine.transition(to: .active)
        try stateMachine.transition(to: .stopping)
        try stateMachine.transition(to: .idle)

        XCTAssertEqual(stateMachine.state, .idle)
    }

    func testLifecycleStateMachineAcceptsUnexpectedActiveProcessExit() throws {
        var stateMachine = ProxyLifecycleStateMachine(state: .active)

        try stateMachine.transition(to: .idle)

        XCTAssertEqual(stateMachine.state, .idle)
    }

    func testLifecycleStateMachineRejectsIllegalTransitionWithoutChangingState() {
        var stateMachine = ProxyLifecycleStateMachine(state: .active)

        XCTAssertThrowsError(try stateMachine.transition(to: .testing)) { error in
            XCTAssertEqual(
                error as? ProxyLifecycleTransitionError,
                .illegal(from: .active, to: .testing)
            )
        }
        XCTAssertEqual(stateMachine.state, .active)
    }

    func testManagedAuthFileIsReadyForCurrentActiveStatus() {
        let file = ManagedAuthFile(
            id: "1", name: "codex-a", provider: "codex",
            status: "active", disabled: false, unavailable: false
        )

        XCTAssertTrue(file.isReady)
    }

    func testManagedAuthFileIsReadyForLegacyReadyStatus() {
        let file = ManagedAuthFile(
            id: "1", name: "codex-a", provider: "codex",
            status: "ready", disabled: false, unavailable: false
        )

        XCTAssertTrue(file.isReady)
    }

    /// Trackability is about existence, not usability: a cooling or unavailable account
    /// is still there and must keep being tracked, while an explicitly disabled one is a
    /// deliberate server-side user action and stays excluded.
    func testManagedAuthFileTrackabilitySeparatesExistenceFromUsability() {
        let ready = ManagedAuthFile(
            id: "1", name: "codex-a", provider: "codex",
            status: "active", disabled: false, unavailable: false
        )
        let cooling = ManagedAuthFile(
            id: "2", name: "codex-b", provider: "codex",
            status: "cooling", disabled: false, unavailable: false
        )
        let unavailable = ManagedAuthFile(
            id: "3", name: "codex-c", provider: "codex",
            status: "active", disabled: false, unavailable: true
        )
        let errored = ManagedAuthFile(
            id: "4", name: "codex-d", provider: "codex",
            status: "error", disabled: false, unavailable: false
        )
        let disabled = ManagedAuthFile(
            id: "5", name: "codex-e", provider: "codex",
            status: "cooling", disabled: true, unavailable: false
        )

        XCTAssertTrue(ready.isQuotaTrackable)
        XCTAssertTrue(cooling.isQuotaTrackable)
        XCTAssertTrue(unavailable.isQuotaTrackable)
        XCTAssertTrue(errored.isQuotaTrackable)
        XCTAssertFalse(disabled.isQuotaTrackable)

        XCTAssertFalse(ready.isTemporarilyUnavailable)
        XCTAssertTrue(cooling.isTemporarilyUnavailable)
        XCTAssertTrue(unavailable.isTemporarilyUnavailable)
        XCTAssertTrue(errored.isTemporarilyUnavailable)
        // A disabled file isn't tracked at all, so it is never "temporarily" anything.
        XCTAssertFalse(disabled.isTemporarilyUnavailable)
    }

    func testManagedAuthFileRejectsDisabledOrUnavailableOrErrorStatus() {
        let disabled = ManagedAuthFile(
            id: "1", name: "codex-a", provider: "codex",
            status: "active", disabled: true, unavailable: false
        )
        let unavailable = ManagedAuthFile(
            id: "2", name: "codex-b", provider: "codex",
            status: "active", disabled: false, unavailable: true
        )
        let errored = ManagedAuthFile(
            id: "3", name: "codex-c", provider: "codex",
            status: "error", disabled: false, unavailable: false
        )

        XCTAssertFalse(disabled.isReady)
        XCTAssertFalse(unavailable.isReady)
        XCTAssertFalse(errored.isReady)
    }

    func testManagedAuthFileMapsXaiProviderAliasToGrok() {
        let file = ManagedAuthFile(
            id: "1", name: "xai-a", provider: "xai",
            status: "active", disabled: false, unavailable: false
        )

        XCTAssertEqual(file.providerID, .grok)
    }

    // MARK: - recoveryDate(fetchedAt:)

    private static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecoveryDateResolvesAnExplicitUnfreezeAtField() {
        let file = ManagedAuthFile(
            id: "1", name: "claude-a", provider: "claude",
            status: "cooling", disabled: false, unavailable: false,
            unfreezeAt: .absolute("2027-01-15T06:00:00Z")
        )

        XCTAssertEqual(
            file.recoveryDate(fetchedAt: Self.fetchedAt),
            ISO8601DateFormatter().date(from: "2027-01-15T06:00:00Z")
        )
    }

    func testRecoveryDateResolvesARetryAfterDurationRelativeToFetchTime() {
        let file = ManagedAuthFile(
            id: "1", name: "claude-a", provider: "claude",
            status: "cooling", disabled: false, unavailable: false,
            retryAfter: .secondsFromNow(120)
        )

        XCTAssertEqual(file.recoveryDate(fetchedAt: Self.fetchedAt), Self.fetchedAt.addingTimeInterval(120))
    }

    /// Only one real field present (`frozenUntil`) — must resolve to exactly that time,
    /// never fall back to any other signal.
    func testRecoveryDateResolvesWhenOnlyFrozenUntilIsPresent() {
        let file = ManagedAuthFile(
            id: "1", name: "claude-a", provider: "claude",
            status: "cooling", disabled: false, unavailable: false,
            frozenUntil: .absolute("2027-01-15T06:00:00Z")
        )

        XCTAssertEqual(
            file.recoveryDate(fetchedAt: Self.fetchedAt),
            ISO8601DateFormatter().date(from: "2027-01-15T06:00:00Z")
        )
    }

    /// No recovery field at all, and no explicit timestamp in `statusMessage` — the
    /// result must be `nil`, never a guess.
    func testRecoveryDateIsNilWhenNoTimeFieldsArePresentAtAll() {
        let file = ManagedAuthFile(
            id: "1", name: "claude-a", provider: "claude",
            status: "cooling", statusMessage: "rate limited, please wait",
            disabled: false, unavailable: false
        )

        XCTAssertNil(file.recoveryDate(fetchedAt: Self.fetchedAt))
    }

    /// An unambiguous ISO-8601 timestamp embedded in `status_message` must never be
    /// treated as a recovery signal — free-text server copy can change at any time, or
    /// name when the freeze *started* rather than when it ends, so only the explicit
    /// structured fields count.
    func testRecoveryDateNeverInfersFromAnEmbeddedStatusMessageTimestamp() {
        let file = ManagedAuthFile(
            id: "1", name: "claude-a", provider: "claude",
            status: "cooling", statusMessage: "rate limited until 2027-01-15T06:00:00Z, please wait",
            disabled: false, unavailable: false
        )

        XCTAssertNil(file.recoveryDate(fetchedAt: Self.fetchedAt))
    }

    /// A vague relative phrase in `status_message` must never be interpreted as a time —
    /// `status_message` is never consulted for a recovery time at all.
    func testRecoveryDateNeverGuessesFromAVagueStatusMessagePhrase() {
        let file = ManagedAuthFile(
            id: "1", name: "claude-a", provider: "claude",
            status: "cooling", statusMessage: "will retry again shortly",
            disabled: false, unavailable: false
        )

        XCTAssertNil(file.recoveryDate(fetchedAt: Self.fetchedAt))
    }

    /// A structured field resolves regardless of what `status_message` separately claims
    /// — that free-text field is never consulted at all, structured or not.
    func testRecoveryDateResolvesFromStructuredFieldRegardlessOfStatusMessage() {
        let file = ManagedAuthFile(
            id: "1", name: "claude-a", provider: "claude",
            status: "cooling", statusMessage: "rate limited until 2099-01-01T00:00:00Z",
            disabled: false, unavailable: false,
            unfreezeAt: .absolute("2027-01-15T06:00:00Z")
        )

        XCTAssertEqual(
            file.recoveryDate(fetchedAt: Self.fetchedAt),
            ISO8601DateFormatter().date(from: "2027-01-15T06:00:00Z")
        )
    }

    /// `updatedAt`/`lastRefresh` describe when the listing itself was last touched, never
    /// this account's own unfreeze time — they must never be consulted as a recovery
    /// signal even when present and even when no structured recovery field is set.
    func testRecoveryDateNeverTreatsUpdatedAtOrLastRefreshAsRecoveryTime() {
        let file = ManagedAuthFile(
            id: "1", name: "claude-a", provider: "claude",
            status: "cooling", disabled: false, unavailable: false,
            updatedAt: "2027-01-15T06:00:00Z",
            lastRefresh: "2027-01-15T06:00:00Z"
        )

        XCTAssertNil(file.recoveryDate(fetchedAt: Self.fetchedAt))
    }

    /// A bare numeric recovery field this large could never plausibly be a short retry
    /// duration — it reads as a misclassified Unix epoch timestamp instead, which
    /// `AuthFileRecoveryTimeValue` never attempts to reinterpret (that would itself be a
    /// guess) — so it must resolve to `nil`, not a wildly-wrong date decades away.
    func testRecoveryDateRejectsAnImplausiblyLargeNumericDurationAsUnsupported() {
        let file = ManagedAuthFile(
            id: "1", name: "claude-a", provider: "claude",
            status: "cooling", disabled: false, unavailable: false,
            retryAfter: .secondsFromNow(1_800_000_000)
        )

        XCTAssertNil(file.recoveryDate(fetchedAt: Self.fetchedAt))
    }

    /// A short, plausible numeric duration must still resolve normally — the bound only
    /// rejects implausibly large values, never legitimate short retry delays.
    func testRecoveryDateStillResolvesAPlausibleShortNumericDuration() {
        let file = ManagedAuthFile(
            id: "1", name: "claude-a", provider: "claude",
            status: "cooling", disabled: false, unavailable: false,
            retryAfter: .secondsFromNow(600)
        )

        XCTAssertEqual(file.recoveryDate(fetchedAt: Self.fetchedAt), Self.fetchedAt.addingTimeInterval(600))
    }

    /// `next_retry_after` is documented as an absolute timestamp, not a duration — a bare
    /// number under that key must never be reinterpreted as "seconds from now", even
    /// though `retry_after` legitimately accepts that shape.
    func testRecoveryDateRejectsNumericNextRetryAfterAsUnsupported() {
        let file = ManagedAuthFile(
            id: "1", name: "claude-a", provider: "claude",
            status: "cooling", disabled: false, unavailable: false,
            nextRetryAfter: .secondsFromNow(3600)
        )

        XCTAssertNil(file.recoveryDate(fetchedAt: Self.fetchedAt))
    }

    /// `retry_after` remains the one field whose numeric value is a legitimate relative
    /// duration, so a plausible value there must still resolve.
    func testRecoveryDateResolvesNumericRetryAfterAsARelativeDuration() {
        let file = ManagedAuthFile(
            id: "1", name: "claude-a", provider: "claude",
            status: "cooling", disabled: false, unavailable: false,
            retryAfter: .secondsFromNow(3600)
        )

        XCTAssertEqual(file.recoveryDate(fetchedAt: Self.fetchedAt), Self.fetchedAt.addingTimeInterval(3600))
    }
}
