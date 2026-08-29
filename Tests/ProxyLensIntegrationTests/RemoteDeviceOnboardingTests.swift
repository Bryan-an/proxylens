import AppKit
import ProxyLensApplication
import ProxyLensCore
import XCTest

@testable import ProxyLens

@MainActor
final class RemoteDeviceOnboardingTests: XCTestCase {
    func testUserDefaultsStoresRoundTripRemoteAccessAndTrustedDevices() async throws {
        let suiteName = "RemoteDeviceOnboardingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let accessStore = UserDefaultsTrafficRemoteAccessStore(
            defaults: defaults,
            key: "access.key"
        )
        XCTAssertFalse(accessStore.configuration.isEnabled)

        accessStore.save(RemoteAccessConfiguration(isEnabled: true))
        XCTAssertTrue(accessStore.configuration.isEnabled)
        XCTAssertTrue(
            UserDefaultsTrafficRemoteAccessStore(defaults: defaults, key: "access.key")
                .configuration.isEnabled
        )

        defaults.set(Data("not json".utf8), forKey: "access.key")
        XCTAssertFalse(accessStore.configuration.isEnabled, "Malformed data must fail closed")

        let deviceStore = UserDefaultsRemoteDeviceStore(defaults: defaults, key: "devices.key")
        let device = RemoteDevice(
            address: "192.168.1.7",
            name: "Test iPhone",
            isTrusted: true,
            firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await deviceStore.save([device])

        let loaded = await deviceStore.loadDevices()
        XCTAssertEqual(loaded, [device])
    }

    func testSavedRemoteAccessReachesTheSnapshotWithASetupURL() async throws {
        let store = InMemoryTrafficRemoteAccessStore()
        let viewModel = makeViewModel(remoteAccessStore: store)
        await viewModel.prepare()

        XCTAssertFalse(viewModel.snapshot.remoteAccess.isEnabled)
        XCTAssertNil(viewModel.snapshot.remoteAccess.setupURL)

        try viewModel.saveRemoteAccessConfiguration(RemoteAccessConfiguration(isEnabled: true))

        XCTAssertTrue(store.configuration.isEnabled)
        XCTAssertTrue(viewModel.snapshot.remoteAccess.isEnabled)
        XCTAssertEqual(viewModel.snapshot.remoteAccess.addresses, ["192.168.1.5"])
        XCTAssertEqual(viewModel.snapshot.remoteAccess.listenPort, 9_090)
        XCTAssertEqual(
            viewModel.snapshot.remoteAccess.setupURL,
            "http://192.168.1.5:9090/ssl"
        )
    }

    func testEnablingRemoteAccessIsRefusedWhileCaptureIsRunning() async throws {
        let store = InMemoryTrafficRemoteAccessStore()
        let viewModel = makeViewModel(remoteAccessStore: store)
        await viewModel.prepare()

        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }

