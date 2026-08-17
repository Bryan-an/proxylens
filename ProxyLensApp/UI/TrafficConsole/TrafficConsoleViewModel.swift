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

protocol TrafficWebSocketFrameLoading: Sendable {
    func listWebSocketFrames(for flowID: FlowID) async throws -> [CapturedWebSocketFrame]
}

protocol TrafficWebSocketFrameEventStreaming: Sendable {
    func makeWebSocketFrameStream() async -> AsyncStream<CapturedWebSocketFrame>
}

extension WebSocketFrameEventBus: TrafficWebSocketFrameEventStreaming {
    func makeWebSocketFrameStream() async -> AsyncStream<CapturedWebSocketFrame> {
        frames()
    }
}

protocol TrafficRequestReplaying: Sendable {
    func repeatRequest(_ request: HTTPRequest, sessionID: SessionID) async throws -> Flow
}

extension ReplayService: TrafficRequestReplaying {}

struct TrafficRequestEditDraft: Equatable, Sendable {
    let headersText: String
    let bodyText: String
    let canEditBody: Bool
    let bodyMessage: String?
}

protocol TrafficSessionLoading: Sendable {
    func loadWorkspace() async throws -> [Flow]
    func loadSessions() async throws -> [Session]
    func renameSession(sessionID: SessionID, to name: String?) async throws -> Session?
    func removeSession(sessionID: SessionID) async throws
    func clearWorkspace() async throws
    func sessionIDForNewFlow() async throws -> SessionID
    func updateAnnotation(_ annotation: FlowAnnotation?, for flowID: FlowID) async throws -> Flow?
}

extension SessionService: TrafficSessionLoading {}

protocol TrafficHARImporting: Sendable {
    func importHAR(from fileURL: URL) async throws -> HARImportResult
}

extension HARImportService: TrafficHARImporting {}

protocol TrafficPortableSessionTransferring: Sendable {
    func exportSession(sessionID: SessionID, to fileURL: URL) async throws
    func importSession(from fileURL: URL) async throws -> PortableSessionImportResult
}

extension PortableSessionService: TrafficPortableSessionTransferring {}

protocol TrafficRuleProfileArchiving: Sendable {
    func export(_ profile: RuleProfile, to fileURL: URL) async throws
    func importProfile(from fileURL: URL) async throws -> RuleProfile
}

