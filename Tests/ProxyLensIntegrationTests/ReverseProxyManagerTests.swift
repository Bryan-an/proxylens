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

    func testRouteTableRendersLocalEndpointUpstreamAndEnabledState() async throws {
        let enabledRoute = try makeRoute(
            name: "Local API",
            port: 9_443,
            upstream: "https://api.example.com/v1"
        )
        let disabledRoute = try ReverseProxyRoute(
            name: "Staging API",
            listenEndpoint: NetworkEndpoint(host: "::1", port: 9_444),
            upstreamURL: XCTUnwrap(URL(string: "http://staging.example.com/base")),
            isEnabled: false
        )
        let routeStore = InMemoryTrafficReverseProxyRouteStore(
            routes: [enabledRoute, disabledRoute]
        )
        let viewModel = makeViewModel(routeStore: routeStore)
        await viewModel.prepare()
        let controller = ReverseProxyManagerViewController(viewModel: viewModel)
        let window = makeWindow(hosting: controller)
        defer { closeWindow(window) }

        let table = try XCTUnwrap(
            descendant(in: controller.view, identifier: "reverseProxyManager.table")
                as? NSTableView
        )
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.accessibilityLabel(), "Reverse proxy routes")
        XCTAssertEqual(
            table.tableColumns.map(\.identifier.rawValue),
            ["enabled", "name", "listener", "upstream"]
        )
        XCTAssertEqual(
            table.tableColumns.map(\.title),
            ["On", "Name", "Local Listener", "Upstream"]
        )

        XCTAssertEqual(try cellText(in: table, row: 0, column: "name"), "Local API")
        XCTAssertEqual(try cellText(in: table, row: 0, column: "listener"), "127.0.0.1:9443")
        XCTAssertEqual(
            try cellText(in: table, row: 0, column: "upstream"),
            "https://api.example.com/v1"
        )
        XCTAssertEqual(try cellText(in: table, row: 1, column: "name"), "Staging API")
        XCTAssertEqual(try cellText(in: table, row: 1, column: "listener"), "::1:9444")
        XCTAssertEqual(
            try cellText(in: table, row: 1, column: "upstream"),
            "http://staging.example.com/base"
        )

        let firstToggle = try enabledCheckbox(in: table, row: 0)
        let secondToggle = try enabledCheckbox(in: table, row: 1)
        XCTAssertEqual(firstToggle.state, .on)
        XCTAssertEqual(secondToggle.state, .off)
        XCTAssertTrue(firstToggle.isEnabled)
        XCTAssertEqual(firstToggle.accessibilityLabel(), "Enable Local API")
        XCTAssertEqual(secondToggle.accessibilityLabel(), "Enable Staging API")
        XCTAssertEqual(
            descendant(in: controller.view, identifier: "reverseProxyManager.empty")?.isHidden,
            true
        )
    }

    func testTogglingRouteCheckboxPersistsEnabledStateAndReachesNextCapture() async throws {
        let route = try makeRoute()
        let routeStore = InMemoryTrafficReverseProxyRouteStore(routes: [route])
        let captureController = ReverseProxyRecordingCaptureController()
        let viewModel = makeViewModel(
            routeStore: routeStore,
            captureController: captureController
        )
        await viewModel.prepare()
        let controller = ReverseProxyManagerViewController(viewModel: viewModel)
        let window = makeWindow(hosting: controller)
        defer { closeWindow(window) }
        let table = try XCTUnwrap(
            descendant(in: controller.view, identifier: "reverseProxyManager.table")
                as? NSTableView
        )

        try enabledCheckbox(in: table, row: 0).performClick(nil)

        XCTAssertEqual(routeStore.routes.first?.isEnabled, false)
        XCTAssertEqual(viewModel.currentReverseProxyRoutes().first?.isEnabled, false)
        XCTAssertEqual(try enabledCheckbox(in: table, row: 0).state, .off)

        try enabledCheckbox(in: table, row: 0).performClick(nil)

        XCTAssertEqual(routeStore.routes.first?.isEnabled, true)
        XCTAssertEqual(try enabledCheckbox(in: table, row: 0).state, .on)
        XCTAssertEqual(routeStore.routes.first?.id, route.id)

        try enabledCheckbox(in: table, row: 0).performClick(nil)
        viewModel.toggleCapture()
        try await waitUntil { await captureController.lastConfiguration() != nil }

        let startedConfiguration = await captureController.lastConfiguration()
        XCTAssertEqual(startedConfiguration?.proxy.reverseProxyRoutes.count, 1)
        XCTAssertEqual(startedConfiguration?.proxy.reverseProxyRoutes.first?.isEnabled, false)
    }

    func testTogglingRouteDuringCaptureRestoresThePreviousCheckboxState() async throws {
        let route = try makeRoute()
        let routeStore = InMemoryTrafficReverseProxyRouteStore(routes: [route])
        let captureController = ReverseProxyRecordingCaptureController()
        let viewModel = makeViewModel(
            routeStore: routeStore,
            captureController: captureController
        )
        await viewModel.prepare()
        let controller = ReverseProxyManagerViewController(viewModel: viewModel)
        let window = makeWindow(hosting: controller)
        defer { closeWindow(window) }
        let table = try XCTUnwrap(
            descendant(in: controller.view, identifier: "reverseProxyManager.table")
                as? NSTableView
        )

        viewModel.toggleCapture()
        try await waitUntil { await captureController.lastConfiguration() != nil }
        try await waitUntil { !viewModel.canEditReverseProxyRoutes }
        controller.reloadRoutes()

        let toggle = try enabledCheckbox(in: table, row: 0)
        XCTAssertFalse(toggle.isEnabled)

        toggle.isEnabled = true
        dismissingModalAlert { toggle.performClick(nil) }

        XCTAssertEqual(toggle.state, .on)
        XCTAssertEqual(routeStore.routes.first?.isEnabled, true)
    }

    func testRouteEditorPresentsForAddAndSavesThroughTheViewModel() async throws {
        let routeStore = InMemoryTrafficReverseProxyRouteStore()
        let viewModel = makeViewModel(routeStore: routeStore)
        await viewModel.prepare()
        let controller = ReverseProxyManagerViewController(viewModel: viewModel)
        let window = makeWindow(hosting: controller)
        defer { closeWindow(window) }

        try clickButton(in: controller.view, identifier: "reverseProxyManager.add")

        let editor = try presentedEditorView(in: controller)
        XCTAssertEqual(editor.accessibilityIdentifier(), "reverseProxyEditor")
        let name = try field(in: editor, identifier: "reverseProxyEditor.name")
        let port = try field(in: editor, identifier: "reverseProxyEditor.port")
        let upstream = try field(in: editor, identifier: "reverseProxyEditor.upstreamURL")
        let host = try XCTUnwrap(
            descendant(in: editor, identifier: "reverseProxyEditor.host") as? NSPopUpButton
        )
        let enabled = try XCTUnwrap(
            descendant(in: editor, identifier: "reverseProxyEditor.enabled") as? NSButton
        )
        XCTAssertEqual(name.stringValue, "")
        XCTAssertEqual(port.stringValue, "8080")
        XCTAssertEqual(upstream.stringValue, "")
        XCTAssertEqual(host.itemTitles, ["127.0.0.1", "::1"])
        XCTAssertEqual(enabled.state, .on)
        XCTAssertNotNil(descendant(in: editor, identifier: "reverseProxyEditor.cancel"))

        name.stringValue = "  Local API  "
        port.stringValue = "9443"
        upstream.stringValue = "https://api.example.com/v1/"
        try clickButton(in: editor, identifier: "reverseProxyEditor.save")

        let saved = try XCTUnwrap(routeStore.routes.first)
        XCTAssertEqual(routeStore.routes.count, 1)
        XCTAssertEqual(saved.name, "Local API")
        XCTAssertEqual(saved.listenEndpoint, NetworkEndpoint(host: "127.0.0.1", port: 9_443))
        XCTAssertEqual(saved.upstreamURL.absoluteString, "https://api.example.com/v1")
        XCTAssertTrue(saved.isEnabled)
        XCTAssertEqual(controller.numberOfRoutes, 1)
        XCTAssertEqual(
            try field(in: editor, identifier: "reverseProxyEditor.validation").stringValue,
            ""
        )
    }

    func testRouteEditorPrefillsSelectedRouteAndSavesEdits() async throws {
        let route = try makeRoute()
        let routeStore = InMemoryTrafficReverseProxyRouteStore(routes: [route])
        let viewModel = makeViewModel(routeStore: routeStore)
        await viewModel.prepare()
        let controller = ReverseProxyManagerViewController(viewModel: viewModel)
        let window = makeWindow(hosting: controller)
        defer { closeWindow(window) }
        let table = try XCTUnwrap(
            descendant(in: controller.view, identifier: "reverseProxyManager.table")
                as? NSTableView
        )

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try clickButton(in: controller.view, identifier: "reverseProxyManager.edit")

        let editor = try presentedEditorView(in: controller)
        let name = try field(in: editor, identifier: "reverseProxyEditor.name")
        let port = try field(in: editor, identifier: "reverseProxyEditor.port")
        let upstream = try field(in: editor, identifier: "reverseProxyEditor.upstreamURL")
        let host = try XCTUnwrap(
            descendant(in: editor, identifier: "reverseProxyEditor.host") as? NSPopUpButton
        )
        let enabled = try XCTUnwrap(
            descendant(in: editor, identifier: "reverseProxyEditor.enabled") as? NSButton
        )
        XCTAssertEqual(name.stringValue, "Local API")
        XCTAssertEqual(port.stringValue, "9443")
        XCTAssertEqual(upstream.stringValue, "https://api.example.com/v1")
        XCTAssertEqual(host.titleOfSelectedItem, "127.0.0.1")
        XCTAssertEqual(enabled.state, .on)

        name.stringValue = "Renamed API"
        upstream.stringValue = "https://api.example.com/v2"
        enabled.state = .off
        try clickButton(in: editor, identifier: "reverseProxyEditor.save")

        let saved = try XCTUnwrap(routeStore.routes.first)
        XCTAssertEqual(routeStore.routes.count, 1)
        XCTAssertEqual(saved.id, route.id)
        XCTAssertEqual(saved.name, "Renamed API")
        XCTAssertEqual(saved.upstreamURL.absoluteString, "https://api.example.com/v2")
        XCTAssertFalse(saved.isEnabled)
        XCTAssertEqual(try cellText(in: table, row: 0, column: "name"), "Renamed API")
        XCTAssertEqual(try enabledCheckbox(in: table, row: 0).state, .off)
    }

    func testRouteEditorReportsValidationFailuresWithoutSavingTheRoute() async throws {
        let routeStore = InMemoryTrafficReverseProxyRouteStore()
        let viewModel = makeViewModel(routeStore: routeStore)
        await viewModel.prepare()
        let controller = ReverseProxyManagerViewController(viewModel: viewModel)
        let window = makeWindow(hosting: controller)
        defer { closeWindow(window) }

        try clickButton(in: controller.view, identifier: "reverseProxyManager.add")

        let editor = try presentedEditorView(in: controller)
        let name = try field(in: editor, identifier: "reverseProxyEditor.name")
        let port = try field(in: editor, identifier: "reverseProxyEditor.port")
        let upstream = try field(in: editor, identifier: "reverseProxyEditor.upstreamURL")
        let validation = try field(in: editor, identifier: "reverseProxyEditor.validation")

        name.stringValue = "Local API"
        port.stringValue = "0"
        upstream.stringValue = "https://api.example.com/v1"
        try clickButton(in: editor, identifier: "reverseProxyEditor.save")

        XCTAssertEqual(
            validation.stringValue,
            TrafficReverseProxyRouteStoreError.invalidListenPort.localizedDescription
        )
        XCTAssertTrue(routeStore.routes.isEmpty)

        port.stringValue = "9443"
        upstream.stringValue = "https://user:secret@api.example.com/v1"
        try clickButton(in: editor, identifier: "reverseProxyEditor.save")

        XCTAssertEqual(
            validation.stringValue,
            ReverseProxyRouteError.invalidUpstreamURL.localizedDescription
        )
        XCTAssertTrue(routeStore.routes.isEmpty)

        port.stringValue = "9090"
        upstream.stringValue = "https://api.example.com/v1"
        try clickButton(in: editor, identifier: "reverseProxyEditor.save")

        XCTAssertEqual(
            validation.stringValue,
            ReverseProxyRouteError.listenerCollision(
                NetworkEndpoint(host: "127.0.0.1", port: 9_090)
            ).localizedDescription
        )
        XCTAssertTrue(routeStore.routes.isEmpty)
        XCTAssertEqual(controller.numberOfRoutes, 0)
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

    private func makeViewModel(
        routeStore: InMemoryTrafficReverseProxyRouteStore,
        captureController: ReverseProxyRecordingCaptureController =
            ReverseProxyRecordingCaptureController()
    ) -> TrafficConsoleViewModel {
        TrafficConsoleViewModel(
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
    }

    private func makeWindow(hosting controller: ReverseProxyManagerViewController) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 920, height: 780)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(frame.size)
        controller.view.frame = NSRect(origin: .zero, size: frame.size)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func closeWindow(_ window: NSWindow) {
        for sheet in window.sheets {
            window.endSheet(sheet)
        }
        window.contentViewController = nil
        window.orderOut(nil)
    }

    private func presentedEditorView(
        in controller: ReverseProxyManagerViewController
    ) throws -> NSView {
        let editor = try XCTUnwrap(controller.presentedViewControllers?.first)
        return editor.view
    }

    private func clickButton(in view: NSView, identifier: String) throws {
        let button = try XCTUnwrap(descendant(in: view, identifier: identifier) as? NSButton)
        button.performClick(nil)
    }

    private func field(in view: NSView, identifier: String) throws -> NSTextField {
        try XCTUnwrap(descendant(in: view, identifier: identifier) as? NSTextField)
    }

    private func column(_ table: NSTableView, identifier: String) throws -> Int {
        try XCTUnwrap(
            table.tableColumns.firstIndex { $0.identifier.rawValue == identifier }
        )
    }

    private func cellText(in table: NSTableView, row: Int, column name: String) throws -> String {
        let index = try column(table, identifier: name)
        let cell = try XCTUnwrap(
            table.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTextField
        )
        XCTAssertEqual(cell.toolTip, cell.stringValue)
        return cell.stringValue
    }

    private func enabledCheckbox(in table: NSTableView, row: Int) throws -> NSButton {
        let index = try column(table, identifier: "enabled")
        return try XCTUnwrap(
            table.view(atColumn: index, row: row, makeIfNecessary: true) as? NSButton
        )
    }

    private func dismissingModalAlert(_ body: () -> Void) {
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow != nil else { return }
                NSApp.abortModal()
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        body()
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