        XCTAssertThrowsError(
            try viewModel.saveRemoteAccessConfiguration(
                RemoteAccessConfiguration(isEnabled: true)
            )
        ) { error in
            XCTAssertEqual(
                error as? TrafficRemoteAccessStoreError,
                .captureMustBeStopped
            )
        }
        XCTAssertFalse(store.configuration.isEnabled)
    }

    func testCaptureCarriesTheRemoteAccessSettingToTheProxyConfiguration() async throws {
        let captureController = RemoteDeviceRecordingCaptureController()
        let controller = RemoteDeviceStubAccessController()
        let store = InMemoryTrafficRemoteAccessStore(
            configuration: RemoteAccessConfiguration(isEnabled: true)
        )
        let viewModel = makeViewModel(
            captureController: captureController,
            remoteAccessStore: store,
            remoteAccessController: controller
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
        XCTAssertEqual(configuration?.proxy.remoteAccess.isEnabled, true)
        XCTAssertEqual(configuration?.proxy.forwardListenHost, "0.0.0.0")
        let enabled = await controller.enabledStates()
        XCTAssertEqual(enabled, [true])

        viewModel.toggleCapture()
        try await waitUntil { await controller.didEndSession() }
    }

    func testAPendingApprovalReachesTheSnapshotAndClearsWhenAnswered() async throws {
        let controller = RemoteDeviceStubAccessController()
        let viewModel = makeViewModel(remoteAccessController: controller)
        await viewModel.prepare()
        try await waitUntil { await controller.subscriberCount() > 0 }

        await controller.publish(
            .requested(RemoteAccessRequest(address: "192.168.1.7", requestedAt: Date()))
        )
        try await waitUntil {
            viewModel.snapshot.remoteAccess.pendingApproval?.address == "192.168.1.7"
        }

        viewModel.resolveRemoteDeviceApproval(address: "192.168.1.7", approval: .allowAlways)

        XCTAssertNil(viewModel.snapshot.remoteAccess.pendingApproval)
        try await waitUntil {
            await controller.resolutions().contains {
                $0.address == "192.168.1.7" && $0.approval == .allowAlways
            }
        }
    }

    func testAnExpiredApprovalWithdrawsTheSnapshotPrompt() async throws {
        let controller = RemoteDeviceStubAccessController()
        let viewModel = makeViewModel(remoteAccessController: controller)
        await viewModel.prepare()
        try await waitUntil { await controller.subscriberCount() > 0 }

        await controller.publish(
            .requested(RemoteAccessRequest(address: "192.168.1.7", requestedAt: Date()))
        )
        try await waitUntil {
            viewModel.snapshot.remoteAccess.pendingApproval != nil
        }

        await controller.publish(.settled(address: "192.168.1.7"))

        try await waitUntil {
            viewModel.snapshot.remoteAccess.pendingApproval == nil
        }
    }

    func testDeviceSummariesMergeFlowCountsWithWhatTheCoordinatorKnows() async throws {
        let controller = RemoteDeviceStubAccessController(
            devices: [
                RemoteDevice(
                    address: "192.168.1.7",
                    name: "Test iPhone",
                    isTrusted: true,
                    firstSeenAt: Date()
                )
            ]
        )
        let viewModel = makeViewModel(remoteAccessController: controller)
        await viewModel.prepare()

        viewModel.receive(.finished(try Self.makeRemoteDeviceFlow(address: "192.168.1.7")))
        viewModel.receive(.finished(try Self.makeRemoteDeviceFlow(address: "192.168.1.7")))
        viewModel.receive(.finished(try Self.makeRemoteDeviceFlow(address: "192.168.1.9")))
        viewModel.flushPendingEvents()

        let devices = viewModel.snapshot.remoteAccess.devices
        XCTAssertEqual(devices.map(\.id), ["192.168.1.7", "192.168.1.9"])
        XCTAssertEqual(devices[0].displayName, "Test iPhone")
        XCTAssertTrue(devices[0].isTrusted)
        XCTAssertEqual(devices[0].flowCount, 2)
        XCTAssertEqual(devices[1].displayName, "192.168.1.9")
        XCTAssertFalse(devices[1].isTrusted)
        XCTAssertEqual(devices[1].flowCount, 1)
    }

    func testSelectingADeviceFiltersTheFlowTable() async throws {
        let viewModel = makeViewModel()
        await viewModel.prepare()

        viewModel.receive(.finished(try Self.makeRemoteDeviceFlow(address: "192.168.1.7")))
        viewModel.receive(.finished(try Self.makeRemoteDeviceFlow(address: "192.168.1.9")))
        viewModel.receive(.finished(try Self.makeDesktopFlow()))
        viewModel.flushPendingEvents()
        XCTAssertEqual(viewModel.snapshot.visibleRows.count, 3)

        viewModel.selectSource(.device("192.168.1.7"))

        XCTAssertEqual(viewModel.snapshot.selectedSource, .device("192.168.1.7"))
        XCTAssertEqual(viewModel.snapshot.visibleRows.count, 1)
        XCTAssertEqual(viewModel.snapshot.visibleRows.first?.host, "device-192.168.1.7.example")
    }

    // MARK: - Native surface

    func testTheApprovalBarAppearsOnlyWhileADeviceIsWaiting() async throws {
        let controller = RemoteDeviceStubAccessController()
        let viewModel = makeViewModel(remoteAccessController: controller)
        let bar = RemoteDeviceApprovalBar(viewModel: viewModel)
        await viewModel.prepare()
        try await waitUntil { await controller.subscriberCount() > 0 }

        bar.render(viewModel.snapshot)
        XCTAssertTrue(bar.isHidden)

        await controller.publish(
            .requested(RemoteAccessRequest(address: "192.168.1.7", requestedAt: Date()))
        )
        try await waitUntil { viewModel.snapshot.remoteAccess.pendingApproval != nil }
        bar.render(viewModel.snapshot)

        XCTAssertFalse(bar.isHidden)
        let address = try XCTUnwrap(
            descendant(in: bar, identifier: "traffic.remoteApproval.address") as? NSTextField
        )
        XCTAssertTrue(address.stringValue.contains("192.168.1.7"))

        let allowOnce = try XCTUnwrap(
            descendant(in: bar, identifier: "traffic.remoteApproval.allowOnce") as? NSButton
        )
        _ = allowOnce.target?.perform(allowOnce.action, with: allowOnce)

        try await waitUntil {
            await controller.resolutions().contains {
                $0.address == "192.168.1.7" && $0.approval == .allowOnce
            }
        }
        bar.render(viewModel.snapshot)
        XCTAssertTrue(bar.isHidden)
    }

    func testTheRemoteDeviceSheetShowsSetupDetailsAndLocksWhileCapturing() async throws {
        let controller = RemoteDeviceStubAccessController(
            devices: [
                RemoteDevice(
                    address: "192.168.1.7",
                    name: "Test iPhone",
                    isTrusted: true,
                    firstSeenAt: Date()
                )
            ]
        )
        let viewModel = makeViewModel(remoteAccessController: controller)
        await viewModel.prepare()
        let manager = RemoteDeviceManagerViewController(viewModel: viewModel)
        manager.loadView()
        manager.render(viewModel.snapshot)

        let toggle = try XCTUnwrap(
            descendant(in: manager.view, identifier: "remoteDevices.enableToggle") as? NSButton
        )
        let address = try XCTUnwrap(
            descendant(in: manager.view, identifier: "remoteDevices.address") as? NSTextField
        )
        XCTAssertEqual(toggle.state, .off)
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertTrue(address.stringValue.contains("192.168.1.5"))
        XCTAssertTrue(address.stringValue.contains("9090"))
        XCTAssertNotNil(descendant(in: manager.view, identifier: "remoteDevices.qr"))
        XCTAssertNotNil(descendant(in: manager.view, identifier: "remoteDevices.instructions"))

        let table = try XCTUnwrap(
            descendant(in: manager.view, identifier: "remoteDevices.table") as? NSTableView
        )
        XCTAssertEqual(table.numberOfRows, 1)

        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }
        manager.render(viewModel.snapshot)

        XCTAssertFalse(toggle.isEnabled, "Listener changes need capture stopped")
    }

    func testTheSourceListListsDevicesAndSelectsOne() async throws {
        let controller = RemoteDeviceStubAccessController(
            devices: [
                RemoteDevice(
                    address: "192.168.1.7",
                    name: "Test iPhone",
                    isTrusted: true,
                    firstSeenAt: Date()
                )
            ]
        )
        let viewModel = makeViewModel(remoteAccessController: controller)
        await viewModel.prepare()
        let sourceList = SourceListViewController(viewModel: viewModel)
        sourceList.loadView()

        viewModel.receive(.finished(try Self.makeRemoteDeviceFlow(address: "192.168.1.7")))
        viewModel.flushPendingEvents()
        sourceList.render(viewModel.snapshot)

        let outline = try XCTUnwrap(
            descendant(in: sourceList.view, identifier: "traffic.sources") as? NSOutlineView
        )
        let renderedText = (0..<outline.numberOfRows).flatMap { row -> [String] in
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else {
                return []
            }
            return Self.labels(in: cell)
        }
        XCTAssertTrue(renderedText.contains("Devices"), "Rendered rows: \(renderedText)")
        XCTAssertTrue(renderedText.contains("Test iPhone"), "Rendered rows: \(renderedText)")

        let deviceRow = try XCTUnwrap(
            (0..<outline.numberOfRows).first { row in
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else {
                    return false
                }
                return Self.labels(in: cell).contains("Test iPhone")
            }
        )
        outline.selectRowIndexes(IndexSet(integer: deviceRow), byExtendingSelection: false)
        sourceList.outlineViewSelectionDidChange(
            Notification(name: NSOutlineView.selectionDidChangeNotification, object: outline)
        )

        XCTAssertEqual(viewModel.snapshot.selectedSource, .device("192.168.1.7"))
    }

    // MARK: - Helpers

    private func makeViewModel(
        captureController: any TrafficCaptureControlling = RemoteDeviceRecordingCaptureController(),
        remoteAccessStore: any TrafficRemoteAccessStoring = InMemoryTrafficRemoteAccessStore(),
        remoteAccessController: (any TrafficRemoteAccessControlling)? = nil
    ) -> TrafficConsoleViewModel {
        TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: RemoteDeviceEmptyEventSource(),
            bodyReader: RemoteDeviceInlineBodyReader(),
            captureConfiguration: CaptureConfiguration(
                proxy: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                    interceptHTTPS: true
                ),
                configuresSystemProxy: false
            ),
            eventBatchDelay: .seconds(60),
            remoteAccessStore: remoteAccessStore,
            remoteAccessController: remoteAccessController,
            lanAddressProvider: StaticLANAddressProvider(addresses: ["192.168.1.5"])
        )
    }

    private static func makeRemoteDeviceFlow(address: String) throws -> Flow {
        try makeFlow(
            source: .remoteDevice(address: address, port: 51_000),
            host: "device-\(address).example"
        )
    }

    private static func makeDesktopFlow() throws -> Flow {
        try makeFlow(source: .desktopProxy, host: "desktop.example")
    }

    private static func makeFlow(source: FlowSource, host: String) throws -> Flow {
        var headers = HTTPHeaders()
        try headers.append(name: "Host", value: host)
        var flow = Flow(
            sessionID: SessionID(),
            source: source,
            request: HTTPRequest(
                method: .get,
                url: try XCTUnwrap(URL(string: "https://\(host)/")),
                headers: headers
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
        flow.attachResponse(try HTTPResponse(statusCode: 200, reasonPhrase: "OK"))
        flow.markCompleted(at: Date())
        try flow.transition(to: .completed)
        return flow
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

    private static func labels(in view: NSView) -> [String] {
        var values: [String] = []
        if let field = view as? NSTextField {
            values.append(field.stringValue)
        }
        for subview in view.subviews {
            values.append(contentsOf: labels(in: subview))
        }
        return values
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

// MARK: - Test doubles

private actor RemoteDeviceRecordingCaptureController: TrafficCaptureControlling {
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

private actor RemoteDeviceEmptyEventSource: TrafficFlowEventStreaming {
    func makeEventStream() -> AsyncStream<FlowEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor RemoteDeviceInlineBodyReader: TrafficBodyReading {
    func read(_: BodyReference) throws -> Data { Data() }
}

/// Stands in for `RemoteDeviceCoordinator` so the console can be driven without a proxy.
private actor RemoteDeviceStubAccessController: TrafficRemoteAccessControlling {
    struct Resolution: Equatable {
        let address: String
        let approval: RemoteDeviceApproval
    }

    private var devices: [RemoteDevice]
    private var recordedResolutions: [Resolution] = []
    private var enabled: [Bool] = []
    private var endedSession = false
    private var continuations: [UUID: AsyncStream<RemoteAccessApprovalChange>.Continuation] = [:]

    init(devices: [RemoteDevice] = []) {
        self.devices = devices
    }

    func setRemoteAccessEnabled(_ isEnabled: Bool) async {
        enabled.append(isEnabled)
    }

    func endRemoteAccessSession() async {
        endedSession = true
    }

    func remoteDevices() async -> [RemoteDevice] {
        devices
    }

    func makeApprovalChangeStream() async -> AsyncStream<RemoteAccessApprovalChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: RemoteAccessApprovalChange.self
        )
        continuations[id] = continuation
        return stream
    }

    func resolveApproval(address: String, approval: RemoteDeviceApproval) async {
        recordedResolutions.append(Resolution(address: address, approval: approval))
    }

    func renameRemoteDevice(address: String, to name: String?) async {
        guard let index = devices.firstIndex(where: { $0.address == address }) else {
            return
        }
        devices[index].name = name
    }

    func revokeRemoteDevice(address: String) async {
        guard let index = devices.firstIndex(where: { $0.address == address }) else {
            return
        }
        devices[index].isTrusted = false
    }

    func publish(_ change: RemoteAccessApprovalChange) {
        for continuation in continuations.values {
            continuation.yield(change)
        }
    }

    /// The console subscribes asynchronously, so a test must wait for it before publishing:
    /// a change yielded to no continuation is simply lost.
    func subscriberCount() -> Int { continuations.count }

    func resolutions() -> [Resolution] { recordedResolutions }

    func enabledStates() -> [Bool] { enabled }

    func didEndSession() -> Bool { endedSession }
}
