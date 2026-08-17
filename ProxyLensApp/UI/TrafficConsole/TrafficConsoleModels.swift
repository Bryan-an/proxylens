import Foundation
import ProxyLensApplication
import ProxyLensCore

enum TrafficNetworkConditionDraftError: LocalizedError, Equatable {
    case invalidLatency(String)
    case invalidBandwidth(field: String, value: String)
    case invalidPacketLoss(String)
    case emptyProfile

    var errorDescription: String? {
        switch self {
        case .invalidLatency(let value):
            "Latency must be a number from 0 through 60,000 milliseconds; received “\(value)”."
        case .invalidBandwidth(let field, let value):
            "\(field) must be blank for unlimited or a number from 1 through 976,562 KiB/s; received “\(value)”."
        case .invalidPacketLoss(let value):
            "Packet loss must be a number from 0 through 100 percent; received “\(value)”."
        case .emptyProfile:
            "Enter latency, a download limit, or an upload limit."
        }
    }
}

struct TrafficNetworkConditionDraft: Equatable, Sendable {
    let latencyMilliseconds: String
    let downloadKibibytesPerSecond: String
    let uploadKibibytesPerSecond: String
    let packetLossPercentage: String

    init(
        latencyMilliseconds: String,
        downloadKibibytesPerSecond: String,
        uploadKibibytesPerSecond: String,
        packetLossPercentage: String = ""
    ) {
        self.latencyMilliseconds = latencyMilliseconds
        self.downloadKibibytesPerSecond = downloadKibibytesPerSecond
        self.uploadKibibytesPerSecond = uploadKibibytesPerSecond
        self.packetLossPercentage = packetLossPercentage
    }

    func profile() throws -> ThrottleProfile {
        let latencyText = latencyMilliseconds.trimmingCharacters(in: .whitespacesAndNewlines)
        let latencyMilliseconds = latencyText.isEmpty ? 0 : Double(latencyText)
        guard let latencyMilliseconds, latencyMilliseconds.isFinite,
            (0...60_000).contains(latencyMilliseconds)
        else {
            throw TrafficNetworkConditionDraftError.invalidLatency(latencyText)
        }

        let download = try bandwidth(
            downloadKibibytesPerSecond,
            field: "Download"
        )
        let upload = try bandwidth(
            uploadKibibytesPerSecond,
            field: "Upload"
        )
        let packetLossText = packetLossPercentage.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let packetLoss = packetLossText.isEmpty ? 0 : Double(packetLossText)
        guard let packetLoss, packetLoss.isFinite, (0...100).contains(packetLoss) else {
            throw TrafficNetworkConditionDraftError.invalidPacketLoss(packetLossText)
        }
        guard latencyMilliseconds > 0 || download != nil || upload != nil || packetLoss > 0 else {
            throw TrafficNetworkConditionDraftError.emptyProfile
        }

        return ThrottleProfile(
            latency: latencyMilliseconds / 1_000,
            downloadBytesPerSecond: download,
            uploadBytesPerSecond: upload,
            packetLossPercentage: packetLoss
        )
    }

    private func bandwidth(_ text: String, field: String) throws -> Int64? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        guard let kibibytes = Double(normalized), kibibytes.isFinite,
            (1...976_562).contains(kibibytes)
        else {
            throw TrafficNetworkConditionDraftError.invalidBandwidth(
                field: field,
                value: normalized
            )
        }
        return Int64((kibibytes * 1_024).rounded())
    }
}

enum TrafficSourceSelection: Equatable, Hashable, Sendable {
    case allTraffic
    case session(SessionID)
    case application(String)
    case domain(String)
}

struct TrafficSessionSummary: Equatable, Identifiable, Sendable {
    let id: SessionID
    let name: String?
    let startedAt: Date
    let endedAt: Date?
    let state: SessionState
    let flowCount: Int
}

struct TrafficApplicationSummary: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let bundlePath: String?
    let flowCount: Int
}

struct TrafficDomainSummary: Equatable, Identifiable, Sendable {
    let host: String
    let flowCount: Int

    var id: String { host }
}

enum TrafficConsoleSortKey: String, Sendable {
    case method
    case host
    case path
    case graphqlOperation
    case status
    case startedAt
    case duration
    case size
}

struct TrafficConsoleSort: Equatable, Sendable {
    let key: TrafficConsoleSortKey
    let ascending: Bool
}

