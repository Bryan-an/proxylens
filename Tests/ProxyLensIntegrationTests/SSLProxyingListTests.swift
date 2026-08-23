import ProxyLensApplication
import ProxyLensCore
import XCTest

@testable import ProxyLens

@MainActor
final class SSLProxyingListTests: XCTestCase {
    func testUserDefaultsStoreRoundTripsAndFailsClosedOnMalformedData() throws {
        let suiteName = "SSLProxyingListTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTrafficSSLProxyingStore(defaults: defaults, key: "test.key")

        XCTAssertEqual(store.policy, TLSInterceptionPolicy())

        let policy = try TLSInterceptionPolicy(
            mode: .interceptAllExcept,
            entries: ["*.apple.com"]
        )
        store.save(policy)
        XCTAssertEqual(store.policy, policy)
        XCTAssertEqual(
            UserDefaultsTrafficSSLProxyingStore(defaults: defaults, key: "test.key").policy,
            policy
        )

        defaults.set(Data("not json".utf8), forKey: "test.key")
        XCTAssertEqual(store.policy, TLSInterceptionPolicy())
    }

    func testViewModelSavesPolicyToStoreAndLiveSinkWhileCaptureRuns() async throws {
        let store = InMemoryTrafficSSLProxyingStore()
        let sink = MutableTLSInterceptionPolicy()
        let viewModel = makeViewModel(store: store, sink: sink)
        await viewModel.prepare()

        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }

        try viewModel.excludeHostFromTLSInterception("pinned.example.com")

        XCTAssertEqual(store.policy.entries, ["pinned.example.com"])
        XCTAssertFalse(sink.currentPolicy().shouldIntercept(host: "pinned.example.com"))
        XCTAssertFalse(viewModel.isHostIntercepted("pinned.example.com"))
        XCTAssertTrue(viewModel.isHostIntercepted("other.example.com"))

        try viewModel.interceptHostAgain("pinned.example.com")
        XCTAssertTrue(store.policy.entries.isEmpty)
        XCTAssertTrue(sink.currentPolicy().shouldIntercept(host: "pinned.example.com"))
        XCTAssertTrue(viewModel.isHostIntercepted("pinned.example.com"))
    }

    func testViewModelChangesModeAndSeedsTheLiveSinkOnPrepare() async throws {
        let store = InMemoryTrafficSSLProxyingStore(
            policy: try TLSInterceptionPolicy(
                mode: .interceptAllExcept,
                entries: ["seeded.example.com"]
            )
        )
        let sink = MutableTLSInterceptionPolicy()
        let viewModel = makeViewModel(store: store, sink: sink)
        await viewModel.prepare()

        XCTAssertFalse(sink.currentPolicy().shouldIntercept(host: "seeded.example.com"))

        try viewModel.setTLSInterceptionMode(.interceptOnly)
        XCTAssertEqual(store.policy.mode, .interceptOnly)
        XCTAssertTrue(sink.currentPolicy().shouldIntercept(host: "seeded.example.com"))
        XCTAssertFalse(sink.currentPolicy().shouldIntercept(host: "other.example.com"))
    }

    func testExcludeAndInterceptAgainAreSymmetricInInterceptOnlyMode() throws {
        let store = InMemoryTrafficSSLProxyingStore(
            policy: try TLSInterceptionPolicy(
                mode: .interceptOnly,
                entries: ["pinned.example.com"]
            )
        )
        let sink = MutableTLSInterceptionPolicy()
        let viewModel = makeViewModel(store: store, sink: sink)

        XCTAssertTrue(viewModel.isHostIntercepted("pinned.example.com"))
        XCTAssertFalse(viewModel.isHostIntercepted("other.example.com"))

        try viewModel.excludeHostFromTLSInterception("pinned.example.com")
        XCTAssertTrue(store.policy.entries.isEmpty)
        XCTAssertFalse(viewModel.isHostIntercepted("pinned.example.com"))

        try viewModel.interceptHostAgain("pinned.example.com")
        XCTAssertEqual(store.policy.entries, ["pinned.example.com"])
        XCTAssertTrue(viewModel.isHostIntercepted("pinned.example.com"))
    }

    func testHasExactEntryDistinguishesWildcardCoverageFromExactEntries() throws {
        let store = InMemoryTrafficSSLProxyingStore(
            policy: try TLSInterceptionPolicy(
                mode: .interceptAllExcept,
                entries: ["*.example.com"]
            )
        )
        let sink = MutableTLSInterceptionPolicy()
        let viewModel = makeViewModel(store: store, sink: sink)

        XCTAssertFalse(viewModel.isHostIntercepted("pinned.example.com"))
        XCTAssertFalse(viewModel.hasExactTLSInterceptionEntry("pinned.example.com"))

        try viewModel.interceptHostAgain("pinned.example.com")

        XCTAssertEqual(store.policy.entries, ["*.example.com"])
        XCTAssertFalse(viewModel.isHostIntercepted("pinned.example.com"))
    }

    private func makeViewModel(
        store: any TrafficSSLProxyingStoring,
        sink: MutableTLSInterceptionPolicy
    ) -> TrafficConsoleViewModel {
        TrafficConsoleViewModel(
            captureController: SSLProxyingRecordingCaptureController(),
            eventSource: SSLProxyingFinishedEventSource(),
            bodyReader: SSLProxyingInlineBodyReader(),
            captureConfiguration: CaptureConfiguration(
                proxy: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                    interceptHTTPS: true
                ),
                configuresSystemProxy: false
            ),
            eventBatchDelay: .seconds(60),
            sslProxyingStore: store,
            tlsInterceptionPolicySink: sink
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the condition")
    }
}

private actor SSLProxyingRecordingCaptureController: TrafficCaptureControlling {
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

private actor SSLProxyingFinishedEventSource: TrafficFlowEventStreaming {
    func makeEventStream() -> AsyncStream<FlowEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor SSLProxyingInlineBodyReader: TrafficBodyReading {
    func read(_: BodyReference) throws -> Data { Data() }
}
