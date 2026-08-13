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

    func testTrafficConsoleRendersPopulatedThreePaneWorkspace() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flows = try [
            Self.makeFlow(index: 1, host: "api.example.com", statusCode: 201),
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
        let inspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.content" }
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
        XCTAssertEqual(sourceOutline.numberOfRows, 5)
        XCTAssertEqual(flowTable.numberOfRows, flows.count)
        XCTAssertTrue(inspector.string.contains("POST /v1/items/3?source=test HTTP/1.1"))

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
        attachment.name = "ProxyLens populated traffic console"
        attachment.lifetime = .keepAlways
        add(attachment)
        window.orderOut(nil)
        window.contentViewController = nil
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
        let messageSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.message" }
            )
        )
        messageSelector.selectedSegment = 2
        messageSelector.sendAction(messageSelector.action, to: messageSelector.target)
        let inspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.content" }
            )
        )
        XCTAssertTrue(inspector.string.contains("Block ads.example.com"))
        XCTAssertTrue(inspector.string.contains("requestHeaders"))
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
        requestHeaderValue: String? = nil
    ) throws -> Flow {
        var requestHeaders = HTTPHeaders()
        try requestHeaders.append(name: "Host", value: host)
        try requestHeaders.append(name: "Accept", value: "application/json")
        if let requestHeaderValue {
            try requestHeaders.append(name: "X-Debug-Label", value: requestHeaderValue)
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
                    metadata: BodyMetadata(contentType: "text/plain")
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

private actor RecordingSessionService: TrafficSessionLoading {
    private var flows: [Flow]
    private var didClear = false
    private let loadError: (any Error)?

    init(flows: [Flow] = [], loadError: (any Error)? = nil) {
        self.flows = flows
        self.loadError = loadError
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

    func cleared() -> Bool {
        didClear
    }
}