struct TrafficFlowRow: Equatable, Identifiable, Sendable {
    let id: FlowID
    let method: String
    let host: String
    let path: String
    let fullURL: String
    let graphqlOperation: String?
    let graphqlOperationMetadata: GraphQLOperationMetadata?
    let statusCode: Int?
    let state: FlowState
    let startedAt: Date
    let duration: TimeInterval?
    let byteCount: Int64
    let usesTLS: Bool
    let annotation: FlowAnnotation?
    let hasRequestBody: Bool
    let hasResponse: Bool
    let hasResponseBody: Bool
    let hasRequestCookies: Bool
    let hasResponseCookies: Bool

    init(flow: Flow) {
        id = flow.id
        method = flow.request.method.rawValue
        host = Self.host(for: flow)
        path = Self.path(for: flow.request.url)
        fullURL = flow.request.url.absoluteString
        graphqlOperationMetadata = flow.request.graphqlOperation
        graphqlOperation = graphqlOperationMetadata?.displayName
        statusCode = flow.response?.statusCode
        state = flow.state
        startedAt = flow.createdAt
        duration = flow.timing.totalDuration
        byteCount = Self.totalBytes(flow)
        usesTLS =
            flow.connection?.protocolKind == .https
            || flow.connection?.protocolKind == .secureWebSocket
            || flow.request.url.scheme?.lowercased() == "https"
        annotation = flow.annotation
        hasRequestBody = flow.request.body != nil
        hasResponse = flow.response != nil
        hasResponseBody = flow.response?.body != nil
        hasRequestCookies = !flow.request.headers.values(for: "Cookie").isEmpty
        hasResponseCookies = !(flow.response?.headers.values(for: "Set-Cookie").isEmpty ?? true)
    }

    static func host(for flow: Flow) -> String {
        flow.request.url.host?.lowercased()
            ?? flow.connection?.upstreamHost.lowercased()
            ?? "Unknown Host"
    }

    private static func path(for url: URL) -> String {
        var value = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            value += "?\(query)"
        }
        return value
    }

    private static func totalBytes(_ flow: Flow) -> Int64 {
        let requestBytes = flow.request.body?.byteCount ?? 0
        let responseBytes = flow.response?.body?.byteCount ?? 0
        let (total, overflowed) = requestBytes.addingReportingOverflow(responseBytes)
        return overflowed ? Int64.max : total
    }
}

enum TrafficFlowCopyKind: Equatable, Sendable {
    case url
    case requestHeaders
    case requestBody
    case requestCookies
    case responseHeaders
    case responseBody
    case responseCookies
}

enum TrafficCapturePresentation: Equatable, Sendable {
    case recovering
    case stopped
    case starting
    case running(CaptureContext, warning: String?)
    case stopping
    case failed(String)
}

enum TrafficBodyPresentation: Equatable, Sendable {
    case none(String)
    case loading(String)
    case content(metadata: String, value: String)
    case failed(metadata: String, message: String)
}

struct TrafficMessageInspection: Equatable, Sendable {
    let title: String
    let headers: String
    let query: String?
    let cookies: String
    let body: TrafficBodyPresentation
    let json: TrafficBodyPresentation
    let jsonTree: TrafficJSONTreePresentation
    let xml: TrafficBodyPresentation
    let form: TrafficBodyPresentation
    let graphql: TrafficBodyPresentation
    let bodyContentType: String?

    init(
        title: String,
        headers: String,
        query: String? = nil,
        cookies: String = "No cookies.",
        body: TrafficBodyPresentation,
        json: TrafficBodyPresentation,
        jsonTree: TrafficJSONTreePresentation = .none(JSONBodyView.notJSONReason),
        xml: TrafficBodyPresentation = .none(XMLBodyView.notXMLReason),
        form: TrafficBodyPresentation = .none(FormBodyView.notFormReason),
        graphql: TrafficBodyPresentation = .none(GraphQLBodyView.notGraphQLReason),
        bodyContentType: String?
    ) {
        self.title = title
        self.headers = headers
        self.query = query
        self.cookies = cookies
        self.body = body
        self.json = json
        self.jsonTree = jsonTree
        self.xml = xml
        self.form = form
        self.graphql = graphql
        self.bodyContentType = bodyContentType
    }
}

struct TrafficFlowSummaryInspection: Equatable, Sendable {
    let method: String
    let url: String
    let statusCode: Int?
    let statusReason: String?
    let state: FlowState
    let duration: TimeInterval?
    let byteCount: Int64
    let usesTLS: Bool

    init(flow: Flow) {
        let row = TrafficFlowRow(flow: flow)
        method = row.method
        url = row.fullURL
        statusCode = row.statusCode
        statusReason = flow.response?.reasonPhrase
        state = row.state
        duration = row.duration
        byteCount = row.byteCount
        usesTLS = row.usesTLS
    }
}

