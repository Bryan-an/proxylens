import AppKit
import ProxyLensApplication
import ProxyLensCore
import XCTest

@testable import ProxyLens

/// The source list re-renders on every snapshot, which is every batch of flow events while
/// capture is running. What the user did to it — scrolled, collapsed a group — has to
/// survive that.
@MainActor
final class SourceListStateTests: XCTestCase {
    func testACollapsedGroupStaysCollapsedAcrossRenders() async throws {
        let viewModel = makeViewModel()
        await viewModel.prepare()
        let controller = SourceListViewController(viewModel: viewModel)
        controller.loadView()
        try ingest(hostCount: 12, into: viewModel)
        controller.render(viewModel.snapshot)

        let outline = try XCTUnwrap(
            descendant(in: controller.view, identifier: "traffic.sources") as? NSOutlineView
        )
        let domains = try XCTUnwrap(Self.item(in: outline, titled: "Domains"))
        XCTAssertTrue(outline.isItemExpanded(domains))
        let expandedRowCount = outline.numberOfRows

        outline.collapseItem(domains)
        XCTAssertLessThan(outline.numberOfRows, expandedRowCount)
        let collapsedRowCount = outline.numberOfRows

        // A new flow arrives, so the console publishes another snapshot.
        try ingest(hostCount: 1, startingAt: 100, into: viewModel)
        controller.render(viewModel.snapshot)

        let domainsAfter = try XCTUnwrap(Self.item(in: outline, titled: "Domains"))
        XCTAssertFalse(
            outline.isItemExpanded(domainsAfter),
            "A group the user collapsed must not re-expand when new traffic arrives"
        )
        XCTAssertEqual(outline.numberOfRows, collapsedRowCount)
    }

    func testScrollPositionSurvivesARender() async throws {
        let viewModel = makeViewModel()
        await viewModel.prepare()
        let controller = SourceListViewController(viewModel: viewModel)
        let scrollView = try XCTUnwrap(controller.view as? NSScrollView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = scrollView
        try ingest(hostCount: 40, into: viewModel)
        controller.render(viewModel.snapshot)
        scrollView.layoutSubtreeIfNeeded()

        let target = NSPoint(x: 0, y: 240)
        scrollView.contentView.scroll(to: target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, target.y, accuracy: 1)

        try ingest(hostCount: 1, startingAt: 100, into: viewModel)
        controller.render(viewModel.snapshot)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            target.y,
            accuracy: 1,
            "New traffic must not scroll the source list back to the top"
        )
    }

    // MARK: - Helpers

    private func makeViewModel() -> TrafficConsoleViewModel {
        TrafficConsoleViewModel(
            captureController: SourceListStubCaptureController(),
            eventSource: SourceListEmptyEventSource(),
            bodyReader: SourceListInlineBodyReader(),
            captureConfiguration: CaptureConfiguration(
                proxy: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                    interceptHTTPS: true
                ),
                configuresSystemProxy: false
            ),
            eventBatchDelay: .seconds(60)
        )
    }

    private func ingest(
        hostCount: Int,
        startingAt offset: Int = 0,
        into viewModel: TrafficConsoleViewModel
    ) throws {
        for index in 0..<hostCount {
            viewModel.receive(
                .finished(try Self.makeFlow(host: "host\(offset + index).example.com"))
            )
        }
        viewModel.flushPendingEvents()
    }

    private static func item(in outline: NSOutlineView, titled title: String) -> Any? {
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else {
                continue
            }
            if labels(in: cell).contains(title) {
                return outline.item(atRow: row)
            }
        }
        return nil
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

    private static func makeFlow(host: String) throws -> Flow {
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

private actor SourceListStubCaptureController: TrafficCaptureControlling {
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

private actor SourceListEmptyEventSource: TrafficFlowEventStreaming {
    func makeEventStream() -> AsyncStream<FlowEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor SourceListInlineBodyReader: TrafficBodyReading {
    func read(_: BodyReference) throws -> Data { Data() }
}
