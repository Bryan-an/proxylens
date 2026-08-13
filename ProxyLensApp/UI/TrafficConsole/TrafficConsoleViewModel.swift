import Combine
import Foundation
import ProxyLensApplication
import ProxyLensCore

protocol TrafficCaptureControlling: Sendable {
    func recoverInterruptedCapture() async throws
    func start(configuration: CaptureConfiguration) async throws -> CaptureContext
    func stop() async throws
}

extension CaptureCoordinator: TrafficCaptureControlling {}

protocol TrafficFlowEventStreaming: Sendable {
    func makeEventStream() async -> AsyncStream<FlowEvent>
}

extension FlowEventBus: TrafficFlowEventStreaming {
    func makeEventStream() async -> AsyncStream<FlowEvent> {
        events()
    }
}

protocol TrafficBodyReading: Sendable {
    func read(_ reference: BodyReference) async throws -> Data
}

extension FlowBodyReader: TrafficBodyReading {}

@MainActor
final class TrafficConsoleViewModel: ObservableObject {
    @Published private(set) var snapshot = TrafficConsoleSnapshot.initial

    private let captureController: any TrafficCaptureControlling
    private let eventSource: any TrafficFlowEventStreaming
    private let bodyReader: any TrafficBodyReading
    private let captureConfiguration: CaptureConfiguration
    private let eventBatchDelay: Duration
    private let ruleEngine: RuleEngine?

    private var store = TrafficConsoleStore()
    private var capturePresentation: TrafficCapturePresentation = .recovering
    private var inspection = TrafficFlowInspection.empty
    private var pendingEvents: [FlowEvent] = []
    private var isPrepared = false
    private var eventTask: Task<Void, Never>?
    private var eventBatchTask: Task<Void, Never>?
    private var bodyTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?

    init(
        captureController: any TrafficCaptureControlling,
        eventSource: any TrafficFlowEventStreaming,
        bodyReader: any TrafficBodyReading,
        captureConfiguration: CaptureConfiguration,
        eventBatchDelay: Duration = .milliseconds(40),
        ruleEngine: RuleEngine? = nil
    ) {
        self.captureController = captureController
        self.eventSource = eventSource
        self.bodyReader = bodyReader
        self.captureConfiguration = captureConfiguration
        self.eventBatchDelay = eventBatchDelay
        self.ruleEngine = ruleEngine
    }

    deinit {
        eventTask?.cancel()
        eventBatchTask?.cancel()
        bodyTask?.cancel()
        captureTask?.cancel()
    }

    func prepare() async {
        guard !isPrepared else {
            return
        }
        isPrepared = true
        capturePresentation = .recovering
        publishSnapshot()

        do {
            try await captureController.recoverInterruptedCapture()
            capturePresentation = .stopped
        } catch {
            capturePresentation = .failed(error.localizedDescription)
        }
        publishSnapshot()
        subscribeToFlowEvents()
    }

    func toggleCapture() {
        guard captureTask == nil else {
            return
        }
        switch capturePresentation {
        case .stopped, .failed:
            captureTask = Task { [weak self] in
                await self?.startCapture()
            }
        case .running:
            captureTask = Task { [weak self] in
                await self?.stopCapture()
            }
        case .recovering, .starting, .stopping:
            break
        }
    }

    func selectSource(_ source: TrafficSourceSelection) {
        store.selectSource(source)
        if store.selectedFlowID == nil {
            bodyTask?.cancel()
            inspection = .empty
        }
        publishSnapshot()
    }

    func setSearchText(_ searchText: String) {
        updateDisplayFilter { $0.searchText = searchText }
    }

    func setMethodFilter(_ method: TrafficMethodFilter) {
        updateDisplayFilter { $0.method = method }
    }

    func setStatusFilter(_ status: TrafficStatusFilter) {
        updateDisplayFilter { $0.status = status }
    }

    func setContentTypeFilter(_ contentType: TrafficContentTypeFilter) {
        updateDisplayFilter { $0.contentType = contentType }
    }

