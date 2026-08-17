import AppKit
import ProxyLensApplication
import ProxyLensCore
import XCTest

@testable import ProxyLens

@MainActor
final class ReverseProxyManagerTests: XCTestCase {
    func testExternalHTTPProxyStorePersistsValidatedNonSecretConfiguration() throws {
        let suiteName = "ReverseProxyManagerTests.External.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTrafficExternalHTTPProxyStore(defaults: defaults)
        let configuration = try ExternalHTTPProxyConfiguration(
            endpoint: NetworkEndpoint(host: "proxy.example.test", port: 8_080),
            bypassHosts: ["localhost", "*.internal.test"],
            username: "proxy-user",
            isEnabled: true
        )

        try store.save(configuration)

        XCTAssertEqual(
            UserDefaultsTrafficExternalHTTPProxyStore(defaults: defaults).configuration,
            configuration
        )
        let document = try XCTUnwrap(
            defaults.data(forKey: UserDefaultsTrafficExternalHTTPProxyStore.defaultKey)
        )
        XCTAssertFalse(String(decoding: document, as: UTF8.self).contains("password"))
    }

    func testExternalHTTPProxyDraftNormalizesFieldsAndRejectsInvalidPorts() throws {
        let configuration = try TrafficExternalHTTPProxyDraft(
            host: " Proxy.Example.Test ",
            port: " 8080 ",
            username: " proxy-user ",
            bypassHosts: "localhost, *.Internal.Test\n127.0.0.1",
            isEnabled: true
        ).makeConfiguration()

        XCTAssertEqual(configuration.endpoint.host, "proxy.example.test")
        XCTAssertEqual(configuration.endpoint.port, 8_080)
        XCTAssertEqual(configuration.username, "proxy-user")
        XCTAssertEqual(
            configuration.bypassHosts,
            ["localhost", "*.internal.test", "127.0.0.1"]
        )
        for port in ["", "0", "65536", "abc"] {
            XCTAssertThrowsError(
                try TrafficExternalHTTPProxyDraft(port: port).makeConfiguration()
            )
        }
    }