struct TrafficTimingPhaseInspection: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case requestHeaders
        case requestBody
        case connection
        case tls
        case waiting
        case responseBody
        case finalization
    }

    let kind: Kind
    let title: String
    let startOffset: TimeInterval
    let duration: TimeInterval

    var id: Kind { kind }
}

struct TrafficTimingInspection: Equatable, Sendable {
    let startedAt: Date
    let elapsedDuration: TimeInterval
    let totalDuration: TimeInterval
    let timeToFirstByte: TimeInterval?
    let isComplete: Bool
    let phases: [TrafficTimingPhaseInspection]

    init(flow: Flow) {
        let timing = flow.timing
        startedAt = timing.startedAt
        isComplete = timing.completedAt != nil
        timeToFirstByte = timing.timeToFirstByte

        let latestMilestone =
            [
                timing.requestHeadersReceivedAt,
                timing.requestBodyCompletedAt,
                timing.upstreamConnectedAt,
                timing.tlsHandshakeCompletedAt,
                timing.responseHeadersReceivedAt,
                timing.responseBodyCompletedAt,
                timing.completedAt
            ].compactMap { $0 }.max() ?? timing.startedAt
        elapsedDuration = max(0, latestMilestone.timeIntervalSince(timing.startedAt))
        totalDuration = timing.totalDuration ?? elapsedDuration

        var phases: [TrafficTimingPhaseInspection] = []
        Self.appendPhase(
            .requestHeaders,
            title: "Request Headers",
            from: timing.startedAt,
            to: timing.requestHeadersReceivedAt,
            anchor: timing.startedAt,
            into: &phases
        )
        Self.appendPhase(
            .requestBody,
            title: "Request Body",
            from: timing.requestHeadersReceivedAt,
            to: timing.requestBodyCompletedAt,
            anchor: timing.startedAt,
            into: &phases
        )
        Self.appendPhase(
            .connection,
            title: "Connect",
            from: timing.requestHeadersReceivedAt,
            to: timing.upstreamConnectedAt,
            anchor: timing.startedAt,
            into: &phases
        )
        Self.appendPhase(
            .tls,
            title: "TLS Handshake",
            from: timing.upstreamConnectedAt,
            to: timing.tlsHandshakeCompletedAt,
            anchor: timing.startedAt,
            into: &phases
        )

        let waitingStart = [
            timing.requestBodyCompletedAt,
            timing.upstreamConnectedAt,
            timing.tlsHandshakeCompletedAt
        ].compactMap { $0 }.max()
        Self.appendPhase(
            .waiting,
            title: "Waiting (TTFB)",
            from: waitingStart,
            to: timing.responseHeadersReceivedAt,
            anchor: timing.startedAt,
            into: &phases
        )
        Self.appendPhase(
            .responseBody,
            title: "Response Body",
            from: timing.responseHeadersReceivedAt,
            to: timing.responseBodyCompletedAt,
            anchor: timing.startedAt,
            into: &phases
        )
        Self.appendPhase(
            .finalization,
            title: "Finalize",
            from: timing.responseBodyCompletedAt,
            to: timing.completedAt,
            anchor: timing.startedAt,
            into: &phases
        )
        self.phases = phases
    }

    private static func appendPhase(
        _ kind: TrafficTimingPhaseInspection.Kind,
        title: String,
        from start: Date?,
        to end: Date?,
        anchor: Date,
        into phases: inout [TrafficTimingPhaseInspection]
    ) {
        guard let start, let end else {
            return
        }
        phases.append(
            TrafficTimingPhaseInspection(
                kind: kind,
                title: title,
                startOffset: max(0, start.timeIntervalSince(anchor)),
                duration: max(0, end.timeIntervalSince(start))
            )
        )
    }
}

enum TrafficWebSocketPayloadSyntax: Equatable, Sendable {
    case plainText
    case json
    case binary
}

enum TrafficWebSocketDirectionFilter: String, CaseIterable, Equatable, Sendable {
    case all = "All"
    case sent = "Sent"
    case received = "Received"

    func includes(_ direction: WebSocketFrameDirection) -> Bool {
        switch (self, direction) {
        case (.all, _), (.sent, .clientToServer), (.received, .serverToClient):
            true
        case (.sent, .serverToClient), (.received, .clientToServer):
            false
        }
    }
}

struct TrafficWebSocketFrameInspection: Equatable, Identifiable, Sendable {
    let id: UUID
    let sequenceNumber: Int64
    let direction: WebSocketFrameDirection
    let opcode: WebSocketFrameOpcode
    let isFinal: Bool
    let wasMasked: Bool
    let byteCount: Int64
    let receivedAt: Date