    func setOriginFilter(_ origin: TrafficOriginFilter) {
        updateDisplayFilter { $0.origin = origin }
    }

    func clearDisplayFilters() {
        store.clearFilters()
        publishSnapshot()
    }

    func selectFlow(_ flowID: FlowID?) {
        store.selectFlow(flowID)
        refreshInspection()
    }

    func sortRows(by key: TrafficConsoleSortKey, ascending: Bool) {
        store.setSort(TrafficConsoleSort(key: key, ascending: ascending))
        publishSnapshot()
    }

    func clearSort() {
        store.setSort(nil)
        publishSnapshot()
    }

    func blockHost(_ host: String) {
        Task { await ruleEngine?.blockHost(host) }
    }

    func allowHost(_ host: String) {
        Task { await ruleEngine?.allowHost(host) }
    }

    func disableCaching(forHost host: String) {
        Task { await ruleEngine?.disableCaching(forHost: host) }
    }

    func mapLocal(host: String, path: String, fileURL: URL) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.mapLocal(host: host, path: path, fileURL: fileURL)
    }

    private func updateDisplayFilter(_ update: (inout TrafficDisplayFilter) -> Void) {
        var filter = store.displayFilter
        update(&filter)
        store.setDisplayFilter(filter)
        if store.selectedFlowID == nil {
            bodyTask?.cancel()
            inspection = .empty
        }
        publishSnapshot()
    }

    func receive(_ event: FlowEvent) {
        pendingEvents.append(event)
        guard eventBatchTask == nil else {
            return
        }
        eventBatchTask = Task { [weak self, eventBatchDelay] in
            do {
                try await Task.sleep(for: eventBatchDelay)
            } catch {
                return
            }
            self?.flushPendingEvents()
        }
    }

    func flushPendingEvents() {
        eventBatchTask?.cancel()
        eventBatchTask = nil
        guard !pendingEvents.isEmpty else {
            return
        }

        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        let selectedFlowBeforeUpdate = store.selectedFlow
        store.apply(events)

        if store.selectedFlow != selectedFlowBeforeUpdate {
            refreshInspection()
        } else {
            publishSnapshot()
        }
    }

    private func subscribeToFlowEvents() {
        guard eventTask == nil else {
            return
        }
        let eventSource = eventSource
        eventTask = Task { [weak self] in
            let stream = await eventSource.makeEventStream()
            for await event in stream {
                guard !Task.isCancelled else {
                    return
                }
                self?.receive(event)
            }
        }
    }

    private func startCapture() async {
        capturePresentation = .starting
        publishSnapshot()
        do {
            let context = try await captureController.start(configuration: captureConfiguration)
            capturePresentation = .running(context, warning: nil)
        } catch {
            capturePresentation = .failed(error.localizedDescription)
        }
        captureTask = nil
        publishSnapshot()
    }

    private func stopCapture() async {
        guard case .running(let context, _) = capturePresentation else {
            captureTask = nil
            return
        }
        capturePresentation = .stopping
        publishSnapshot()
        do {
            try await captureController.stop()
            capturePresentation = .stopped
        } catch {
            if let coordinatorError = error as? CaptureCoordinatorError,
                case .stopFailed(stage: .systemProxyRestoration, message: _) = coordinatorError
            {
                capturePresentation = .running(
                    context,
                    warning: coordinatorError.localizedDescription
                )
            } else {
                capturePresentation = .failed(error.localizedDescription)
            }
        }
        captureTask = nil
        publishSnapshot()
    }

    private func refreshInspection() {
        bodyTask?.cancel()
        guard let flow = store.selectedFlow else {
            inspection = .empty
            publishSnapshot()
            return
        }

        inspection = Self.initialInspection(for: flow)
        publishSnapshot()

        let bodyReader = bodyReader
        bodyTask = Task { [weak self] in
            async let requestBody = Self.loadBody(flow.request.body, reader: bodyReader)
            async let responseBody = Self.loadBody(flow.response?.body, reader: bodyReader)
            let loadedRequestBody = await requestBody
            let loadedResponseBody = await responseBody
            guard !Task.isCancelled, self?.store.selectedFlowID == flow.id else {
                return
            }
            self?.applyLoadedBodies(
                request: loadedRequestBody,
                response: loadedResponseBody,
                to: flow.id
            )
        }
    }

    private func applyLoadedBodies(
        request: TrafficBodyPresentation,
        response: TrafficBodyPresentation,
        to flowID: FlowID
    ) {
        guard inspection.flowID == flowID else {
            return
        }
        inspection = TrafficFlowInspection(
            flowID: inspection.flowID,
            title: inspection.title,
            request: inspection.request.map {
                TrafficMessageInspection(title: $0.title, headers: $0.headers, body: request)
            },
            response: inspection.response.map {
                TrafficMessageInspection(title: $0.title, headers: $0.headers, body: response)
            },
            rules: inspection.rules
        )
        publishSnapshot()
    }

    private func publishSnapshot() {
        snapshot = store.snapshot(capture: capturePresentation, inspection: inspection)
    }

    private static func initialInspection(for flow: Flow) -> TrafficFlowInspection {
        TrafficFlowInspection(
            flowID: flow.id,
            title: "\(flow.request.method.rawValue) \(flow.request.url.absoluteString)",
            request: TrafficMessageInspection(
                title: "Request",
                headers: requestHeadersText(flow.request),
                body: initialBody(flow.request.body, emptyMessage: "This request has no body.")
            ),
            response: flow.response.map {
                TrafficMessageInspection(
                    title: "Response",
                    headers: responseHeadersText($0),
                    body: initialBody($0.body, emptyMessage: "This response has no body.")
                )
            },
            rules: rulesText(flow.ruleTraces)
        )
    }

    private static func requestHeadersText(_ request: HTTPRequest) -> String {
        let target = request.rawTarget ?? request.url.pathAndQuery
        return messageText(
            firstLine: "\(request.method.rawValue) \(target) \(request.version.rawValue)",
            headers: request.headers
        )
    }

    private static func responseHeadersText(_ response: HTTPResponse) -> String {
        let reason = response.reasonPhrase.map { " \($0)" } ?? ""
        return messageText(
            firstLine: "\(response.version.rawValue) \(response.statusCode)\(reason)",
            headers: response.headers
        )
    }

    private static func messageText(firstLine: String, headers: HTTPHeaders) -> String {
        let fields = headers.map { "\($0.name): \($0.value)" }
        return ([firstLine] + fields).joined(separator: "\n")
    }

    private static func rulesText(_ traces: [RuleTrace]) -> String {
        guard !traces.isEmpty else {
            return "No rules applied to this flow."
        }

        return traces.map { trace in
            let name: String
            if let ruleName = trace.ruleName, !ruleName.isEmpty {
                name = ruleName
            } else {
                name = trace.ruleID.description
            }
            let result: String
            switch trace.outcome {
            case .matched:
                result = "matched"
            case .applied:
                result = "applied"
            case .skipped(let reason):
                result = "skipped (\(reason))"
            case .failed(let message):
                result = "failed (\(message))"
            }
            return "\(name)\nphase: \(trace.phase.rawValue)\noutcome: \(result)"
        }.joined(separator: "\n\n")
    }

    private static func initialBody(
        _ reference: BodyReference?,
        emptyMessage: String
    ) -> TrafficBodyPresentation {
        guard let reference else {
            return .none(emptyMessage)
        }
        return .loading(BodyDisplayFormatter.metadata(for: reference))
    }

    private static func loadBody(
        _ reference: BodyReference?,
        reader: any TrafficBodyReading
    ) async -> TrafficBodyPresentation {
        guard let reference else {
            return .none("No body was captured.")
        }
        let metadata = BodyDisplayFormatter.metadata(for: reference)
        do {
            let data = try await reader.read(reference)
            return await Task.detached(priority: .utility) {
                .content(
                    metadata: metadata,
                    value: BodyDisplayFormatter.render(data, reference: reference)
                )
            }.value
        } catch {
            return .failed(metadata: metadata, message: error.localizedDescription)
        }
    }
}

