import AppKit
import ProxyLensApplication
import ProxyLensCore
import XCTest

@testable import ProxyLens

/// Scrolling behaviour of the flow table under live traffic: follow the newest flow only
/// while the user is already at the bottom, and never move the view out from under them.
@MainActor
final class FlowTableScrollTests: XCTestCase {
    private let visibleHeight: CGFloat = 200

    func testNewFlowsFollowTheTailWhileScrolledToTheBottom() async throws {
        let harness = try await makeHarness(flowCount: 60)

        harness.tableView.scrollRowToVisible(harness.tableView.numberOfRows - 1)
        harness.layout()
        XCTAssertTrue(harness.isScrolledToBottom, "Precondition: parked at the bottom")

        try harness.ingest(hostCount: 1, startingAt: 900)

        XCTAssertTrue(
            harness.isScrolledToBottom,
            "A new flow must keep the newest row in view while the user is at the bottom"
        )
        XCTAssertEqual(harness.tableView.numberOfRows, 61)
    }

    func testNewFlowsLeaveTheScrollAloneWhenTheUserHasScrolledUp() async throws {
        let harness = try await makeHarness(flowCount: 60)

        harness.scroll(toY: 0)
        XCTAssertFalse(harness.isScrolledToBottom)

        try harness.ingest(hostCount: 1, startingAt: 900)

        XCTAssertEqual(
            harness.scrollOffsetY,
            0,
            accuracy: 1,
            "New traffic must not move a view the user scrolled away from"
        )
    }

    func testASelectedFlowDoesNotDragTheViewBackOnEveryUpdate() async throws {
        let harness = try await makeHarness(flowCount: 60)

        let firstFlowID = try XCTUnwrap(harness.viewModel.snapshot.visibleRows.first?.id)
        harness.viewModel.selectFlow(firstFlowID)
        harness.render()
        harness.scroll(toY: 400)
        let parked = harness.scrollOffsetY

        try harness.ingest(hostCount: 1, startingAt: 900)

        XCTAssertEqual(
            harness.scrollOffsetY,
            parked,
            accuracy: 1,
            "An already-selected flow must not pull the view back when new traffic arrives"
        )
    }

    func testSelectingAFlowStillScrollsItIntoView() async throws {
        let harness = try await makeHarness(flowCount: 60)
        harness.scroll(toY: 0)

        let lastFlowID = try XCTUnwrap(harness.viewModel.snapshot.visibleRows.last?.id)
        harness.viewModel.selectFlow(lastFlowID)
        harness.render()

        XCTAssertGreaterThan(
            harness.scrollOffsetY,
            0,
            "Choosing a flow that is off-screen must still reveal it"
        )
    }

    // MARK: - Harness

    private func makeHarness(flowCount: Int) async throws -> Harness {
        let viewModel = TrafficConsoleViewModel(
            captureController: FlowScrollStubCaptureController(),
            eventSource: FlowScrollEmptyEventSource(),
            bodyReader: FlowScrollInlineBodyReader(),
            captureConfiguration: CaptureConfiguration(
                proxy: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                    interceptHTTPS: true
                ),
                configuresSystemProxy: false
            ),
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let tableView = NSTableView()
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        controller.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: visibleHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = controller.view

        let harness = Harness(
            viewModel: viewModel,
            controller: controller,
            tableView: tableView,
            window: window
        )
        try harness.ingest(hostCount: flowCount)
        return harness
    }

    @MainActor
    final class Harness {
        let viewModel: TrafficConsoleViewModel
        let controller: FlowTableViewController
        let tableView: NSTableView
        let window: NSWindow

        init(
            viewModel: TrafficConsoleViewModel,
            controller: FlowTableViewController,
            tableView: NSTableView,
            window: NSWindow
        ) {
            self.viewModel = viewModel
            self.controller = controller
            self.tableView = tableView
            self.window = window
        }

        var scrollView: NSScrollView? { tableView.enclosingScrollView }

        var scrollOffsetY: CGFloat { scrollView?.contentView.bounds.origin.y ?? 0 }

        var isScrolledToBottom: Bool {
            guard let scrollView else {
                return false
            }
            let visible = scrollView.contentView.documentVisibleRect
            let contentHeight = tableView.bounds.height
            guard contentHeight > visible.height else {
                return true
            }
            return visible.maxY >= contentHeight - 2
        }

        func layout() {
            controller.view.layoutSubtreeIfNeeded()
        }

        func render() {
            controller.render(viewModel.snapshot)
            layout()
        }

        func scroll(toY offset: CGFloat) {
            guard let scrollView else {
                return
            }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            layout()
        }

        func ingest(hostCount: Int, startingAt offset: Int = 0) throws {
            for index in 0..<hostCount {
                viewModel.receive(
                    .finished(try Harness.makeFlow(host: "host\(offset + index).example.com"))
                )
            }
            viewModel.flushPendingEvents()
            render()
        }

        static func makeFlow(host: String) throws -> Flow {
            var headers = HTTPHeaders()
            try headers.append(name: "Host", value: host)
            var flow = Flow(
                sessionID: SessionID(),
                source: .desktopProxy,
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
    }
}

private actor FlowScrollStubCaptureController: TrafficCaptureControlling {
    func recoverInterruptedCapture() {}

    func start(configuration: CaptureConfiguration) -> CaptureContext {
        CaptureContext(
            sessionID: SessionID(),
            endpoint: configuration.proxy.listenEndpoint,
            startedAt: Date(),
            configuration: configuration
        )
    }

    func stop() {}
}

private actor FlowScrollEmptyEventSource: TrafficFlowEventStreaming {
    func makeEventStream() -> AsyncStream<FlowEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor FlowScrollInlineBodyReader: TrafficBodyReading {
    func read(_: BodyReference) throws -> Data { Data() }
}
