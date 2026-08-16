import AppKit
import Foundation
import ProxyLensApplication
import ProxyLensCore
import XCTest

@testable import ProxyLens

@MainActor
final class ProxyLensIntegrationTests: XCTestCase {
    func testConsoleStoreGroupsFiltersSortsAndPreservesSelectionAcrossUpdates() throws {
        let first = try Self.makeFlow(index: 1, host: "api.example.com", statusCode: 204)
        let second = try Self.makeFlow(index: 2, host: "cdn.example.com", statusCode: 404)
        let third = try Self.makeFlow(index: 3, host: "api.example.com", statusCode: 200)
        var store = TrafficConsoleStore()

        store.apply([.started(first), .finished(second), .finished(third)])
        store.selectFlow(first.id)
        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)

        XCTAssertEqual(snapshot.allFlowCount, 3)
        XCTAssertEqual(
            snapshot.domains,
            [
                TrafficDomainSummary(host: "api.example.com", flowCount: 2),
                TrafficDomainSummary(host: "cdn.example.com", flowCount: 1)
            ]
        )
        XCTAssertEqual(snapshot.selectedFlowID, first.id)

        var updatedFirst = first
        updatedFirst.markTLSHandshakeCompleted(at: Date(timeIntervalSince1970: 1.1))
        store.apply([.updated(updatedFirst)])
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.selectedFlowID, first.id)
        XCTAssertEqual(snapshot.visibleRows.first?.state, .completed)

        store.selectSource(.domain("api.example.com"))
        store.setSort(TrafficConsoleSort(key: .status, ascending: false))
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [first.id, third.id])

        store.selectSource(.domain("cdn.example.com"))
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertNil(snapshot.selectedFlowID)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [second.id])
    }

    func testConsoleStoreKeepsPinnedDomainsVisibleAcrossSessionChanges() throws {
        let api = try Self.makeFlow(index: 1, host: "api.example.com", statusCode: 200)
        let cdn = try Self.makeFlow(index: 2, host: "cdn.example.com", statusCode: 200)
        var store = TrafficConsoleStore()
        store.apply([.finished(api), .finished(cdn)])

        store.setPinnedDomain("cdn.example.com", isPinned: true)
        store.setPinnedDomain("api.example.com", isPinned: true)

        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(
            snapshot.pinnedDomains,
            [
                TrafficDomainSummary(host: "api.example.com", flowCount: 1),
                TrafficDomainSummary(host: "cdn.example.com", flowCount: 1)
            ]
        )

        store.replaceAll([])
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(
            snapshot.pinnedDomains,
            [
                TrafficDomainSummary(host: "api.example.com", flowCount: 0),
                TrafficDomainSummary(host: "cdn.example.com", flowCount: 0)
            ]
        )

        store.setPinnedDomain("api.example.com", isPinned: false)
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(
            snapshot.pinnedDomains,
            [TrafficDomainSummary(host: "cdn.example.com", flowCount: 0)]
        )
    }

    func testPinnedDomainsStorePersistsNormalizedSortedDomains() throws {
        let suiteName = "ProxyLensIntegrationTests.PinnedDomains.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTrafficPinnedDomainsStore(defaults: defaults)

        store.save([" CDN.Example.com ", "api.example.com", ""])

        XCTAssertEqual(
            defaults.stringArray(forKey: UserDefaultsTrafficPinnedDomainsStore.defaultKey),
            ["api.example.com", "cdn.example.com"]
        )
        let restored = UserDefaultsTrafficPinnedDomainsStore(defaults: defaults)
        XCTAssertEqual(restored.domains, ["api.example.com", "cdn.example.com"])
    }

    func testConsoleStoreReplaceAllResetsRowsAndKeepsFilters() throws {
        let first = try Self.makeFlow(index: 1, host: "api.example.com", statusCode: 200)
        let second = try Self.makeFlow(index: 2, host: "cdn.example.com", statusCode: 404)
        let replacement = try Self.makeFlow(index: 3, host: "api.example.com", statusCode: 201)
        var store = TrafficConsoleStore()
        store.apply([.finished(first), .finished(second)])
        store.selectFlow(first.id)
        store.setDisplayFilter(TrafficDisplayFilter(searchText: "api"))

        store.replaceAll([replacement])
        let snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.allFlowCount, 1)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [replacement.id])
        XCTAssertNil(snapshot.selectedFlowID)
        XCTAssertEqual(snapshot.displayFilter.searchText, "api")
    }

    func testConsoleStoreGroupsAndFiltersDesktopApplicationsWithUnknownFallback() throws {
        let safari = FlowSource(
            kind: .desktopProxy,
            label: "Safari",
            application: FlowApplication(
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                bundlePath: "/System/Applications/Safari.app",
                executablePath: "/System/Applications/Safari.app/Contents/MacOS/Safari",
                processIdentifier: 101
            )
        )
        let curl = FlowSource(
            kind: .desktopProxy,
            label: "curl",
            application: FlowApplication(
                name: "curl",
                executablePath: "/usr/bin/curl",
                processIdentifier: 202
            )
        )
        let imported = FlowSource(kind: .importedSession, label: "Saved capture")
        let flows = try [
            Self.makeFlow(index: 1, host: "one.example.com", statusCode: 200, source: safari),
            Self.makeFlow(index: 2, host: "two.example.com", statusCode: 200, source: safari),
            Self.makeFlow(index: 3, host: "three.example.com", statusCode: 200, source: curl),
            Self.makeFlow(index: 4, host: "four.example.com", statusCode: 200),
            Self.makeFlow(index: 5, host: "five.example.com", statusCode: 200, source: imported)
        ]
        var store = TrafficConsoleStore()

        store.apply(flows.map(FlowEvent.finished))
        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)

        XCTAssertEqual(snapshot.applications.map(\.name), ["curl", "Safari", "Unknown App"])
        XCTAssertEqual(snapshot.applications.map(\.flowCount), [1, 2, 1])

        let safariID = try XCTUnwrap(snapshot.applications.first { $0.name == "Safari" }?.id)
        store.selectSource(.application(safariID))
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [flows[0].id, flows[1].id])

        let unknownID = try XCTUnwrap(
            snapshot.applications.first { $0.name == "Unknown App" }?.id
        )
        store.selectSource(.application(unknownID))
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [flows[3].id])
    }

    func testDisplayFilterComposesSearchFacetsAndDomainSelection() throws {
        let matching = try Self.makeFlow(
            index: 1,
            host: "api.example.com",
            statusCode: 201,
            method: .post,
            responseContentType: "application/problem+json; charset=utf-8",
            requestHeaderValue: "Blue Café"
        )
        let wrongOrigin = try Self.makeFlow(
            index: 2,
            host: "api.example.com",
            statusCode: 201,
            method: .post,
            responseContentType: "application/json",
            source: FlowSource(kind: .importedSession, label: "Blue Cafe archive"),
            requestHeaderValue: "Blue Cafe"
        )
        let wrongStatus = try Self.makeFlow(
            index: 3,
            host: "api.example.com",
            statusCode: 404,
            method: .post,
            responseContentType: "application/json",
            requestHeaderValue: "Blue Cafe"
        )
        let wrongDomain = try Self.makeFlow(
            index: 4,
            host: "cdn.example.com",
            statusCode: 200,
            method: .post,
            responseContentType: "application/json",
            requestHeaderValue: "Blue Cafe"
        )
        var store = TrafficConsoleStore()
        store.apply([
            .finished(matching),
            .finished(wrongOrigin),
            .finished(wrongStatus),
            .finished(wrongDomain)
        ])
        store.selectSource(.domain("api.example.com"))
        store.setDisplayFilter(
            TrafficDisplayFilter(
                searchText: "blue cafe",
                method: .post,
                status: .success,
                contentType: .json,
                origin: .desktopProxy
            )
        )

        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [matching.id])
        XCTAssertEqual(snapshot.allFlowCount, 4)
        XCTAssertTrue(snapshot.displayFilter.isActive)

        store.selectFlow(matching.id)
        store.setDisplayFilter(
            TrafficDisplayFilter(
                searchText: "missing",
                method: .post,
                status: .success,
                contentType: .json,
                origin: .desktopProxy
            )
        )
        XCTAssertNil(store.selectedFlowID)

        store.clearFilters()
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.count, 4)
        XCTAssertEqual(snapshot.selectedSource, .allTraffic)
        XCTAssertEqual(snapshot.displayFilter, .all)
    }

    func testDisplayFilterPersistsAcrossLargeLiveUpdatesAndSelectionChanges() throws {
        var flows: [Flow] = []
        flows.reserveCapacity(2_000)
        for index in 0..<2_000 {
            flows.append(
                try Self.makeFlow(
                    index: index,
                    host: "host-\(index % 25).example.com",
                    statusCode: 200 + (index % 5)
                )
            )
        }

        let filter = TrafficDisplayFilter(
            searchText: "host-7.example.com",
            method: .get,
            status: .success,
            contentType: .binary,
            origin: .desktopProxy
        )
        var store = TrafficConsoleStore()
        store.setDisplayFilter(filter)
        store.apply(flows.map(FlowEvent.finished))

        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.displayFilter, filter)
        XCTAssertEqual(snapshot.visibleRows.count, 40)

        let selectedID = try XCTUnwrap(snapshot.visibleRows.first?.id)
        store.selectFlow(selectedID)
        var selectedUpdate = try XCTUnwrap(flows.first { $0.id == selectedID })
        selectedUpdate.markTLSHandshakeCompleted(at: Date(timeIntervalSince1970: 2_100))
        store.apply([.updated(selectedUpdate)])
        XCTAssertEqual(store.selectedFlowID, selectedID)

        selectedUpdate.attachResponse(
            try HTTPResponse(
                statusCode: 404,
                reasonPhrase: "Not Found",
                headers: selectedUpdate.response?.headers ?? HTTPHeaders()
            )
        )
        store.apply([.updated(selectedUpdate)])
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertNil(snapshot.selectedFlowID)
        XCTAssertEqual(snapshot.visibleRows.count, 39)
        XCTAssertEqual(snapshot.displayFilter, filter)
    }

    func testActiveFilterIncrementallyProjectsLiveInsertionsAndUpdates() throws {
        let matching = try Self.makeFlow(
            index: 1,
            host: "api.example.com",
            statusCode: 200,
            requestHeaderValue: "needle"
        )
        var promoted = try Self.makeFlow(
            index: 2,
            host: "promoted.example.com",
            statusCode: 404,
            requestHeaderValue: "needle"
        )
        let hidden = try Self.makeFlow(
            index: 3,
            host: "hidden.example.com",
            statusCode: 200,
            requestHeaderValue: "haystack"
        )
        let liveMatching = try Self.makeFlow(
            index: 4,
            host: "live.example.com",
            statusCode: 204,
            requestHeaderValue: "needle"
        )

        var store = TrafficConsoleStore()
        store.setDisplayFilter(
            TrafficDisplayFilter(searchText: "needle", status: .success)
        )
        store.apply([.finished(matching), .finished(promoted), .finished(hidden)])
        XCTAssertEqual(
            store.snapshot(capture: .stopped, inspection: .empty).visibleRows.map(\.id),
            [matching.id]
        )

        store.apply([.finished(liveMatching)])
        XCTAssertEqual(
            store.snapshot(capture: .stopped, inspection: .empty).visibleRows.map(\.id),
            [matching.id, liveMatching.id]
        )

        promoted.attachResponse(
            try HTTPResponse(
                statusCode: 202,
                reasonPhrase: "Accepted",
                headers: promoted.response?.headers ?? HTTPHeaders()
            )
        )
        store.apply([.updated(promoted)])
        XCTAssertEqual(
            store.snapshot(capture: .stopped, inspection: .empty).visibleRows.map(\.id),
            [matching.id, promoted.id, liveMatching.id]
        )

        store.selectFlow(promoted.id)
        promoted.attachResponse(
            try HTTPResponse(
                statusCode: 503,
                reasonPhrase: "Unavailable",
                headers: promoted.response?.headers ?? HTTPHeaders()
            )
        )
        store.apply([.updated(promoted)])
        let snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [matching.id, liveMatching.id])
        XCTAssertNil(snapshot.selectedFlowID)
        XCTAssertEqual(snapshot.allFlowCount, 4)
    }

    func testFlowTableInsertsPromotedFilteredRowWithoutFullReload() throws {
        let tableView = RecordingTableView()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view

        let first = try Self.makeFlow(
            index: 1,
            host: "first.example.com",
            statusCode: 200,
            requestHeaderValue: "needle"
        )
        var promoted = try Self.makeFlow(
            index: 2,
            host: "promoted.example.com",
            statusCode: 404,
            requestHeaderValue: "needle"
        )
        let last = try Self.makeFlow(
            index: 3,
            host: "last.example.com",
            statusCode: 204,
            requestHeaderValue: "needle"
        )

        var store = TrafficConsoleStore()
        store.setDisplayFilter(
            TrafficDisplayFilter(searchText: "needle", status: .success)
        )
        store.apply([.finished(first), .finished(promoted), .finished(last)])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))
        tableView.resetRecordedUpdates()

        promoted.attachResponse(
            try HTTPResponse(
                statusCode: 202,
                reasonPhrase: "Accepted",
                headers: promoted.response?.headers ?? HTTPHeaders()
            )
        )
        store.apply([.updated(promoted)])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))

        XCTAssertEqual(tableView.insertedRowIndexes, [IndexSet(integer: 1)])
        XCTAssertEqual(tableView.fullReloadCount, 0)
        XCTAssertEqual(tableView.numberOfRows, 3)
    }

    func testFlowTableMovesSortedLiveUpdatesWithoutFullReload() throws {
        let tableView = RecordingTableView()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view

        var first = try Self.makeFlow(
            index: 1,
            host: "first.example.com",
            statusCode: 200,
            requestHeaderValue: "needle"
        )
        let second = try Self.makeFlow(
            index: 2,
            host: "second.example.com",
            statusCode: 300,
            requestHeaderValue: "needle"
        )
        let third = try Self.makeFlow(
            index: 3,
            host: "third.example.com",
            statusCode: 400,
            requestHeaderValue: "needle"
        )

        var store = TrafficConsoleStore()
        store.setDisplayFilter(TrafficDisplayFilter(searchText: "needle"))
        store.setSort(TrafficConsoleSort(key: .status, ascending: true))
        store.apply([.finished(first), .finished(second), .finished(third)])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))
        tableView.resetRecordedUpdates()

        first.attachResponse(
            try HTTPResponse(
                statusCode: 500,
                reasonPhrase: "Server Error",
                headers: first.response?.headers ?? HTTPHeaders()
            )
        )
        store.apply([.updated(first)])
        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [second.id, third.id, first.id])
        controller.render(snapshot)
        XCTAssertFalse(tableView.movedRows.isEmpty)
        XCTAssertEqual(tableView.fullReloadCount, 0)

        tableView.resetRecordedUpdates()
        first.attachResponse(
            try HTTPResponse(
                statusCode: 100,
                reasonPhrase: "Continue",
                headers: first.response?.headers ?? HTTPHeaders()
            )
        )
        store.apply([.updated(first)])
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [first.id, second.id, third.id])
        controller.render(snapshot)
        XCTAssertEqual(tableView.movedRows.count, 1)
        XCTAssertEqual(tableView.movedRows.first?.from, 2)
        XCTAssertEqual(tableView.movedRows.first?.to, 0)
        XCTAssertEqual(tableView.fullReloadCount, 0)
        XCTAssertEqual(tableView.numberOfRows, 3)
    }

    func testFlowTableKeepsDataSourceInSyncWhenRemovingMultipleRows() throws {
        let tableView = RecordingTableView()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view

        let kept = try Self.makeFlow(index: 1, host: "keep.example.com", statusCode: 200)
        let droppedA = try Self.makeFlow(index: 2, host: "drop-a.example.com", statusCode: 404)
        let droppedB = try Self.makeFlow(index: 3, host: "drop-b.example.com", statusCode: 500)
        let droppedC = try Self.makeFlow(index: 4, host: "drop-c.example.com", statusCode: 204)

        var store = TrafficConsoleStore()
        store.apply([
            .finished(kept),
            .finished(droppedA),
            .finished(droppedB),
            .finished(droppedC)
        ])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))
        XCTAssertEqual(tableView.numberOfRows, 4)
        tableView.resetRecordedUpdates()

        store.selectSource(.domain("keep.example.com"))
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))

        XCTAssertEqual(
            tableView.removedRowIndexes,
            [
                IndexSet(integer: 3),
                IndexSet(integer: 2),
                IndexSet(integer: 1)
            ])
        XCTAssertEqual(tableView.dataSourceRowCountsDuringRemovals, [3, 2, 1])
        XCTAssertEqual(tableView.fullReloadCount, 0)
        XCTAssertEqual(tableView.numberOfRows, 1)
    }

    func testFlowTableContextMenuOffersRepeatRequestFirst() throws {
        let tableView = RecordingTableView()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view
        let flow = try Self.makeFlow(
            index: 1,
            host: "api.example.com",
            statusCode: 200
        )
        var store = TrafficConsoleStore()
        store.apply([.finished(flow)])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))
        tableView.clickedRowOverride = 0
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(menu.items.first?.title, "Repeat Request")
        XCTAssertEqual(menu.items.first?.action, NSSelectorFromString("repeatRequest:"))
        XCTAssertEqual(menu.items.first?.representedObject as? FlowID, flow.id)
        XCTAssertEqual(menu.items[1].title, "Edit & Repeat…")
        XCTAssertEqual(menu.items[1].action, NSSelectorFromString("editAndRepeat:"))
        XCTAssertEqual(menu.items[1].representedObject as? FlowID, flow.id)
    }

    func testRequestEditorExposesAccessiblePlainTextFieldsAndOnlyReturnsChangedBody() throws {
        let controller = RequestEditorViewController(
            draft: TrafficRequestEditDraft(
                headersText: "GET / HTTP/1.1\nHost: api.example.com",
                bodyText: "before",
                canEditBody: true,
                bodyMessage: nil
            )
        )
        _ = controller.view

        XCTAssertEqual(controller.headersText, "GET / HTTP/1.1\nHost: api.example.com")
        XCTAssertEqual(controller.bodyText, "before")
        XCTAssertNil(controller.changedBodyText)
        XCTAssertNotNil(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestEditor.headers" }
            )
        )
        XCTAssertNotNil(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestEditor.body" }
            )
        )

        controller.bodyText = "after"

        XCTAssertEqual(controller.changedBodyText, "after")

        let binaryController = RequestEditorViewController(
            draft: TrafficRequestEditDraft(
                headersText: "POST / HTTP/1.1\nHost: api.example.com",
                bodyText: "",
                canEditBody: false,
                bodyMessage: "Binary request bodies are preserved but cannot be edited"
            )
        )
        _ = binaryController.view
        let binaryBodyEditor = Self.descendant(
            of: NSTextView.self,
            in: binaryController.view,
            matching: { $0.accessibilityIdentifier() == "requestEditor.body" }
        )
        XCTAssertFalse(try XCTUnwrap(binaryBodyEditor).isEditable)
        binaryController.bodyText = "replacement"
        XCTAssertNil(binaryController.changedBodyText)
    }

    func testRequestEditorPrettyPrintsAndHighlightsJSONWithoutTreatingFormattingAsAnEdit()
        async throws
    {
        let controller = RequestEditorViewController(
            draft: TrafficRequestEditDraft(
                headersText:
                    "POST /events HTTP/1.1\nHost: api.example.com\nContent-Type: application/json",
                bodyText: #"{"name":"ProxyLens","enabled":true}"#,
                canEditBody: true,
                bodyMessage: nil
            )
        )

        _ = controller.view

        let expected = """
            {
              "enabled" : true,
              "name" : "ProxyLens"
            }
            """
        XCTAssertEqual(controller.bodyText, expected)
        XCTAssertNil(controller.changedBodyText)

        let headersEditor = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestEditor.headers" }
            )
        )
        let bodyEditor = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestEditor.body" }
            )
        )

        XCTAssertEqual(
            headersEditor.textStorage?.attribute(
                .foregroundColor,
                at: (headersEditor.string as NSString).range(of: "Content-Type").location,
                effectiveRange: nil
            ) as? NSColor,
            InspectorSyntaxPalette.key
        )
        XCTAssertEqual(
            bodyEditor.textStorage?.attribute(
                .foregroundColor,
                at: (bodyEditor.string as NSString).range(of: #""name""#).location,
                effectiveRange: nil
            ) as? NSColor,
            InspectorSyntaxPalette.key
        )

        bodyEditor.string = #"{"count":42}"#
        controller.textDidChange(
            Notification(name: NSText.didChangeNotification, object: bodyEditor)
        )
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(
            bodyEditor.textStorage?.attribute(
                .foregroundColor,
                at: (bodyEditor.string as NSString).range(of: "42").location,
                effectiveRange: nil
            ) as? NSColor,
            InspectorSyntaxPalette.number
        )
        XCTAssertEqual(controller.changedBodyText, #"{"count":42}"#)
    }

    func testViewModelBatchesLargeFlowListsAndLoadsAuthoritativeBodies() async throws {
        let captureController = RecordingCaptureController()
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        var flows: [Flow] = []
        flows.reserveCapacity(2_000)
        for index in 0..<2_000 {
            let flow = try Self.makeFlow(
                index: index,
                host: "host-\(index % 25).example.com",
                statusCode: 200 + (index % 5)
            )
            flows.append(flow)
            viewModel.receive(.finished(flow))
        }
        viewModel.flushPendingEvents()

        XCTAssertEqual(viewModel.snapshot.allFlowCount, 2_000)
        XCTAssertEqual(viewModel.snapshot.visibleRows.count, 2_000)
        XCTAssertEqual(viewModel.snapshot.domains.count, 25)

        let selected = try Self.makeFlow(
            index: 2_001,
            host: "inspect.example.com",
            statusCode: 201,
            requestBody: Data("request body".utf8),
            responseBody: Data([0, 1, 255])
        )
        viewModel.receive(.finished(selected))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(selected.id)

        try await waitUntil {
            guard case .content = viewModel.snapshot.inspection.request?.body else {
                return false
            }
            return true
        }

        guard
            case .content(let requestMetadata, let requestValue) =
                viewModel.snapshot.inspection.request?.body
        else {
            return XCTFail("Expected loaded request body")
        }
        XCTAssertTrue(requestMetadata.contains("12 B"))
        XCTAssertEqual(requestValue, "request body")

        guard
            case .content(let responseMetadata, let responseValue) =
                viewModel.snapshot.inspection.response?.body
        else {
            return XCTFail("Expected loaded response body")
        }
        XCTAssertTrue(responseMetadata.contains("3 B"))
        XCTAssertTrue(responseValue.contains("00000000"))
        XCTAssertTrue(responseValue.contains("00 01 ff"))
    }

    func testViewModelHydratesPersistedWorkspaceAndClearsItOffline() async throws {
        let first = try Self.makeFlow(
            index: 1,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data("request body".utf8),
            responseBody: Data("response body".utf8)
        )
        let second = try Self.makeFlow(
            index: 2,
            host: "cdn.example.com",
            statusCode: 404
        )
        let sessionService = RecordingSessionService(flows: [first, second])
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            exportService: ExportService(bodyStore: InlineBodyStore()),
            sessionService: sessionService
        )

        await viewModel.prepare()

        XCTAssertEqual(viewModel.snapshot.allFlowCount, 2)
        XCTAssertEqual(viewModel.snapshot.visibleRows.map(\.id), [first.id, second.id])
        XCTAssertEqual(viewModel.snapshot.capture, .stopped)

        viewModel.selectFlow(first.id)
        try await waitUntil {
            guard case .content = viewModel.snapshot.inspection.request?.body else {
                return false
            }
            return true
        }
        guard
            case .content(_, let requestValue) = viewModel.snapshot.inspection.request?.body
        else {
            return XCTFail("Expected loaded request body")
        }
        XCTAssertEqual(requestValue, "request body")

        let command = try await viewModel.curlCommand(for: first.id)
        XCTAssertTrue(command.contains("curl 'https://api.example.com/v1/items/1?source=test'"))
        XCTAssertTrue(command.contains("--data-binary 'request body'"))

        try await viewModel.clearSession()
        let didClear = await sessionService.cleared()
        XCTAssertTrue(didClear)
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 0)
        XCTAssertTrue(viewModel.snapshot.visibleRows.isEmpty)
        XCTAssertNil(viewModel.snapshot.selectedFlowID)
        XCTAssertEqual(viewModel.snapshot.inspection, .empty)
    }

    func testViewModelStopsCaptureAndDropsPendingEventsWhenClearingTheSession() async throws {
        let persisted = try Self.makeFlow(index: 1, host: "api.example.com", statusCode: 200)
        let pending = try Self.makeFlow(index: 2, host: "cdn.example.com", statusCode: 404)
        let sessionService = RecordingSessionService(flows: [persisted])
        let captureController = RecordingCaptureController()
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            sessionService: sessionService
        )

        await viewModel.prepare()
        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }
        viewModel.receive(.finished(pending))
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 1)

        try await viewModel.clearSession()

        XCTAssertEqual(viewModel.snapshot.capture, .stopped)
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 0)
        XCTAssertTrue(viewModel.snapshot.visibleRows.isEmpty)
        let didClear = await sessionService.cleared()
        XCTAssertTrue(didClear)
        let calls = await captureController.calls()
        XCTAssertEqual(calls, ["recover", "start", "stop"])

        viewModel.flushPendingEvents()
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 0)
    }

    func testViewModelSurfacesWorkspaceHydrationFailures() async throws {
        let sessionService = RecordingSessionService(
            loadError: ProxyLensError.unsupportedOperation("The capture database could not be read")
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            sessionService: sessionService
        )

        await viewModel.prepare()

        XCTAssertEqual(viewModel.snapshot.capture, .stopped)
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 0)
        XCTAssertEqual(
            viewModel.snapshot.workspaceWarning,
            "Could not restore the previous session: Unsupported operation: The capture database could not be read"
        )
    }

    func testViewModelPublishesCertificateTrustAndRefreshesAfterInstall() async throws {
        let trust = RecordingCertificateTrust(state: .untrusted)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            certificateTrust: trust
        )

        await viewModel.prepare()
        XCTAssertEqual(viewModel.snapshot.certificateTrust, .untrusted)

        try await viewModel.installCertificateTrust()
        XCTAssertEqual(viewModel.snapshot.certificateTrust, .trusted)
        let calls = await trust.calls()
        XCTAssertEqual(calls, ["state", "install", "state"])
    }

    func testViewModelSwallowsCertificateTrustCancellationAndSurfacesFailures() async throws {
        let trust = RecordingCertificateTrust(state: .untrusted)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            certificateTrust: trust
        )

        await viewModel.prepare()
        await trust.failNextInstall(CertificateTrustError.userCancelled)
        try await viewModel.installCertificateTrust()
        XCTAssertEqual(viewModel.snapshot.certificateTrust, .untrusted)

        await trust.failNextInstall(
            ProxyLensError.unsupportedOperation("The trust settings could not be updated")
        )
        do {
            try await viewModel.installCertificateTrust()
            XCTFail("Expected a trust failure to be surfaced")
        } catch let error as ProxyLensError {
            XCTAssertEqual(
                error,
                .unsupportedOperation("The trust settings could not be updated")
            )
        }
        XCTAssertEqual(viewModel.snapshot.certificateTrust, .untrusted)

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-trust-\(UUID().uuidString).pem")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try await viewModel.exportRootCertificate(to: exportURL)
        XCTAssertEqual(viewModel.snapshot.certificateTrust, .untrusted)
        let exported = await trust.exportedURLs()
        XCTAssertEqual(exported, [exportURL])
    }

    func testCaptureControlPresentsRecoveryStartAndStopTransitions() async throws {
        let captureController = RecordingCaptureController()
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )

        await viewModel.prepare()
        XCTAssertEqual(viewModel.snapshot.capture, .stopped)

        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }
        guard case .running(let context, _) = viewModel.snapshot.capture else {
            return XCTFail("Expected capture to be running")
        }
        XCTAssertEqual(context.endpoint, NetworkEndpoint(host: "127.0.0.1", port: 59_090))

        viewModel.toggleCapture()
        try await waitUntil {
            viewModel.snapshot.capture == .stopped
        }
        let calls = await captureController.calls()
        XCTAssertEqual(calls, ["recover", "start", "stop"])
    }

    func testCaptureControlKeepsStopAvailableAfterProxyRestoreFailure() async throws {
        let restoreError = CaptureCoordinatorError.stopFailed(
            stage: .systemProxyRestoration,
            message: "Previous proxy settings are temporarily unavailable"
        )
        let captureController = RecordingCaptureController(stopError: restoreError)
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )

        await viewModel.prepare()
        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }

        viewModel.toggleCapture()
        try await waitUntil {
            guard case .running(_, let warning) = viewModel.snapshot.capture else {
                return false
            }
            return warning?.contains("systemProxyRestoration") == true
        }

        viewModel.toggleCapture()
        try await waitUntil {
            viewModel.snapshot.capture == .stopped
        }
        let calls = await captureController.calls()
        XCTAssertEqual(calls, ["recover", "start", "stop", "stop"])
    }

    func testViewModelObservesPublishedFlowEvents() async throws {
        let eventBus = FlowEventBus()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: eventBus,
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .milliseconds(1)
        )
        await viewModel.prepare()
        try await waitUntilAsync {
            await eventBus.subscriptionCount() == 1
        }

        let flow = try Self.makeFlow(index: 5, host: "stream.example.com", statusCode: 202)
        await eventBus.publish(.finished(flow))

        try await waitUntil {
            viewModel.snapshot.visibleRows.map(\.id) == [flow.id]
        }
    }

    func testViewModelComposesARequestIntoTheCurrentWorkspace() async throws {
        let sessionID = SessionID()
        let replayed = try Self.makeFlow(
            index: 40,
            host: "api.example.com",
            statusCode: 201,
            source: .replay
        )
        let replayer = RecordingRequestReplayer(result: replayed)
        let sessionService = RecordingSessionService(composeSessionID: sessionID)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            requestReplayer: replayer,
            sessionService: sessionService
        )
        await viewModel.prepare()

        let replayedID = try await viewModel.composeRequest(
            headersText: """
                POST https://api.example.com/v1/events HTTP/1.1
                Content-Type: application/json
                """,
            bodyText: #"{"name":"ProxyLens"}"#
        )

        XCTAssertEqual(replayedID, replayed.id)
        XCTAssertEqual(viewModel.snapshot.selectedFlowID, replayed.id)
        let received = await replayer.receivedRequests()
        let request = try XCTUnwrap(received.first?.request)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/events")
        XCTAssertEqual(request.body?.inlineData, Data(#"{"name":"ProxyLens"}"#.utf8))
        XCTAssertEqual(
            request.headers.firstValue(for: "Content-Length"),
            "20"
        )
        XCTAssertEqual(received.first?.sessionID, sessionID)
        let composeSessionRequestCount = await sessionService.composeSessionRequestCount()
        XCTAssertEqual(composeSessionRequestCount, 1)

        do {
            try await viewModel.composeRequest(
                headersText: "GET /relative HTTP/1.1\nHost: api.example.com",
                bodyText: nil
            )
            XCTFail("Expected a relative composed target to be rejected")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid HTTP message: A composed request must use an absolute HTTP or HTTPS URL"
            )
        }
        let requestsAfterInvalidInput = await replayer.receivedRequests()
        let sessionsAfterInvalidInput = await sessionService.composeSessionRequestCount()
        XCTAssertEqual(requestsAfterInvalidInput.count, 1)
        XCTAssertEqual(sessionsAfterInvalidInput, 1)
    }

    func testViewModelRepeatsAFlowAndSelectsTheVisibleReplayResult() async throws {
        let original = try Self.makeFlow(
            index: 41,
            host: "api.example.com",
            statusCode: 200
        )
        let replayed = try Self.makeFlow(
            index: 42,
            host: "api.example.com",
            statusCode: 202,
            source: .replay
        )
        let replayer = RecordingRequestReplayer(result: replayed)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            requestReplayer: replayer
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()
        viewModel.setOriginFilter(.desktopProxy)

        let replayedID = try await viewModel.repeatRequest(flowID: original.id)

        XCTAssertEqual(replayedID, replayed.id)
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 2)
        XCTAssertEqual(viewModel.snapshot.selectedFlowID, replayed.id)
        XCTAssertEqual(viewModel.snapshot.displayFilter, .all)
        XCTAssertEqual(viewModel.snapshot.selectedSource, .allTraffic)
        XCTAssertEqual(viewModel.snapshot.inspection.flowID, replayed.id)
        let received = await replayer.receivedRequests()
        XCTAssertEqual(received.map(\.request), [original.request])
        XCTAssertEqual(received.map(\.sessionID), [original.sessionID])
    }

    func testViewModelBuildsARequestDraftAndRepeatsTheEditedRequest() async throws {
        let original = try Self.makeFlow(
            index: 43,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data("before".utf8),
            method: .post
        )
        let replayed = try Self.makeFlow(
            index: 44,
            host: "staging.example.com",
            statusCode: 201,
            source: .replay
        )
        let replayer = RecordingRequestReplayer(result: replayed)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            requestReplayer: replayer
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()

        let draft = try await viewModel.requestEditDraft(flowID: original.id)
        let replayedID = try await viewModel.editAndRepeat(
            flowID: original.id,
            headersText: """
                PUT /v2/users/42 HTTP/1.1
                Host: staging.example.com
                Content-Type: text/plain
                X-Debug: enabled
                """,
            bodyText: "after"
        )

        XCTAssertEqual(draft.headersText, HTTPMessageText.requestHeaders(original.request))
        XCTAssertEqual(draft.bodyText, "before")
        XCTAssertTrue(draft.canEditBody)
        XCTAssertNil(draft.bodyMessage)
        XCTAssertEqual(replayedID, replayed.id)
        XCTAssertEqual(viewModel.snapshot.selectedFlowID, replayed.id)
        let received = await replayer.receivedRequests()
        let editedRequest = try XCTUnwrap(received.first?.request)
        XCTAssertEqual(editedRequest.method, .put)
        XCTAssertEqual(editedRequest.url.absoluteString, "https://staging.example.com/v2/users/42")
        XCTAssertEqual(editedRequest.headers.firstValue(for: "X-Debug"), "enabled")
        XCTAssertEqual(editedRequest.body?.inlineData, Data("after".utf8))
        XCTAssertEqual(received.first?.sessionID, original.sessionID)
    }

    func testViewModelEditsAndReencodesAGzipJSONRequestBody() async throws {
        let compressedBody = try XCTUnwrap(
            Data(base64Encoded: "H4sIAAAAAAAC/6tWKkvMKU1VslJKSk3LL0pVqgUAy2iO6hIAAAA=")
        )
        let original = try Self.makeFlow(
            index: 47,
            host: "api.example.com",
            statusCode: 200,
            requestBody: compressedBody,
            method: .post,
            requestContentType: "application/json",
            requestContentEncoding: "gzip"
        )
        let replayed = try Self.makeFlow(
            index: 48,
            host: "api.example.com",
            statusCode: 201,
            source: .replay
        )
        let replayer = RecordingRequestReplayer(result: replayed)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            requestReplayer: replayer
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()

        let draft = try await viewModel.requestEditDraft(flowID: original.id)
        let replayedID = try await viewModel.editAndRepeat(
            flowID: original.id,
            headersText: draft.headersText,
            bodyText: #"{"value":"after"}"#
        )

        XCTAssertTrue(draft.canEditBody)
        XCTAssertEqual(draft.bodyText, #"{"value":"before"}"#)
        XCTAssertNil(draft.bodyMessage)
        XCTAssertEqual(replayedID, replayed.id)
        let received = await replayer.receivedRequests()
        let editedRequest = try XCTUnwrap(received.first?.request)
        let editedBody = try XCTUnwrap(editedRequest.body?.inlineData)
        XCTAssertEqual(editedRequest.headers.firstValue(for: "Content-Encoding"), "gzip")
        XCTAssertEqual(
            editedRequest.headers.firstValue(for: "Content-Length"),
            "\(editedBody.count)"
        )
        guard
            case .prettyPrinted(let editedJSON) = JSONBodyView.render(
                data: editedBody,
                contentType: editedRequest.headers.firstValue(for: "Content-Type"),
                contentEncoding: editedRequest.headers.firstValue(for: "Content-Encoding")
            )
        else {
            return XCTFail("Expected the edited body to remain valid gzip JSON")
        }
        XCTAssertTrue(editedJSON.contains(#""value" : "after""#))
    }

    func testViewModelDoesNotLoadAnOversizedBodyIntoTheRequestEditor() async throws {
        let original = try Self.makeFlow(
            index: 45,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data("ninebytes".utf8)
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            maximumEditableRequestBodyBytes: 8
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()

        let draft = try await viewModel.requestEditDraft(flowID: original.id)

        XCTAssertEqual(draft.bodyText, "")
        XCTAssertFalse(draft.canEditBody)
        XCTAssertEqual(draft.bodyMessage, "Body editing is limited to 8 bytes")
    }

    func testViewModelRejectsAnEditedBodyThatExceedsTheEditorLimit() async throws {
        let original = try Self.makeFlow(
            index: 49,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data("before".utf8)
        )
        let replayed = try Self.makeFlow(
            index: 50,
            host: "api.example.com",
            statusCode: 201,
            source: .replay
        )
        let replayer = RecordingRequestReplayer(result: replayed)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            maximumEditableRequestBodyBytes: 8,
            requestReplayer: replayer
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()

        do {
            try await viewModel.editAndRepeat(
                flowID: original.id,
                headersText: HTTPMessageText.requestHeaders(original.request),
                bodyText: "ninebytes"
            )
            XCTFail("Expected the oversized edit to be rejected")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Unsupported operation: Body editing is limited to 8 bytes"
            )
        }
        let received = await replayer.receivedRequests()
        XCTAssertTrue(received.isEmpty)
    }

    func testViewModelPreservesABinaryBodyOutsideTheTextRequestEditor() async throws {
        let original = try Self.makeFlow(
            index: 46,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data([0x00, 0xFF, 0x01])
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()

        let draft = try await viewModel.requestEditDraft(flowID: original.id)

        XCTAssertEqual(draft.bodyText, "")
        XCTAssertFalse(draft.canEditBody)
        XCTAssertEqual(
            draft.bodyMessage,
            "Binary request bodies are preserved but cannot be edited"
        )
    }

    func testTrafficConsoleHidesWindowTitleAndInspectorWithoutSelection() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 12,
            host: "api.example.com",
            statusCode: 200
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        XCTAssertNil(viewModel.snapshot.selectedFlowID)

        let frame = NSRect(x: 0, y: 0, width: 1_200, height: 720)
        let controller = TrafficConsoleViewController(viewModel: viewModel)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ProxyLens"
        window.contentViewController = controller
        window.setContentSize(frame.size)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.superview?.layoutSubtreeIfNeeded()

        let detailSplit = try XCTUnwrap(
            Self.descendant(
                of: NSSplitView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.split.detail" }
            )
        )
        let flowPane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.flows" }
            )
        )
        let inspectorPane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.inspector" }
            )
        )
        XCTAssertEqual(flowPane.frame.height, detailSplit.bounds.height, accuracy: 1)
        XCTAssertTrue(inspectorPane.visibleRect.isEmpty)

        let titlebarRoot = try XCTUnwrap(window.contentView?.superview)
        let title = Self.descendant(
            of: NSTextField.self,
            in: titlebarRoot,
            matching: { $0.accessibilityIdentifier() == "window.title.centered" }
        )
        XCTAssertNil(title)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertNil(window.toolbar)

        let composeButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "request.compose" }
            )
        )
        XCTAssertEqual(composeButton.title, "Compose Request…")
        XCTAssertEqual(composeButton.action, NSSelectorFromString("composeRequest:"))
        XCTAssertEqual(composeButton.keyEquivalent, "n")
        XCTAssertEqual(composeButton.keyEquivalentModifierMask, [.command])

        viewModel.selectFlow(flow.id)
        try await waitUntil {
            viewModel.snapshot.selectedFlowID == flow.id
                && !inspectorPane.visibleRect.isEmpty
                && inspectorPane.frame.height >= 240
        }
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            flowPane.frame.height / detailSplit.bounds.height,
            0.36,
            accuracy: 0.05
        )

        let requestedInspectorHeight: CGFloat = 280
        detailSplit.setPosition(
            detailSplit.bounds.height
                - detailSplit.dividerThickness
                - requestedInspectorHeight,
            ofDividerAt: 0
        )
        controller.view.layoutSubtreeIfNeeded()
        let rememberedInspectorHeight = inspectorPane.frame.height
        XCTAssertEqual(rememberedInspectorHeight, requestedInspectorHeight, accuracy: 1)

        viewModel.selectFlow(nil)
        try await waitUntil {
            viewModel.snapshot.selectedFlowID == nil
                && inspectorPane.visibleRect.isEmpty
                && abs(flowPane.frame.height - detailSplit.bounds.height) <= 1
        }
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(flowPane.frame.height, detailSplit.bounds.height, accuracy: 1)
        XCTAssertTrue(inspectorPane.visibleRect.isEmpty)

        viewModel.selectFlow(flow.id)
        try await waitUntil {
            viewModel.snapshot.selectedFlowID == flow.id
                && !inspectorPane.visibleRect.isEmpty
        }
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(inspectorPane.frame.height, rememberedInspectorHeight, accuracy: 1)
    }

    func testTrafficConsoleTogglesSourceListAndRendersPinnedDomains() async throws {
        let pinnedDomainsStore = InMemoryTrafficPinnedDomainsStore(
            domains: ["offline.example.com"]
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            pinnedDomainsStore: pinnedDomainsStore
        )
        await viewModel.prepare()
        let flow = try Self.makeFlow(
            index: 13,
            host: "api.example.com",
            statusCode: 200
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()

        let frame = NSRect(x: 0, y: 0, width: 1_200, height: 720)
        let controller = TrafficConsoleViewController(viewModel: viewModel)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(frame.size)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutSubtreeIfNeeded()

        let sourcePane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.sources" }
            )
        )
        let sourceOutline = try XCTUnwrap(
            Self.descendant(
                of: NSOutlineView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.sources" }
            )
        )
        let sourceToggle = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "sourceList.toggle" }
            )
        )
        let sourceLabels = (0..<sourceOutline.numberOfRows).compactMap { row in
            sourceOutline.view(atColumn: 0, row: row, makeIfNecessary: true)?
                .accessibilityLabel()
        }
        XCTAssertTrue(sourceLabels.contains("Pinned, 1 domain"))
        XCTAssertTrue(sourceLabels.contains("api.example.com, 1 flow"))
        XCTAssertTrue(sourceLabels.contains("offline.example.com, 0 flows"))
        let apiRow = try XCTUnwrap(
            (0..<sourceOutline.numberOfRows).first { row in
                sourceOutline.view(atColumn: 0, row: row, makeIfNecessary: true)?
                    .accessibilityLabel() == "api.example.com, 1 flow"
            }
        )
        sourceOutline.selectRowIndexes(IndexSet(integer: apiRow), byExtendingSelection: false)
        let sourceMenu = try XCTUnwrap(sourceOutline.menu)
        let menuDelegate = try XCTUnwrap(sourceMenu.delegate as? SourceListViewController)
        menuDelegate.menuNeedsUpdate(sourceMenu)
        let pinItem = try XCTUnwrap(sourceMenu.items.first)
        XCTAssertEqual(pinItem.title, "Pin Domain")
        XCTAssertEqual(pinItem.representedObject as? String, "api.example.com")
        let pinAction = try XCTUnwrap(pinItem.action)
        XCTAssertTrue(NSApp.sendAction(pinAction, to: pinItem.target, from: pinItem))
        XCTAssertEqual(
            viewModel.snapshot.pinnedDomains.map(\.host),
            [
                "api.example.com", "offline.example.com"
            ])
        XCTAssertEqual(
            pinnedDomainsStore.domains,
            ["api.example.com", "offline.example.com"]
        )
        let updatedSourceLabels = (0..<sourceOutline.numberOfRows).compactMap { row in
            sourceOutline.view(atColumn: 0, row: row, makeIfNecessary: true)?
                .accessibilityLabel()
        }
        XCTAssertTrue(updatedSourceLabels.contains("Pinned, 2 domains"))
        XCTAssertFalse(sourcePane.visibleRect.isEmpty)
        XCTAssertEqual(sourceToggle.accessibilityLabel(), "Hide Source List")

        sourceToggle.performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(sourcePane.visibleRect.isEmpty)
        XCTAssertEqual(sourceToggle.accessibilityLabel(), "Show Source List")

        sourceToggle.performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(sourcePane.visibleRect.isEmpty)
        XCTAssertEqual(sourceToggle.accessibilityLabel(), "Hide Source List")
    }

    func testTrafficConsoleRendersSplitMessageInspector() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let safariSource = FlowSource(
            kind: .desktopProxy,
            label: "Safari",
            application: FlowApplication(
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                bundlePath: "/System/Applications/Safari.app",
                processIdentifier: 501
            )
        )
        let flows = try [
            Self.makeFlow(
                index: 1,
                host: "api.example.com",
                statusCode: 201,
                source: safariSource
            ),
            Self.makeFlow(index: 2, host: "cdn.example.com", statusCode: 304),
            Self.makeFlow(
                index: 3,
                host: "api.example.com",
                statusCode: 404,
                requestBody: Data("{\"query\":\"proxylens\"}".utf8),
                responseBody: Data("{\"error\":\"not found\"}".utf8)
            ),
            Self.makeFlow(index: 4, host: "auth.example.net", statusCode: 500)
        ]
        for flow in flows {
            viewModel.receive(.finished(flow))
        }
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flows[2].id)
        try await waitUntil {
            guard case .content = viewModel.snapshot.inspection.request?.body else {
                return false
            }
            return true
        }
        XCTAssertEqual(viewModel.snapshot.visibleRows.count, flows.count)

        let frame = NSRect(x: 0, y: 0, width: 1_200, height: 720)
        let controller = TrafficConsoleViewController(viewModel: viewModel)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(frame.size)
        controller.view.frame = NSRect(origin: .zero, size: frame.size)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()

        let sourceOutline = try XCTUnwrap(
            Self.descendant(of: NSOutlineView.self, in: controller.view)
        )
        let flowTable = try XCTUnwrap(
            Self.descendant(
                of: NSTableView.self,
                in: controller.view,
                matching: { !($0 is NSOutlineView) }
            )
        )
        let requestInspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.request.content" }
            )
        )
        let responseInspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.response.content" }
            )
        )
        let searchField = try XCTUnwrap(
            Self.descendant(
                of: NSSearchField.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.search" }
            )
        )
        let clearButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.filter.clear" }
            )
        )
        let rootSplit = try XCTUnwrap(
            Self.descendant(
                of: NSSplitView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.split.root" }
            )
        )
        let detailSplit = try XCTUnwrap(
            Self.descendant(
                of: NSSplitView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.split.detail" }
            )
        )
        XCTAssertTrue(rootSplit.isVertical)
        XCTAssertFalse(detailSplit.isVertical)
        let sourcePane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.sources" }
            )
        )
        let flowPane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.flows" }
            )
        )
        let inspectorPane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.inspector" }
            )
        )

        let sourcePaneFrame = sourcePane.convert(sourcePane.bounds, to: controller.view)
        let workspaceFrame = detailSplit.convert(detailSplit.bounds, to: controller.view)
        XCTAssertGreaterThanOrEqual(sourcePaneFrame.width, 250)
        XCTAssertGreaterThanOrEqual(sourcePaneFrame.minY, workspaceFrame.minY)
        XCTAssertLessThanOrEqual(sourcePaneFrame.maxY, workspaceFrame.maxY)
        XCTAssertGreaterThan(sourcePaneFrame.height, workspaceFrame.height * 0.9)

        let flowPaneFrame = flowPane.convert(flowPane.bounds, to: controller.view)
        let inspectorPaneFrame = inspectorPane.convert(inspectorPane.bounds, to: controller.view)
        XCTAssertLessThanOrEqual(sourcePaneFrame.maxX, flowPaneFrame.minX)
        XCTAssertEqual(flowPaneFrame.minX, inspectorPaneFrame.minX, accuracy: 1)
        XCTAssertEqual(flowPaneFrame.width, inspectorPaneFrame.width, accuracy: 1)
        XCTAssertGreaterThan(flowPaneFrame.minY, inspectorPaneFrame.minY)
        XCTAssertLessThanOrEqual(inspectorPaneFrame.maxY, flowPaneFrame.minY)
        XCTAssertEqual(
            flowPaneFrame.height / workspaceFrame.height,
            0.36,
            accuracy: 0.05
        )

        let messageSplit = try XCTUnwrap(
            Self.descendant(
                of: NSSplitView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.split.messages"
                }
            )
        )
        let requestPane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.request" }
            )
        )
        let responsePane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.response" }
            )
        )
        XCTAssertTrue(messageSplit.isVertical)
        let requestPaneFrame = requestPane.convert(requestPane.bounds, to: inspectorPane)
        let responsePaneFrame = responsePane.convert(responsePane.bounds, to: inspectorPane)
        XCTAssertLessThanOrEqual(requestPaneFrame.maxX, responsePaneFrame.minX)
        XCTAssertEqual(requestPaneFrame.minY, responsePaneFrame.minY, accuracy: 1)
        XCTAssertEqual(requestPaneFrame.height, responsePaneFrame.height, accuracy: 1)
        XCTAssertEqual(requestPaneFrame.width, responsePaneFrame.width, accuracy: 2)

        let modeSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.mode" }
            )
        )
        let requestSectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.section"
                }
            )
        )
        let responseSectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.response.section"
                }
            )
        )
        let summaryMethod = Self.descendant(
            of: NSTextField.self,
            in: controller.view,
            matching: { $0.accessibilityIdentifier() == "inspector.summary.method" }
        )
        let summaryStatus = Self.descendant(
            of: NSTextField.self,
            in: controller.view,
            matching: { $0.accessibilityIdentifier() == "inspector.summary.status" }
        )
        let summaryURL = Self.descendant(
            of: NSTextField.self,
            in: controller.view,
            matching: { $0.accessibilityIdentifier() == "inspector.summary.url" }
        )
        XCTAssertLessThan(modeSelector.frame.width, inspectorPaneFrame.width / 2)
        XCTAssertLessThan(requestSectionSelector.frame.width, requestPaneFrame.width)
        XCTAssertLessThan(responseSectionSelector.frame.width, responsePaneFrame.width)
        XCTAssertEqual(
            (0..<requestSectionSelector.segmentCount).map {
                requestSectionSelector.label(forSegment: $0)
            },
            ["Headers", "Query", "Body", "JSON", "Raw"]
        )
        XCTAssertEqual(
            (0..<responseSectionSelector.segmentCount).map {
                responseSectionSelector.label(forSegment: $0)
            },
            ["Headers", "Body", "JSON", "Raw"]
        )
        XCTAssertEqual(summaryMethod?.stringValue, "POST")
        XCTAssertEqual(summaryStatus?.stringValue, "404 Result")
        XCTAssertEqual(
            summaryURL?.stringValue,
            "https://api.example.com/v1/items/3?source=test"
        )
        for identifier in [
            "traffic.filter.method",
            "traffic.filter.status",
            "traffic.filter.contentType",
            "traffic.filter.source"
        ] {
            XCTAssertNotNil(
                Self.descendant(
                    of: NSPopUpButton.self,
                    in: controller.view,
                    matching: { $0.accessibilityIdentifier() == identifier }
                )
            )
        }
        XCTAssertEqual(sourceOutline.numberOfRows, 8)
        let sourceLabels = (0..<sourceOutline.numberOfRows).compactMap { row in
            sourceOutline.view(atColumn: 0, row: row, makeIfNecessary: true)?
                .accessibilityLabel()
        }
        XCTAssertEqual(
            sourceLabels,
            [
                "All Traffic, 4 flows",
                "Apps, 2 applications",
                "Safari, 1 flow",
                "Unknown App, 3 flows",
                "Domains, 3 domains",
                "api.example.com, 2 flows",
                "auth.example.net, 1 flow",
                "cdn.example.com, 1 flow"
            ]
        )
        XCTAssertEqual(flowTable.numberOfRows, flows.count)
        XCTAssertTrue(requestInspector.string.contains("POST /v1/items/3?source=test HTTP/1.1"))
        XCTAssertTrue(responseInspector.string.contains("HTTP/1.1 404 Result"))

        requestSectionSelector.selectedSegment = 1
        XCTAssertTrue(
            requestSectionSelector.sendAction(
                requestSectionSelector.action,
                to: requestSectionSelector.target
            )
        )
        XCTAssertEqual(requestInspector.string, "source=test")

        if requestSectionSelector.segmentCount > 4 {
            requestSectionSelector.selectedSegment = 4
            XCTAssertTrue(
                requestSectionSelector.sendAction(
                    requestSectionSelector.action,
                    to: requestSectionSelector.target
                )
            )
            XCTAssertTrue(
                requestInspector.string.contains("POST /v1/items/3?source=test HTTP/1.1")
            )
            XCTAssertTrue(requestInspector.string.contains(#"{"query":"proxylens"}"#))
        } else {
            XCTFail("Request inspector is missing its Raw tab")
        }

        if responseSectionSelector.segmentCount > 3 {
            responseSectionSelector.selectedSegment = 3
            XCTAssertTrue(
                responseSectionSelector.sendAction(
                    responseSectionSelector.action,
                    to: responseSectionSelector.target
                )
            )
            XCTAssertTrue(responseInspector.string.contains("HTTP/1.1 404 Result"))
            XCTAssertTrue(responseInspector.string.contains(#"{"error":"not found"}"#))
        } else {
            XCTFail("Response inspector is missing its Raw tab")
        }

        searchField.stringValue = "api.example.com"
        XCTAssertTrue(searchField.sendAction(searchField.action, to: searchField.target))
        XCTAssertEqual(viewModel.snapshot.visibleRows.count, 2)
        XCTAssertEqual(flowTable.numberOfRows, 2)

        clearButton.performClick(nil)
        XCTAssertEqual(viewModel.snapshot.displayFilter, .all)
        XCTAssertEqual(flowTable.numberOfRows, flows.count)

        let representation = try XCTUnwrap(
            controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds)
        )
        controller.view.cacheDisplay(in: controller.view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "ProxyLens stacked traffic workspace"
        attachment.lifetime = .keepAlways
        add(attachment)
        window.orderOut(nil)
        window.contentViewController = nil
    }

    func testInspectorLongURLDoesNotExpandPastWindowBounds() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        var flow = try Self.makeFlow(index: 9, host: "api.example.com", statusCode: 200)
        let query = String(repeating: "parameter=0123456789&", count: 100)
        flow.replaceRequest(
            HTTPRequest(
                method: flow.request.method,
                url: try XCTUnwrap(URL(string: "https://api.example.com/search?\(query)")),
                headers: flow.request.headers
            )
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        let frame = NSRect(x: 0, y: 0, width: 1_200, height: 720)
        let controller = TrafficConsoleViewController(viewModel: viewModel)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(frame.size)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(controller.view.fittingSize.width, frame.width)

        for identifier in [
            "inspector.request.section",
            "inspector.response.section"
        ] {
            let sectionSelector = try XCTUnwrap(
                Self.descendant(
                    of: NSSegmentedControl.self,
                    in: controller.view,
                    matching: { $0.accessibilityIdentifier() == identifier }
                )
            )
            let selectorFrame = sectionSelector.convert(
                sectionSelector.bounds,
                to: controller.view
            )
            XCTAssertLessThanOrEqual(selectorFrame.maxX, controller.view.bounds.maxX)
        }

        let representation = try XCTUnwrap(
            controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds)
        )
        controller.view.cacheDisplay(in: controller.view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "ProxyLens long URL inspector"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testInspectorShowsAppliedRuleTraces() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        var flow = try Self.makeFlow(index: 7, host: "ads.example.com", statusCode: 403)
        flow.appendRuleTrace(
            RuleTrace(
                ruleID: RuleID(),
                phase: .requestHeaders,
                outcome: .applied,
                ruleName: "Block ads.example.com"
            )
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        XCTAssertTrue(viewModel.snapshot.inspection.rules.contains("Block ads.example.com"))
        XCTAssertTrue(viewModel.snapshot.inspection.rules.contains("applied"))

        var filter = TrafficDisplayFilter()
        filter.searchText = "Block ads.example.com"
        XCTAssertTrue(filter.matches(flow))

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(viewModel.snapshot)
        let modeSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.mode" }
            )
        )
        modeSelector.selectedSegment = 1
        modeSelector.sendAction(modeSelector.action, to: modeSelector.target)
        let inspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.rules.content"
                }
            )
        )
        XCTAssertTrue(inspector.string.contains("Block ads.example.com"))
        XCTAssertTrue(inspector.string.contains("requestHeaders"))
    }

    func testInspectorShowsDerivedJSONWithoutReplacingRawBody() async throws {
        let compact = #"{"z":1,"a":2}"#
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 3,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data(compact.utf8),
            responseBody: Data(compact.utf8),
            responseContentType: "application/json"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)
        try await waitUntil {
            guard case .content(_, let json) = viewModel.snapshot.inspection.response?.json,
                case .content(_, let body) = viewModel.snapshot.inspection.response?.body
            else {
                return false
            }
            return json.contains(#""a""#) && body.contains(compact)
        }

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(viewModel.snapshot)
        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.response.section"
                }
            )
        )
        XCTAssertEqual(sectionSelector.segmentCount, 4)
        XCTAssertEqual(sectionSelector.label(forSegment: 2), "JSON")

        sectionSelector.selectedSegment = 1
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        let inspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.response.content"
                }
            )
        )
        XCTAssertTrue(inspector.string.contains(compact))

        sectionSelector.selectedSegment = 2
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        XCTAssertTrue(inspector.string.contains(#""a""#))
        XCTAssertTrue(inspector.string.contains(#""z""#))
        XCTAssertTrue(inspector.string.contains("\n"))
        XCTAssertFalse(inspector.string.contains(compact))
        let keyRange = try XCTUnwrap(inspector.string.range(of: #""a""#))
        let keyColor =
            inspector.textStorage?.attribute(
                .foregroundColor,
                at: NSRange(keyRange, in: inspector.string).location,
                effectiveRange: nil
            ) as? NSColor
        XCTAssertEqual(keyColor, InspectorSyntaxPalette.key)
    }

    func testInspectorHighlightsBodyFromDeclaredContentTypeWithoutColoringMetadata() throws {
        let requestXML = #"<root id="42"/>"#
        let responseForm = "name=ProxyLens&enabled=true"
        let flowID = FlowID()
        let snapshot = TrafficConsoleSnapshot(
            capture: .stopped,
            workspaceWarning: nil,
            certificateTrust: nil,
            allFlowCount: 1,
            applications: [],
            pinnedDomains: [],
            domains: [],
            selectedSource: .allTraffic,
            displayFilter: .all,
            visibleRows: [],
            selectedFlowID: flowID,
            inspection: TrafficFlowInspection(
                flowID: flowID,
                title: "POST https://api.example.com/v1",
                request: TrafficMessageInspection(
                    title: "Request",
                    headers: "POST /v1 HTTP/1.1\nHost: api.example.com",
                    body: .content(metadata: "15 B • application/xml", value: requestXML),
                    json: .none("This body is not JSON."),
                    bodyContentType: "application/xml"
                ),
                response: TrafficMessageInspection(
                    title: "Response",
                    headers: "HTTP/1.1 200 OK",
                    body: .content(
                        metadata: "27 B • application/x-www-form-urlencoded",
                        value: responseForm
                    ),
                    json: .none("This body is not JSON."),
                    bodyContentType: "application/x-www-form-urlencoded"
                ),
                rules: "No rules applied to this flow.",
                breakpoint: nil
            )
        )

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(snapshot)

        for (prefix, token, expectedColor) in [
            ("request", "root", InspectorSyntaxPalette.key),
            ("response", "name", InspectorSyntaxPalette.key),
            ("response", "ProxyLens", InspectorSyntaxPalette.string)
        ] {
            let sectionSelector = try XCTUnwrap(
                Self.descendant(
                    of: NSSegmentedControl.self,
                    in: controller.view,
                    matching: {
                        $0.accessibilityIdentifier() == "inspector.\(prefix).section"
                    }
                )
            )
            let bodySegment = try XCTUnwrap(
                (0..<sectionSelector.segmentCount).first {
                    sectionSelector.label(forSegment: $0) == "Body"
                }
            )
            sectionSelector.selectedSegment = bodySegment
            sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)

            let inspector = try XCTUnwrap(
                Self.descendant(
                    of: NSTextView.self,
                    in: controller.view,
                    matching: {
                        $0.accessibilityIdentifier() == "inspector.\(prefix).content"
                    }
                )
            )
            let tokenRange = try XCTUnwrap(inspector.string.range(of: token))
            let tokenColor =
                inspector.textStorage?.attribute(
                    .foregroundColor,
                    at: NSRange(tokenRange, in: inspector.string).location,
                    effectiveRange: nil
                ) as? NSColor
            XCTAssertEqual(tokenColor, expectedColor)
            XCTAssertEqual(
                inspector.textStorage?.attribute(
                    .foregroundColor,
                    at: 0,
                    effectiveRange: nil
                ) as? NSColor,
                .textColor
            )
        }
    }

    func testInspectorDoesNotCopyJSONTabIntoBodyEditsDuringBreakpoint() throws {
        let compact = #"{"z":1,"a":2}"#
        let pretty = "{\n  \"a\" : 2,\n  \"z\" : 1\n}"
        let flowID = FlowID()
        let snapshot = TrafficConsoleSnapshot(
            capture: .stopped,
            workspaceWarning: nil,
            certificateTrust: nil,
            allFlowCount: 1,
            applications: [],
            pinnedDomains: [],
            domains: [],
            selectedSource: .allTraffic,
            displayFilter: .all,
            visibleRows: [],
            selectedFlowID: flowID,
            inspection: TrafficFlowInspection(
                flowID: flowID,
                title: "POST https://api.example.com/v1",
                request: TrafficMessageInspection(
                    title: "Request",
                    headers: "POST /v1 HTTP/1.1\nHost: api.example.com",
                    body: .content(metadata: "11 B", value: compact),
                    json: .content(metadata: "11 B", value: pretty),
                    bodyContentType: "application/json"
                ),
                response: nil,
                rules: "No rules applied to this flow.",
                breakpoint: TrafficBreakpointInspection(phase: .request, canEditBody: true)
            )
        )

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(snapshot)
        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.section"
                }
            )
        )
        let inspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.content"
                }
            )
        )

        sectionSelector.selectedSegment = 3
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        XCTAssertTrue(inspector.string.contains(pretty))

        sectionSelector.selectedSegment = 2
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        XCTAssertEqual(inspector.string, compact)
        XCTAssertFalse(inspector.string.contains(pretty))
    }

    private static var captureConfiguration: CaptureConfiguration {
        CaptureConfiguration(
            proxy: ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                interceptHTTPS: false
            ),
            configuresSystemProxy: false
        )
    }

    private static func makeFlow(
        index: Int,
        host: String,
        statusCode: Int,
        requestBody: Data? = nil,
        responseBody: Data? = nil,
        method: HTTPMethod? = nil,
        responseContentType: String = "application/octet-stream",
        source: FlowSource = .desktopProxy,
        requestHeaderValue: String? = nil,
        requestContentType: String = "text/plain",
        requestContentEncoding: String? = nil
    ) throws -> Flow {
        var requestHeaders = HTTPHeaders()
        try requestHeaders.append(name: "Host", value: host)
        try requestHeaders.append(name: "Accept", value: "application/json")
        if let requestHeaderValue {
            try requestHeaders.append(name: "X-Debug-Label", value: requestHeaderValue)
        }
        if let requestBody {
            try requestHeaders.append(name: "Content-Type", value: requestContentType)
            try requestHeaders.append(name: "Content-Length", value: "\(requestBody.count)")
            if let requestContentEncoding {
                try requestHeaders.append(name: "Content-Encoding", value: requestContentEncoding)
            }
        }
        var request = HTTPRequest(
            method: method ?? (index.isMultiple(of: 2) ? .get : .post),
            url: try XCTUnwrap(URL(string: "https://\(host)/v1/items/\(index)?source=test")),
            headers: requestHeaders
        )
        if let requestBody {
            request.attachBody(
                BodyReference(
                    inline: requestBody,
                    metadata: BodyMetadata(
                        contentType: requestContentType,
                        contentEncoding: requestContentEncoding
                    )
                )
            )
        }

        var responseHeaders = HTTPHeaders()
        try responseHeaders.append(name: "Content-Type", value: responseContentType)
        var response = try HTTPResponse(
            statusCode: statusCode,
            reasonPhrase: "Result",
            headers: responseHeaders
        )
        if let responseBody {
            response.attachBody(
                BodyReference(
                    inline: responseBody,
                    metadata: BodyMetadata(contentType: responseContentType)
                )
            )
        }

        var flow = Flow(
            sessionID: SessionID(),
            source: source,
            request: request,
            connection: ConnectionInfo(
                protocolKind: .https,
                upstreamHost: host,
                upstreamPort: 443,
                tlsIntercepted: true
            ),
            startedAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
        try flow.transition(to: .receivingRequest)
        try flow.transition(to: .connectingUpstream)
        try flow.transition(to: .receivingResponse)
        flow.attachResponse(response)
        flow.markCompleted(at: Date(timeIntervalSince1970: TimeInterval(index) + 0.25))
        try flow.transition(to: .completed)
        return flow
    }

    private static func descendant<T: NSView>(
        of type: T.Type,
        in root: NSView,
        matching predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        if let match = root as? T, predicate(match) {
            return match
        }
        for subview in root.subviews {
            if let match = descendant(of: type, in: subview, matching: predicate) {
                return match
            }
        }
        return nil
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not satisfied before timeout")
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not satisfied before timeout")
    }
}

