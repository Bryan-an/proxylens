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

protocol TrafficRequestReplaying: Sendable {
    func repeatRequest(_ flow: Flow) async throws -> Flow
}

extension ReplayService: TrafficRequestReplaying {}

protocol TrafficSessionLoading: Sendable {
    func loadWorkspace() async throws -> [Flow]
    func clearWorkspace() async throws
}

extension SessionService: TrafficSessionLoading {}

protocol TrafficCertificateTrusting: Sendable {
    func state() async throws -> CertificateTrustState
    func install() async throws
    func remove() async throws
    func exportRootCertificate(to url: URL) async throws
}

extension CertificateTrustService: TrafficCertificateTrusting {}

@MainActor
final class TrafficConsoleViewModel: ObservableObject {
    @Published private(set) var snapshot = TrafficConsoleSnapshot.initial

    private let captureController: any TrafficCaptureControlling
    private let eventSource: any TrafficFlowEventStreaming
    private let bodyReader: any TrafficBodyReading
    private let captureConfiguration: CaptureConfiguration
    private let eventBatchDelay: Duration
    private let ruleEngine: RuleEngine?
    private let breakpointCoordinator: BreakpointCoordinator?
    private let exportService: ExportService?
    private let requestReplayer: (any TrafficRequestReplaying)?
    private let sessionService: (any TrafficSessionLoading)?
    private let certificateTrust: (any TrafficCertificateTrusting)?

