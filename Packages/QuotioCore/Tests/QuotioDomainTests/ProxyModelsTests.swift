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
}
