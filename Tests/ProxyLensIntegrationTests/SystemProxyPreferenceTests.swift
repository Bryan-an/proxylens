import AppKit
import ProxyLensApplication
import ProxyLensCore
import XCTest

@testable import ProxyLens

/// Whether capture rewrites the macOS system proxy is a user preference. Leaving it off
/// avoids the admin authentication macOS demands on every start, at the cost of only
/// capturing what is pointed at the proxy explicitly.
@MainActor
final class SystemProxyPreferenceTests: XCTestCase {
    func testThePreferenceDefaultsToOnAndPersists() throws {
        let suiteName = "SystemProxyPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTrafficSystemProxyStore(defaults: defaults, key: "test.key")

        XCTAssertTrue(store.configuresSystemProxy, "Existing behaviour is the default")

        store.save(configuresSystemProxy: false)

        XCTAssertFalse(store.configuresSystemProxy)
        XCTAssertFalse(
            UserDefaultsTrafficSystemProxyStore(defaults: defaults, key: "test.key")
                .configuresSystemProxy
        )
    }

    func testCaptureStartsWithoutTouchingTheSystemProxyWhenTurnedOff() async throws {
        let captureController = SystemProxyRecordingCaptureController()
        let store = InMemoryTrafficSystemProxyStore(configuresSystemProxy: false)
        let viewModel = makeViewModel(captureController: captureController, store: store)
        await viewModel.prepare()

        XCTAssertFalse(viewModel.currentConfiguresSystemProxy())

        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }

        let configuration = await captureController.lastConfiguration()
        XCTAssertEqual(configuration?.configuresSystemProxy, false)
    }

    func testCaptureStillConfiguresTheSystemProxyWhenLeftOn() async throws {
        let captureController = SystemProxyRecordingCaptureController()
        let viewModel = makeViewModel(
            captureController: captureController,
            store: InMemoryTrafficSystemProxyStore()
        )
        await viewModel.prepare()

        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }

        let configuration = await captureController.lastConfiguration()
        XCTAssertEqual(configuration?.configuresSystemProxy, true)
    }

    func testThePreferenceCannotChangeWhileCaptureIsRunning() async throws {
        let store = InMemoryTrafficSystemProxyStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.prepare()

        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }

        XCTAssertThrowsError(try viewModel.saveConfiguresSystemProxy(false)) { error in
            XCTAssertEqual(
                error as? TrafficSystemProxyStoreError,
                .captureMustBeStopped
            )
        }
        XCTAssertTrue(store.configuresSystemProxy)
    }

    func testTheListenerSheetExposesTheToggle() async throws {
        let store = InMemoryTrafficSystemProxyStore()
        let viewModel = makeViewModel(store: store)
        await viewModel.prepare()
        let manager = ReverseProxyManagerViewController(viewModel: viewModel)
        manager.loadView()
        manager.reloadRoutes()

        let toggle = try XCTUnwrap(
            descendant(in: manager.view, identifier: "reverseProxyManager.systemProxy")
                as? NSButton
        )
        XCTAssertEqual(toggle.state, .on)
        XCTAssertTrue(toggle.isEnabled)

        // performClick flips the checkbox and fires the action, which is what a real click
        // does; invoking the action alone would leave the state untouched.
        toggle.performClick(nil)

        XCTAssertEqual(toggle.state, .off)
        XCTAssertFalse(store.configuresSystemProxy)
        XCTAssertFalse(viewModel.currentConfiguresSystemProxy())

        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }
        manager.reloadRoutes()

        XCTAssertFalse(toggle.isEnabled, "Listener settings need capture stopped")
    }

    // MARK: - Helpers

    private func makeViewModel(
        captureController: any TrafficCaptureControlling =
            SystemProxyRecordingCaptureController(),
        store: any TrafficSystemProxyStoring = InMemoryTrafficSystemProxyStore()
    ) -> TrafficConsoleViewModel {
        TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: SystemProxyEmptyEventSource(),
            bodyReader: SystemProxyInlineBodyReader(),
            captureConfiguration: CaptureConfiguration(
                proxy: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                    interceptHTTPS: true
                ),
                configuresSystemProxy: true
            ),
            eventBatchDelay: .seconds(60),
            systemProxyStore: store
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the condition")
    }

    private func descendant(in view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = descendant(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }
}

private actor SystemProxyRecordingCaptureController: TrafficCaptureControlling {
    private var configuration: CaptureConfiguration?

    func recoverInterruptedCapture() {}

    func start(configuration: CaptureConfiguration) -> CaptureContext {
        self.configuration = configuration
        return CaptureContext(
            sessionID: SessionID(),
            endpoint: configuration.proxy.listenEndpoint,
            startedAt: Date(),
            configuration: configuration
        )
    }

    func stop() {}

    func lastConfiguration() -> CaptureConfiguration? { configuration }
}

private actor SystemProxyEmptyEventSource: TrafficFlowEventStreaming {
    func makeEventStream() -> AsyncStream<FlowEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor SystemProxyInlineBodyReader: TrafficBodyReading {
    func read(_: BodyReference) throws -> Data { Data() }
}