extension RuleProfileArchiveService: TrafficRuleProfileArchiving {}

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
    private let webSocketFrameLoader: (any TrafficWebSocketFrameLoading)?
    private let webSocketFrameEventSource: (any TrafficWebSocketFrameEventStreaming)?
    private let captureConfiguration: CaptureConfiguration
    private let eventBatchDelay: Duration
    private let maximumVisibleWebSocketFrames: Int
    private let maximumWebSocketSearchBytes: Int64
    private let maximumWebSocketSearchBytesPerFrame: Int64
    private let maximumEditableRequestBodyBytes: Int64
    private let maximumComparableBodyBytes: Int64
    private let maximumCopiedBodyBytes: Int64
    private let ruleEngine: RuleEngine?
    private let breakpointCoordinator: BreakpointCoordinator?
    private let exportService: ExportService?
    private let requestReplayer: (any TrafficRequestReplaying)?
    private let sessionService: (any TrafficSessionLoading)?
    private let harImporter: (any TrafficHARImporting)?
    private let portableSessionTransfer: (any TrafficPortableSessionTransferring)?
    private let certificateTrust: (any TrafficCertificateTrusting)?
    private let ruleProfileStore: (any RuleProfileStoring)?
    private let ruleProfileArchive: any TrafficRuleProfileArchiving
    private let pinnedDomainsStore: any TrafficPinnedDomainsStoring

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
    private var webSocketFrameEventTask: Task<Void, Never>?
    private var webSocketFrameTask: Task<Void, Never>?
    private var webSocketPayloadTask: Task<Void, Never>?
    private var webSocketSearchTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var currentWebSocketFrames: [CapturedWebSocketFrame] = []
    private var omittedWebSocketFrameCount = 0
    private var webSocketDirectionFilter: TrafficWebSocketDirectionFilter = .all
    private var webSocketSearchText = ""
    private var webSocketSearchMatchIDs: Set<UUID>?
    private var skippedLargeWebSocketSearchPayloadCount = 0

    init(
        captureController: any TrafficCaptureControlling,
        eventSource: any TrafficFlowEventStreaming,
        bodyReader: any TrafficBodyReading,
        captureConfiguration: CaptureConfiguration,
        eventBatchDelay: Duration = .milliseconds(40),
        webSocketFrameLoader: (any TrafficWebSocketFrameLoading)? = nil,
        webSocketFrameEventSource: (any TrafficWebSocketFrameEventStreaming)? = nil,
        maximumVisibleWebSocketFrames: Int = 500,
        maximumWebSocketSearchBytes: Int64 = 8 * 1_024 * 1_024,
        maximumWebSocketSearchBytesPerFrame: Int64 = 256 * 1_024,
        maximumEditableRequestBodyBytes: Int64 = 1_024 * 1_024,
        maximumComparableBodyBytes: Int64 = 1_024 * 1_024,
        maximumCopiedBodyBytes: Int64 = 8 * 1_024 * 1_024,
        ruleEngine: RuleEngine? = nil,
        breakpointCoordinator: BreakpointCoordinator? = nil,
        exportService: ExportService? = nil,
        requestReplayer: (any TrafficRequestReplaying)? = nil,
        sessionService: (any TrafficSessionLoading)? = nil,
        harImporter: (any TrafficHARImporting)? = nil,
        portableSessionTransfer: (any TrafficPortableSessionTransferring)? = nil,
        certificateTrust: (any TrafficCertificateTrusting)? = nil,
        ruleProfileStore: (any RuleProfileStoring)? = nil,
        ruleProfileArchive: any TrafficRuleProfileArchiving = RuleProfileArchiveService(),
        pinnedDomainsStore: any TrafficPinnedDomainsStoring = InMemoryTrafficPinnedDomainsStore()
    ) {
        self.captureController = captureController
        self.eventSource = eventSource
        self.bodyReader = bodyReader
        self.webSocketFrameLoader = webSocketFrameLoader
        self.webSocketFrameEventSource = webSocketFrameEventSource
        self.captureConfiguration = captureConfiguration
        self.eventBatchDelay = eventBatchDelay
        self.maximumVisibleWebSocketFrames = max(1, maximumVisibleWebSocketFrames)
        self.maximumWebSocketSearchBytes = max(0, maximumWebSocketSearchBytes)
        self.maximumWebSocketSearchBytesPerFrame = max(
            0,
            maximumWebSocketSearchBytesPerFrame
        )
        self.maximumEditableRequestBodyBytes = max(0, maximumEditableRequestBodyBytes)
        self.maximumComparableBodyBytes = max(0, maximumComparableBodyBytes)
        self.maximumCopiedBodyBytes = max(0, maximumCopiedBodyBytes)
        self.ruleEngine = ruleEngine
        self.breakpointCoordinator = breakpointCoordinator
        self.exportService = exportService
        self.requestReplayer = requestReplayer
        self.sessionService = sessionService
        self.harImporter = harImporter
        self.portableSessionTransfer = portableSessionTransfer
        self.certificateTrust = certificateTrust
        self.ruleProfileStore = ruleProfileStore
        self.ruleProfileArchive = ruleProfileArchive
        self.pinnedDomainsStore = pinnedDomainsStore
        for domain in pinnedDomainsStore.domains {
            store.setPinnedDomain(domain, isPinned: true)
        }
    }

    deinit {
        eventTask?.cancel()
        eventBatchTask?.cancel()
        bodyTask?.cancel()
        webSocketFrameEventTask?.cancel()
        webSocketFrameTask?.cancel()
        webSocketPayloadTask?.cancel()
        webSocketSearchTask?.cancel()
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
        subscribeToWebSocketFrameEvents()
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
            webSocketFrameTask?.cancel()
            webSocketPayloadTask?.cancel()
            currentWebSocketFrames.removeAll(keepingCapacity: true)
            omittedWebSocketFrameCount = 0
            inspection = .empty
        }
        publishSnapshot()
    }

    func setPinnedDomain(_ host: String, isPinned: Bool) {
        store.setPinnedDomain(host, isPinned: isPinned)
        pinnedDomainsStore.save(store.pinnedDomainHosts)
        publishSnapshot()
    }

    func renameSession(_ sessionID: SessionID, to name: String?) async throws {
        guard let sessionService else {
            throw ProxyLensError.unsupportedOperation("Workspace sessions are not available")
        }
        guard let session = try await sessionService.renameSession(sessionID: sessionID, to: name)
        else {
            throw ProxyLensError.unsupportedOperation("The session is no longer available")
        }
        store.upsertSession(session)
        publishSnapshot()
    }

    func deleteSession(_ sessionID: SessionID) async throws {
        guard let sessionService else {
            throw ProxyLensError.unsupportedOperation("Workspace sessions are not available")
        }
        try await sessionService.removeSession(sessionID: sessionID)
        store.removeSession(sessionID)
        if store.selectedFlowID == nil {
            bodyTask?.cancel()
            webSocketFrameTask?.cancel()
            webSocketPayloadTask?.cancel()
            currentWebSocketFrames.removeAll(keepingCapacity: true)
            omittedWebSocketFrameCount = 0
            inspection = .empty
        } else {
            refreshInspection()
            return
        }
        publishSnapshot()
    }

    @discardableResult
    func importHAR(from fileURL: URL) async throws -> SessionID {
        guard let harImporter else {
            throw ProxyLensError.unsupportedOperation("HAR import is not available")
        }

        let result = try await harImporter.importHAR(from: fileURL)
        return applyImportedSession(session: result.session, flows: result.flows)
    }

    @discardableResult
    func importPortableSession(from fileURL: URL) async throws -> SessionID {
        guard let portableSessionTransfer else {
            throw ProxyLensError.unsupportedOperation("ProxyLens session import is not available")
        }

        let result = try await portableSessionTransfer.importSession(from: fileURL)
        return applyImportedSession(session: result.session, flows: result.flows)
    }

    private func applyImportedSession(session: Session, flows: [Flow]) -> SessionID {
        store.upsertSession(session)
        store.apply(flows.map(FlowEvent.finished))
        store.selectSource(.session(session.id))

        if let firstFlowID = flows.first?.id {
            store.selectFlow(firstFlowID)
            if store.selectedFlowID == nil {
                store.clearFilters()
                store.selectSource(.session(session.id))
                store.selectFlow(firstFlowID)
            }
        }
        workspaceWarning = nil
        refreshInspection()
        return session.id
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

    func setAnnotationFilter(_ annotation: TrafficAnnotationFilter) {
        updateDisplayFilter { $0.annotation = annotation }
    }

    func updateAnnotation(_ annotation: FlowAnnotation?, for flowID: FlowID) async throws {
        guard let sessionService else {
            throw ProxyLensError.unsupportedOperation("Flow annotations are not available")
        }
        guard store.flow(id: flowID) != nil else {
            throw ProxyLensError.unsupportedOperation("The flow is no longer available")
        }
        guard let updated = try await sessionService.updateAnnotation(annotation, for: flowID)
        else {
            throw ProxyLensError.unsupportedOperation("The flow is no longer available")
        }
        store.updateAnnotation(updated.annotation, for: flowID)
        if store.selectedFlowID == flowID {
            refreshInspection()
        } else {
            publishSnapshot()
        }
    }

    func clearDisplayFilters() {
        store.clearFilters()
        publishSnapshot()
    }

    func selectFlow(_ flowID: FlowID?) {
        store.selectFlow(flowID)
        refreshInspection()
    }

    func selectFlows(_ flowIDs: [FlowID], primary: FlowID?) {
        let previousPrimary = store.selectedFlowID
        store.selectFlows(flowIDs, primary: primary)
        if store.selectedFlowID == previousPrimary {
            publishSnapshot()
        } else {
            refreshInspection()
        }
    }

    func comparison(flowIDs: [FlowID]) async throws -> TrafficFlowComparison {
        var seen: Set<FlowID> = []
        let uniqueFlowIDs = flowIDs.filter { seen.insert($0).inserted }
        guard uniqueFlowIDs.count == 2 else {
            throw ProxyLensError.unsupportedOperation(
                "Select exactly two flows to compare"
            )
        }
        let flows = store.flows(ids: uniqueFlowIDs)
        guard flows.count == 2 else {
            throw ProxyLensError.unsupportedOperation(
                "A selected flow is no longer available"
            )
        }

        let left = flows[0]
        let right = flows[1]
        let reader = bodyReader
        let limit = maximumComparableBodyBytes
        async let leftRequestBody = Self.comparisonBodyText(
            reference: left.request.body,
            reader: reader,
            maximumByteCount: limit
        )
        async let rightRequestBody = Self.comparisonBodyText(
            reference: right.request.body,
            reader: reader,
            maximumByteCount: limit
        )
        async let leftResponseBody = Self.comparisonBodyText(
            reference: left.response?.body,
            reader: reader,
            maximumByteCount: limit
        )
        async let rightResponseBody = Self.comparisonBodyText(
            reference: right.response?.body,
            reader: reader,
            maximumByteCount: limit
        )
        let bodyTexts = await (
            leftRequestBody,
            rightRequestBody,
            leftResponseBody,
            rightResponseBody
        )

        return await Task.detached(priority: .utility) {
            let leftRequest = TrafficComparisonTextBuilder.requestText(
                for: left,
                bodyText: bodyTexts.0
            )
            let rightRequest = TrafficComparisonTextBuilder.requestText(
                for: right,
                bodyText: bodyTexts.1
            )
            let leftResponse = TrafficComparisonTextBuilder.responseText(
                for: left,
                bodyText: bodyTexts.2
            )
            let rightResponse = TrafficComparisonTextBuilder.responseText(
                for: right,
                bodyText: bodyTexts.3
            )
            return TrafficFlowComparison(
                leftTitle: TrafficComparisonTextBuilder.title(for: left),
                rightTitle: TrafficComparisonTextBuilder.title(for: right),
                request: TrafficMessageComparison(
                    rows: TrafficLineDiff.rows(left: leftRequest, right: rightRequest)
                ),
                response: TrafficMessageComparison(
                    rows: TrafficLineDiff.rows(left: leftResponse, right: rightResponse)
                )
            )
        }.value
    }

    func sortRows(by key: TrafficConsoleSortKey, ascending: Bool) {
        store.setSort(TrafficConsoleSort(key: key, ascending: ascending))
        publishSnapshot()
    }

    func clearSort() {
        store.setSort(nil)
        publishSnapshot()
    }

    func currentRulePresentations() async -> [TrafficRulePresentation] {
        guard let ruleEngine else {
            return []
        }
        return await ruleEngine.currentRules().orderedRules.map(TrafficRulePresentation.init)
    }

    func addRule(_ rule: Rule) async {
        await ruleEngine?.add(rule)
    }

    func updateRule(_ rule: Rule) async -> Bool {
        await ruleEngine?.update(rule) ?? false
    }

    func ruleDraft(id: RuleID) async -> TrafficRuleDraft? {
        guard let ruleEngine else {
            return nil
        }
        let rule = await ruleEngine.currentRules().rules.first { $0.id == id }
        return rule.flatMap(TrafficRuleDraft.init)
    }

    func setRuleEnabled(_ enabled: Bool, id: RuleID) async {
        await ruleEngine?.setEnabled(enabled, for: id)
    }

    func removeRule(id: RuleID) async {
        await ruleEngine?.remove(id: id)
    }

    func currentRuleProfiles() async throws -> [RuleProfile] {
        guard let ruleProfileStore else {
            return []
        }
        return try await ruleProfileStore.list()
    }

    @discardableResult
    func saveRuleProfile(name: String) async throws -> RuleProfile {
        guard let ruleEngine, let ruleProfileStore else {
            throw ProxyLensError.unsupportedOperation("Rule profiles are not available")
        }
        let profile = try await ruleEngine.makeProfile(name: name)
        return try await ruleProfileStore.save(profile)
    }

    func applyRuleProfile(id: UUID) async throws {
        guard let ruleEngine, let ruleProfileStore else {
            throw ProxyLensError.unsupportedOperation("Rule profiles are not available")
        }
        guard let profile = try await ruleProfileStore.list().first(where: { $0.id == id }) else {
            throw ProxyLensError.unsupportedOperation("The rule profile is no longer available")
        }
        try await ruleEngine.apply(profile)
    }

    func removeRuleProfile(id: UUID) async throws {
        guard let ruleProfileStore else {
            throw ProxyLensError.unsupportedOperation("Rule profiles are not available")
        }
        try await ruleProfileStore.remove(id: id)
    }

    func exportRuleProfile(id: UUID, to fileURL: URL) async throws {
        guard let ruleProfileStore else {
            throw ProxyLensError.unsupportedOperation("Rule profiles are not available")
        }
        guard let profile = try await ruleProfileStore.list().first(where: { $0.id == id }) else {
            throw ProxyLensError.unsupportedOperation("The rule profile is no longer available")
        }
        try await ruleProfileArchive.export(profile, to: fileURL)
    }

    @discardableResult
    func importRuleProfile(from fileURL: URL) async throws -> RuleProfile {
        guard let ruleProfileStore else {
            throw ProxyLensError.unsupportedOperation("Rule profiles are not available")
        }
        let profile = try await ruleProfileArchive.importProfile(from: fileURL)
        return try await ruleProfileStore.save(profile)
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

    func throttle(host: String, latency: TimeInterval) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.throttle(host: host, latency: latency)
    }

    func throttle(
        host: String,
        profile: ThrottleProfile,
        label: String
    ) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.throttle(host: host, profile: profile, label: label)
    }

    func clearThrottle(forHost host: String) async {
        await ruleEngine?.clearThrottle(forHost: host)
    }

    func mapLocal(host: String, path: String, fileURL: URL) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.mapLocal(host: host, path: path, fileURL: fileURL)
    }

    func mapLocal(graphqlOperation: GraphQLOperationMetadata, fileURL: URL) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.mapLocal(graphqlOperation: graphqlOperation, fileURL: fileURL)
    }

    func mapRemote(host: String, path: String, destination: URL) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.mapRemote(host: host, path: path, destination: destination)
    }

    func mapRemote(
        graphqlOperation: GraphQLOperationMetadata,
        destination: URL
    ) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.mapRemote(
            graphqlOperation: graphqlOperation,
            destination: destination
        )
    }

    func redirect(host: String, path: String, destination: URL) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.redirect(host: host, path: path, destination: destination)
    }

    func replaceRequestBody(
        host: String,
        path: String,
        fileURL: URL
    ) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.replaceRequestBody(host: host, path: path, fileURL: fileURL)
    }

    func replaceRequestBody(
        graphqlOperation: GraphQLOperationMetadata,
        fileURL: URL
    ) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.replaceRequestBody(
            graphqlOperation: graphqlOperation,
            fileURL: fileURL
        )
    }

    func replaceResponseBody(
        host: String,
        path: String,
        fileURL: URL
    ) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.replaceResponseBody(host: host, path: path, fileURL: fileURL)
    }

    func replaceResponseBody(
        graphqlOperation: GraphQLOperationMetadata,
        fileURL: URL
    ) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.replaceResponseBody(
            graphqlOperation: graphqlOperation,
            fileURL: fileURL
        )
    }

    func breakpoint(host: String, path: String, phase: RulePhase) {
        Task { await ruleEngine?.breakpoint(host: host, path: path, phase: phase) }
    }

    func breakpoint(graphqlOperation: GraphQLOperationMetadata) {
        Task { await ruleEngine?.breakpoint(graphqlOperation: graphqlOperation) }
    }

    func block(graphqlOperation: GraphQLOperationMetadata) {
        Task { await ruleEngine?.block(graphqlOperation: graphqlOperation) }
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

    func requestCodeSnippets(for flowID: FlowID) async throws -> [RequestCodeSnippet] {
        guard let exportService else {
            throw ProxyLensError.unsupportedOperation("Export is not available")
        }
        guard let flow = store.flow(id: flowID) else {
            throw ProxyLensError.unsupportedOperation("The flow is no longer available")
        }
        return try await exportService.requestCodeSnippets(for: flow)
    }

    func copyText(for flowID: FlowID, kind: TrafficFlowCopyKind) async throws -> String {
        guard let flow = store.flow(id: flowID) else {
            throw ProxyLensError.unsupportedOperation("The flow is no longer available")
        }
        switch kind {
        case .url:
            return flow.request.url.absoluteString
        case .requestHeaders:
            return HTTPMessageText.requestHeaders(flow.request)
        case .requestBody:
            return try await copiedBodyText(
                flow.request.body,
                missingMessage: "This request has no body"
            )
        case .requestCookies:
            guard !flow.request.headers.values(for: "Cookie").isEmpty else {
                throw ProxyLensError.unsupportedOperation("This request has no cookies")
            }
            return Self.requestCookiesText(flow.request.headers)
        case .responseHeaders:
            guard let response = flow.response else {
                throw ProxyLensError.unsupportedOperation("No response has been captured")
            }
            return HTTPMessageText.responseHeaders(response)
        case .responseBody:
            return try await copiedBodyText(
                flow.response?.body,
                missingMessage: "This response has no body"
            )
        case .responseCookies:
            guard let headers = flow.response?.headers,
                !headers.values(for: "Set-Cookie").isEmpty
            else {
                throw ProxyLensError.unsupportedOperation("This response has no cookies")
            }
            return Self.responseCookiesText(headers)
        }
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

    func writePortableSession(sessionID: SessionID, to fileURL: URL) async throws {
        guard let portableSessionTransfer else {
            throw ProxyLensError.unsupportedOperation("ProxyLens session export is not available")
        }
        try await portableSessionTransfer.exportSession(sessionID: sessionID, to: fileURL)
    }

    func writeHAR(sessionID: SessionID, to fileURL: URL) async throws {
        guard let exportService else {
            throw ProxyLensError.unsupportedOperation("Export is not available")
        }
        let flows = store.flows(in: sessionID)
        guard !flows.isEmpty else {
            throw ProxyLensError.unsupportedOperation("The session has no flows to export")
        }
        try await exportService.writeHAR(for: flows, to: fileURL)
    }

    func writeHAR(flowIDs: [FlowID], to fileURL: URL) async throws {
        guard let exportService else {
            throw ProxyLensError.unsupportedOperation("Export is not available")
        }
        var seen: Set<FlowID> = []
        let uniqueFlowIDs = flowIDs.filter { seen.insert($0).inserted }
        let flows = store.flows(ids: uniqueFlowIDs)
        guard !flows.isEmpty else {
            throw ProxyLensError.unsupportedOperation("Select at least one flow to export")
        }
        guard flows.count == uniqueFlowIDs.count else {
            throw ProxyLensError.unsupportedOperation("A selected flow is no longer available")
        }
        try await exportService.writeHAR(for: flows, to: fileURL)
    }

    func writeOpenAPI(flowIDs: [FlowID], to fileURL: URL) async throws {
        guard let exportService else {
            throw ProxyLensError.unsupportedOperation("Export is not available")
        }
        var seen: Set<FlowID> = []
        let uniqueFlowIDs = flowIDs.filter { seen.insert($0).inserted }
        let flows = store.flows(ids: uniqueFlowIDs)
        guard !flows.isEmpty else {
            throw ProxyLensError.unsupportedOperation("Select at least one flow to export")
        }
        guard flows.count == uniqueFlowIDs.count else {
            throw ProxyLensError.unsupportedOperation("A selected flow is no longer available")
        }
        let data = try await exportService.openAPI(for: flows)
        try data.write(to: fileURL, options: .atomic)
    }

    func writeWebSocketFrames(flowID: FlowID, to fileURL: URL) async throws {
        guard let exportService else {
            throw ProxyLensError.unsupportedOperation("Export is not available")
        }
        guard let webSocketFrameLoader else {
            throw ProxyLensError.unsupportedOperation(
                "WebSocket frame history is not available"
            )
        }
        guard let flow = store.flow(id: flowID) else {
            throw ProxyLensError.unsupportedOperation("The flow is no longer available")
        }
        guard Self.isWebSocket(flow) else {
            throw ProxyLensError.unsupportedOperation("The selected flow is not a WebSocket")
        }

        let frames = try await webSocketFrameLoader.listWebSocketFrames(for: flowID)
        try await exportService.writeWebSocketFrames(frames, for: flowID, to: fileURL)
    }

    @discardableResult
    func repeatRequest(flowID: FlowID) async throws -> FlowID {
        guard let requestReplayer else {
            throw ProxyLensError.unsupportedOperation("Repeat Request is not available")
        }
        guard let flow = store.flow(id: flowID) else {
            throw ProxyLensError.unsupportedOperation("The flow is no longer available")
        }

        let replayedFlow = try await requestReplayer.repeatRequest(
            flow.request,
            sessionID: flow.sessionID
        )
        applyReplayedFlow(replayedFlow)
        return replayedFlow.id
    }

    @discardableResult
    func composeRequest(headersText: String, bodyText: String?) async throws -> FlowID {
        guard let requestReplayer else {
            throw ProxyLensError.unsupportedOperation("Compose Request is not available")
        }
        guard let sessionService else {
            throw ProxyLensError.unsupportedOperation("Workspace sessions are not available")
        }

        let request: HTTPRequest
        if let bodyText {
            let decodedBody = Data(bodyText.utf8)
            guard Int64(decodedBody.count) <= maximumEditableRequestBodyBytes else {
                throw ProxyLensError.unsupportedOperation(requestBodyEditingLimitMessage)
            }
            let headersOnlyRequest = try HTTPMessageText.parseRequest(
                headersText: headersText,
                body: nil
            )
            let encodedBody = try HTTPContentCoding.encode(
                decodedBody,
                contentEncoding: headersOnlyRequest.headers.firstValue(for: "Content-Encoding")
            )
            request = try HTTPMessageText.parseRequest(
                headersText: headersText,
                body: encodedBody
            )
        } else {
            request = try HTTPMessageText.parseRequest(
                headersText: headersText,
                body: nil
            )
        }

        let sessionID = try await sessionService.sessionIDForNewFlow()
        let replayedFlow = try await requestReplayer.repeatRequest(
            request,
            sessionID: sessionID
        )
        applyReplayedFlow(replayedFlow)
        return replayedFlow.id
    }

    func requestEditDraft(flowID: FlowID) async throws -> TrafficRequestEditDraft {
        guard let flow = store.flow(id: flowID) else {
            throw ProxyLensError.unsupportedOperation("The flow is no longer available")
        }
        let headersText = HTTPMessageText.requestHeaders(flow.request)
        guard let body = flow.request.body else {
            return TrafficRequestEditDraft(
                headersText: headersText,
                bodyText: "",
                canEditBody: true,
                bodyMessage: nil
            )
        }
        let bodyLimitMessage = requestBodyEditingLimitMessage
        guard body.byteCount <= maximumEditableRequestBodyBytes else {
            return TrafficRequestEditDraft(
                headersText: headersText,
                bodyText: "",
                canEditBody: false,
                bodyMessage: bodyLimitMessage
            )
        }

        let data = try await bodyReader.read(body)
        guard Int64(data.count) <= maximumEditableRequestBodyBytes else {
            return TrafficRequestEditDraft(
                headersText: headersText,
                bodyText: "",
                canEditBody: false,
                bodyMessage: bodyLimitMessage
            )
        }

        let contentEncoding =
            body.contentEncoding ?? flow.request.headers.firstValue(for: "Content-Encoding")
        let decodedData: Data
        do {
            decodedData = try HTTPContentCoding.decode(
                data,
                contentEncoding: contentEncoding,
                maximumOutputByteCount: Int(clamping: maximumEditableRequestBodyBytes)
            )
        } catch HTTPContentCoding.CodingError.exceedsLimit {
            return TrafficRequestEditDraft(
                headersText: headersText,
                bodyText: "",
                canEditBody: false,
                bodyMessage: bodyLimitMessage
            )
        } catch {
            return TrafficRequestEditDraft(
                headersText: headersText,
                bodyText: "",
                canEditBody: false,
                bodyMessage: error.localizedDescription
            )
        }
        guard let bodyText = String(data: decodedData, encoding: .utf8) else {
            return TrafficRequestEditDraft(
                headersText: headersText,
                bodyText: "",
                canEditBody: false,
                bodyMessage: "Binary request bodies are preserved but cannot be edited"
            )
        }
        return TrafficRequestEditDraft(
            headersText: headersText,
            bodyText: bodyText,
            canEditBody: true,
            bodyMessage: nil
        )
    }

    @discardableResult
    func editAndRepeat(
        flowID: FlowID,
        headersText: String,
        bodyText: String?
    ) async throws -> FlowID {
        guard let requestReplayer else {
            throw ProxyLensError.unsupportedOperation("Edit & Repeat is not available")
        }
        guard let flow = store.flow(id: flowID) else {
            throw ProxyLensError.unsupportedOperation("The flow is no longer available")
        }
        let request: HTTPRequest
        if let bodyText {
            let decodedBody = Data(bodyText.utf8)
            guard Int64(decodedBody.count) <= maximumEditableRequestBodyBytes else {
                throw ProxyLensError.unsupportedOperation(requestBodyEditingLimitMessage)
            }
            let headersOnlyRequest = try HTTPMessageText.parseRequest(
                headersText: headersText,
                body: nil,
                original: flow.request
            )
            let encodedBody = try HTTPContentCoding.encode(
                decodedBody,
                contentEncoding: headersOnlyRequest.headers.firstValue(for: "Content-Encoding")
            )
            request = try HTTPMessageText.parseRequest(
                headersText: headersText,
                body: encodedBody,
                original: flow.request
            )
        } else {
            request = try HTTPMessageText.parseRequest(
                headersText: headersText,
                body: nil,
                original: flow.request
            )
        }
        let replayedFlow = try await requestReplayer.repeatRequest(
            request,
            sessionID: flow.sessionID
        )
        applyReplayedFlow(replayedFlow)
        return replayedFlow.id
    }

    private var requestBodyEditingLimitMessage: String {
        "Body editing is limited to \(ByteCountFormatter.string(fromByteCount: maximumEditableRequestBodyBytes, countStyle: .file))"
    }

    private func copiedBodyText(
        _ reference: BodyReference?,
        missingMessage: String
    ) async throws -> String {
        guard let reference else {
            throw ProxyLensError.unsupportedOperation(missingMessage)
        }
        guard reference.byteCount <= maximumCopiedBodyBytes else {
            throw ProxyLensError.unsupportedOperation(
                "Body copying is limited to \(ByteCountFormatter.string(fromByteCount: maximumCopiedBodyBytes, countStyle: .file))"
            )
        }
        let rawData = try await bodyReader.read(reference)
        guard Int64(rawData.count) <= maximumCopiedBodyBytes else {
            throw ProxyLensError.unsupportedOperation(
                "Body copying is limited to \(ByteCountFormatter.string(fromByteCount: maximumCopiedBodyBytes, countStyle: .file))"
            )
        }
        let data = try HTTPContentCoding.decode(
            rawData,
            contentEncoding: reference.contentEncoding,
            maximumOutputByteCount: Int(clamping: maximumCopiedBodyBytes)
        )
        if let text = String(data: data, encoding: .utf8), !data.contains(0) {
            return text
        }
        return data.base64EncodedString()
    }

    private func applyReplayedFlow(_ replayedFlow: Flow) {
        store.apply([.finished(replayedFlow)])
        store.selectFlow(replayedFlow.id)
        if store.selectedFlowID == nil {
            store.clearFilters()
            store.selectFlow(replayedFlow.id)
        }
        refreshInspection()
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
        store.replaceSessions([])
        store.replaceAll([])
        bodyTask?.cancel()
        webSocketFrameTask?.cancel()
        webSocketPayloadTask?.cancel()
        webSocketSearchTask?.cancel()
        currentWebSocketFrames.removeAll(keepingCapacity: true)
        omittedWebSocketFrameCount = 0
        webSocketDirectionFilter = .all
        webSocketSearchText = ""
        webSocketSearchMatchIDs = nil
        skippedLargeWebSocketSearchPayloadCount = 0
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
            webSocketFrameTask?.cancel()
            webSocketPayloadTask?.cancel()
            currentWebSocketFrames.removeAll(keepingCapacity: true)
            omittedWebSocketFrameCount = 0
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
            async let loadedFlows = sessionService.loadWorkspace()
            async let loadedSessions = sessionService.loadSessions()
            let (flows, sessions) = try await (loadedFlows, loadedSessions)
            store.replaceSessions(sessions)
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

    private func subscribeToWebSocketFrameEvents() {
        guard webSocketFrameEventTask == nil, let webSocketFrameEventSource else {
            return
        }
        webSocketFrameEventTask = Task { [weak self] in
            let stream = await webSocketFrameEventSource.makeWebSocketFrameStream()
            for await frame in stream {
                guard !Task.isCancelled else {
                    return
                }
                self?.receiveWebSocketFrame(frame)
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
        await refreshSessions(publish: false)
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
        await refreshSessions(publish: false)
        captureTask = nil
        publishSnapshot()
    }

    private func refreshSessions(publish: Bool) async {
        guard let sessionService else {
            return
        }
        do {
            store.replaceSessions(try await sessionService.loadSessions())
            if workspaceWarning?.hasPrefix("Could not refresh saved sessions:") == true {
                workspaceWarning = nil
            }
        } catch {
            workspaceWarning =
                "Could not refresh saved sessions: \(error.localizedDescription)"
        }
        if publish {
            publishSnapshot()
        }
    }

    private func refreshInspection() {
        bodyTask?.cancel()
        webSocketFrameTask?.cancel()
        webSocketPayloadTask?.cancel()
        webSocketSearchTask?.cancel()
        currentWebSocketFrames.removeAll(keepingCapacity: true)
        omittedWebSocketFrameCount = 0
        webSocketDirectionFilter = .all
        webSocketSearchText = ""
        webSocketSearchMatchIDs = nil
        skippedLargeWebSocketSearchPayloadCount = 0
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
        refreshWebSocketFrames(for: flow)
    }

    private func refreshWebSocketFrames(for flow: Flow) {
        guard Self.isWebSocket(flow) else {
            return
        }
        guard let webSocketFrameLoader else {
            replaceWebSocketInspection(
                TrafficWebSocketInspection(
                    frames: [],
                    selectedFrameID: nil,
                    payload: .none("Select a WebSocket frame to inspect its payload."),
                    payloadSyntax: .plainText,
                    omittedFrameCount: 0,
                    statusMessage: "WebSocket frame storage is unavailable."
                ),
                for: flow.id
            )
            return
        }

        webSocketFrameTask = Task { [weak self] in
            do {
                let frames = try await webSocketFrameLoader.listWebSocketFrames(for: flow.id)
                guard !Task.isCancelled, self?.store.selectedFlowID == flow.id else {
                    return
                }
                self?.applyLoadedWebSocketFrames(frames, to: flow.id)
            } catch {
                guard !Task.isCancelled, self?.store.selectedFlowID == flow.id else {
                    return
                }
                self?.replaceWebSocketInspection(
                    TrafficWebSocketInspection(
                        frames: [],
                        selectedFrameID: nil,
                        payload: .none("Select a WebSocket frame to inspect its payload."),
                        payloadSyntax: .plainText,
                        omittedFrameCount: 0,
                        statusMessage:
                            "Could not load WebSocket frames: \(error.localizedDescription)"
                    ),
                    for: flow.id
                )
            }
        }
    }

    func setWebSocketDirectionFilter(_ filter: TrafficWebSocketDirectionFilter) {
        guard let flowID = inspection.flowID, inspection.webSocket != nil else {
            return
        }
        webSocketDirectionFilter = filter
        refreshWebSocketFramePresentation(for: flowID)
    }

    func setWebSocketSearchText(_ text: String) {
        guard let flowID = inspection.flowID, inspection.webSocket != nil else {
            return
        }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != webSocketSearchText || webSocketSearchMatchIDs == nil else {
            return
        }
        webSocketSearchTask?.cancel()
        webSocketSearchText = query
        webSocketSearchMatchIDs = query.isEmpty ? nil : []
        skippedLargeWebSocketSearchPayloadCount = 0
        if query.isEmpty {
            refreshWebSocketFramePresentation(for: flowID)
            return
        }
        beginWebSocketSearch(query, flowID: flowID)
    }

    private func beginWebSocketSearch(_ query: String, flowID: FlowID) {
        webSocketSearchTask?.cancel()
        webSocketSearchMatchIDs = nil
        skippedLargeWebSocketSearchPayloadCount = 0
        refreshWebSocketFramePresentation(for: flowID)

        let frames = currentWebSocketFrames
        let bodyReader = bodyReader
        let maximumBytes = maximumWebSocketSearchBytes
        let maximumBytesPerFrame = maximumWebSocketSearchBytesPerFrame
        webSocketSearchTask = Task { [weak self] in
            let result = await Self.searchWebSocketFrames(
                frames,
                query: query,
                reader: bodyReader,
                maximumBytes: maximumBytes,
                maximumBytesPerFrame: maximumBytesPerFrame
            )
            guard !Task.isCancelled,
                self?.inspection.flowID == flowID,
                self?.webSocketSearchText == query
            else {
                return
            }
            self?.webSocketSearchMatchIDs = result.matchIDs
            self?.skippedLargeWebSocketSearchPayloadCount = result.skippedLargePayloadCount
            self?.refreshWebSocketFramePresentation(for: flowID)
        }
    }

    private func applyLoadedWebSocketFrames(
        _ frames: [CapturedWebSocketFrame],
        to flowID: FlowID
    ) {
        guard inspection.flowID == flowID else {
            return
        }
        let orderedFrames = Self.orderedUniqueWebSocketFrames(frames + currentWebSocketFrames)
        omittedWebSocketFrameCount = max(0, orderedFrames.count - maximumVisibleWebSocketFrames)
        currentWebSocketFrames = Array(orderedFrames.suffix(maximumVisibleWebSocketFrames))
        refreshWebSocketFramePresentation(for: flowID)
    }

    private func receiveWebSocketFrame(_ frame: CapturedWebSocketFrame) {
        guard inspection.flowID == frame.flowID, inspection.webSocket != nil else {
            return
        }
        guard !currentWebSocketFrames.contains(where: { $0.id == frame.id }) else {
            return
        }

        currentWebSocketFrames.append(frame)
        currentWebSocketFrames = Self.orderedUniqueWebSocketFrames(currentWebSocketFrames)
        if currentWebSocketFrames.count > maximumVisibleWebSocketFrames {
            let overflow = currentWebSocketFrames.count - maximumVisibleWebSocketFrames
            currentWebSocketFrames.removeFirst(overflow)
            omittedWebSocketFrameCount += overflow
        }

        if webSocketSearchText.isEmpty {
            refreshWebSocketFramePresentation(for: frame.flowID)
        } else {
            beginWebSocketSearch(webSocketSearchText, flowID: frame.flowID)
        }
    }

    private func refreshWebSocketFramePresentation(for flowID: FlowID) {
        guard inspection.flowID == flowID, let previous = inspection.webSocket else {
            return
        }
        let visibleFrames = visibleWebSocketFrames()
        let selectedFrameID =
            previous.selectedFrameID.flatMap { selectedID in
                visibleFrames.contains(where: { $0.id == selectedID }) ? selectedID : nil
            } ?? visibleFrames.first?.id
        let selectionChanged = previous.selectedFrameID != selectedFrameID
        let isSearching = !webSocketSearchText.isEmpty && webSocketSearchMatchIDs == nil
        let payload: TrafficBodyPresentation
        if selectedFrameID == nil {
            payload = .none(
                isSearching
                    ? "Searching captured frame payloads…"
                    : "No WebSocket frame matches the current filters."
            )
        } else if selectionChanged {
            payload = .loading("Loading WebSocket frame payload…")
        } else {
            payload = previous.payload
        }
        replaceWebSocketInspection(
            makeWebSocketInspection(
                frames: visibleFrames,
                selectedFrameID: selectedFrameID,
                payload: payload,
                payloadSyntax: selectionChanged ? .plainText : previous.payloadSyntax,
                isSearching: isSearching
            ),
            for: flowID
        )
        if selectionChanged, let selectedFrameID {
            selectWebSocketFrame(selectedFrameID)
        }
    }

    func selectWebSocketFrame(_ frameID: UUID) {
        guard let flowID = inspection.flowID,
            inspection.webSocket != nil,
            let frame = visibleWebSocketFrames().first(where: { $0.id == frameID })
        else {
            return
        }

        webSocketPayloadTask?.cancel()
        replaceWebSocketInspection(
            makeWebSocketInspection(
                frames: visibleWebSocketFrames(),
                selectedFrameID: frame.id,
                payload: .loading(BodyDisplayFormatter.metadata(for: frame.payload)),
                payloadSyntax: frame.opcode == .binary ? .binary : .plainText,
                isSearching: false
            ),
            for: flowID
        )

        let bodyReader = bodyReader
        webSocketPayloadTask = Task { [weak self] in
            do {
                let data = try await bodyReader.read(frame.payload)
                guard !Task.isCancelled,
                    self?.inspection.flowID == flowID,
                    self?.inspection.webSocket?.selectedFrameID == frame.id
                else {
                    return
                }
                let presentation = Self.webSocketPayloadPresentation(data, frame: frame)
                self?.applyWebSocketPayload(
                    presentation.body,
                    syntax: presentation.syntax,
                    frameID: frame.id,
                    flowID: flowID
                )
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.applyWebSocketPayload(
                    .failed(
                        metadata: BodyDisplayFormatter.metadata(for: frame.payload),
                        message: "Could not load frame payload: \(error.localizedDescription)"
                    ),
                    syntax: .plainText,
                    frameID: frame.id,
                    flowID: flowID
                )
            }
        }
    }

    private func applyWebSocketPayload(
        _ payload: TrafficBodyPresentation,
        syntax: TrafficWebSocketPayloadSyntax,
        frameID: UUID,
        flowID: FlowID
    ) {
        guard inspection.flowID == flowID,
            let webSocket = inspection.webSocket,
            webSocket.selectedFrameID == frameID
        else {
            return
        }
        replaceWebSocketInspection(
            makeWebSocketInspection(
                frames: visibleWebSocketFrames(),
                selectedFrameID: frameID,
                payload: payload,
                payloadSyntax: syntax,
                isSearching: webSocket.isSearching
            ),
            for: flowID
        )
    }

    private func visibleWebSocketFrames() -> [CapturedWebSocketFrame] {
        currentWebSocketFrames.filter { frame in
            guard webSocketDirectionFilter.includes(frame.direction) else {
                return false
            }
            guard !webSocketSearchText.isEmpty else {
                return true
            }
            guard let webSocketSearchMatchIDs else {
                return true
            }
            return webSocketSearchMatchIDs.contains(frame.id)
        }
    }

    private func makeWebSocketInspection(
        frames: [CapturedWebSocketFrame],
        selectedFrameID: UUID?,
        payload: TrafficBodyPresentation,
        payloadSyntax: TrafficWebSocketPayloadSyntax,
        isSearching: Bool
    ) -> TrafficWebSocketInspection {
        TrafficWebSocketInspection(
            frames: frames.map(TrafficWebSocketFrameInspection.init),
            capturedFrameCount: currentWebSocketFrames.count,
            selectedFrameID: selectedFrameID,
            payload: payload,
            payloadSyntax: payloadSyntax,
            omittedFrameCount: omittedWebSocketFrameCount,
            statusMessage: currentWebSocketStatusMessage(
                visibleCount: frames.count,
                isSearching: isSearching
            ),
            directionFilter: webSocketDirectionFilter,
            searchText: webSocketSearchText,
            isSearching: isSearching
        )
    }

    private func replaceWebSocketInspection(
        _ webSocket: TrafficWebSocketInspection,
        for flowID: FlowID
    ) {
        guard inspection.flowID == flowID else {
            return
        }
        inspection = TrafficFlowInspection(
            flowID: inspection.flowID,
            title: inspection.title,
            summary: inspection.summary,
            request: inspection.request,
            response: inspection.response,
            rules: inspection.rules,
            timing: inspection.timing,
            breakpoint: inspection.breakpoint,
            annotation: inspection.annotation,
            webSocket: webSocket
        )
        publishSnapshot()
    }

    private static func orderedUniqueWebSocketFrames(
        _ frames: [CapturedWebSocketFrame]
    ) -> [CapturedWebSocketFrame] {
        var seen: Set<UUID> = []
        return
            frames
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.sequenceNumber != $1.sequenceNumber {
                    return $0.sequenceNumber < $1.sequenceNumber
                }
                return $0.receivedAt < $1.receivedAt
            }
    }

    nonisolated private static func searchWebSocketFrames(
        _ frames: [CapturedWebSocketFrame],
        query: String,
        reader: any TrafficBodyReading,
        maximumBytes: Int64,
        maximumBytesPerFrame: Int64
    ) async -> (matchIDs: Set<UUID>, skippedLargePayloadCount: Int) {
        var matchIDs: Set<UUID> = []
        var remainingBytes = maximumBytes
        var skippedLargePayloadCount = 0
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        for frame in frames {
            guard !Task.isCancelled else {
                break
            }
            let metadata = TrafficWebSocketFrameInspection(frame: frame)
            let metadataText = [
                String(frame.sequenceNumber),
                metadata.directionLabel,
                metadata.opcodeLabel,
                frame.isFinal ? "final fin" : "fragment",
                frame.wasMasked ? "masked" : "unmasked"
            ].joined(separator: " ")
            if metadataText.range(of: query, options: options) != nil {
                matchIDs.insert(frame.id)
                continue
            }
            guard frame.opcode != .binary else {
                continue
            }
            guard frame.payloadByteCount <= maximumBytesPerFrame,
                frame.payloadByteCount <= remainingBytes
            else {
                skippedLargePayloadCount += 1
                continue
            }

            do {
                let data = try await reader.read(frame.payload)
                remainingBytes = max(0, remainingBytes - Int64(data.count))
                if let text = String(data: data, encoding: .utf8),
                    text.range(of: query, options: options) != nil
                {
                    matchIDs.insert(frame.id)
                }
            } catch {
                continue
            }
        }
        return (matchIDs, skippedLargePayloadCount)
    }

    private func currentWebSocketStatusMessage(
        visibleCount: Int,
        isSearching: Bool
    ) -> String? {
        if isSearching {
            return "Searching \(currentWebSocketFrames.count) captured WebSocket frames…"
        }
        let hasFilter = webSocketDirectionFilter != .all || !webSocketSearchText.isEmpty
        guard hasFilter else {
            return Self.webSocketStatusMessage(
                visibleCount: visibleCount,
                omittedCount: omittedWebSocketFrameCount
            )
        }

        var message = "\(visibleCount) of \(currentWebSocketFrames.count) captured frames match."
        if skippedLargeWebSocketSearchPayloadCount == 1 {
            message += " 1 large payload skipped."
        } else if skippedLargeWebSocketSearchPayloadCount > 1 {
            message += " \(skippedLargeWebSocketSearchPayloadCount) large payloads skipped."
        }
        if omittedWebSocketFrameCount == 1 {
            message += " 1 earlier frame is outside the visible history."
        } else if omittedWebSocketFrameCount > 1 {
            message +=
                " \(omittedWebSocketFrameCount) earlier frames are outside the visible history."
        }
        return message
    }

    private static func webSocketStatusMessage(
        visibleCount: Int,
        omittedCount: Int
    ) -> String? {
        if visibleCount == 0 {
            return "No WebSocket frames were captured."
        }
        guard omittedCount > 0 else {
            return nil
        }
        if omittedCount == 1 {
            return "Showing the latest \(visibleCount) frames; 1 earlier frame is hidden."
        }
        return
            "Showing the latest \(visibleCount) frames; \(omittedCount) earlier frames are hidden."
    }

    nonisolated private static func webSocketPayloadPresentation(
        _ data: Data,
        frame: CapturedWebSocketFrame
    ) -> (body: TrafficBodyPresentation, syntax: TrafficWebSocketPayloadSyntax) {
        let metadata = BodyDisplayFormatter.metadata(for: frame.payload)
        if frame.opcode == .text {
            switch JSONBodyView.render(
                data: data,
                contentType: nil,
                contentEncoding: frame.payload.contentEncoding,
                isTruncated: frame.payload.isTruncated
            ) {
            case .prettyPrinted(let value):
                return (.content(metadata: metadata, value: value), .json)
            case .unavailable:
                return (
                    .content(
                        metadata: metadata,
                        value: BodyDisplayFormatter.render(data, reference: frame.payload)
                    ),
                    .plainText
                )
            }
        }
        return (
            .content(
                metadata: metadata,
                value: BodyDisplayFormatter.render(data, reference: frame.payload)
            ),
            frame.opcode == .binary ? .binary : .plainText
        )
    }

    private static func isWebSocket(_ flow: Flow) -> Bool {
        switch flow.connection?.protocolKind {
        case .webSocket, .secureWebSocket:
            true
        case .http, .https, .none:
            false
        }
    }

    private func applyLoadedBodies(
        request: (
            body: TrafficBodyPresentation,
            json: TrafficBodyPresentation,
            jsonTree: TrafficJSONTreePresentation,
            xml: TrafficBodyPresentation,
            form: TrafficBodyPresentation,
            graphql: TrafficBodyPresentation
        ),
        response: (
            body: TrafficBodyPresentation,
            json: TrafficBodyPresentation,
            jsonTree: TrafficJSONTreePresentation,
            xml: TrafficBodyPresentation,
            form: TrafficBodyPresentation,
            graphql: TrafficBodyPresentation
        ),
        to flowID: FlowID
    ) {
        guard inspection.flowID == flowID else {
            return
        }
        inspection = TrafficFlowInspection(
            flowID: inspection.flowID,
            title: inspection.title,
            summary: inspection.summary,
            request: inspection.request.map {
                TrafficMessageInspection(
                    title: $0.title,
                    headers: $0.headers,
                    query: $0.query,
                    cookies: $0.cookies,
                    body: request.body,
                    json: request.json,
                    jsonTree: request.jsonTree,
                    xml: request.xml,
                    form: request.form,
                    graphql: request.graphql,
                    bodyContentType: $0.bodyContentType
                )
            },
            response: inspection.response.map {
                TrafficMessageInspection(
                    title: $0.title,
                    headers: $0.headers,
                    query: $0.query,
                    cookies: $0.cookies,
                    body: response.body,
                    json: response.json,
                    jsonTree: response.jsonTree,
                    xml: response.xml,
                    form: response.form,
                    graphql: response.graphql,
                    bodyContentType: $0.bodyContentType
                )
            },
            rules: inspection.rules,
            timing: inspection.timing,
            breakpoint: inspection.breakpoint.map { breakpoint in
                let body = breakpoint.phase == .response ? response.body : request.body
                return TrafficBreakpointInspection(
                    phase: breakpoint.phase,
                    canEditBody: Self.bodyIsEditable(body)
                )
            },
            annotation: inspection.annotation,
            webSocket: inspection.webSocket
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
            summary: TrafficFlowSummaryInspection(flow: flow),
            request: TrafficMessageInspection(
                title: "Request",
                headers: requestHeadersText(flow.request),
                query: queryText(flow.request.url),
                cookies: requestCookiesText(flow.request.headers),
                body: initialBody(flow.request.body, emptyMessage: "This request has no body."),
                json: initialJSON(flow.request.body),
                jsonTree: initialJSONTree(flow.request.body),
                xml: initialXML(flow.request.body),
                form: initialForm(flow.request.body),
                graphql: initialGraphQL(flow.request.body),
                bodyContentType: flow.request.body?.contentType
            ),
            response: flow.response.map {
                TrafficMessageInspection(
                    title: "Response",
                    headers: responseHeadersText($0),
                    cookies: responseCookiesText($0.headers),
                    body: initialBody($0.body, emptyMessage: "This response has no body."),
                    json: initialJSON($0.body),
                    jsonTree: initialJSONTree($0.body),
                    xml: initialXML($0.body),
                    form: initialForm($0.body),
                    graphql: initialGraphQL($0.body),
                    bodyContentType: $0.body?.contentType
                )
            },
            rules: rulesText(flow.ruleTraces),
            timing: TrafficTimingInspection(flow: flow),
            breakpoint: flow.state.breakpointPhase.map {
                TrafficBreakpointInspection(phase: $0, canEditBody: false)
            },
            annotation: flow.annotation,
            webSocket: isWebSocket(flow) ? .loading : nil
        )
    }

    private static func requestHeadersText(_ request: HTTPRequest) -> String {
        HTTPMessageText.requestHeaders(request)
    }

    private static func responseHeadersText(_ response: HTTPResponse) -> String {
        HTTPMessageText.responseHeaders(response)
    }

    private static func queryText(_ url: URL) -> String {
        guard
            let items = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems, !items.isEmpty
        else {
            return "No query parameters."
        }

        return items.map { item in
            guard let value = item.value else {
                return item.name
            }
            return "\(item.name)=\(value)"
        }.joined(separator: "\n")
    }

    private static func requestCookiesText(_ headers: HTTPHeaders) -> String {
        let cookies = headers.values(for: "Cookie").flatMap { value in
            value.split(separator: ";").compactMap { component -> String? in
                let cookie = component.trimmingCharacters(in: .whitespacesAndNewlines)
                return cookie.isEmpty ? nil : cookie
            }
        }
        return cookies.isEmpty ? "No request cookies." : cookies.joined(separator: "\n")
    }

    private static func responseCookiesText(_ headers: HTTPHeaders) -> String {
        let cookies = headers.values(for: "Set-Cookie").compactMap { value -> String? in
            let components = value.split(separator: ";").compactMap { component -> String? in
                let part = component.trimmingCharacters(in: .whitespacesAndNewlines)
                return part.isEmpty ? nil : part
            }
            guard let cookie = components.first else {
                return nil
            }
            return ([cookie] + components.dropFirst().map { "  \($0)" })
                .joined(separator: "\n")
        }
        return cookies.isEmpty ? "No response cookies." : cookies.joined(separator: "\n\n")
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

    private static func initialJSONTree(
        _ reference: BodyReference?
    ) -> TrafficJSONTreePresentation {
        guard let reference else {
            return .none(JSONBodyView.notJSONReason)
        }
        return .loading("Loading \(BodyDisplayFormatter.metadata(for: reference))…")
    }

    private static func initialXML(_ reference: BodyReference?) -> TrafficBodyPresentation {
        guard let reference else {
            return .none(XMLBodyView.notXMLReason)
        }
        return .loading(BodyDisplayFormatter.metadata(for: reference))
    }

    private static func initialForm(_ reference: BodyReference?) -> TrafficBodyPresentation {
        guard let reference else {
            return .none(FormBodyView.notFormReason)
        }
        return .loading(BodyDisplayFormatter.metadata(for: reference))
    }

    private static func initialGraphQL(_ reference: BodyReference?) -> TrafficBodyPresentation {
        guard let reference else {
            return .none(GraphQLBodyView.notGraphQLReason)
        }
        return .loading(BodyDisplayFormatter.metadata(for: reference))
    }

    private static func loadBodies(
        _ reference: BodyReference?,
        reader: any TrafficBodyReading
    ) async -> (
        body: TrafficBodyPresentation,
        json: TrafficBodyPresentation,
        jsonTree: TrafficJSONTreePresentation,
        xml: TrafficBodyPresentation,
        form: TrafficBodyPresentation,
        graphql: TrafficBodyPresentation
    ) {
        guard let reference else {
            return (
                body: .none("No body was captured."),
                json: .none(JSONBodyView.notJSONReason),
                jsonTree: .none(JSONBodyView.notJSONReason),
                xml: .none(XMLBodyView.notXMLReason),
                form: .none(FormBodyView.notFormReason),
                graphql: .none(GraphQLBodyView.notGraphQLReason)
            )
        }
        let metadata = BodyDisplayFormatter.metadata(for: reference)
        do {
            let data = try await reader.read(reference)
            return await Task.detached(priority: .utility) {
                () -> (
                    body: TrafficBodyPresentation,
                    json: TrafficBodyPresentation,
                    jsonTree: TrafficJSONTreePresentation,
                    xml: TrafficBodyPresentation,
                    form: TrafficBodyPresentation,
                    graphql: TrafficBodyPresentation
                ) in
                let json = jsonPresentation(
                    from: data,
                    reference: reference,
                    metadata: metadata
                )
                return (
                    body: .content(
                        metadata: metadata,
                        value: BodyDisplayFormatter.render(data, reference: reference)
                    ),
                    json: json,
                    jsonTree: jsonTreePresentation(from: json),
                    xml: xmlPresentation(
                        from: data,
                        reference: reference,
                        metadata: metadata
                    ),
                    form: formPresentation(
                        from: data,
                        reference: reference,
                        metadata: metadata
                    ),
                    graphql: graphqlPresentation(
                        from: data,
                        reference: reference,
                        metadata: metadata
                    )
                )
            }.value
        } catch {
            let failed = TrafficBodyPresentation.failed(
                metadata: metadata,
                message: error.localizedDescription
            )
            return (
                body: failed,
                json: failed,
                jsonTree: .failed(error.localizedDescription),
                xml: failed,
                form: failed,
                graphql: failed
            )
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

    nonisolated private static func jsonTreePresentation(
        from json: TrafficBodyPresentation
    ) -> TrafficJSONTreePresentation {
        switch json {
        case .content(_, let value):
            return TrafficJSONTreeBuilder.build(value)
        case .none(let message):
            return .none(message)
        case .loading(let message):
            return .loading(message)
        case .failed(_, let message):
            return .failed(message)
        }
    }

    nonisolated private static func xmlPresentation(
        from data: Data,
        reference: BodyReference,
        metadata: String
    ) -> TrafficBodyPresentation {
        switch XMLBodyView.render(
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

    nonisolated private static func formPresentation(
        from data: Data,
        reference: BodyReference,
        metadata: String
    ) -> TrafficBodyPresentation {
        switch FormBodyView.render(
            data: data,
            contentType: reference.contentType,
            contentEncoding: reference.contentEncoding,
            isTruncated: reference.isTruncated
        ) {
        case .decoded(let text):
            .content(metadata: metadata, value: text)
        case .unavailable(let reason):
            .none(reason)
        }
    }

    nonisolated private static func graphqlPresentation(
        from data: Data,
        reference: BodyReference,
        metadata: String
    ) -> TrafficBodyPresentation {
        switch GraphQLBodyView.render(
            data: data,
            contentType: reference.contentType,
            contentEncoding: reference.contentEncoding,
            isTruncated: reference.isTruncated
        ) {
        case .formatted(let text):
            .content(metadata: metadata, value: text)
        case .unavailable(let reason):
            .none(reason)
        }
    }

    nonisolated private static func comparisonBodyText(
        reference: BodyReference?,
        reader: any TrafficBodyReading,
        maximumByteCount: Int64
    ) async -> String? {
        guard let reference else {
            return nil
        }
        guard reference.byteCount <= maximumByteCount else {
            return TrafficComparisonTextBuilder.omittedBodyText(
                for: reference,
                maximumByteCount: maximumByteCount
            )
        }
        do {
            let data = try await reader.read(reference)
            guard Int64(data.count) <= maximumByteCount else {
                return TrafficComparisonTextBuilder.omittedBodyText(
                    for: reference,
                    maximumByteCount: maximumByteCount
                )
            }
            return TrafficComparisonTextBuilder.bodyText(
                data: data,
                reference: reference,
                maximumDecodedByteCount: Int(clamping: maximumByteCount)
            )
        } catch {
            return TrafficComparisonTextBuilder.failedBodyText(error)
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