@MainActor
private final class RecordingTableView: NSTableView {
    private(set) var fullReloadCount = 0
    private(set) var insertedRowIndexes: [IndexSet] = []
    private(set) var removedRowIndexes: [IndexSet] = []
    private(set) var movedRows: [(from: Int, to: Int)] = []
    private(set) var dataSourceRowCountsDuringRemovals: [Int] = []
    var clickedRowOverride: Int?

    override var clickedRow: Int {
        clickedRowOverride ?? super.clickedRow
    }

    override func reloadData() {
        fullReloadCount += 1
        super.reloadData()
    }

    override func insertRows(
        at indexes: IndexSet,
        withAnimation animationOptions: NSTableView.AnimationOptions
    ) {
        insertedRowIndexes.append(indexes)
        super.insertRows(at: indexes, withAnimation: animationOptions)
    }

    override func removeRows(
        at indexes: IndexSet,
        withAnimation animationOptions: NSTableView.AnimationOptions
    ) {
        if let numberOfRows = dataSource?.numberOfRows {
            dataSourceRowCountsDuringRemovals.append(numberOfRows(self))
        }
        removedRowIndexes.append(indexes)
        super.removeRows(at: indexes, withAnimation: animationOptions)
    }

    override func moveRow(at oldIndex: Int, to newIndex: Int) {
        movedRows.append((from: oldIndex, to: newIndex))
        super.moveRow(at: oldIndex, to: newIndex)
    }