private enum BodyDisplayFormatter {
    private static let textDisplayLimit = 1_048_576
    private static let binaryDisplayLimit = 65_536
    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func metadata(for reference: BodyReference) -> String {
        var components = [formattedByteCount(reference.byteCount)]
        if let contentType = reference.contentType, !contentType.isEmpty {
            components.append(contentType)
        }
        if let contentEncoding = reference.contentEncoding, !contentEncoding.isEmpty {
            components.append("Content-Encoding: \(contentEncoding)")
        }
        if reference.isTruncated {
            components.append("Capture truncated")
        }
        return components.joined(separator: " • ")
    }

    static func render(_ data: Data, reference: BodyReference) -> String {
        if isText(data, contentEncoding: reference.contentEncoding) {
            let shown = data.prefix(textDisplayLimit)
            var result = String(decoding: shown, as: UTF8.self)
            if data.count > shown.count {
                result +=
                    "\n\n[Displaying the first \(formattedByteCount(Int64(shown.count))) of \(formattedByteCount(Int64(data.count))).]"
            }
            return result
        }

        let shown = data.prefix(binaryDisplayLimit)
        var result = hexDump(shown)
        if data.count > shown.count {
            result +=
                "\n\n[Displaying the first \(formattedByteCount(Int64(shown.count))) of \(formattedByteCount(Int64(data.count))).]"
        }
        return result
    }