    init(frame: CapturedWebSocketFrame) {
        id = frame.id
        sequenceNumber = frame.sequenceNumber
        direction = frame.direction
        opcode = frame.opcode
        isFinal = frame.isFinal
        wasMasked = frame.wasMasked
        byteCount = frame.payloadByteCount
        receivedAt = frame.receivedAt
    }

    var directionLabel: String {
        switch direction {
        case .clientToServer: "Client → Server"
        case .serverToClient: "Server → Client"
        }
    }

    var opcodeLabel: String {
        switch opcode {
        case .continuation: "Continuation"
        case .text: "Text"
        case .binary: "Binary"
        case .close: "Close"
        case .ping: "Ping"
        case .pong: "Pong"
        case .unknown(let value): String(format: "Unknown 0x%02X", value)
        }
    }
}

struct TrafficWebSocketInspection: Equatable, Sendable {
    let frames: [TrafficWebSocketFrameInspection]
    let capturedFrameCount: Int
    let selectedFrameID: UUID?
    let payload: TrafficBodyPresentation
    let payloadSyntax: TrafficWebSocketPayloadSyntax
    let omittedFrameCount: Int
    let statusMessage: String?
    let directionFilter: TrafficWebSocketDirectionFilter
    let searchText: String
    let isSearching: Bool

    init(
        frames: [TrafficWebSocketFrameInspection],
        capturedFrameCount: Int? = nil,
        selectedFrameID: UUID?,
        payload: TrafficBodyPresentation,
        payloadSyntax: TrafficWebSocketPayloadSyntax,
        omittedFrameCount: Int,
        statusMessage: String?,
        directionFilter: TrafficWebSocketDirectionFilter = .all,
        searchText: String = "",
        isSearching: Bool = false
    ) {
        self.frames = frames
        self.capturedFrameCount = capturedFrameCount ?? frames.count
        self.selectedFrameID = selectedFrameID
        self.payload = payload
        self.payloadSyntax = payloadSyntax
        self.omittedFrameCount = omittedFrameCount
        self.statusMessage = statusMessage
        self.directionFilter = directionFilter
        self.searchText = searchText
        self.isSearching = isSearching
    }

    static let loading = TrafficWebSocketInspection(
        frames: [],
        selectedFrameID: nil,
        payload: .none("Select a WebSocket frame to inspect its payload."),
        payloadSyntax: .plainText,
        omittedFrameCount: 0,
        statusMessage: "Loading captured WebSocket frames…"
    )
}

struct TrafficFlowInspection: Equatable, Sendable {
    let flowID: FlowID?
    let title: String
    let summary: TrafficFlowSummaryInspection?
    let request: TrafficMessageInspection?
    let response: TrafficMessageInspection?
    let rules: String
    let timing: TrafficTimingInspection?
    let breakpoint: TrafficBreakpointInspection?
    let annotation: FlowAnnotation?
    let webSocket: TrafficWebSocketInspection?

    init(
        flowID: FlowID?,
        title: String,
        summary: TrafficFlowSummaryInspection? = nil,
        request: TrafficMessageInspection?,
        response: TrafficMessageInspection?,
        rules: String,
        timing: TrafficTimingInspection? = nil,
        breakpoint: TrafficBreakpointInspection?,
        annotation: FlowAnnotation? = nil,
        webSocket: TrafficWebSocketInspection? = nil
    ) {
        self.flowID = flowID
        self.title = title
        self.summary = summary
        self.request = request
        self.response = response
        self.rules = rules
        self.timing = timing
        self.breakpoint = breakpoint
        self.annotation = annotation
        self.webSocket = webSocket
    }

    static let empty = TrafficFlowInspection(
        flowID: nil,
        title: "No Flow Selected",
        request: nil,
        response: nil,
        rules: "Select a captured flow to inspect applied rules.",
        breakpoint: nil
    )
}

struct TrafficBreakpointInspection: Equatable, Sendable {
    let phase: BreakpointPhase
    let canEditBody: Bool
}

struct TrafficConsoleSnapshot: Equatable, Sendable {
    let capture: TrafficCapturePresentation
    let workspaceWarning: String?
    let certificateTrust: CertificateTrustState?
    let allFlowCount: Int
    let sessions: [TrafficSessionSummary]
    let applications: [TrafficApplicationSummary]
    let pinnedDomains: [TrafficDomainSummary]
    let domains: [TrafficDomainSummary]
    let selectedSource: TrafficSourceSelection
    let displayFilter: TrafficDisplayFilter
    let visibleRows: [TrafficFlowRow]
    let selectedFlowIDs: [FlowID]
    let selectedFlowID: FlowID?
    let inspection: TrafficFlowInspection