    func resetRecordedUpdates() {
        fullReloadCount = 0
        insertedRowIndexes = []
        removedRowIndexes = []
        movedRows = []
        dataSourceRowCountsDuringRemovals = []
    }
}

private actor RecordingCaptureController: TrafficCaptureControlling {
    private var recordedCalls: [String] = []
    private var stopError: CaptureCoordinatorError?

    init(stopError: CaptureCoordinatorError? = nil) {
        self.stopError = stopError
    }

    func recoverInterruptedCapture() {
        recordedCalls.append("recover")
    }

    func start(configuration: CaptureConfiguration) -> CaptureContext {
        recordedCalls.append("start")
        return CaptureContext(
            sessionID: SessionID(),
            endpoint: NetworkEndpoint(host: "127.0.0.1", port: 59_090),
            startedAt: Date(timeIntervalSince1970: 1_000),
            configuration: configuration
        )
    }

    func stop() throws {
        recordedCalls.append("stop")
        if let stopError {
            self.stopError = nil
            throw stopError
        }
    }

    func calls() -> [String] {
        recordedCalls
    }
}

private actor FinishedEventSource: TrafficFlowEventStreaming {
    func makeEventStream() -> AsyncStream<FlowEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

private actor InlineBodyReader: TrafficBodyReading {
    func read(_ reference: BodyReference) throws -> Data {
        guard case .inline(let data) = reference.storage else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }
}

private actor InlineBodyStore: BodyStore {
    func beginWrite(
        metadata _: BodyMetadata,
        maximumByteCount _: Int64?
    ) throws -> any BodyWriter {
        throw CocoaError(.fileWriteUnknown)
    }

    func read(_ reference: BodyReference) throws -> Data {
        guard case .inline(let data) = reference.storage else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }

    func remove(_: BodyReference) {}
}

private actor RecordingRequestReplayer: TrafficRequestReplaying {
    private let result: Flow
    private var requests: [(request: HTTPRequest, sessionID: SessionID)] = []

    init(result: Flow) {
        self.result = result
    }

    func repeatRequest(_ request: HTTPRequest, sessionID: SessionID) -> Flow {
        requests.append((request, sessionID))
        return result
    }

    func receivedRequests() -> [(request: HTTPRequest, sessionID: SessionID)] {
        requests
    }
}

private actor RecordingSessionService: TrafficSessionLoading {
    private var flows: [Flow]
    private var didClear = false
    private let loadError: (any Error)?
    private let composeSessionID: SessionID
    private var composeSessionRequests = 0

    init(
        flows: [Flow] = [],
        loadError: (any Error)? = nil,
        composeSessionID: SessionID = SessionID()
    ) {
        self.flows = flows
        self.loadError = loadError
        self.composeSessionID = composeSessionID
    }

    func loadWorkspace() throws -> [Flow] {
        if let loadError {
            throw loadError
        }
        return flows
    }

    func clearWorkspace() {
        flows = []
        didClear = true
    }

    func sessionIDForNewFlow() -> SessionID {
        composeSessionRequests += 1
        return composeSessionID
    }

    func cleared() -> Bool {
        didClear
    }

    func composeSessionRequestCount() -> Int {
        composeSessionRequests
    }
}

private actor RecordingCertificateTrust: TrafficCertificateTrusting {
    private var currentState: CertificateTrustState
    private var installError: (any Error)?
    private var recordedCalls: [String] = []
    private var exported: [URL] = []

    init(state: CertificateTrustState) {
        currentState = state
    }

    func state() -> CertificateTrustState {
        recordedCalls.append("state")
        return currentState
    }

    func install() throws {
        recordedCalls.append("install")
        if let installError {
            self.installError = nil
            throw installError
        }
        currentState = .trusted
    }

    func remove() {
        recordedCalls.append("remove")
        if currentState != .notGenerated {
            currentState = .untrusted
        }
    }

    func exportRootCertificate(to url: URL) throws {
        recordedCalls.append("export")
        exported.append(url)
        try Data().write(to: url)
    }

    func failNextInstall(_ error: any Error) {
        installError = error
    }

    func calls() -> [String] {
        recordedCalls
    }

    func exportedURLs() -> [URL] {
        exported
    }
}
