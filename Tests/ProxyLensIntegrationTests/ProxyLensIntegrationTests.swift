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
            Self.descendant(of: NSTextView.self, in: controller.view)
        )
        XCTAssertEqual(sourceOutline.numberOfRows, 5)
        XCTAssertEqual(flowTable.numberOfRows, flows.count)
        XCTAssertTrue(inspector.string.contains("POST /v1/items/3?source=test HTTP/1.1"))

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
        responseBody: Data? = nil
    ) throws -> Flow {
        var requestHeaders = HTTPHeaders()
        try requestHeaders.append(name: "Host", value: host)
        try requestHeaders.append(name: "Accept", value: "application/json")
        var request = HTTPRequest(
            method: index.isMultiple(of: 2) ? .get : .post,
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
        try responseHeaders.append(name: "Content-Type", value: "application/octet-stream")
        var response = try HTTPResponse(
            statusCode: statusCode,
            reasonPhrase: "Result",
            headers: responseHeaders
        )
        if let responseBody {
            response.attachBody(
                BodyReference(
                    inline: responseBody,
                    metadata: BodyMetadata(contentType: "application/octet-stream")
                )
            )
        }

        var flow = Flow(
            sessionID: SessionID(),
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