    init(
        capture: TrafficCapturePresentation,
        workspaceWarning: String?,
        certificateTrust: CertificateTrustState?,
        allFlowCount: Int,
        sessions: [TrafficSessionSummary] = [],
        applications: [TrafficApplicationSummary],
        pinnedDomains: [TrafficDomainSummary],
        domains: [TrafficDomainSummary],
        selectedSource: TrafficSourceSelection,
        displayFilter: TrafficDisplayFilter,
        visibleRows: [TrafficFlowRow],
        selectedFlowIDs: [FlowID]? = nil,
        selectedFlowID: FlowID?,
        inspection: TrafficFlowInspection
    ) {
        self.capture = capture
        self.workspaceWarning = workspaceWarning
        self.certificateTrust = certificateTrust
        self.allFlowCount = allFlowCount
        self.sessions = sessions
        self.applications = applications
        self.pinnedDomains = pinnedDomains
        self.domains = domains
        self.selectedSource = selectedSource
        self.displayFilter = displayFilter
        self.visibleRows = visibleRows
        self.selectedFlowIDs = selectedFlowIDs ?? selectedFlowID.map { [$0] } ?? []
        self.selectedFlowID = selectedFlowID
        self.inspection = inspection
    }

    static let initial = TrafficConsoleSnapshot(
        capture: .recovering,
        workspaceWarning: nil,
        certificateTrust: nil,
        allFlowCount: 0,
        applications: [],
        pinnedDomains: [],
        domains: [],
        selectedSource: .allTraffic,
        displayFilter: .all,
        visibleRows: [],
        selectedFlowID: nil,
        inspection: .empty
    )
}

struct TrafficConsoleStore {
    private var flowsByID: [FlowID: Flow] = [:]
    private var orderedFlowIDs: [FlowID] = []
    private var orderIndexByID: [FlowID: Int] = [:]
    private var searchableTextByID: [FlowID: String] = [:]
    private var sessionsByID: [SessionID: Session] = [:]
    private var sessionFlowCounts: [SessionID: Int] = [:]
    private var applicationProjections: [String: ApplicationProjection] = [:]
    private var applicationSummaries: [TrafficApplicationSummary] = []
    private var domainCounts: [String: Int] = [:]
    private var domainSummaries: [TrafficDomainSummary] = []
    private(set) var pinnedDomainHosts: Set<String> = []
    private var visibleRows: [TrafficFlowRow] = []
    private var visibleFlowIDs: Set<FlowID> = []
    private(set) var selectedSource: TrafficSourceSelection = .allTraffic
    private(set) var selectedFlowIDs: Set<FlowID> = []
    private(set) var selectedFlowID: FlowID?
    private(set) var displayFilter: TrafficDisplayFilter = .all
    private var searchTokens: [String] = []
    private var sort: TrafficConsoleSort?

    var selectedFlow: Flow? {
        selectedFlowID.flatMap { flowsByID[$0] }
    }

    func flow(id: FlowID) -> Flow? {
        flowsByID[id]
    }

    func flows(in sessionID: SessionID) -> [Flow] {
        orderedFlowIDs.compactMap { flowID in
            guard let flow = flowsByID[flowID], flow.sessionID == sessionID else {
                return nil
            }
            return flow
        }
    }

    func flows(ids: [FlowID]) -> [Flow] {
        var seen: Set<FlowID> = []
        return ids.compactMap { flowID in
            guard seen.insert(flowID).inserted else {
                return nil
            }
            return flowsByID[flowID]
        }
    }

