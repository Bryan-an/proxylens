import AppKit
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
        try store.save(policy)
        XCTAssertEqual(store.policy, policy)
        XCTAssertEqual(
            UserDefaultsTrafficSSLProxyingStore(defaults: defaults, key: "test.key").policy,
            policy
        )

        defaults.set(Data("not json".utf8), forKey: "test.key")
        XCTAssertEqual(store.policy, TLSInterceptionPolicy())
    }

    func testUserDefaultsStoreRoundTripsAPolicyNearCoresMaximumSize() throws {
        let suiteName = "SSLProxyingListTests.MaxSize.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTrafficSSLProxyingStore(defaults: defaults, key: "test.key")

        let policy = try TLSInterceptionPolicy(
            mode: .interceptAllExcept,
            entries: Self.makeMaximalTLSInterceptionEntries()
        )

        try store.save(policy)

        XCTAssertEqual(store.policy, policy)
        XCTAssertEqual(
            UserDefaultsTrafficSSLProxyingStore(defaults: defaults, key: "test.key").policy,
            policy
        )
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

    func testInterceptHostAgainSkipsRedundantSaveWhenOnlyWildcardCoversTheHost() throws {
        let store = SSLProxyingCountingStore(
            policy: try TLSInterceptionPolicy(
                mode: .interceptAllExcept,
                entries: ["*.example.com"]
            )
        )
        let viewModel = makeViewModel(store: store, sink: MutableTLSInterceptionPolicy())

        try viewModel.interceptHostAgain("pinned.example.com")

        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(store.policy.entries, ["*.example.com"])
    }

    func testExcludeHostFromTLSInterceptionSkipsRedundantSaveWhenHostHasNoExactEntry() throws {
        let store = SSLProxyingCountingStore(
            policy: try TLSInterceptionPolicy(mode: .interceptOnly, entries: ["*.example.com"])
        )
        let viewModel = makeViewModel(store: store, sink: MutableTLSInterceptionPolicy())

        try viewModel.excludeHostFromTLSInterception("pinned.example.com")

        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(store.policy.entries, ["*.example.com"])
    }

    func testExactEntryOperationsNormalizeWhitespaceAndIPv6BracketsLikeMatches() throws {
        let store = InMemoryTrafficSSLProxyingStore(
            policy: try TLSInterceptionPolicy(mode: .interceptAllExcept, entries: ["::1"])
        )
        let sink = MutableTLSInterceptionPolicy()
        let viewModel = makeViewModel(store: store, sink: sink)

        XCTAssertTrue(viewModel.hasExactTLSInterceptionEntry("[::1]"))
        XCTAssertTrue(viewModel.hasExactTLSInterceptionEntry("  ::1  "))

        try viewModel.interceptHostAgain(" [::1] ")

        XCTAssertTrue(store.policy.entries.isEmpty)
        XCTAssertTrue(sink.currentPolicy().shouldIntercept(host: "::1"))
    }

    func testManagerSheetAddsAndRemovesEntriesWhileCaptureRuns() async throws {
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

        let controller = SSLProxyingManagerViewController(viewModel: viewModel)
        _ = controller.view

        let entryField = try XCTUnwrap(
            descendant(in: controller.view, identifier: "sslProxyingManager.entry")
                as? NSTextField
        )
        let addButton = try XCTUnwrap(
            descendant(in: controller.view, identifier: "sslProxyingManager.add") as? NSButton
        )
        let modeControl = try XCTUnwrap(
            descendant(in: controller.view, identifier: "sslProxyingManager.mode")
                as? NSSegmentedControl
        )
        let table = try XCTUnwrap(
            descendant(in: controller.view, identifier: "sslProxyingManager.table")
                as? NSTableView
        )

        // Capture is running and the controls stay enabled: this policy is hot.
        XCTAssertTrue(addButton.isEnabled)
        XCTAssertTrue(modeControl.isEnabled)

        entryField.stringValue = "*.apple.com"
        _ = addButton.target?.perform(addButton.action, with: addButton)

        XCTAssertEqual(store.policy.entries, ["*.apple.com"])
        XCTAssertFalse(sink.currentPolicy().shouldIntercept(host: "push.apple.com"))
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(controller.numberOfEntries, 1)

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let removeButton = try XCTUnwrap(
            descendant(in: controller.view, identifier: "sslProxyingManager.remove")
                as? NSButton
        )
        _ = removeButton.target?.perform(removeButton.action, with: removeButton)

        XCTAssertTrue(store.policy.entries.isEmpty)
        XCTAssertTrue(sink.currentPolicy().shouldIntercept(host: "push.apple.com"))
        XCTAssertEqual(controller.numberOfEntries, 0)
    }

    func testManagerSheetRejectsInvalidEntriesWithVisibleValidation() async throws {
        let store = InMemoryTrafficSSLProxyingStore()
        let viewModel = makeViewModel(store: store, sink: MutableTLSInterceptionPolicy())
        await viewModel.prepare()

        let controller = SSLProxyingManagerViewController(viewModel: viewModel)
        _ = controller.view

        let entryField = try XCTUnwrap(
            descendant(in: controller.view, identifier: "sslProxyingManager.entry")
                as? NSTextField
        )
        let addButton = try XCTUnwrap(
            descendant(in: controller.view, identifier: "sslProxyingManager.add") as? NSButton
        )
        let validation = try XCTUnwrap(
            descendant(in: controller.view, identifier: "sslProxyingManager.validation")
                as? NSTextField
        )

        entryField.stringValue = "not a host"
        _ = addButton.target?.perform(addButton.action, with: addButton)

        XCTAssertTrue(store.policy.entries.isEmpty)
        XCTAssertFalse(validation.isHidden)
        XCTAssertFalse(validation.stringValue.isEmpty)
    }

    func testManagerSheetModeControlSwitchesPolicyMode() async throws {
        let store = InMemoryTrafficSSLProxyingStore()
        let viewModel = makeViewModel(store: store, sink: MutableTLSInterceptionPolicy())
        await viewModel.prepare()

        let controller = SSLProxyingManagerViewController(viewModel: viewModel)
        _ = controller.view

        let modeControl = try XCTUnwrap(
            descendant(in: controller.view, identifier: "sslProxyingManager.mode")
                as? NSSegmentedControl
        )
        modeControl.selectedSegment = 1
        _ = modeControl.target?.perform(modeControl.action, with: modeControl)

        XCTAssertEqual(store.policy.mode, .interceptOnly)
    }

    /// Guards the layout pitfall this repo has hit twice: a chrome row silently absorbing
    /// all the vertical slack and squeezing the table down to nothing. Hosts the controller
    /// in a real window at a fixed size, as the other layout tests in this suite do.
    func testManagerSheetGivesTheTableRealHeightNotJustChrome() async throws {
        let store = InMemoryTrafficSSLProxyingStore(
            policy: try TLSInterceptionPolicy(
                mode: .interceptAllExcept,
                entries: ["*.example.com"]
            )
        )
        let viewModel = makeViewModel(store: store, sink: MutableTLSInterceptionPolicy())
        await viewModel.prepare()

        let controller = SSLProxyingManagerViewController(viewModel: viewModel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 620, height: 520))
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        controller.view.layoutSubtreeIfNeeded()

        let table = try XCTUnwrap(
            descendant(in: controller.view, identifier: "sslProxyingManager.table")
                as? NSTableView
        )
        let scrollView = try XCTUnwrap(table.enclosingScrollView)

        XCTAssertGreaterThan(scrollView.frame.height, 200)
    }

    func testFlowTableContextMenuTogglesSSLProxyingForTheClickedHost() async throws {
        let store = InMemoryTrafficSSLProxyingStore()
        let sink = MutableTLSInterceptionPolicy()
        let viewModel = makeViewModel(store: store, sink: sink)
        await viewModel.prepare()

        let tableView = SSLProxyingRecordingTableView()
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view

        let flow = try Self.makeCompletedFlow(host: "api.example.com", statusCode: 200)
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        controller.render(viewModel.snapshot)

        tableView.clickedRowOverride = 0
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let excludeItem = try XCTUnwrap(
            menu.items.first { $0.title == "Don't Intercept api.example.com" }
        )
        XCTAssertTrue(excludeItem.isEnabled)
        _ = excludeItem.target?.perform(excludeItem.action, with: excludeItem)

        try await waitUntil { store.policy.entries == ["api.example.com"] }
        XCTAssertFalse(sink.currentPolicy().shouldIntercept(host: "api.example.com"))

        let reopened = NSMenu()
        controller.menuNeedsUpdate(reopened)
        let interceptItem = try XCTUnwrap(
            reopened.items.first { $0.title == "Intercept api.example.com" }
        )
        XCTAssertTrue(interceptItem.isEnabled)
        _ = interceptItem.target?.perform(interceptItem.action, with: interceptItem)

        try await waitUntil { store.policy.entries.isEmpty }
    }

    func testFlowTableContextMenuDisablesInterceptForAWildcardOnlyExclusion() async throws {
        let store = InMemoryTrafficSSLProxyingStore(
            policy: try TLSInterceptionPolicy(
                mode: .interceptAllExcept,
                entries: ["*.example.com"]
            )
        )
        let sink = MutableTLSInterceptionPolicy()
        let viewModel = makeViewModel(store: store, sink: sink)
        await viewModel.prepare()

        let tableView = SSLProxyingRecordingTableView()
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view

        let flow = try Self.makeCompletedFlow(host: "pinned.example.com", statusCode: 200)
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        controller.render(viewModel.snapshot)

        tableView.clickedRowOverride = 0
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let interceptItem = try XCTUnwrap(
            menu.items.first { $0.title == "Intercept pinned.example.com" }
        )
        XCTAssertFalse(interceptItem.isEnabled)
    }

    func testFlowTableRendersAPassthroughTunnelRow() async throws {
        let viewModel = makeViewModel(
            store: InMemoryTrafficSSLProxyingStore(),
            sink: MutableTLSInterceptionPolicy()
        )
        await viewModel.prepare()

        let flow = try Self.makeTunnelFlow(host: "pinned.example.com")
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()

        let tableView = NSTableView()
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view
        controller.render(viewModel.snapshot)

        let row = try XCTUnwrap(viewModel.snapshot.visibleRows.first)
        XCTAssertEqual(row.method, "CONNECT")
        XCTAssertEqual(row.host, "pinned.example.com")
        XCTAssertNil(row.statusCode)
        XCTAssertTrue(row.usesTLS)
        // The status cell falls back on the flow state for a response-less completed flow.
        XCTAssertEqual(tableView.numberOfRows, 1)
    }

    /// Builds a completed HTTP flow the way `TrafficFlowRow` expects one shaped, so seeded
    /// rows here match what the real capture path produces (see the equivalent helper in
    /// `ProxyLensIntegrationTests.swift`, which is file-private and not reusable here).
    private static func makeCompletedFlow(host: String, statusCode: Int) throws -> Flow {
        var requestHeaders = HTTPHeaders()
        try requestHeaders.append(name: "Host", value: host)
        var flow = Flow(
            sessionID: SessionID(),
            source: .desktopProxy,
            request: HTTPRequest(
                method: .get,
                url: try XCTUnwrap(URL(string: "https://\(host)/")),
                headers: requestHeaders
            ),
            connection: ConnectionInfo(
                protocolKind: .https,
                upstreamHost: host,
                upstreamPort: 443,
                tlsIntercepted: true
            )
        )
        try flow.transition(to: .receivingRequest)
        try flow.transition(to: .connectingUpstream)
        try flow.transition(to: .receivingResponse)
        flow.attachResponse(try HTTPResponse(statusCode: statusCode, reasonPhrase: "OK"))
        flow.markCompleted(at: Date())
        try flow.transition(to: .completed)
        return flow
    }

    /// Shapes a flow exactly the way `TunnelPassthrough.makeFlow` plus the real completion
    /// path (`FlowTransaction.finishResponse` with a nil body) leave it: CONNECT method, no
    /// response, `tlsIntercepted == false`, terminal state `.completed`.
    private static func makeTunnelFlow(host: String) throws -> Flow {
        var flow = Flow(
            sessionID: SessionID(),
            source: .desktopProxy,
            request: HTTPRequest(
                method: .connect,
                url: try XCTUnwrap(URL(string: "https://\(host):443/")),
                rawTarget: "\(host):443"
            ),
            connection: ConnectionInfo(
                protocolKind: .https,
                upstreamHost: host,
                upstreamPort: 443,
                tlsIntercepted: false
            )
        )
        try flow.transition(to: .receivingRequest)
        try flow.transition(to: .receivingResponse)
        try flow.transition(to: .completed)
        flow.markCompleted(at: Date())
        return flow
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

    /// 256 unique wildcard entries at `TLSInterceptionPolicy.maximumHostLength`, matching
    /// the largest policy Core will accept — used to pin the persistence store's size cap
    /// above anything a valid policy can produce.
    private static func makeMaximalTLSInterceptionEntries() -> [String] {
        let suffix = ".example.com"
        let maximumHostLength = TLSInterceptionPolicy.maximumHostLength
        return (0..<TLSInterceptionPolicy.maximumEntryCount).map { index in
            let token = String(format: "h%03d", index)
            let fillLength = maximumHostLength - token.count - suffix.count
            let fill = String(repeating: "a", count: max(0, fillLength))
            return "*." + token + fill + suffix
        }
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

    private func descendant(in view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews {
            if let match = descendant(in: subview, identifier: identifier) { return match }
        }
        return nil
    }
}

/// Lets the context-menu test drive `menuNeedsUpdate` against a specific row without a real
/// click event — same technique as `RecordingTableView` in `ProxyLensIntegrationTests.swift`,
/// which is file-private and not reusable here.
private final class SSLProxyingRecordingTableView: NSTableView {
    var clickedRowOverride: Int?

    override var clickedRow: Int {
        clickedRowOverride ?? super.clickedRow
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

/// Counts `save` calls so tests can assert a no-op edit never writes.
@MainActor
private final class SSLProxyingCountingStore: TrafficSSLProxyingStoring {
    private(set) var policy: TLSInterceptionPolicy
    private(set) var saveCount = 0

    init(policy: TLSInterceptionPolicy) {
        self.policy = policy
    }

    func save(_ policy: TLSInterceptionPolicy) throws {
        saveCount += 1
        self.policy = policy
    }
}