    private var store = TrafficConsoleStore()
    private var capturePresentation: TrafficCapturePresentation = .recovering
    private var inspection = TrafficFlowInspection.empty
    private var pendingEvents: [FlowEvent] = []
    private var isPrepared = false
    private var isClearingSession = false
    private var workspaceWarning: String?
    private var certificateTrustState: CertificateTrustState?
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
        ruleEngine: RuleEngine? = nil,
        breakpointCoordinator: BreakpointCoordinator? = nil,
        exportService: ExportService? = nil,
        requestReplayer: (any TrafficRequestReplaying)? = nil,
        sessionService: (any TrafficSessionLoading)? = nil,
        certificateTrust: (any TrafficCertificateTrusting)? = nil
    ) {
        self.captureController = captureController
        self.eventSource = eventSource
        self.bodyReader = bodyReader
        self.captureConfiguration = captureConfiguration
        self.eventBatchDelay = eventBatchDelay
        self.ruleEngine = ruleEngine
        self.breakpointCoordinator = breakpointCoordinator
        self.exportService = exportService
        self.requestReplayer = requestReplayer
        self.sessionService = sessionService
        self.certificateTrust = certificateTrust
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
        await hydrateWorkspace()
        await refreshCertificateTrust()
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

    func mapRemote(host: String, path: String, destination: URL) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.mapRemote(host: host, path: path, destination: destination)
    }

    func breakpoint(host: String, path: String, phase: RulePhase) {
        Task { await ruleEngine?.breakpoint(host: host, path: path, phase: phase) }
    }

    func curlCommand(for flowID: FlowID) async throws -> String {
        guard let exportService else {
            throw ProxyLensError.unsupportedOperation("Export is not available")
        }
        guard let flow = store.flow(id: flowID) else {
            throw ProxyLensError.unsupportedOperation("The flow is no longer available")
        }
        return try await exportService.curl(for: flow)
    }

    func harFile(for flowID: FlowID) async throws -> Data {
        guard let exportService else {
            throw ProxyLensError.unsupportedOperation("Export is not available")
        }
        guard let flow = store.flow(id: flowID) else {
            throw ProxyLensError.unsupportedOperation("The flow is no longer available")
        }
        return try await exportService.har(for: flow)
    }

    @discardableResult
    func repeatRequest(flowID: FlowID) async throws -> FlowID {
        guard let requestReplayer else {
            throw ProxyLensError.unsupportedOperation("Repeat Request is not available")
        }
        guard let flow = store.flow(id: flowID) else {
            throw ProxyLensError.unsupportedOperation("The flow is no longer available")
        }

        let replayedFlow = try await requestReplayer.repeatRequest(flow)
        store.apply([.finished(replayedFlow)])
        store.selectFlow(replayedFlow.id)
        if store.selectedFlowID == nil {
            store.clearFilters()
            store.selectFlow(replayedFlow.id)
        }
        refreshInspection()
        return replayedFlow.id
    }

    func clearSession() async throws {
        switch capturePresentation {
        case .recovering, .starting, .stopping:
            throw ProxyLensError.unsupportedOperation(
                "Wait until capture has finished starting or stopping before clearing the session"
            )
        case .running:
            await stopCapture()
            guard case .stopped = capturePresentation else {
                throw ProxyLensError.unsupportedOperation(
                    "Capture must be stopped before the session can be cleared"
                )
            }
        case .stopped, .failed:
            break
        }

        isClearingSession = true
        defer { isClearingSession = false }
        discardPendingFlowEvents()
        try await sessionService?.clearWorkspace()
        discardPendingFlowEvents()
        store.replaceAll([])
        bodyTask?.cancel()
        inspection = .empty
        workspaceWarning = nil
        publishSnapshot()
    }

    func continueBreakpoint(headersText: String, bodyText: String?) async throws {
        guard let flow = store.selectedFlow,
            let coordinator = breakpointCoordinator,
            let hit = await coordinator.hit(for: flow.id)
        else {
            return
        }

        switch hit.phase {
        case .request:
            let request = try HTTPMessageText.parseRequest(
                headersText: headersText,
                body: bodyText.map { Data($0.utf8) },
                original: hit.request
            )
            await coordinator.resume(
                flowID: hit.flowID,
                decision: .continue(
                    BreakpointHit(
                        flowID: hit.flowID,
                        phase: .request,
                        request: request
                    )
                )
            )
        case .response:
            guard let original = hit.response else {
                throw ProxyLensError.unsupportedOperation("The paused response is unavailable")
            }
            let response = try HTTPMessageText.parseResponse(
                headersText: headersText,
                body: bodyText.map { Data($0.utf8) },
                original: original
            )
            await coordinator.resume(
                flowID: hit.flowID,
                decision: .continue(
                    BreakpointHit(
                        flowID: hit.flowID,
                        phase: .response,
                        request: hit.request,
                        response: response
                    )
                )
            )
        }
    }

    func abortBreakpoint() {
        guard let flowID = store.selectedFlowID else {
            return
        }
        Task { await breakpointCoordinator?.abort(flowID: flowID) }
    }

    func installCertificateTrust() async throws {
        do {
            try await certificateTrust?.install()
        } catch {
            if Self.isCertificateTrustCancellation(error) {
                await refreshCertificateTrust()
                return
            }
            await refreshCertificateTrust()
            throw error
        }
        await refreshCertificateTrust()
    }

    func removeCertificateTrust() async throws {
        do {
            try await certificateTrust?.remove()
        } catch {
            if Self.isCertificateTrustCancellation(error) {
                await refreshCertificateTrust()
                return
            }
            await refreshCertificateTrust()
            throw error
        }
        await refreshCertificateTrust()
    }

    func exportRootCertificate(to url: URL) async throws {
        try await certificateTrust?.exportRootCertificate(to: url)
        await refreshCertificateTrust()
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
        guard !isClearingSession else {
            return
        }
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
            guard !Task.isCancelled else {
                return
            }
            self?.flushPendingEvents()
        }
    }

    func flushPendingEvents() {
        eventBatchTask?.cancel()
        eventBatchTask = nil
        guard !isClearingSession else {
            pendingEvents.removeAll(keepingCapacity: true)
            return
        }
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

    private func hydrateWorkspace() async {
        guard let sessionService else {
            return
        }

        do {
            let flows = try await sessionService.loadWorkspace()
            store.replaceAll(flows)
            workspaceWarning = nil
        } catch {
            workspaceWarning =
                "Could not restore the previous session: \(error.localizedDescription)"
        }
    }

    private func refreshCertificateTrust() async {
        guard let certificateTrust else {
            certificateTrustState = nil
            return
        }

        do {
            certificateTrustState = try await certificateTrust.state()
        } catch {
            if Self.isCertificateTrustCancellation(error) {
                return
            }
            certificateTrustState = nil
        }
        publishSnapshot()
    }

    private static func isCertificateTrustCancellation(_ error: Error) -> Bool {
        if let trustError = error as? CertificateTrustError, trustError == .userCancelled {
            return true
        }
        return error.localizedDescription == CertificateTrustError.cancelledDescription
    }

    private func discardPendingFlowEvents() {
        eventBatchTask?.cancel()
        eventBatchTask = nil
        pendingEvents.removeAll(keepingCapacity: true)
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
        await breakpointCoordinator?.abortAll()
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
            async let requestBodies = Self.loadBodies(flow.request.body, reader: bodyReader)
            async let responseBodies = Self.loadBodies(flow.response?.body, reader: bodyReader)
            let loadedRequestBodies = await requestBodies
            let loadedResponseBodies = await responseBodies
            guard !Task.isCancelled, self?.store.selectedFlowID == flow.id else {
                return
            }
            self?.applyLoadedBodies(
                request: loadedRequestBodies,
                response: loadedResponseBodies,
                to: flow.id
            )
        }
    }

    private func applyLoadedBodies(
        request: (body: TrafficBodyPresentation, json: TrafficBodyPresentation),
        response: (body: TrafficBodyPresentation, json: TrafficBodyPresentation),
        to flowID: FlowID
    ) {
        guard inspection.flowID == flowID else {
            return
        }
        inspection = TrafficFlowInspection(
            flowID: inspection.flowID,
            title: inspection.title,
            request: inspection.request.map {
                TrafficMessageInspection(
                    title: $0.title,
                    headers: $0.headers,
                    body: request.body,
                    json: request.json,
                    bodyContentType: $0.bodyContentType
                )
            },
            response: inspection.response.map {
                TrafficMessageInspection(
                    title: $0.title,
                    headers: $0.headers,
                    body: response.body,
                    json: response.json,
                    bodyContentType: $0.bodyContentType
                )
            },
            rules: inspection.rules,
            breakpoint: inspection.breakpoint.map { breakpoint in
                let body = breakpoint.phase == .response ? response.body : request.body
                return TrafficBreakpointInspection(
                    phase: breakpoint.phase,
                    canEditBody: Self.bodyIsEditable(body)
                )
            }
        )
        publishSnapshot()
    }

    private func publishSnapshot() {
        snapshot = store.snapshot(
            capture: capturePresentation,
            inspection: inspection,
            workspaceWarning: workspaceWarning,
            certificateTrust: certificateTrustState
        )
    }

    private static func initialInspection(for flow: Flow) -> TrafficFlowInspection {
        TrafficFlowInspection(
            flowID: flow.id,
            title: "\(flow.request.method.rawValue) \(flow.request.url.absoluteString)",
            request: TrafficMessageInspection(
                title: "Request",
                headers: requestHeadersText(flow.request),
                body: initialBody(flow.request.body, emptyMessage: "This request has no body."),
                json: initialJSON(flow.request.body),
                bodyContentType: flow.request.body?.contentType
            ),
            response: flow.response.map {
                TrafficMessageInspection(
                    title: "Response",
                    headers: responseHeadersText($0),
                    body: initialBody($0.body, emptyMessage: "This response has no body."),
                    json: initialJSON($0.body),
                    bodyContentType: $0.body?.contentType
                )
            },
            rules: rulesText(flow.ruleTraces),
            breakpoint: flow.state.breakpointPhase.map {
                TrafficBreakpointInspection(phase: $0, canEditBody: false)
            }
        )
    }

    private static func requestHeadersText(_ request: HTTPRequest) -> String {
        HTTPMessageText.requestHeaders(request)
    }

    private static func responseHeadersText(_ response: HTTPResponse) -> String {
        HTTPMessageText.responseHeaders(response)
    }

    private static func bodyIsEditable(_ body: TrafficBodyPresentation) -> Bool {
        switch body {
        case .none:
            true
        case .content(_, let value):
            !value.hasPrefix("00000000  ")
        case .loading, .failed:
            false
        }
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

    private static func initialJSON(_ reference: BodyReference?) -> TrafficBodyPresentation {
        guard let reference else {
            return .none(JSONBodyView.notJSONReason)
        }
        return .loading(BodyDisplayFormatter.metadata(for: reference))
    }

    private static func loadBodies(
        _ reference: BodyReference?,
        reader: any TrafficBodyReading
    ) async -> (body: TrafficBodyPresentation, json: TrafficBodyPresentation) {
        guard let reference else {
            return (
                body: .none("No body was captured."),
                json: .none(JSONBodyView.notJSONReason)
            )
        }
        let metadata = BodyDisplayFormatter.metadata(for: reference)
        do {
            let data = try await reader.read(reference)
            return await Task.detached(priority: .utility) {
                (
                    body: .content(
                        metadata: metadata,
                        value: BodyDisplayFormatter.render(data, reference: reference)
                    ),
                    json: jsonPresentation(from: data, reference: reference, metadata: metadata)
                )
            }.value
        } catch {
            let failed = TrafficBodyPresentation.failed(
                metadata: metadata,
                message: error.localizedDescription
            )
            return (body: failed, json: failed)
        }
    }

    nonisolated private static func jsonPresentation(
        from data: Data,
        reference: BodyReference,
        metadata: String
    ) -> TrafficBodyPresentation {
        switch JSONBodyView.render(
            data: data,
            contentType: reference.contentType,
            contentEncoding: reference.contentEncoding,
            isTruncated: reference.isTruncated
        ) {
        case .prettyPrinted(let text):
            .content(metadata: metadata, value: text)
        case .unavailable(let reason):
            .none(reason)
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