    mutating func apply(_ events: [FlowEvent]) {
        var applicationProjectionChanged = false
        var domainProjectionChanged = false
        var needsSort = false

        for event in events {
            var flow = event.flow
            let previousFlow = flowsByID[flow.id]
            if flow.annotation == nil, let previousAnnotation = previousFlow?.annotation {
                flow.setAnnotation(previousAnnotation)
            }
            if previousFlow == nil {
                orderIndexByID[flow.id] = orderedFlowIDs.count
                orderedFlowIDs.append(flow.id)
            }

            flowsByID[flow.id] = flow
            searchableTextByID[flow.id] = TrafficDisplayFilter.searchableText(for: flow)
            updateSessionFlowCounts(previousFlow: previousFlow, currentFlow: flow)
            applicationProjectionChanged =
                updateApplicationProjections(previousFlow: previousFlow, currentFlow: flow)
                || applicationProjectionChanged
            domainProjectionChanged =
                updateDomainCounts(previousFlow: previousFlow, currentFlow: flow)
                || domainProjectionChanged

            let wasVisible = visibleFlowIDs.contains(flow.id)
            let isVisible = matchesCurrentProjection(flow)
            switch (wasVisible, isVisible) {
            case (true, true):
                guard let index = visibleRows.firstIndex(where: { $0.id == flow.id }) else {
                    rebuildVisibleProjection()
                    continue
                }
                visibleRows[index] = TrafficFlowRow(flow: flow)
                needsSort = needsSort || sort != nil
            case (true, false):
                visibleFlowIDs.remove(flow.id)
                if let index = visibleRows.firstIndex(where: { $0.id == flow.id }) {
                    visibleRows.remove(at: index)
                }
            case (false, true):
                let row = TrafficFlowRow(flow: flow)
                visibleFlowIDs.insert(flow.id)
                if sort == nil {
                    visibleRows.insert(row, at: captureOrderInsertionIndex(for: flow.id))
                } else {
                    visibleRows.append(row)
                    needsSort = true
                }
            case (false, false):
                break
            }
        }

        if applicationProjectionChanged {
            rebuildApplicationSummaries()
        }
        if domainProjectionChanged {
            rebuildDomainSummaries()
        }
        if needsSort {
            restoreVisibleOrder()
        }
        clearSelectionIfHidden()
    }

    mutating func updateAnnotation(_ annotation: FlowAnnotation?, for flowID: FlowID) {
        guard var flow = flowsByID[flowID] else {
            return
        }
        flow.setAnnotation(annotation)
        flowsByID[flowID] = flow
        searchableTextByID[flowID] = TrafficDisplayFilter.searchableText(for: flow)
        rebuildVisibleProjection()
        clearSelectionIfHidden()
    }

    mutating func replaceAll(_ flows: [Flow]) {
        flowsByID = [:]
        orderedFlowIDs = []
        orderIndexByID = [:]
        searchableTextByID = [:]
        sessionFlowCounts = [:]
        applicationProjections = [:]
        applicationSummaries = []
        domainCounts = [:]
        domainSummaries = []
        visibleRows = []
        visibleFlowIDs = []
        selectedFlowIDs = []
        selectedFlowID = nil
        apply(flows.map(FlowEvent.finished))
    }

    mutating func replaceSessions(_ sessions: [Session]) {
        sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        if case .session(let sessionID) = selectedSource,
            sessionsByID[sessionID] == nil
        {
            selectedSource = .allTraffic
            rebuildVisibleProjection()
            clearSelectionIfHidden()
        }
    }

    mutating func upsertSession(_ session: Session) {
        sessionsByID[session.id] = session
    }

    mutating func removeSession(_ sessionID: SessionID) {
        sessionsByID.removeValue(forKey: sessionID)
        if selectedSource == .session(sessionID) {
            selectedSource = .allTraffic
        }
        let remainingFlows = orderedFlowIDs.compactMap { flowID -> Flow? in
            guard let flow = flowsByID[flowID], flow.sessionID != sessionID else {
                return nil
            }
            return flow
        }
        replaceAll(remainingFlows)
    }

    mutating func selectSource(_ source: TrafficSourceSelection) {
        guard selectedSource != source else {
            return
        }
        selectedSource = source
        rebuildVisibleProjection()
        clearSelectionIfHidden()
    }