    private static func isText(_ data: Data, contentEncoding: String?) -> Bool {
        if let contentEncoding,
            !contentEncoding.isEmpty,
            contentEncoding.caseInsensitiveCompare("identity") != .orderedSame
        {
            return false
        }
        let sample = data.prefix(min(data.count, 8_192))
        guard String(data: sample, encoding: .utf8) != nil else {
            return false
        }
        return !sample.contains { byte in
            byte == 0 || (byte < 9) || (byte > 13 && byte < 32)
        }
    }

    private static func hexDump(_ data: Data.SubSequence) -> String {
        guard !data.isEmpty else {
            return "[Empty body]"
        }
        let bytes = Array(data)
        var output = [UInt8]()
        output.reserveCapacity(((bytes.count + 15) / 16) * 76)

        for lineStart in stride(from: 0, to: bytes.count, by: 16) {
            appendHex(UInt64(lineStart), width: 8, to: &output)
            output.append(contentsOf: [32, 32])
            let lineEnd = min(lineStart + 16, bytes.count)
            for index in lineStart..<(lineStart + 16) {
                if index < lineEnd {
                    let byte = bytes[index]
                    output.append(hexDigits[Int(byte >> 4)])
                    output.append(hexDigits[Int(byte & 0x0F)])
                } else {
                    output.append(contentsOf: [32, 32])
                }
                output.append(index == lineStart + 7 ? 32 : 32)
            }
            output.append(32)
            output.append(124)
            for index in lineStart..<lineEnd {
                let byte = bytes[index]
                output.append((32...126).contains(byte) ? byte : 46)
            }
            if lineEnd - lineStart < 16 {
                output.append(contentsOf: repeatElement(32, count: 16 - (lineEnd - lineStart)))
            }
            output.append(124)
            if lineEnd < bytes.count {
                output.append(10)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func appendHex(_ value: UInt64, width: Int, to output: inout [UInt8]) {
        for offset in (0..<width).reversed() {
            let nibble = Int((value >> UInt64(offset * 4)) & 0x0F)
            output.append(hexDigits[nibble])
        }
    }

    private static func formattedByteCount(_ count: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(count)
        var unitIndex = 0
        while value >= 1_000, unitIndex < units.count - 1 {
            value /= 1_000
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(count) B"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

extension URL {
    fileprivate var pathAndQuery: String {
        var result = path.isEmpty ? "/" : path
        if let query, !query.isEmpty {
            result += "?\(query)"
        }
        return result
    }
}