    func testSOCKS5UserDefaultsStorePersistsValidatedConfigurationAndFailsClosed() throws {
        let suiteName = "ReverseProxyManagerTests.SOCKS5.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTrafficSOCKS5ListenerStore(defaults: defaults)
        let configuration = try SOCKS5ListenerConfiguration(
            listenEndpoint: NetworkEndpoint(host: "::1", port: 10_080),
            isEnabled: true
        )

        try store.save(configuration)

        XCTAssertEqual(
            UserDefaultsTrafficSOCKS5ListenerStore(defaults: defaults).configuration,
            configuration
        )
        defaults.set(
            Data("not-json".utf8),
            forKey: UserDefaultsTrafficSOCKS5ListenerStore.defaultKey
        )
        XCTAssertEqual(
            store.configuration,
            try SOCKS5ListenerConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 1_080)
            )
        )
    }

    func testSOCKS5DraftRejectsUnsafeHostsAndInvalidPorts() throws {
        XCTAssertEqual(
            try TrafficSOCKS5ListenerDraft(
                listenHost: " ::1 ",
                listenPort: " 1080 ",
                isEnabled: true
            ).makeConfiguration(),
            try SOCKS5ListenerConfiguration(
                listenEndpoint: NetworkEndpoint(host: "::1", port: 1_080),
                isEnabled: true
            )
        )

        for port in ["", "0", "65536", "abc"] {
            XCTAssertThrowsError(
                try TrafficSOCKS5ListenerDraft(
                    listenHost: "127.0.0.1",
                    listenPort: port,
                    isEnabled: true
                ).makeConfiguration()
            )
        }
        XCTAssertThrowsError(
            try TrafficSOCKS5ListenerDraft(
                listenHost: "0.0.0.0",
                listenPort: "1080",
                isEnabled: true
            ).makeConfiguration()
        )
    }

    func testUserDefaultsStorePersistsUpsertsAndRemovesValidatedRoutes() throws {
        let suiteName = "ReverseProxyManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTrafficReverseProxyRouteStore(defaults: defaults)
        let routeID = UUID()
        let route = try makeRoute(id: routeID, upstream: "https://api.example.com/v1")

        try store.save(route)
        XCTAssertEqual(
            UserDefaultsTrafficReverseProxyRouteStore(defaults: defaults).routes,
            [route]
        )

        let updated = try makeRoute(
            id: routeID,
            name: "Updated API",
            upstream: "http://127.0.0.1:8080/base"
        )
        try store.save(updated)
        XCTAssertEqual(store.routes, [updated])

        store.remove(id: routeID)
        XCTAssertTrue(store.routes.isEmpty)
    }

    func testUserDefaultsStoreFailsClosedForMalformedDataAndBoundsRouteCount() throws {
        let suiteName = "ReverseProxyManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data("not-json".utf8), forKey: UserDefaultsTrafficReverseProxyRouteStore.defaultKey)
        let store = UserDefaultsTrafficReverseProxyRouteStore(defaults: defaults)

        XCTAssertTrue(store.routes.isEmpty)
        for index in 0..<ReverseProxyRoute.maximumRouteCount {
            try store.save(
                makeRoute(
                    name: "Route \(index)",
                    port: UInt16(20_000 + index),
                    upstream: "https://route-\(index).example.com"
                )
            )
        }

        XCTAssertThrowsError(
            try store.save(
                makeRoute(name: "Overflow", port: 30_000, upstream: "https://overflow.example.com")
            )
        ) { error in
            XCTAssertEqual(
                error as? ReverseProxyRouteError,
                .tooManyRoutes(maximum: ReverseProxyRoute.maximumRouteCount)
            )
        }
    }

    func testDraftFormatsFieldsAndRejectsUnsafeInput() throws {
        let route = try TrafficReverseProxyRouteDraft(
            name: "  Local API  ",
            listenHost: "127.0.0.1",
            listenPort: " 9443 ",
            upstreamURL: " https://api.example.com/v1/ ",
            isEnabled: true
        ).makeRoute()

        XCTAssertEqual(route.name, "Local API")
        XCTAssertEqual(route.listenEndpoint.port, 9_443)
        XCTAssertEqual(route.upstreamURL.absoluteString, "https://api.example.com/v1")

        for port in ["", "0", "65536", "abc"] {
            XCTAssertThrowsError(
                try TrafficReverseProxyRouteDraft(
                    name: "API",
                    listenHost: "127.0.0.1",
                    listenPort: port,
                    upstreamURL: "https://api.example.com",
                    isEnabled: true
                ).makeRoute()
            )
        }
        XCTAssertThrowsError(
            try TrafficReverseProxyRouteDraft(
                name: "API",
                listenHost: "0.0.0.0",
                listenPort: "9443",
                upstreamURL: "https://user:secret@example.com",
                isEnabled: true
            ).makeRoute()
        )
    }

    func testViewModelInjectsSavedRoutesAtNextStartAndLocksMutationsWhileRunning() async throws {
        let route = try makeRoute()
        let routeStore = InMemoryTrafficReverseProxyRouteStore(routes: [route])
        let captureController = ReverseProxyRecordingCaptureController()
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: ReverseProxyFinishedEventSource(),
            bodyReader: ReverseProxyInlineBodyReader(),
            captureConfiguration: CaptureConfiguration(
                proxy: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                    interceptHTTPS: true
                ),
                configuresSystemProxy: false
            ),
            reverseProxyRouteStore: routeStore
        )

        await viewModel.prepare()
        XCTAssertTrue(viewModel.canEditReverseProxyRoutes)
        viewModel.toggleCapture()
        try await waitUntil { await captureController.lastConfiguration() != nil }

        let startedConfiguration = await captureController.lastConfiguration()
        XCTAssertEqual(startedConfiguration?.proxy.reverseProxyRoutes, [route])
        XCTAssertFalse(viewModel.canEditReverseProxyRoutes)
        XCTAssertThrowsError(try viewModel.removeReverseProxyRoute(id: route.id)) { error in
            XCTAssertEqual(error as? TrafficReverseProxyRouteStoreError, .captureMustBeStopped)
        }
    }

    func testViewModelInjectsSavedSOCKS5ListenerAtNextStartAndLocksMutationsWhileRunning()
        async throws
    {
        let listener = try SOCKS5ListenerConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 10_080),
            isEnabled: true
        )
        let listenerStore = InMemoryTrafficSOCKS5ListenerStore(configuration: listener)
        let captureController = ReverseProxyRecordingCaptureController()
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: ReverseProxyFinishedEventSource(),
            bodyReader: ReverseProxyInlineBodyReader(),
            captureConfiguration: CaptureConfiguration(
                proxy: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                    interceptHTTPS: true
                ),
                configuresSystemProxy: false
            ),
            socks5ListenerStore: listenerStore
        )

        await viewModel.prepare()
        XCTAssertTrue(viewModel.canEditListenerConfiguration)
        viewModel.toggleCapture()
        try await waitUntil { await captureController.lastConfiguration() != nil }

        let startedConfiguration = await captureController.lastConfiguration()
        XCTAssertEqual(startedConfiguration?.proxy.socks5Listener, listener)
        XCTAssertFalse(viewModel.canEditListenerConfiguration)
        XCTAssertThrowsError(
            try viewModel.saveSOCKS5ListenerConfiguration(listener)
        ) { error in
            XCTAssertEqual(error as? TrafficSOCKS5ListenerStoreError, .captureMustBeStopped)
        }
    }

    func testManagerExposesAccessibleRouteControlsAndLocksThemDuringCapture() async throws {
        let route = try makeRoute()
        let routeStore = InMemoryTrafficReverseProxyRouteStore(routes: [route])
        let captureController = ReverseProxyRecordingCaptureController()
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: ReverseProxyFinishedEventSource(),
            bodyReader: ReverseProxyInlineBodyReader(),
            captureConfiguration: CaptureConfiguration(
                proxy: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                    interceptHTTPS: true
                ),
                configuresSystemProxy: false
            ),
            reverseProxyRouteStore: routeStore
        )
        await viewModel.prepare()
        let controller = ReverseProxyManagerViewController(viewModel: viewModel)
        _ = controller.view

        XCTAssertEqual(controller.numberOfRoutes, 1)
        XCTAssertNotNil(descendant(in: controller.view, identifier: "reverseProxyManager.table"))
        XCTAssertEqual(
            (descendant(in: controller.view, identifier: "reverseProxyManager.add") as? NSControl)?
                .isEnabled,
            true
        )

        viewModel.toggleCapture()
        try await waitUntil { await captureController.lastConfiguration() != nil }
        try await waitUntil { !viewModel.canEditReverseProxyRoutes }
        controller.reloadRoutes()

        XCTAssertEqual(
            (descendant(in: controller.view, identifier: "reverseProxyManager.add") as? NSControl)?
                .isEnabled,
            false
        )
        XCTAssertEqual(
            descendant(in: controller.view, identifier: "reverseProxyManager.lockMessage")?
                .isHidden,
            false
        )
    }

    func testManagerExposesAccessibleSOCKS5ControlsAndLocksThemDuringCapture() async throws {
        let listener = try SOCKS5ListenerConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 10_080),
            isEnabled: true
        )
        let captureController = ReverseProxyRecordingCaptureController()
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: ReverseProxyFinishedEventSource(),
            bodyReader: ReverseProxyInlineBodyReader(),
            captureConfiguration: CaptureConfiguration(
                proxy: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                    interceptHTTPS: true
                ),
                configuresSystemProxy: false
            ),
            socks5ListenerStore: InMemoryTrafficSOCKS5ListenerStore(configuration: listener)
        )
        await viewModel.prepare()
        let controller = ReverseProxyManagerViewController(viewModel: viewModel)
        _ = controller.view

        let enabled = try XCTUnwrap(
            descendant(in: controller.view, identifier: "listenerManager.socks5.enabled")
                as? NSButton
        )
        let port = try XCTUnwrap(
            descendant(in: controller.view, identifier: "listenerManager.socks5.port")
                as? NSTextField
        )
        XCTAssertEqual(enabled.state, .on)
        XCTAssertEqual(port.stringValue, "10080")
        XCTAssertTrue(port.isEnabled)

        viewModel.toggleCapture()
        try await waitUntil { await captureController.lastConfiguration() != nil }
        try await waitUntil { !viewModel.canEditListenerConfiguration }
        controller.reloadRoutes()

        XCTAssertFalse(enabled.isEnabled)
        XCTAssertFalse(port.isEnabled)
    }

    func testManagerExposesExternalProxyControlsAndCaptureUsesSavedConfiguration() async throws {
        let externalProxy = try ExternalHTTPProxyConfiguration(
            endpoint: NetworkEndpoint(host: "proxy.example.test", port: 3_128),
            bypassHosts: ["localhost"],
            isEnabled: true
        )
        let captureController = ReverseProxyRecordingCaptureController()
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: ReverseProxyFinishedEventSource(),
            bodyReader: ReverseProxyInlineBodyReader(),
            captureConfiguration: CaptureConfiguration(
                proxy: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                    interceptHTTPS: true
                ),
                configuresSystemProxy: false
            ),
            externalHTTPProxyStore: InMemoryTrafficExternalHTTPProxyStore(
                configuration: externalProxy
            )
        )
        await viewModel.prepare()
        let controller = ReverseProxyManagerViewController(viewModel: viewModel)
        _ = controller.view

        let enabled = try XCTUnwrap(
            descendant(in: controller.view, identifier: "listenerManager.external.enabled")
                as? NSButton
        )
        let host = try XCTUnwrap(
            descendant(in: controller.view, identifier: "listenerManager.external.host")
                as? NSTextField
        )
        let password = try XCTUnwrap(
            descendant(in: controller.view, identifier: "listenerManager.external.password")
                as? NSSecureTextField
        )
        XCTAssertEqual(enabled.state, .on)
        XCTAssertEqual(host.stringValue, "proxy.example.test")
        XCTAssertTrue(password.stringValue.isEmpty)

        viewModel.toggleCapture()
        try await waitUntil { await captureController.lastConfiguration() != nil }
        try await waitUntil { !viewModel.canEditListenerConfiguration }
        controller.reloadRoutes()

        let startedConfiguration = await captureController.lastConfiguration()
        XCTAssertEqual(
            startedConfiguration?.proxy.externalHTTPProxy,
            externalProxy
        )
        XCTAssertFalse(host.isEnabled)
        XCTAssertFalse(password.isEnabled)
    }

    private func makeRoute(
        id: UUID = UUID(),
        name: String = "Local API",
        port: UInt16 = 9_443,
        upstream: String = "https://api.example.com/v1"
    ) throws -> ReverseProxyRoute {
        try ReverseProxyRoute(
            id: id,
            name: name,
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: port),
            upstreamURL: XCTUnwrap(URL(string: upstream))
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

    private func descendant(in view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews {
            if let match = descendant(in: subview, identifier: identifier) { return match }
        }
        return nil
    }
}

private actor ReverseProxyRecordingCaptureController: TrafficCaptureControlling {
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

private actor ReverseProxyFinishedEventSource: TrafficFlowEventStreaming {
    func makeEventStream() -> AsyncStream<FlowEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor ReverseProxyInlineBodyReader: TrafficBodyReading {
    func read(_: BodyReference) throws -> Data { Data() }
}