    mutating func setPinnedDomain(_ host: String, isPinned: Bool) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else {
            return
        }
        if isPinned {
            pinnedDomainHosts.insert(normalizedHost)
        } else {
            pinnedDomainHosts.remove(normalizedHost)
        }
    }

    mutating func setDisplayFilter(_ filter: TrafficDisplayFilter) {
        guard displayFilter != filter else {
            return
        }
        displayFilter = filter
        searchTokens = filter.normalizedSearchTokens
        rebuildVisibleProjection()
        clearSelectionIfHidden()
    }

    mutating func clearFilters() {
        guard selectedSource != .allTraffic || displayFilter != .all else {
            return
        }
        selectedSource = .allTraffic
        displayFilter = .all
        searchTokens = []
        rebuildVisibleProjection()
    }

    mutating func selectFlow(_ flowID: FlowID?) {
        selectFlows(flowID.map { [$0] } ?? [], primary: flowID)
    }

    mutating func selectFlows(_ flowIDs: [FlowID], primary: FlowID?) {
        selectedFlowIDs = Set(flowIDs).intersection(visibleFlowIDs)
        if let primary, selectedFlowIDs.contains(primary) {
            selectedFlowID = primary
        } else {
            selectedFlowID = orderedSelectedFlowIDs.first
        }
    }

    mutating func setSort(_ sort: TrafficConsoleSort?) {
        guard self.sort != sort else {
            return
        }
        self.sort = sort
        restoreVisibleOrder()
    }

    func snapshot(
        capture: TrafficCapturePresentation,
        inspection: TrafficFlowInspection,
        workspaceWarning: String? = nil,
        certificateTrust: CertificateTrustState? = nil
    ) -> TrafficConsoleSnapshot {
        TrafficConsoleSnapshot(
            capture: capture,
            workspaceWarning: workspaceWarning,
            certificateTrust: certificateTrust,
            allFlowCount: flowsByID.count,
            sessions: sessionSummaries,
            applications: applicationSummaries,
            pinnedDomains:
                pinnedDomainHosts
                .map {
                    TrafficDomainSummary(host: $0, flowCount: domainCounts[$0] ?? 0)
                }
                .sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending },
            domains: domainSummaries,
            selectedSource: selectedSource,
            displayFilter: displayFilter,
            visibleRows: visibleRows,
            selectedFlowIDs: orderedSelectedFlowIDs,
            selectedFlowID: selectedFlowID,
            inspection: inspection
        )
    }

    private func matchesCurrentProjection(_ flow: Flow) -> Bool {
        switch selectedSource {
        case .allTraffic:
            break
        case .session(let sessionID):
            guard flow.sessionID == sessionID else {
                return false
            }
        case .application(let applicationID):
            guard Self.applicationProjection(for: flow)?.id == applicationID else {
                return false
            }
        case .domain(let host):
            guard TrafficFlowRow.host(for: flow) == host else {
                return false
            }
        }
        return displayFilter.matches(
            flow,
            searchableText: searchableTextByID[flow.id]
                ?? TrafficDisplayFilter.searchableText(for: flow),
            searchTokens: searchTokens
        )
    }

    private var sessionSummaries: [TrafficSessionSummary] {
        sessionsByID.values
            .map { session in
                TrafficSessionSummary(
                    id: session.id,
                    name: session.name,
                    startedAt: session.startedAt,
                    endedAt: session.endedAt,
                    state: session.state,
                    flowCount: sessionFlowCounts[session.id] ?? session.flowCount
                )
            }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt > rhs.startedAt
                }
                return lhs.id.description < rhs.id.description
            }
    }

    private mutating func updateSessionFlowCounts(
        previousFlow: Flow?,
        currentFlow: Flow
    ) {
        guard let previousFlow else {
            sessionFlowCounts[currentFlow.sessionID, default: 0] += 1
            return
        }
        guard previousFlow.sessionID != currentFlow.sessionID else {
            return
        }
        decrementSessionFlowCount(previousFlow.sessionID)
        sessionFlowCounts[currentFlow.sessionID, default: 0] += 1
    }

    private mutating func decrementSessionFlowCount(_ sessionID: SessionID) {
        guard let count = sessionFlowCounts[sessionID] else {
            return
        }
        if count <= 1 {
            sessionFlowCounts.removeValue(forKey: sessionID)
        } else {
            sessionFlowCounts[sessionID] = count - 1
        }
    }

    private mutating func rebuildVisibleProjection() {
        var rebuiltRows: [TrafficFlowRow] = []
        rebuiltRows.reserveCapacity(visibleRows.count)
        for flowID in orderedFlowIDs {
            guard let flow = flowsByID[flowID], matchesCurrentProjection(flow) else {
                continue
            }
            rebuiltRows.append(TrafficFlowRow(flow: flow))
        }
        visibleRows = rebuiltRows
        visibleFlowIDs = Set(rebuiltRows.map(\.id))
        restoreVisibleOrder()
    }

    private mutating func updateDomainCounts(
        previousFlow: Flow?,
        currentFlow: Flow
    ) -> Bool {
        let currentHost = TrafficFlowRow.host(for: currentFlow)
        guard let previousFlow else {
            domainCounts[currentHost, default: 0] += 1
            return true
        }

        let previousHost = TrafficFlowRow.host(for: previousFlow)
        guard previousHost != currentHost else {
            return false
        }
        decrementDomainCount(previousHost)
        domainCounts[currentHost, default: 0] += 1
        return true
    }

    private mutating func updateApplicationProjections(
        previousFlow: Flow?,
        currentFlow: Flow
    ) -> Bool {
        let current = Self.applicationProjection(for: currentFlow)
        guard let previousFlow else {
            guard let current else {
                return false
            }
            incrementApplicationProjection(current)
            return true
        }

        let previous = Self.applicationProjection(for: previousFlow)
        guard previous != current else {
            return false
        }
        if let previous {
            decrementApplicationProjection(previous.id)
        }
        if let current {
            incrementApplicationProjection(current)
        }
        return true
    }

    private mutating func incrementApplicationProjection(_ projection: ApplicationProjection) {
        var updated = applicationProjections[projection.id] ?? projection
        updated.flowCount += 1
        applicationProjections[projection.id] = updated
    }

    private mutating func decrementApplicationProjection(_ id: String) {
        guard var projection = applicationProjections[id] else {
            return
        }
        if projection.flowCount == 1 {
            applicationProjections.removeValue(forKey: id)
        } else {
            projection.flowCount -= 1
            applicationProjections[id] = projection
        }
    }

    private mutating func rebuildApplicationSummaries() {
        applicationSummaries = applicationProjections.values
            .map {
                TrafficApplicationSummary(
                    id: $0.id,
                    name: $0.name,
                    bundlePath: $0.bundlePath,
                    flowCount: $0.flowCount
                )
            }
            .sorted {
                if $0.id == ApplicationProjection.unknownID {
                    return false
                }
                if $1.id == ApplicationProjection.unknownID {
                    return true
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private static func applicationProjection(for flow: Flow) -> ApplicationProjection? {
        guard flow.source.kind == .desktopProxy else {
            return nil
        }
        guard let application = flow.source.application else {
            return .unknown
        }
        return ApplicationProjection(
            id: application.groupingIdentifier,
            name: application.name,
            bundlePath: application.bundlePath
        )
    }

    private mutating func decrementDomainCount(_ host: String) {
        guard let count = domainCounts[host] else {
            return
        }
        if count == 1 {
            domainCounts.removeValue(forKey: host)
        } else {
            domainCounts[host] = count - 1
        }
    }

    private mutating func rebuildDomainSummaries() {
        domainSummaries =
            domainCounts
            .map { TrafficDomainSummary(host: $0.key, flowCount: $0.value) }
            .sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
    }

    private func captureOrderInsertionIndex(for flowID: FlowID) -> Int {
        let targetOrder = orderIndexByID[flowID] ?? Int.max
        var lowerBound = 0
        var upperBound = visibleRows.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            let midpointOrder = orderIndexByID[visibleRows[midpoint].id] ?? Int.max
            if midpointOrder < targetOrder {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private mutating func restoreVisibleOrder() {
        let orderIndices = orderIndexByID
        guard let sort else {
            visibleRows.sort {
                (orderIndices[$0.id] ?? Int.max) < (orderIndices[$1.id] ?? Int.max)
            }
            return
        }

        visibleRows.sort { lhs, rhs in
            let comparison = Self.compare(lhs, rhs, key: sort.key)
            if comparison == .orderedSame {
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt < rhs.startedAt
                }
                return (orderIndices[lhs.id] ?? Int.max) < (orderIndices[rhs.id] ?? Int.max)
            }
            return sort.ascending
                ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private mutating func clearSelectionIfHidden() {
        selectedFlowIDs.formIntersection(visibleFlowIDs)
        if let selectedFlowID, selectedFlowIDs.contains(selectedFlowID) {
            return
        }
        selectedFlowID = orderedSelectedFlowIDs.first
    }

    private var orderedSelectedFlowIDs: [FlowID] {
        visibleRows.compactMap { selectedFlowIDs.contains($0.id) ? $0.id : nil }
    }

    private static func compare(
        _ lhs: TrafficFlowRow,
        _ rhs: TrafficFlowRow,
        key: TrafficConsoleSortKey
    ) -> ComparisonResult {
        switch key {
        case .method:
            return lhs.method.localizedStandardCompare(rhs.method)
        case .host:
            return lhs.host.localizedStandardCompare(rhs.host)
        case .path:
            return lhs.path.localizedStandardCompare(rhs.path)
        case .graphqlOperation:
            return (lhs.graphqlOperation ?? "").localizedStandardCompare(
                rhs.graphqlOperation ?? ""
            )
        case .status:
            return compare(lhs.statusCode ?? -1, rhs.statusCode ?? -1)
        case .startedAt:
            return compare(lhs.startedAt, rhs.startedAt)
        case .duration:
            return compare(lhs.duration ?? -1, rhs.duration ?? -1)
        case .size:
            return compare(lhs.byteCount, rhs.byteCount)
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return .orderedSame
    }
}

private struct ApplicationProjection: Equatable {
    static let unknownID = "application:unknown"
    static let unknown = ApplicationProjection(
        id: unknownID,
        name: "Unknown App",
        bundlePath: nil
    )

    let id: String
    let name: String
    let bundlePath: String?
    var flowCount = 0
}

extension FlowEvent {
    fileprivate var flow: Flow {
        switch self {
        case .started(let flow), .updated(let flow), .finished(let flow):
            flow
        }
    }
}
