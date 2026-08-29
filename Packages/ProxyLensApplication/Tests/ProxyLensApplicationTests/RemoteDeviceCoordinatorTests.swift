import Foundation
import ProxyLensCore
import XCTest

@testable import ProxyLensApplication

final class RemoteDeviceCoordinatorTests: XCTestCase {
    func testLoopbackClientsAreAdmittedEvenWhileRemoteAccessIsDisabled() async {
        let coordinator = RemoteDeviceCoordinator()

        let decision = await coordinator.authorize(
            RemoteAccessClient(address: "127.0.0.1", port: 51_000)
        )

        XCTAssertEqual(decision, .allow)
        let devices = await coordinator.devices()
        XCTAssertTrue(devices.isEmpty, "This Mac is not a remote device")
    }

    func testNetworkClientsAreRefusedWhileRemoteAccessIsDisabled() async {
        let coordinator = RemoteDeviceCoordinator()

        let decision = await coordinator.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_000)
        )

        XCTAssertEqual(decision, .deny)
    }

    func testConcurrentConnectionsFromOneDevicePromptOnceAndResumeTogether() async throws {
        let coordinator = RemoteDeviceCoordinator()
        await coordinator.setRemoteAccessEnabled(true)
        let requests = RequestRecorder()
        let stream = await coordinator.approvalChanges()
        let subscription = Task { await requests.consume(stream) }

        async let first = coordinator.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_000)
        )
        async let second = coordinator.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_001)
        )

        try await requests.waitForFirst()
        await coordinator.resolve(address: "192.168.1.7", approval: .allowOnce)

        let decisions = await [first, second]
        XCTAssertEqual(decisions, [.allow, .allow])
        let recorded = await requests.recorded()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.address, "192.168.1.7")

        subscription.cancel()
    }

    func testAlwaysAllowSurvivesARelaunchWhileAllowOnceDoesNot() async throws {
        let store = InMemoryRemoteDeviceStore()

        let first = RemoteDeviceCoordinator(store: store, approvalTimeout: .milliseconds(50))
        await first.setRemoteAccessEnabled(true)
        async let trusted = first.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_000)
        )
        async let temporary = first.authorize(
            RemoteAccessClient(address: "192.168.1.8", port: 51_000)
        )
        try await Task.sleep(for: .milliseconds(10))
        await first.resolve(address: "192.168.1.7", approval: .allowAlways)
        await first.resolve(address: "192.168.1.8", approval: .allowOnce)
        let initial = await [trusted, temporary]
        XCTAssertEqual(initial, [.allow, .allow])

        let relaunched = RemoteDeviceCoordinator(
            store: store,
            approvalTimeout: .milliseconds(50)
        )
        await relaunched.setRemoteAccessEnabled(true)

        let trustedAgain = await relaunched.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 52_000)
        )
        let temporaryAgain = await relaunched.authorize(
            RemoteAccessClient(address: "192.168.1.8", port: 52_000)
        )

        XCTAssertEqual(trustedAgain, .allow, "Always-allow must survive a relaunch")
        XCTAssertEqual(temporaryAgain, .deny, "Allow-once must not, so it times out unanswered")
    }

    func testAnUnansweredRequestIsDeniedWithoutBeingRemembered() async {
        let coordinator = RemoteDeviceCoordinator(approvalTimeout: .milliseconds(50))
        await coordinator.setRemoteAccessEnabled(true)

        let denied = await coordinator.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_000)
        )
        XCTAssertEqual(denied, .deny)

        // The timeout is not a decision: the device is still unresolved and prompts again.
        let devices = await coordinator.devices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertFalse(devices[0].isTrusted)
        let stillDenied = await coordinator.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_001)
        )
        XCTAssertEqual(stillDenied, .deny)
    }

    func testADeniedDeviceIsRefusedWithoutPromptingAgainThisSession() async throws {
        let coordinator = RemoteDeviceCoordinator()
        await coordinator.setRemoteAccessEnabled(true)
        let requests = RequestRecorder()
        let stream = await coordinator.approvalChanges()
        let subscription = Task { await requests.consume(stream) }

        async let first = coordinator.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_000)
        )
        try await requests.waitForFirst()
        await coordinator.resolve(address: "192.168.1.7", approval: .deny)
        let firstDecision = await first

        let secondDecision = await coordinator.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_001)
        )

        XCTAssertEqual(firstDecision, .deny)
        XCTAssertEqual(secondDecision, .deny)
        let recorded = await requests.recorded()
        XCTAssertEqual(recorded.count, 1, "A denied device must not prompt again this session")

        subscription.cancel()
    }

    func testRevokingADeviceMakesItPromptAgain() async throws {
        let store = InMemoryRemoteDeviceStore()
        let coordinator = RemoteDeviceCoordinator(store: store, approvalTimeout: .milliseconds(50))
        await coordinator.setRemoteAccessEnabled(true)

        async let pending = coordinator.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_000)
        )
        try await Task.sleep(for: .milliseconds(10))
        await coordinator.resolve(address: "192.168.1.7", approval: .allowAlways)
        _ = await pending

        await coordinator.revoke(address: "192.168.1.7")

        let afterRevoke = await coordinator.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_001)
        )
        XCTAssertEqual(afterRevoke, .deny, "A revoked device prompts again, so it times out")
        let stored = await store.loadDevices()
        XCTAssertFalse(stored.contains { $0.address == "192.168.1.7" && $0.isTrusted })
    }

    func testEndingTheSessionRefusesWaitersAndForgetsOnceOnlyDecisions() async throws {
        let coordinator = RemoteDeviceCoordinator()
        await coordinator.setRemoteAccessEnabled(true)
        let requests = RequestRecorder()
        let stream = await coordinator.approvalChanges()
        let subscription = Task { await requests.consume(stream) }

        await coordinator.resolve(address: "192.168.1.8", approval: .allowOnce)
        async let waiting = coordinator.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_000)
        )
        try await requests.waitForFirst()

        await coordinator.endSession()

        let decision = await waiting
        XCTAssertEqual(decision, .deny)

        await coordinator.setRemoteAccessEnabled(false)
        let afterSession = await coordinator.authorize(
            RemoteAccessClient(address: "192.168.1.8", port: 51_000)
        )
        XCTAssertEqual(afterSession, .deny)

        subscription.cancel()
    }

    func testRenamingADeviceKeepsItsAddressAsIdentity() async throws {
        let store = InMemoryRemoteDeviceStore()
        let coordinator = RemoteDeviceCoordinator(store: store, approvalTimeout: .milliseconds(50))
        await coordinator.setRemoteAccessEnabled(true)

        async let pending = coordinator.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_000)
        )
        try await Task.sleep(for: .milliseconds(10))
        await coordinator.resolve(address: "192.168.1.7", approval: .allowAlways)
        _ = await pending

        await coordinator.rename(address: "192.168.1.7", to: "Test iPhone")

        let devices = await coordinator.devices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].address, "192.168.1.7")
        XCTAssertEqual(devices[0].displayName, "Test iPhone")
        let stored = await store.loadDevices()
        XCTAssertEqual(stored.first?.name, "Test iPhone")
    }
}

/// Collects the approval requests the coordinator publishes.
private actor RequestRecorder {
    private var changes: [RemoteAccessApprovalChange] = []

    func consume(_ stream: AsyncStream<RemoteAccessApprovalChange>) async {
        for await change in stream {
            changes.append(change)
        }
    }

    /// Only the arrivals: a prompt shown to the user.
    private var requests: [RemoteAccessRequest] {
        changes.compactMap { change in
            guard case .requested(let request) = change else {
                return nil
            }
            return request
        }
    }

    func recorded() -> [RemoteAccessRequest] {
        requests
    }

    /// Waits for the first published request so a test can answer it deterministically.
    func waitForFirst(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while requests.isEmpty {
            guard ContinuousClock.now < deadline else {
                throw RecorderError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    enum RecorderError: Error {
        case timedOut
    }
}
