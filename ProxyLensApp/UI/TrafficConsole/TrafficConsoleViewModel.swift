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

protocol TrafficWebSocketComposing: Sendable {
    func isConnectionOpen(for flowID: FlowID) async -> Bool
    func send(_ request: WebSocketComposeRequest) async throws
    func reconnect(
        _ request: WebSocketReconnectRequest,
        sessionID: SessionID
    ) async throws -> Flow
    func disconnect(flowID: FlowID) async
}

extension WebSocketComposeService: TrafficWebSocketComposing {}

extension WebSocketFrameEventBus: TrafficWebSocketFrameEventStreaming {
    func makeWebSocketFrameStream() async -> AsyncStream<CapturedWebSocketFrame> {
        frames()
    }
}

protocol TrafficServerSentEventLoading: Sendable {
    func listServerSentEvents(for flowID: FlowID) async throws -> [CapturedServerSentEvent]
}

protocol TrafficServerSentEventEventStreaming: Sendable {
    func makeServerSentEventStream() async -> AsyncStream<CapturedServerSentEvent>
}

extension ServerSentEventEventBus: TrafficServerSentEventEventStreaming {
    func makeServerSentEventStream() async -> AsyncStream<CapturedServerSentEvent> {
        events()
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

struct TrafficWebSocketReconnectDraft: Equatable, Sendable {
    let urlText: String
    let headersText: String
    let payloadEncoding: WebSocketComposePayloadEncoding
    let payload: String
    let payloadStatusMessage: String?
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

private enum WebSocketMessagePayloadLoadingError: Error, LocalizedError {
    case exceedsInputLimit

    var errorDescription: String? {
        switch self {
        case .exceedsInputLimit:
            "WebSocket reconstruction exceeds the input limit. Use Hex to inspect the selected frame."
        }
    }
}

@MainActor
final class TrafficConsoleViewModel: ObservableObject {
    @Published private(set) var snapshot = TrafficConsoleSnapshot.initial

    private let captureController: any TrafficCaptureControlling
    private let eventSource: any TrafficFlowEventStreaming
    private let bodyReader: any TrafficBodyReading
    private let webSocketFrameLoader: (any TrafficWebSocketFrameLoading)?
    private let webSocketFrameEventSource: (any TrafficWebSocketFrameEventStreaming)?
    private let webSocketComposer: (any TrafficWebSocketComposing)?
    private let serverSentEventLoader: (any TrafficServerSentEventLoading)?
    private let serverSentEventEventSource: (any TrafficServerSentEventEventStreaming)?
    private let captureConfiguration: CaptureConfiguration
    private let eventBatchDelay: Duration
    private let maximumVisibleWebSocketFrames: Int
    private let maximumWebSocketReconstructionFrames: Int
    private let maximumWebSocketReconstructionBytes: Int64
    private let maximumWebSocketSearchBytes: Int64
    private let maximumWebSocketSearchBytesPerFrame: Int64
    private let maximumVisibleServerSentEvents: Int
    private let maximumServerSentEventSearchBytes: Int64
    private let maximumServerSentEventSearchBytesPerEvent: Int64
    private let maximumServerSentEventAccumulationBytes: Int64
    private let maximumServerSentEventAccumulationBytesPerEvent: Int64
    private let maximumServerSentEventAccumulatedOutputBytes: Int
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
    private let protobufDescriptorStore: any TrafficProtobufDescriptorStoring
    private let reverseProxyRouteStore: any TrafficReverseProxyRouteStoring
    private let socks5ListenerStore: any TrafficSOCKS5ListenerStoring
    private let externalHTTPProxyStore: any TrafficExternalHTTPProxyStoring
    private let externalHTTPProxyCredentialStore: (any ExternalHTTPProxyCredentialStoring)?
    private let customFilterPresetStore: any TrafficCustomFilterPresetStoring
    private let sslProxyingStore: any TrafficSSLProxyingStoring
    private let tlsInterceptionPolicySink: MutableTLSInterceptionPolicy?

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
    private var breakpointPresentationTask: Task<Void, Never>?
    private var webSocketFrameEventTask: Task<Void, Never>?
    private var webSocketFrameTask: Task<Void, Never>?
    private var webSocketPayloadTask: Task<Void, Never>?
    private var webSocketSearchTask: Task<Void, Never>?
    private var webSocketComposeTask: Task<Void, Never>?
    private var serverSentEventEventTask: Task<Void, Never>?
    private var serverSentEventTask: Task<Void, Never>?
    private var serverSentEventPayloadTask: Task<Void, Never>?
    private var serverSentEventSearchTask: Task<Void, Never>?
    private var serverSentEventAccumulationTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var currentWebSocketFrames: [CapturedWebSocketFrame] = []
    private var currentWebSocketReconstructionFrames: [CapturedWebSocketFrame] = []
    private var omittedWebSocketFrameCount = 0
    private var webSocketDirectionFilter: TrafficWebSocketDirectionFilter = .all
    private var webSocketPayloadMode: TrafficWebSocketPayloadMode = .automatic
    private var preferredWebSocketFrameID: UUID?
    private var webSocketSearchText = ""
    private var webSocketSearchMatchIDs: Set<UUID>?
    private var skippedLargeWebSocketSearchPayloadCount = 0
    private var currentServerSentEvents: [CapturedServerSentEvent] = []
    private var omittedServerSentEventCount = 0
    private var serverSentEventSearchText = ""
    private var serverSentEventSearchMatchIDs: Set<UUID>?
    private var skippedLargeServerSentEventSearchPayloadCount = 0
    private var protobufCatalog: ProtobufSchemaCatalog?
    private var protobufDescriptorName: String?
    private var requestProtobufMessageType: String?
    private var responseProtobufMessageType: String?

    init(
        captureController: any TrafficCaptureControlling,
        eventSource: any TrafficFlowEventStreaming,
        bodyReader: any TrafficBodyReading,
        captureConfiguration: CaptureConfiguration,
        eventBatchDelay: Duration = .milliseconds(40),
        webSocketFrameLoader: (any TrafficWebSocketFrameLoading)? = nil,
        webSocketFrameEventSource: (any TrafficWebSocketFrameEventStreaming)? = nil,
        webSocketComposer: (any TrafficWebSocketComposing)? = nil,
        serverSentEventLoader: (any TrafficServerSentEventLoading)? = nil,
        serverSentEventEventSource: (any TrafficServerSentEventEventStreaming)? = nil,
        maximumVisibleWebSocketFrames: Int = 500,
        maximumWebSocketReconstructionFrames: Int = 10_000,
        maximumWebSocketReconstructionBytes: Int64 = 8 * 1_024 * 1_024,
        maximumWebSocketSearchBytes: Int64 = 8 * 1_024 * 1_024,
        maximumWebSocketSearchBytesPerFrame: Int64 = 256 * 1_024,
        maximumVisibleServerSentEvents: Int = 500,
        maximumServerSentEventSearchBytes: Int64 = 8 * 1_024 * 1_024,
        maximumServerSentEventSearchBytesPerEvent: Int64 = 256 * 1_024,
        maximumServerSentEventAccumulationBytes: Int64 = 8 * 1_024 * 1_024,
        maximumServerSentEventAccumulationBytesPerEvent: Int64 = 256 * 1_024,
        maximumServerSentEventAccumulatedOutputBytes: Int = 1_024 * 1_024,
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
        pinnedDomainsStore: any TrafficPinnedDomainsStoring = InMemoryTrafficPinnedDomainsStore(),
        protobufDescriptorStore: any TrafficProtobufDescriptorStoring =
            InMemoryTrafficProtobufDescriptorStore(),
        reverseProxyRouteStore: any TrafficReverseProxyRouteStoring =
            InMemoryTrafficReverseProxyRouteStore(),
        socks5ListenerStore: any TrafficSOCKS5ListenerStoring =
            InMemoryTrafficSOCKS5ListenerStore(),
        externalHTTPProxyStore: any TrafficExternalHTTPProxyStoring =
            InMemoryTrafficExternalHTTPProxyStore(),
        externalHTTPProxyCredentialStore: (any ExternalHTTPProxyCredentialStoring)? = nil,
        customFilterPresetStore: any TrafficCustomFilterPresetStoring =
            InMemoryTrafficCustomFilterPresetStore(),
        sslProxyingStore: any TrafficSSLProxyingStoring = InMemoryTrafficSSLProxyingStore(),
        tlsInterceptionPolicySink: MutableTLSInterceptionPolicy? = nil
    ) {
        self.captureController = captureController
        self.eventSource = eventSource
        self.bodyReader = bodyReader
        self.webSocketFrameLoader = webSocketFrameLoader
        self.webSocketFrameEventSource = webSocketFrameEventSource
        self.webSocketComposer = webSocketComposer
        self.serverSentEventLoader = serverSentEventLoader
        self.serverSentEventEventSource = serverSentEventEventSource
        self.captureConfiguration = captureConfiguration
        self.eventBatchDelay = eventBatchDelay
        self.maximumVisibleWebSocketFrames = max(1, maximumVisibleWebSocketFrames)
        self.maximumWebSocketReconstructionFrames = max(
            1,
            maximumWebSocketReconstructionFrames
        )
        self.maximumWebSocketReconstructionBytes = max(
            0,
            maximumWebSocketReconstructionBytes
        )
        self.maximumWebSocketSearchBytes = max(0, maximumWebSocketSearchBytes)
        self.maximumWebSocketSearchBytesPerFrame = max(
            0,
            maximumWebSocketSearchBytesPerFrame
        )
        self.maximumVisibleServerSentEvents = max(1, maximumVisibleServerSentEvents)
        self.maximumServerSentEventSearchBytes = max(0, maximumServerSentEventSearchBytes)
        self.maximumServerSentEventSearchBytesPerEvent = max(
            0,
            maximumServerSentEventSearchBytesPerEvent
        )
        self.maximumServerSentEventAccumulationBytes = max(
            0,
            maximumServerSentEventAccumulationBytes
        )
        self.maximumServerSentEventAccumulationBytesPerEvent = max(
            0,
            maximumServerSentEventAccumulationBytesPerEvent
        )
        self.maximumServerSentEventAccumulatedOutputBytes = max(
            0,
            maximumServerSentEventAccumulatedOutputBytes
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
        self.protobufDescriptorStore = protobufDescriptorStore
        self.reverseProxyRouteStore = reverseProxyRouteStore
        self.socks5ListenerStore = socks5ListenerStore
        self.externalHTTPProxyStore = externalHTTPProxyStore
        self.externalHTTPProxyCredentialStore = externalHTTPProxyCredentialStore
        self.customFilterPresetStore = customFilterPresetStore
        self.sslProxyingStore = sslProxyingStore
        self.tlsInterceptionPolicySink = tlsInterceptionPolicySink
        for domain in pinnedDomainsStore.domains {
            store.setPinnedDomain(domain, isPinned: true)
        }
    }

    deinit {
        eventTask?.cancel()
        eventBatchTask?.cancel()
        bodyTask?.cancel()
        breakpointPresentationTask?.cancel()
        webSocketFrameEventTask?.cancel()
        webSocketFrameTask?.cancel()
        webSocketPayloadTask?.cancel()
        webSocketSearchTask?.cancel()
        webSocketComposeTask?.cancel()
        serverSentEventEventTask?.cancel()
        serverSentEventTask?.cancel()
        serverSentEventPayloadTask?.cancel()
        serverSentEventSearchTask?.cancel()
        serverSentEventAccumulationTask?.cancel()
        captureTask?.cancel()
    }

    func prepare() async {
        guard !isPrepared else {
            return
        }
        isPrepared = true
        capturePresentation = .recovering
        publishSnapshot()
        tlsInterceptionPolicySink?.replace(sslProxyingStore.policy)

        do {
            try await captureController.recoverInterruptedCapture()
            capturePresentation = .stopped
        } catch {
            capturePresentation = .failed(error.localizedDescription)
        }
        await hydrateWorkspace()
        await hydrateProtobufDescriptor()
        await refreshCertificateTrust()
        publishSnapshot()
        subscribeToFlowEvents()
        subscribeToWebSocketFrameEvents()
        subscribeToServerSentEventEvents()
    }

    func importProtobufDescriptorSet(from url: URL) async throws {
        let (data, sourceName) = try await Task.detached(priority: .utility) {
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let maximumByteCount = ProtobufDescriptorSetParser.maximumByteCount
            let data = try file.read(upToCount: maximumByteCount + 1) ?? Data()
            guard data.count <= maximumByteCount else {
                throw ProtobufDescriptorSetError.exceedsByteLimit(
                    maximum: maximumByteCount
                )
            }
            return (data, url.lastPathComponent)
        }.value
        try await importProtobufDescriptorSet(data: data, sourceName: sourceName)
    }

    func importProtobufDescriptorSet(data: Data, sourceName: String) async throws {
        let catalog = try await Task.detached(priority: .utility) {
            try ProtobufDescriptorSetParser.parse(data)
        }.value
        let normalizedName = URL(fileURLWithPath: sourceName).lastPathComponent
        let displayName = normalizedName.isEmpty ? "Descriptor.desc" : normalizedName
        try await protobufDescriptorStore.saveDescriptor(
            data: data,
            sourceName: displayName
        )

        protobufCatalog = catalog
        protobufDescriptorName = displayName
        requestProtobufMessageType = nil
        responseProtobufMessageType = nil
        refreshInspection(preservingWebSocketSelection: true)
    }

    func selectProtobufMessageType(
        _ messageType: String?,
        direction: TrafficMessageDirection
    ) async throws {
        if let messageType, protobufCatalog?.message(named: messageType) == nil {
            throw ProxyLensError.unsupportedOperation(
                "The imported descriptor does not contain message type \(messageType)"
            )
        }

        let requestType = direction == .request ? messageType : requestProtobufMessageType
        let responseType = direction == .response ? messageType : responseProtobufMessageType
        try await protobufDescriptorStore.saveSelections(
            requestMessageType: requestType,
            responseMessageType: responseType
        )
        requestProtobufMessageType = requestType
        responseProtobufMessageType = responseType
        refreshInspection(preservingWebSocketSelection: true)
    }

    private func hydrateProtobufDescriptor() async {
        do {
            guard let stored = try await protobufDescriptorStore.load() else {
                return
            }
            let catalog = try await Task.detached(priority: .utility) {
                try ProtobufDescriptorSetParser.parse(stored.data)
            }.value
            protobufCatalog = catalog
            protobufDescriptorName = stored.sourceName
            requestProtobufMessageType = Self.validMessageType(
                stored.requestMessageType,
                in: catalog
            )
            responseProtobufMessageType = Self.validMessageType(
                stored.responseMessageType,
                in: catalog
            )
        } catch {
            workspaceWarning =
                "Could not restore the Protobuf descriptor: \(error.localizedDescription)"
        }
    }

    nonisolated private static func validMessageType(
        _ messageType: String?,
        in catalog: ProtobufSchemaCatalog
    ) -> String? {
        guard let messageType, catalog.message(named: messageType) != nil else {
            return nil
        }
        return messageType
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
            breakpointPresentationTask?.cancel()
            webSocketFrameTask?.cancel()
            webSocketPayloadTask?.cancel()
            webSocketComposeTask?.cancel()
            serverSentEventTask?.cancel()
            serverSentEventPayloadTask?.cancel()
            serverSentEventSearchTask?.cancel()
            serverSentEventAccumulationTask?.cancel()
            currentWebSocketFrames.removeAll(keepingCapacity: true)
            currentWebSocketReconstructionFrames.removeAll(keepingCapacity: true)
            omittedWebSocketFrameCount = 0
            currentServerSentEvents.removeAll(keepingCapacity: true)
            omittedServerSentEventCount = 0
            inspection = .empty
        }
        publishSnapshot()
    }

    func setPinnedDomain(_ host: String, isPinned: Bool) {
        store.setPinnedDomain(host, isPinned: isPinned)
        pinnedDomainsStore.save(store.pinnedDomainHosts)
        publishSnapshot()
    }

    var canEditListenerConfiguration: Bool {
        switch capturePresentation {
        case .stopped, .failed:
            true
        case .recovering, .starting, .running, .stopping:
            false
        }
    }

    var canEditReverseProxyRoutes: Bool { canEditListenerConfiguration }

    func currentSOCKS5ListenerConfiguration() -> SOCKS5ListenerConfiguration {
        socks5ListenerStore.configuration
    }

    func saveSOCKS5ListenerConfiguration(
        _ configuration: SOCKS5ListenerConfiguration
    ) throws {
        guard canEditListenerConfiguration else {
            throw TrafficSOCKS5ListenerStoreError.captureMustBeStopped
        }
        _ = try captureConfiguration(
            with: reverseProxyRouteStore.routes,
            socks5Listener: configuration
        )
        try socks5ListenerStore.save(configuration)
    }

    func currentExternalHTTPProxyConfiguration() -> ExternalHTTPProxyConfiguration {
        externalHTTPProxyStore.configuration
    }

    func saveExternalHTTPProxyConfiguration(
        _ configuration: ExternalHTTPProxyConfiguration,
        password: String
    ) async throws {
        guard canEditListenerConfiguration else {
            throw TrafficExternalHTTPProxyStoreError.captureMustBeStopped
        }
        _ = try captureConfiguration(
            with: reverseProxyRouteStore.routes,
            externalHTTPProxy: configuration
        )
        let previous = externalHTTPProxyStore.configuration
        guard let externalHTTPProxyCredentialStore else {
            if configuration.username != nil || previous.username != nil {
                throw TrafficExternalHTTPProxyStoreError.credentialStoreUnavailable
            }
            try externalHTTPProxyStore.save(configuration)
            return
        }

        if let username = configuration.username {
            let credentials: ExternalHTTPProxyCredentials
            if !password.isEmpty {
                credentials = try ExternalHTTPProxyCredentials(
                    username: username,
                    password: password
                )
            } else if let existing = try await externalHTTPProxyCredentialStore.credentials(
                for: previous.endpoint,
                username: username
            ) {
                credentials = existing
            } else {
                throw TrafficExternalHTTPProxyStoreError.credentialsRequired
            }
            try await externalHTTPProxyCredentialStore.save(
                credentials,
                for: configuration.endpoint
            )
            if previous.endpoint != configuration.endpoint {
                try await externalHTTPProxyCredentialStore.removeCredentials(
                    for: previous.endpoint
                )
            }
        } else {
            try await externalHTTPProxyCredentialStore.removeCredentials(
                for: previous.endpoint
            )
            if previous.endpoint != configuration.endpoint {
                try await externalHTTPProxyCredentialStore.removeCredentials(
                    for: configuration.endpoint
                )
            }
        }
        try externalHTTPProxyStore.save(configuration)
    }

    func clearExternalHTTPProxyCredentials() async throws {
        guard canEditListenerConfiguration else {
            throw TrafficExternalHTTPProxyStoreError.captureMustBeStopped
        }
        guard let externalHTTPProxyCredentialStore else {
            throw TrafficExternalHTTPProxyStoreError.credentialStoreUnavailable
        }
        let current = externalHTTPProxyStore.configuration
        try await externalHTTPProxyCredentialStore.removeCredentials(for: current.endpoint)
        let updated = try ExternalHTTPProxyConfiguration(
            endpoint: current.endpoint,
            bypassHosts: current.bypassHosts,
            username: nil,
            isEnabled: current.isEnabled
        )
        try externalHTTPProxyStore.save(updated)
    }

    func currentReverseProxyRoutes() -> [ReverseProxyRoute] {
        reverseProxyRouteStore.routes
    }

    func saveReverseProxyRoute(_ route: ReverseProxyRoute) throws {
        try requireStoppedCaptureForReverseProxyChanges()
        var routes = reverseProxyRouteStore.routes
        if let index = routes.firstIndex(where: { $0.id == route.id }) {
            routes[index] = route
        } else {
            routes.append(route)
        }
        _ = try captureConfiguration(with: routes)
        try reverseProxyRouteStore.save(route)
    }

    func removeReverseProxyRoute(id: UUID) throws {
        try requireStoppedCaptureForReverseProxyChanges()
        reverseProxyRouteStore.remove(id: id)
    }

    func setReverseProxyRouteEnabled(id: UUID, isEnabled: Bool) throws {
        try requireStoppedCaptureForReverseProxyChanges()
        guard let route = reverseProxyRouteStore.routes.first(where: { $0.id == id }) else {
            return
        }
        try saveReverseProxyRoute(
            ReverseProxyRoute(
                id: route.id,
                name: route.name,
                listenEndpoint: route.listenEndpoint,
                upstreamURL: route.upstreamURL,
                isEnabled: isEnabled
            )
        )
    }

    private func requireStoppedCaptureForReverseProxyChanges() throws {
        guard canEditReverseProxyRoutes else {
            throw TrafficReverseProxyRouteStoreError.captureMustBeStopped
        }
    }

    private func captureConfiguration(
        with reverseProxyRoutes: [ReverseProxyRoute],
        socks5Listener: SOCKS5ListenerConfiguration? = nil,
        externalHTTPProxy: ExternalHTTPProxyConfiguration? = nil
    ) throws -> CaptureConfiguration {
        let proxy = ProxyConfiguration(
            listenEndpoint: captureConfiguration.proxy.listenEndpoint,
            interceptHTTPS: captureConfiguration.proxy.interceptHTTPS,
            reverseProxyRoutes: reverseProxyRoutes,
            socks5Listener: socks5Listener ?? socks5ListenerStore.configuration,
            externalHTTPProxy: externalHTTPProxy ?? externalHTTPProxyStore.configuration
        )
        try proxy.validateListeners()
        return CaptureConfiguration(
            proxy: proxy,
            configuresSystemProxy: captureConfiguration.configuresSystemProxy,
            bypassDomains: captureConfiguration.bypassDomains
        )
    }

    // SSL proxying list edits apply live, while capture is running — unlike the reverse
    // proxy and listener settings above, there is no stopped-capture guard here.

    func currentTLSInterceptionPolicy() -> TLSInterceptionPolicy {
        sslProxyingStore.policy
    }

    /// Persists first and only publishes to the live capture policy on success, so a
    /// rejected save (e.g. an oversized document) can never leave the running engine
    /// out of sync with what is actually on disk.
    func saveTLSInterceptionPolicy(_ policy: TLSInterceptionPolicy) throws {
        try sslProxyingStore.save(policy)
        tlsInterceptionPolicySink?.replace(policy)
    }

    func setTLSInterceptionMode(_ mode: TLSInterceptionMode) throws {
        let current = sslProxyingStore.policy
        try saveTLSInterceptionPolicy(
            try TLSInterceptionPolicy(mode: mode, entries: current.entries)
        )
    }

    func excludeHostFromTLSInterception(_ host: String) throws {
        let current = sslProxyingStore.policy
        switch current.mode {
        case .interceptAllExcept:
            guard !current.matches(host: host) else { return }
            try saveTLSInterceptionPolicy(
                try TLSInterceptionPolicy(mode: current.mode, entries: current.entries + [host])
            )
        case .interceptOnly:
            let normalizedHost = normalizedHostForTLSInterceptionComparison(host)
            let filteredEntries = current.entries.filter {
                $0.caseInsensitiveCompare(normalizedHost) != .orderedSame
            }
            guard filteredEntries.count != current.entries.count else { return }
            try saveTLSInterceptionPolicy(
                try TLSInterceptionPolicy(mode: current.mode, entries: filteredEntries)
            )
        }
    }

    func interceptHostAgain(_ host: String) throws {
        let current = sslProxyingStore.policy
        switch current.mode {
        case .interceptAllExcept:
            let normalizedHost = normalizedHostForTLSInterceptionComparison(host)
            let filteredEntries = current.entries.filter {
                $0.caseInsensitiveCompare(normalizedHost) != .orderedSame
            }
            guard filteredEntries.count != current.entries.count else { return }
            try saveTLSInterceptionPolicy(
                try TLSInterceptionPolicy(mode: current.mode, entries: filteredEntries)
            )
        case .interceptOnly:
            guard !current.matches(host: host) else { return }
            try saveTLSInterceptionPolicy(
                try TLSInterceptionPolicy(mode: current.mode, entries: current.entries + [host])
            )
        }
    }

    func isHostIntercepted(_ host: String) -> Bool {
        sslProxyingStore.policy.shouldIntercept(host: host)
    }

    func hasExactTLSInterceptionEntry(_ host: String) -> Bool {
        let normalizedHost = normalizedHostForTLSInterceptionComparison(host)
        return sslProxyingStore.policy.entries.contains {
            $0.caseInsensitiveCompare(normalizedHost) == .orderedSame
        }
    }

    /// Mirrors only the trim/lowercase/de-bracket steps of `TLSInterceptionPolicy`'s
    /// internal host normalization (not visible outside `ProxyLensCore`), not its
    /// trailing-dot handling: unlike `TLSInterceptionPolicy.matches(host:)`, this does
    /// not strip a single trailing dot, so `"api.example.com."` compares unequal to a
    /// stored `"api.example.com"` entry here even though the two match as a policy. This
    /// is benign for its callers (`excludeHostFromTLSInterception`, `interceptHostAgain`,
    /// `hasExactTLSInterceptionEntry`), but for two different reasons depending on which
    /// branch a trailing-dot host reaches: where this comparison is the only thing
    /// guarding a "remove one host from a wildcard-covered exclusion/inclusion" edit
    /// (interceptOnly's "Don't Intercept", interceptAllExcept's "Intercept"), the mismatch
    /// falls through to the no-op guard already in place for "no matching entry," which is
    /// also what disables that context-menu item. Where the mode itself already permits
    /// the edit (interceptAllExcept's "Don't Intercept", interceptOnly's "Intercept" for an
    /// unlisted host), the item stays enabled and the edit succeeds anyway, because
    /// `TLSInterceptionPolicy.init` normalizes the trailing dot away when the new entry is
    /// actually stored — this helper never enters into that path. This also does not
    /// reproduce full validation — entries reaching this comparison are already valid,
    /// having been normalized and checked when they were saved.
    private func normalizedHostForTLSInterceptionComparison(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        return normalized
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
            breakpointPresentationTask?.cancel()
            webSocketFrameTask?.cancel()
            webSocketPayloadTask?.cancel()
            webSocketComposeTask?.cancel()
            serverSentEventTask?.cancel()
            serverSentEventPayloadTask?.cancel()
            serverSentEventSearchTask?.cancel()
            serverSentEventAccumulationTask?.cancel()
            currentWebSocketFrames.removeAll(keepingCapacity: true)
            currentWebSocketReconstructionFrames.removeAll(keepingCapacity: true)
            omittedWebSocketFrameCount = 0
            currentServerSentEvents.removeAll(keepingCapacity: true)
            omittedServerSentEventCount = 0
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

    var customFilterPresets: [TrafficCustomFilterPreset] {
        customFilterPresetStore.presets
    }

    var matchingCustomFilterPreset: TrafficCustomFilterPreset? {
        customFilterPresetStore.presets.first { $0.filter == store.displayFilter }
    }

    @discardableResult
    func saveCustomFilterPreset(named name: String) throws -> TrafficCustomFilterPreset {
        let preset = try customFilterPresetStore.save(name: name, filter: store.displayFilter)
        publishSnapshot()
        return preset
    }

    func applyCustomFilterPreset(id: UUID) throws {
        guard let preset = customFilterPresetStore.presets.first(where: { $0.id == id }) else {
            throw TrafficCustomFilterPresetError.presetNotFound
        }
        updateDisplayFilter { $0 = preset.filter }
    }

    @discardableResult
    func renameCustomFilterPreset(id: UUID, name: String) throws -> TrafficCustomFilterPreset {
        let preset = try customFilterPresetStore.rename(id: id, name: name)
        publishSnapshot()
        return preset
    }

    func removeCustomFilterPreset(id: UUID) {
        customFilterPresetStore.remove(id: id)
        publishSnapshot()
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

    func dnsSpoof(host: String, address: String) async throws {
        guard let ruleEngine else {
            return
        }
        try await ruleEngine.dnsSpoof(host: host, address: address)
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

    func writeServerSentEvents(flowID: FlowID, to fileURL: URL) async throws {
        guard let exportService else {
            throw ProxyLensError.unsupportedOperation("Export is not available")
        }
        guard let serverSentEventLoader else {
            throw ProxyLensError.unsupportedOperation(
                "Server-Sent Event history is not available"
            )
        }
        guard let flow = store.flow(id: flowID) else {
            throw ProxyLensError.unsupportedOperation("The flow is no longer available")
        }
        guard Self.isServerSentEventStream(flow) else {
            throw ProxyLensError.unsupportedOperation(
                "The selected flow is not a Server-Sent Event stream"
            )
        }

        let events = try await serverSentEventLoader.listServerSentEvents(for: flowID)
        try await exportService.writeServerSentEvents(events, for: flowID, to: fileURL)
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
        store.apply([
            replayedFlow.state.isTerminal
                ? .finished(replayedFlow)
                : .updated(replayedFlow)
        ])
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
        breakpointPresentationTask?.cancel()
        webSocketFrameTask?.cancel()
        webSocketPayloadTask?.cancel()
        webSocketSearchTask?.cancel()
        webSocketComposeTask?.cancel()
        serverSentEventTask?.cancel()
        serverSentEventPayloadTask?.cancel()
        serverSentEventSearchTask?.cancel()
        serverSentEventAccumulationTask?.cancel()
        currentWebSocketFrames.removeAll(keepingCapacity: true)
        currentWebSocketReconstructionFrames.removeAll(keepingCapacity: true)
        omittedWebSocketFrameCount = 0
        webSocketDirectionFilter = .all
        webSocketSearchText = ""
        webSocketSearchMatchIDs = nil
        skippedLargeWebSocketSearchPayloadCount = 0
        currentServerSentEvents.removeAll(keepingCapacity: true)
        omittedServerSentEventCount = 0
        serverSentEventSearchText = ""
        serverSentEventSearchMatchIDs = nil
        skippedLargeServerSentEventSearchPayloadCount = 0
        inspection = .empty
        workspaceWarning = nil
        publishSnapshot()
    }

    func continueBreakpoint(
        headersText: String,
        bodyText: String?,
        webSocketPayloadText: String? = nil
    ) async throws {
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
        case .webSocketResponse:
            guard let originalFrame = hit.webSocketFrame else {
                throw ProxyLensError.unsupportedOperation(
                    "The paused WebSocket response frame is unavailable"
                )
            }
            let decidedFrame: WebSocketBreakpointFrame
            if originalFrame.canEditPayload, let webSocketPayloadText {
                decidedFrame = try originalFrame.replacingPayload(Data(webSocketPayloadText.utf8))
            } else {
                decidedFrame = originalFrame
            }
            await coordinator.resume(
                flowID: hit.flowID,
                decision: .continue(
                    BreakpointHit(
                        flowID: hit.flowID,
                        phase: .webSocketResponse,
                        request: hit.request,
                        response: hit.response,
                        webSocketFrame: decidedFrame
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
            breakpointPresentationTask?.cancel()
            webSocketFrameTask?.cancel()
            webSocketPayloadTask?.cancel()
            webSocketComposeTask?.cancel()
            serverSentEventTask?.cancel()
            serverSentEventPayloadTask?.cancel()
            serverSentEventSearchTask?.cancel()
            serverSentEventAccumulationTask?.cancel()
            currentWebSocketFrames.removeAll(keepingCapacity: true)
            currentWebSocketReconstructionFrames.removeAll(keepingCapacity: true)
            omittedWebSocketFrameCount = 0
            currentServerSentEvents.removeAll(keepingCapacity: true)
            omittedServerSentEventCount = 0
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

    private func subscribeToServerSentEventEvents() {
        guard serverSentEventEventTask == nil, let serverSentEventEventSource else {
            return
        }
        serverSentEventEventTask = Task { [weak self] in
            let stream = await serverSentEventEventSource.makeServerSentEventStream()
            for await event in stream {
                guard !Task.isCancelled else {
                    return
                }
                self?.receiveServerSentEvent(event)
            }
        }
    }

    private func startCapture() async {
        capturePresentation = .starting
        publishSnapshot()
        do {
            let configuration = try captureConfiguration(
                with: reverseProxyRouteStore.routes
            )
            let context = try await captureController.start(configuration: configuration)
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

    private func refreshInspection(preservingWebSocketSelection: Bool = false) {
        if preservingWebSocketSelection {
            preferredWebSocketFrameID = inspection.webSocket?.selectedFrameID
        } else {
            preferredWebSocketFrameID = nil
            webSocketPayloadMode = .automatic
        }
        bodyTask?.cancel()
        breakpointPresentationTask?.cancel()
        webSocketFrameTask?.cancel()
        webSocketPayloadTask?.cancel()
        webSocketSearchTask?.cancel()
        webSocketComposeTask?.cancel()
        serverSentEventTask?.cancel()
        serverSentEventPayloadTask?.cancel()
        serverSentEventSearchTask?.cancel()
        serverSentEventAccumulationTask?.cancel()
        currentWebSocketFrames.removeAll(keepingCapacity: true)
        currentWebSocketReconstructionFrames.removeAll(keepingCapacity: true)
        omittedWebSocketFrameCount = 0
        webSocketDirectionFilter = .all
        webSocketSearchText = ""
        webSocketSearchMatchIDs = nil
        skippedLargeWebSocketSearchPayloadCount = 0
        currentServerSentEvents.removeAll(keepingCapacity: true)
        omittedServerSentEventCount = 0
        serverSentEventSearchText = ""
        serverSentEventSearchMatchIDs = nil
        skippedLargeServerSentEventSearchPayloadCount = 0
        guard let flow = store.selectedFlow else {
            inspection = .empty
            publishSnapshot()
            return
        }

        let requestProtobufSchema = protobufMessageSchema(for: .request)
        let responseProtobufSchema = protobufMessageSchema(for: .response)
        let loadedProtobufCatalog = protobufCatalog
        inspection = Self.initialInspection(
            for: flow,
            requestProtobufInspection: protobufSchemaInspection(for: .request),
            responseProtobufInspection: protobufSchemaInspection(for: .response)
        )
        publishSnapshot()
        refreshBreakpointPresentation(for: flow)

        let bodyReader = bodyReader
        bodyTask = Task { [weak self] in
            async let requestBodies = Self.loadBodies(
                flow.request.body,
                grpcEncoding: flow.request.headers.firstValue(for: "grpc-encoding"),
                protobufSchema: requestProtobufSchema,
                protobufCatalog: loadedProtobufCatalog,
                reader: bodyReader
            )
            async let responseBodies = Self.loadBodies(
                flow.response?.body,
                grpcEncoding: flow.response?.headers.firstValue(for: "grpc-encoding"),
                protobufSchema: responseProtobufSchema,
                protobufCatalog: loadedProtobufCatalog,
                reader: bodyReader
            )
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
        refreshWebSocketComposeAvailability(for: flow)
        refreshServerSentEvents(for: flow)
    }

    private func protobufSchemaInspection(
        for direction: TrafficMessageDirection
    ) -> TrafficProtobufSchemaInspection {
        TrafficProtobufSchemaInspection(
            descriptorName: protobufDescriptorName,
            messageTypeNames: protobufCatalog?.messageTypeNames ?? [],
            selectedMessageType: direction == .request
                ? requestProtobufMessageType
                : responseProtobufMessageType
        )
    }

    private func protobufMessageSchema(
        for direction: TrafficMessageDirection
    ) -> ProtobufMessageSchema? {
        let messageType =
            direction == .request
            ? requestProtobufMessageType
            : responseProtobufMessageType
        guard let messageType else {
            return nil
        }
        return protobufCatalog?.message(named: messageType)
    }

    func sendWebSocketMessage(
        direction: WebSocketFrameDirection,
        payloadEncoding: WebSocketComposePayloadEncoding,
        payload: String
    ) async throws {
        guard let flow = store.selectedFlow, Self.isWebSocket(flow) else {
            throw ProxyLensError.unsupportedOperation(
                "Select a WebSocket flow before composing a message"
            )
        }
        guard inspection.webSocket?.canCompose == true, let webSocketComposer else {
            throw ProxyLensError.unsupportedOperation(
                "The selected WebSocket connection is no longer open"
            )
        }
        try await webSocketComposer.send(
            WebSocketComposeRequest(
                flowID: flow.id,
                direction: direction,
                payloadEncoding: payloadEncoding,
                payload: payload
            )
        )
        refreshWebSocketComposeAvailability(for: flow)
    }

    func webSocketReconnectDraft() async throws -> TrafficWebSocketReconnectDraft {
        guard let flow = store.selectedFlow, Self.isWebSocket(flow) else {
            throw ProxyLensError.unsupportedOperation(
                "Select a WebSocket flow before reconnecting"
            )
        }

        let urlText = Self.webSocketURL(for: flow).absoluteString
        let headersText = flow.request.headers
            .map { "\($0.name): \($0.value)" }
            .joined(separator: "\n")
        guard let selectedFrameID = inspection.webSocket?.selectedFrameID,
            let selectedFrame = currentWebSocketReconstructionFrames.first(where: {
                $0.id == selectedFrameID
            }),
            Self.isWebSocketDataFrame(selectedFrame.opcode)
        else {
            return TrafficWebSocketReconnectDraft(
                urlText: urlText,
                headersText: headersText,
                payloadEncoding: .text,
                payload: "",
                payloadStatusMessage:
                    "Select a complete text or binary message to prefill a replay payload."
            )
        }

        let inputs = try await Self.loadWebSocketMessageInputs(
            currentWebSocketReconstructionFrames,
            direction: selectedFrame.direction,
            reader: bodyReader,
            maximumByteCount: maximumWebSocketReconstructionBytes
        )
        let result = WebSocketMessageDecoder.decode(
            selectedFrameID: selectedFrameID,
            frames: inputs,
            acceptedExtensions: acceptedWebSocketExtensions(),
            limits: WebSocketMessageDecoder.Limits(
                maximumFrameCount: currentWebSocketReconstructionFrames.count,
                maximumInputByteCount: Int(
                    min(maximumWebSocketReconstructionBytes, Int64(Int.max))
                ),
                maximumMessageOutputByteCount: WebSocketComposeService.defaultMaximumPayloadBytes,
                maximumHistoryOutputByteCount: Int(
                    min(maximumWebSocketReconstructionBytes, Int64(Int.max))
                )
            )
        )
        guard case .decoded(let message) = result else {
            let reason: String
            if case .unavailable(let unavailableReason) = result {
                reason = unavailableReason
            } else {
                reason = "The selected WebSocket message is unavailable."
            }
            return TrafficWebSocketReconnectDraft(
                urlText: urlText,
                headersText: headersText,
                payloadEncoding: .text,
                payload: "",
                payloadStatusMessage: reason
            )
        }

        switch message.opcode {
        case .text:
            guard let payload = String(data: message.payload, encoding: .utf8) else {
                return TrafficWebSocketReconnectDraft(
                    urlText: urlText,
                    headersText: headersText,
                    payloadEncoding: .text,
                    payload: "",
                    payloadStatusMessage: "The selected text message is not valid UTF-8."
                )
            }
            return TrafficWebSocketReconnectDraft(
                urlText: urlText,
                headersText: headersText,
                payloadEncoding: .text,
                payload: payload,
                payloadStatusMessage: "Prefilled from the selected complete text message."
            )
        case .binary:
            return TrafficWebSocketReconnectDraft(
                urlText: urlText,
                headersText: headersText,
                payloadEncoding: .base64,
                payload: message.payload.base64EncodedString(),
                payloadStatusMessage: "Prefilled from the selected complete binary message."
            )
        case .continuation, .close, .ping, .pong, .unknown:
            return TrafficWebSocketReconnectDraft(
                urlText: urlText,
                headersText: headersText,
                payloadEncoding: .text,
                payload: "",
                payloadStatusMessage: "The selected WebSocket message cannot be replayed."
            )
        }
    }

    @discardableResult
    func reconnectWebSocket(
        urlText: String,
        headersText: String,
        payloadEncoding: WebSocketComposePayloadEncoding,
        payload: String,
        replayPayload: Bool
    ) async throws -> FlowID {
        guard let originalFlow = store.selectedFlow, Self.isWebSocket(originalFlow) else {
            throw ProxyLensError.unsupportedOperation(
                "Select a WebSocket flow before reconnecting"
            )
        }
        guard let webSocketComposer else {
            throw WebSocketReconnectError.unavailable
        }
        guard
            let url = URL(
                string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        else {
            throw WebSocketReconnectError.invalidURL
        }
        let headers = try Self.parseWebSocketHeaders(headersText)
        let replay =
            replayPayload
            ? WebSocketReplayPayload(encoding: payloadEncoding, payload: payload)
            : nil
        let replayedFlow = try await webSocketComposer.reconnect(
            WebSocketReconnectRequest(url: url, headers: headers, replayPayload: replay),
            sessionID: originalFlow.sessionID
        )
        applyReplayedFlow(replayedFlow)
        return replayedFlow.id
    }

    func disconnectSelectedWebSocket() async throws {
        guard let flow = store.selectedFlow, Self.isWebSocket(flow),
            flow.source.kind == .replay,
            inspection.webSocket?.canDisconnect == true,
            let webSocketComposer
        else {
            throw ProxyLensError.unsupportedOperation(
                "Select a live replay WebSocket before disconnecting"
            )
        }
        await webSocketComposer.disconnect(flowID: flow.id)
        updateWebSocketComposeAvailability(
            false,
            message: "Disconnecting this WebSocket connection…",
            for: flow.id
        )
    }

    private func refreshWebSocketComposeAvailability(for flow: Flow) {
        guard Self.isWebSocket(flow) else {
            return
        }
        webSocketComposeTask?.cancel()
        guard !flow.state.isTerminal else {
            updateWebSocketComposeAvailability(
                false,
                message: "This WebSocket connection is closed. Captured frames remain available.",
                for: flow.id
            )
            return
        }
        guard let webSocketComposer else {
            updateWebSocketComposeAvailability(
                false,
                message: "WebSocket composition is unavailable.",
                for: flow.id
            )
            return
        }

        webSocketComposeTask = Task { [weak self] in
            let isOpen = await webSocketComposer.isConnectionOpen(for: flow.id)
            guard !Task.isCancelled, self?.store.selectedFlowID == flow.id else {
                return
            }
            self?.updateWebSocketComposeAvailability(
                isOpen,
                message: isOpen
                    ? nil
                    : "This WebSocket connection is closed. Captured frames remain available.",
                for: flow.id
            )
        }
    }

    private func updateWebSocketComposeAvailability(
        _ canCompose: Bool,
        message: String?,
        for flowID: FlowID
    ) {
        guard let webSocket = inspection.webSocket else {
            return
        }
        replaceWebSocketInspection(
            TrafficWebSocketInspection(
                frames: webSocket.frames,
                capturedFrameCount: webSocket.capturedFrameCount,
                selectedFrameID: webSocket.selectedFrameID,
                payload: webSocket.payload,
                payloadSyntax: webSocket.payloadSyntax,
                payloadMode: webSocket.payloadMode,
                canDecodePayloadAsProtobuf: webSocket.canDecodePayloadAsProtobuf,
                omittedFrameCount: webSocket.omittedFrameCount,
                statusMessage: webSocket.statusMessage,
                directionFilter: webSocket.directionFilter,
                searchText: webSocket.searchText,
                isSearching: webSocket.isSearching,
                canCompose: canCompose,
                canReconnect: !canCompose && webSocketComposer != nil,
                canDisconnect: canCompose && store.flow(id: flowID)?.source.kind == .replay,
                composeStatusMessage: message
            ),
            for: flowID
        )
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
        let orderedFrames = Self.orderedUniqueWebSocketFrames(
            frames + currentWebSocketReconstructionFrames
        )
        omittedWebSocketFrameCount = max(0, orderedFrames.count - maximumVisibleWebSocketFrames)
        currentWebSocketReconstructionFrames = Array(
            orderedFrames.suffix(maximumWebSocketReconstructionFrames)
        )
        currentWebSocketFrames = Array(orderedFrames.suffix(maximumVisibleWebSocketFrames))
        refreshWebSocketFramePresentation(for: flowID)
    }

    private func receiveWebSocketFrame(_ frame: CapturedWebSocketFrame) {
        guard inspection.flowID == frame.flowID, inspection.webSocket != nil else {
            return
        }
        guard !currentWebSocketReconstructionFrames.contains(where: { $0.id == frame.id }) else {
            return
        }

        currentWebSocketReconstructionFrames.append(frame)
        currentWebSocketReconstructionFrames = Self.orderedUniqueWebSocketFrames(
            currentWebSocketReconstructionFrames
        )
        if currentWebSocketReconstructionFrames.count > maximumWebSocketReconstructionFrames {
            currentWebSocketReconstructionFrames.removeFirst(
                currentWebSocketReconstructionFrames.count
                    - maximumWebSocketReconstructionFrames
            )
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
        let preferredSelection = previous.selectedFrameID ?? preferredWebSocketFrameID
        let selectedFrameID =
            preferredSelection.flatMap { selectedID in
                visibleFrames.contains(where: { $0.id == selectedID }) ? selectedID : nil
            } ?? visibleFrames.first?.id
        preferredWebSocketFrameID = selectedFrameID
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
            payload = .loading("Loading WebSocket payload…")
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

        let acceptedExtensions = acceptedWebSocketExtensions()
        let messageOpcode = Self.webSocketMessageOpcode(
            containing: frame.id,
            frames: currentWebSocketReconstructionFrames,
            acceptedExtensions: acceptedExtensions
        )
        preferredWebSocketFrameID = frame.id
        webSocketPayloadMode = Self.normalizedWebSocketPayloadMode(
            webSocketPayloadMode,
            messageOpcode: messageOpcode
        )
        webSocketPayloadTask?.cancel()
        replaceWebSocketInspection(
            makeWebSocketInspection(
                frames: visibleWebSocketFrames(),
                selectedFrameID: frame.id,
                payload: .loading(BodyDisplayFormatter.metadata(for: frame.payload)),
                payloadSyntax: Self.loadingWebSocketPayloadSyntax(
                    mode: webSocketPayloadMode,
                    messageOpcode: messageOpcode
                ),
                isSearching: false
            ),
            for: flowID
        )

        let bodyReader = bodyReader
        let payloadMode = webSocketPayloadMode
        let protobufDirection: TrafficMessageDirection =
            frame.direction == .clientToServer ? .request : .response
        let protobufSchema = protobufMessageSchema(for: protobufDirection)
        let loadedProtobufCatalog = protobufCatalog
        let reconstructionFrames = currentWebSocketReconstructionFrames
        let maximumReconstructionBytes = maximumWebSocketReconstructionBytes
        webSocketPayloadTask = Task { [weak self] in
            do {
                let presentation:
                    (
                        body: TrafficBodyPresentation,
                        syntax: TrafficWebSocketPayloadSyntax
                    )
                if payloadMode == .hex || !Self.isWebSocketDataFrame(frame.opcode) {
                    let data = try await bodyReader.read(frame.payload)
                    guard !Task.isCancelled else {
                        return
                    }
                    presentation = await Task.detached(priority: .utility) {
                        Self.webSocketFramePayloadPresentation(
                            data,
                            frame: frame,
                            mode: payloadMode,
                            protobufSchema: protobufSchema,
                            protobufCatalog: loadedProtobufCatalog
                        )
                    }.value
                } else {
                    let inputs = try await Self.loadWebSocketMessageInputs(
                        reconstructionFrames,
                        direction: frame.direction,
                        reader: bodyReader,
                        maximumByteCount: maximumReconstructionBytes
                    )
                    guard !Task.isCancelled else {
                        return
                    }
                    presentation = await Task.detached(priority: .utility) {
                        let result = WebSocketMessageDecoder.decode(
                            selectedFrameID: frame.id,
                            frames: inputs,
                            acceptedExtensions: acceptedExtensions,
                            limits: WebSocketMessageDecoder.Limits(
                                maximumFrameCount: reconstructionFrames.count,
                                maximumInputByteCount: Int(
                                    min(maximumReconstructionBytes, Int64(Int.max))
                                )
                            )
                        )
                        return Self.webSocketMessagePayloadPresentation(
                            result,
                            mode: payloadMode,
                            protobufSchema: protobufSchema,
                            protobufCatalog: loadedProtobufCatalog
                        )
                    }.value
                }
                guard !Task.isCancelled,
                    self?.inspection.flowID == flowID,
                    self?.inspection.webSocket?.selectedFrameID == frame.id,
                    self?.webSocketPayloadMode == payloadMode
                else {
                    return
                }
                self?.applyWebSocketPayload(
                    presentation.body,
                    syntax: presentation.syntax,
                    frameID: frame.id,
                    flowID: flowID
                )
            } catch {
                guard !Task.isCancelled,
                    self?.inspection.flowID == flowID,
                    self?.inspection.webSocket?.selectedFrameID == frame.id,
                    self?.webSocketPayloadMode == payloadMode
                else {
                    return
                }
                let message =
                    error is WebSocketMessagePayloadLoadingError
                    ? error.localizedDescription
                    : "Could not load frame payload: \(error.localizedDescription)"
                self?.applyWebSocketPayload(
                    error is WebSocketMessagePayloadLoadingError
                        ? .none(message)
                        : .failed(
                            metadata: BodyDisplayFormatter.metadata(for: frame.payload),
                            message: message
                        ),
                    syntax: .plainText,
                    frameID: frame.id,
                    flowID: flowID
                )
            }
        }
    }

    func setWebSocketPayloadMode(_ mode: TrafficWebSocketPayloadMode) {
        guard let selectedFrameID = inspection.webSocket?.selectedFrameID,
            let frame = visibleWebSocketFrames().first(where: { $0.id == selectedFrameID })
        else {
            return
        }
        let messageOpcode = Self.webSocketMessageOpcode(
            containing: frame.id,
            frames: currentWebSocketReconstructionFrames,
            acceptedExtensions: acceptedWebSocketExtensions()
        )
        guard mode != .protobuf || messageOpcode == .binary else {
            return
        }
        guard mode != webSocketPayloadMode else {
            return
        }
        webSocketPayloadMode = mode
        selectWebSocketFrame(selectedFrameID)
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

    private func acceptedWebSocketExtensions() -> [String] {
        store.selectedFlow?.response?.headers.values(for: "Sec-WebSocket-Extensions") ?? []
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
            payloadMode: webSocketPayloadMode,
            canDecodePayloadAsProtobuf: selectedFrameID.flatMap { selectedID in
                Self.webSocketMessageOpcode(
                    containing: selectedID,
                    frames: currentWebSocketReconstructionFrames,
                    acceptedExtensions: acceptedWebSocketExtensions()
                )
            } == .binary,
            omittedFrameCount: omittedWebSocketFrameCount,
            statusMessage: currentWebSocketStatusMessage(
                visibleCount: frames.count,
                isSearching: isSearching
            ),
            directionFilter: webSocketDirectionFilter,
            searchText: webSocketSearchText,
            isSearching: isSearching,
            canCompose: inspection.webSocket?.canCompose ?? false,
            canReconnect: inspection.webSocket?.canReconnect ?? false,
            canDisconnect: inspection.webSocket?.canDisconnect ?? false,
            composeStatusMessage: inspection.webSocket?.composeStatusMessage
        )
    }

    private static func webSocketURL(for flow: Flow) -> URL {
        guard
            var components = URLComponents(
                url: flow.request.url,
                resolvingAgainstBaseURL: false
            )
        else {
            return flow.request.url
        }
        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        default:
            break
        }
        return components.url ?? flow.request.url
    }

    private static func parseWebSocketHeaders(_ text: String) throws -> HTTPHeaders {
        guard text.utf8.count <= WebSocketComposeService.defaultMaximumReconnectHeaderBytes else {
            throw WebSocketReconnectError.headersTooLarge(
                maximumBytes: WebSocketComposeService.defaultMaximumReconnectHeaderBytes
            )
        }
        let lines =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var headers = HTTPHeaders()
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                continue
            }
            guard let separator = line.firstIndex(of: ":") else {
                throw ProxyLensError.invalidHTTPMessage("Invalid header line: \(line)")
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            try headers.append(name: name, value: value)
        }
        return headers
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
            webSocket: webSocket,
            serverSentEvents: inspection.serverSentEvents
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

    nonisolated private static func loadWebSocketMessageInputs(
        _ frames: [CapturedWebSocketFrame],
        direction: WebSocketFrameDirection,
        reader: any TrafficBodyReading,
        maximumByteCount: Int64
    ) async throws -> [WebSocketMessageFrameInput] {
        var remainingByteCount = maximumByteCount
        var inputs: [WebSocketMessageFrameInput] = []
        inputs.reserveCapacity(frames.count)

        for frame in frames where frame.direction == direction {
            guard !Task.isCancelled else {
                return []
            }
            guard frame.payload.byteCount <= remainingByteCount else {
                throw WebSocketMessagePayloadLoadingError.exceedsInputLimit
            }
            let data = try await reader.read(frame.payload)
            guard Int64(data.count) <= remainingByteCount else {
                throw WebSocketMessagePayloadLoadingError.exceedsInputLimit
            }
            remainingByteCount -= Int64(data.count)
            inputs.append(
                WebSocketMessageFrameInput(
                    id: frame.id,
                    sequenceNumber: frame.sequenceNumber,
                    direction: frame.direction,
                    opcode: frame.opcode,
                    isFinal: frame.isFinal,
                    reservedBits: frame.reservedBits,
                    payload: data,
                    isPayloadTruncated: frame.payload.isTruncated
                )
            )
        }
        return inputs
    }

    nonisolated private static func webSocketFramePayloadPresentation(
        _ data: Data,
        frame: CapturedWebSocketFrame,
        mode: TrafficWebSocketPayloadMode,
        protobufSchema: ProtobufMessageSchema?,
        protobufCatalog: ProtobufSchemaCatalog?
    ) -> (body: TrafficBodyPresentation, syntax: TrafficWebSocketPayloadSyntax) {
        let metadata = BodyDisplayFormatter.metadata(for: frame.payload)
        switch mode {
        case .protobuf:
            return webSocketFramePayloadPresentation(
                data,
                frame: frame,
                mode: .automatic,
                protobufSchema: protobufSchema,
                protobufCatalog: protobufCatalog
            )
        case .hex:
            return (.content(metadata: metadata, value: HexBodyView.render(data)), .binary)
        case .automatic:
            break
        }

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

    nonisolated private static func webSocketMessagePayloadPresentation(
        _ result: WebSocketMessageDecodingResult,
        mode: TrafficWebSocketPayloadMode,
        protobufSchema: ProtobufMessageSchema?,
        protobufCatalog: ProtobufSchemaCatalog?
    ) -> (body: TrafficBodyPresentation, syntax: TrafficWebSocketPayloadSyntax) {
        guard case .decoded(let message) = result else {
            if case .unavailable(let reason) = result {
                return (.none(reason), mode == .protobuf ? .protobuf : .plainText)
            }
            return (.none("The WebSocket message is unavailable."), .plainText)
        }

        let reference = BodyReference(inline: message.payload)
        let metadata = webSocketMessageMetadata(message, reference: reference)
        switch mode {
        case .protobuf:
            guard message.opcode == .binary else {
                return webSocketMessagePayloadPresentation(
                    result,
                    mode: .automatic,
                    protobufSchema: protobufSchema,
                    protobufCatalog: protobufCatalog
                )
            }
            switch ProtobufBodyView.renderMessage(
                data: message.payload,
                isTruncated: false,
                schema: protobufSchema,
                catalog: protobufCatalog
            ) {
            case .decoded(let text):
                return (.content(metadata: metadata, value: text), .protobuf)
            case .unavailable(let reason):
                return (.none(reason), .protobuf)
            }
        case .hex:
            return (
                .content(metadata: metadata, value: HexBodyView.render(message.payload)), .binary
            )
        case .automatic:
            break
        }

        if message.opcode == .text {
            switch JSONBodyView.render(
                data: message.payload,
                contentType: nil,
                contentEncoding: nil,
                isTruncated: false
            ) {
            case .prettyPrinted(let value):
                return (.content(metadata: metadata, value: value), .json)
            case .unavailable:
                return (
                    .content(
                        metadata: metadata,
                        value: BodyDisplayFormatter.render(
                            message.payload,
                            reference: reference
                        )
                    ),
                    .plainText
                )
            }
        }
        return (
            .content(
                metadata: metadata,
                value: BodyDisplayFormatter.render(message.payload, reference: reference)
            ),
            .binary
        )
    }

    nonisolated private static func webSocketMessageMetadata(
        _ message: DecodedWebSocketMessage,
        reference: BodyReference
    ) -> String {
        let frameDescription =
            message.frameIDs.count == 1
            ? "1 frame (#\(message.firstSequenceNumber))"
            : "\(message.frameIDs.count) frames (#\(message.firstSequenceNumber)–#\(message.lastSequenceNumber))"
        var components = [BodyDisplayFormatter.metadata(for: reference), frameDescription]
        if message.isCompressed {
            components.append("permessage-deflate")
            components.append("\(message.wirePayloadByteCount) B on wire")
        }
        return components.joined(separator: " • ")
    }

    nonisolated private static func normalizedWebSocketPayloadMode(
        _ mode: TrafficWebSocketPayloadMode,
        messageOpcode: WebSocketFrameOpcode?
    ) -> TrafficWebSocketPayloadMode {
        if mode == .protobuf, messageOpcode != .binary {
            return .automatic
        }
        return mode
    }

    nonisolated private static func loadingWebSocketPayloadSyntax(
        mode: TrafficWebSocketPayloadMode,
        messageOpcode: WebSocketFrameOpcode?
    ) -> TrafficWebSocketPayloadSyntax {
        switch mode {
        case .protobuf:
            .protobuf
        case .hex:
            .binary
        case .automatic:
            messageOpcode == .binary ? .binary : .plainText
        }
    }

    nonisolated private static func webSocketMessageOpcode(
        containing selectedFrameID: UUID,
        frames: [CapturedWebSocketFrame],
        acceptedExtensions: [String]
    ) -> WebSocketFrameOpcode? {
        guard let selected = frames.first(where: { $0.id == selectedFrameID }),
            isWebSocketDataFrame(selected.opcode)
        else {
            return nil
        }
        let compressionConfiguration: WebSocketPerMessageDeflateConfiguration?
        do {
            compressionConfiguration = try WebSocketPerMessageDeflateConfiguration.parse(
                acceptedExtensions: acceptedExtensions
            )
        } catch {
            return nil
        }

        var seen: Set<UUID> = []
        let orderedFrames =
            frames
            .filter { $0.direction == selected.direction && seen.insert($0.id).inserted }
            .sorted {
                if $0.sequenceNumber == $1.sequenceNumber {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.sequenceNumber < $1.sequenceNumber
            }
        var messageOpcode: WebSocketFrameOpcode?
        var containsSelection = false
        for frame in orderedFrames {
            switch frame.opcode {
            case .close, .ping, .pong:
                guard frame.isFinal,
                    frame.reservedBits.isEmpty,
                    frame.payloadByteCount <= 125
                else {
                    return nil
                }
                continue
            case .unknown:
                return nil
            case .text, .binary:
                guard messageOpcode == nil,
                    frame.reservedBits.intersection([.rsv2, .rsv3]).isEmpty,
                    !frame.reservedBits.contains(.rsv1) || compressionConfiguration != nil
                else {
                    return nil
                }
                messageOpcode = frame.opcode
                containsSelection = frame.id == selectedFrameID
            case .continuation:
                guard messageOpcode != nil, frame.reservedBits.isEmpty else {
                    return nil
                }
                containsSelection = containsSelection || frame.id == selectedFrameID
            }

            if frame.isFinal, let completedOpcode = messageOpcode {
                if containsSelection {
                    return completedOpcode
                }
                messageOpcode = nil
                containsSelection = false
            }
        }
        return nil
    }

    nonisolated private static func isWebSocketDataFrame(
        _ opcode: WebSocketFrameOpcode
    ) -> Bool {
        switch opcode {
        case .continuation, .text, .binary:
            true
        case .close, .ping, .pong, .unknown:
            false
        }
    }

    private static func isWebSocket(_ flow: Flow) -> Bool {
        switch flow.connection?.protocolKind {
        case .webSocket, .secureWebSocket:
            true
        case .http, .https, .none:
            false
        }
    }

    private func refreshServerSentEvents(for flow: Flow) {
        guard Self.isServerSentEventStream(flow) else {
            return
        }
        guard let serverSentEventLoader else {
            replaceServerSentEventInspection(
                TrafficServerSentEventInspection(
                    events: [],
                    selectedEventID: nil,
                    payload: .none("Select a Server-Sent Event to inspect its data."),
                    payloadSyntax: .plainText,
                    omittedEventCount: 0,
                    statusMessage: "Server-Sent Event storage is unavailable."
                ),
                for: flow.id
            )
            return
        }

        serverSentEventTask = Task { [weak self] in
            do {
                let events = try await serverSentEventLoader.listServerSentEvents(for: flow.id)
                guard !Task.isCancelled, self?.store.selectedFlowID == flow.id else {
                    return
                }
                self?.applyLoadedServerSentEvents(events, to: flow.id)
            } catch {
                guard !Task.isCancelled, self?.store.selectedFlowID == flow.id else {
                    return
                }
                self?.replaceServerSentEventInspection(
                    TrafficServerSentEventInspection(
                        events: [],
                        selectedEventID: nil,
                        payload: .none("Select a Server-Sent Event to inspect its data."),
                        payloadSyntax: .plainText,
                        omittedEventCount: 0,
                        statusMessage:
                            "Could not load Server-Sent Events: \(error.localizedDescription)"
                    ),
                    for: flow.id
                )
            }
        }
    }

    func setServerSentEventSearchText(_ text: String) {
        guard let flowID = inspection.flowID, inspection.serverSentEvents != nil else {
            return
        }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != serverSentEventSearchText || serverSentEventSearchMatchIDs == nil else {
            return
        }
        serverSentEventSearchTask?.cancel()
        serverSentEventSearchText = query
        serverSentEventSearchMatchIDs = query.isEmpty ? nil : []
        skippedLargeServerSentEventSearchPayloadCount = 0
        if query.isEmpty {
            refreshServerSentEventPresentation(for: flowID)
        } else {
            beginServerSentEventSearch(query, flowID: flowID)
        }
    }

    private func beginServerSentEventSearch(_ query: String, flowID: FlowID) {
        serverSentEventSearchTask?.cancel()
        serverSentEventSearchMatchIDs = nil
        skippedLargeServerSentEventSearchPayloadCount = 0
        refreshServerSentEventPresentation(for: flowID)

        let events = currentServerSentEvents
        let bodyReader = bodyReader
        let maximumBytes = maximumServerSentEventSearchBytes
        let maximumBytesPerEvent = maximumServerSentEventSearchBytesPerEvent
        serverSentEventSearchTask = Task { [weak self] in
            let result = await Self.searchServerSentEvents(
                events,
                query: query,
                reader: bodyReader,
                maximumBytes: maximumBytes,
                maximumBytesPerEvent: maximumBytesPerEvent
            )
            guard !Task.isCancelled,
                self?.inspection.flowID == flowID,
                self?.serverSentEventSearchText == query
            else {
                return
            }
            self?.serverSentEventSearchMatchIDs = result.matchIDs
            self?.skippedLargeServerSentEventSearchPayloadCount = result.skippedLargePayloadCount
            self?.refreshServerSentEventPresentation(for: flowID)
        }
    }

    private func applyLoadedServerSentEvents(
        _ events: [CapturedServerSentEvent],
        to flowID: FlowID
    ) {
        guard inspection.flowID == flowID else {
            return
        }
        let orderedEvents = Self.orderedUniqueServerSentEvents(
            events + currentServerSentEvents
        )
        omittedServerSentEventCount = max(
            0,
            orderedEvents.count - maximumVisibleServerSentEvents
        )
        currentServerSentEvents = Array(orderedEvents.suffix(maximumVisibleServerSentEvents))
        refreshServerSentEventPresentation(for: flowID)
        beginServerSentEventAccumulation(for: flowID)
    }

    private func beginServerSentEventAccumulation(for flowID: FlowID) {
        guard inspection.flowID == flowID, inspection.serverSentEvents != nil else {
            return
        }
        serverSentEventAccumulationTask?.cancel()
        let events = currentServerSentEvents
        let expectedEventIDs = events.map(\.id)
        let bodyReader = bodyReader
        let maximumInputBytes = maximumServerSentEventAccumulationBytes
        let maximumInputBytesPerEvent = maximumServerSentEventAccumulationBytesPerEvent
        let maximumOutputBytes = maximumServerSentEventAccumulatedOutputBytes
        let omittedEventCount = omittedServerSentEventCount

        guard !events.isEmpty else {
            applyServerSentEventAccumulation(
                .none("No supported streaming text deltas were found."),
                flowID: flowID,
                expectedEventIDs: expectedEventIDs
            )
            return
        }

        serverSentEventAccumulationTask = Task { [weak self] in
            let preview = await Self.accumulateServerSentEventText(
                events,
                reader: bodyReader,
                maximumInputBytes: maximumInputBytes,
                maximumInputBytesPerEvent: maximumInputBytesPerEvent,
                maximumOutputBytes: maximumOutputBytes
            )
            guard !Task.isCancelled else {
                return
            }
            let presentation = Self.serverSentEventAccumulationPresentation(
                preview,
                visibleEventCount: events.count,
                omittedEventCount: omittedEventCount
            )
            self?.applyServerSentEventAccumulation(
                presentation,
                flowID: flowID,
                expectedEventIDs: expectedEventIDs
            )
        }
    }

    private func applyServerSentEventAccumulation(
        _ accumulated: TrafficBodyPresentation,
        flowID: FlowID,
        expectedEventIDs: [UUID]
    ) {
        guard inspection.flowID == flowID,
            let serverSentEvents = inspection.serverSentEvents,
            currentServerSentEvents.map(\.id) == expectedEventIDs
        else {
            return
        }
        replaceServerSentEventInspection(
            makeServerSentEventInspection(
                events: visibleServerSentEvents(),
                selectedEventID: serverSentEvents.selectedEventID,
                payload: serverSentEvents.payload,
                payloadSyntax: serverSentEvents.payloadSyntax,
                isSearching: serverSentEvents.isSearching,
                accumulated: accumulated
            ),
            for: flowID
        )
    }

    private func receiveServerSentEvent(_ event: CapturedServerSentEvent) {
        guard inspection.flowID == event.flowID, inspection.serverSentEvents != nil else {
            return
        }
        guard !currentServerSentEvents.contains(where: { $0.id == event.id }) else {
            return
        }

        currentServerSentEvents.append(event)
        currentServerSentEvents = Self.orderedUniqueServerSentEvents(currentServerSentEvents)
        if currentServerSentEvents.count > maximumVisibleServerSentEvents {
            let overflow = currentServerSentEvents.count - maximumVisibleServerSentEvents
            currentServerSentEvents.removeFirst(overflow)
            omittedServerSentEventCount += overflow
        }

        if serverSentEventSearchText.isEmpty {
            refreshServerSentEventPresentation(for: event.flowID)
        } else {
            beginServerSentEventSearch(serverSentEventSearchText, flowID: event.flowID)
        }
        beginServerSentEventAccumulation(for: event.flowID)
    }

    private func refreshServerSentEventPresentation(for flowID: FlowID) {
        guard inspection.flowID == flowID, let previous = inspection.serverSentEvents else {
            return
        }
        let visibleEvents = visibleServerSentEvents()
        let selectedEventID =
            previous.selectedEventID.flatMap { selectedID in
                visibleEvents.contains(where: { $0.id == selectedID }) ? selectedID : nil
            } ?? visibleEvents.first?.id
        let selectionChanged = previous.selectedEventID != selectedEventID
        let isSearching =
            !serverSentEventSearchText.isEmpty && serverSentEventSearchMatchIDs == nil
        let payload: TrafficBodyPresentation
        if selectedEventID == nil {
            payload = .none(
                isSearching
                    ? "Searching captured Server-Sent Event data…"
                    : "No Server-Sent Event matches the current search."
            )
        } else if selectionChanged {
            payload = .loading("Loading Server-Sent Event data…")
        } else {
            payload = previous.payload
        }
        replaceServerSentEventInspection(
            makeServerSentEventInspection(
                events: visibleEvents,
                selectedEventID: selectedEventID,
                payload: payload,
                payloadSyntax: selectionChanged ? .plainText : previous.payloadSyntax,
                isSearching: isSearching
            ),
            for: flowID
        )
        if selectionChanged, let selectedEventID {
            selectServerSentEvent(selectedEventID)
        }
    }

    func selectServerSentEvent(_ eventID: UUID) {
        guard let flowID = inspection.flowID,
            inspection.serverSentEvents != nil,
            let event = visibleServerSentEvents().first(where: { $0.id == eventID })
        else {
            return
        }

        serverSentEventPayloadTask?.cancel()
        replaceServerSentEventInspection(
            makeServerSentEventInspection(
                events: visibleServerSentEvents(),
                selectedEventID: event.id,
                payload: .loading(BodyDisplayFormatter.metadata(for: event.data)),
                payloadSyntax: .plainText,
                isSearching: false
            ),
            for: flowID
        )

        let bodyReader = bodyReader
        serverSentEventPayloadTask = Task { [weak self] in
            do {
                let data = try await bodyReader.read(event.data)
                guard !Task.isCancelled,
                    self?.inspection.flowID == flowID,
                    self?.inspection.serverSentEvents?.selectedEventID == event.id
                else {
                    return
                }
                let presentation = Self.serverSentEventPayloadPresentation(data, event: event)
                self?.applyServerSentEventPayload(
                    presentation.body,
                    syntax: presentation.syntax,
                    eventID: event.id,
                    flowID: flowID
                )
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.applyServerSentEventPayload(
                    .failed(
                        metadata: BodyDisplayFormatter.metadata(for: event.data),
                        message: "Could not load event data: \(error.localizedDescription)"
                    ),
                    syntax: .plainText,
                    eventID: event.id,
                    flowID: flowID
                )
            }
        }
    }

    private func applyServerSentEventPayload(
        _ payload: TrafficBodyPresentation,
        syntax: TrafficServerSentEventPayloadSyntax,
        eventID: UUID,
        flowID: FlowID
    ) {
        guard inspection.flowID == flowID,
            let serverSentEvents = inspection.serverSentEvents,
            serverSentEvents.selectedEventID == eventID
        else {
            return
        }
        replaceServerSentEventInspection(
            makeServerSentEventInspection(
                events: visibleServerSentEvents(),
                selectedEventID: eventID,
                payload: payload,
                payloadSyntax: syntax,
                isSearching: serverSentEvents.isSearching
            ),
            for: flowID
        )
    }

    private func visibleServerSentEvents() -> [CapturedServerSentEvent] {
        currentServerSentEvents.filter { event in
            guard !serverSentEventSearchText.isEmpty else {
                return true
            }
            guard let serverSentEventSearchMatchIDs else {
                return true
            }
            return serverSentEventSearchMatchIDs.contains(event.id)
        }
    }

    private func makeServerSentEventInspection(
        events: [CapturedServerSentEvent],
        selectedEventID: UUID?,
        payload: TrafficBodyPresentation,
        payloadSyntax: TrafficServerSentEventPayloadSyntax,
        isSearching: Bool,
        accumulated: TrafficBodyPresentation? = nil
    ) -> TrafficServerSentEventInspection {
        TrafficServerSentEventInspection(
            events: events.map(TrafficServerSentEventRow.init),
            capturedEventCount: currentServerSentEvents.count,
            selectedEventID: selectedEventID,
            payload: payload,
            payloadSyntax: payloadSyntax,
            accumulated: accumulated
                ?? inspection.serverSentEvents?.accumulated
                ?? .loading("Building accumulated streaming response preview…"),
            omittedEventCount: omittedServerSentEventCount,
            statusMessage: currentServerSentEventStatusMessage(
                visibleCount: events.count,
                isSearching: isSearching
            ),
            searchText: serverSentEventSearchText,
            isSearching: isSearching
        )
    }

    private func replaceServerSentEventInspection(
        _ serverSentEvents: TrafficServerSentEventInspection,
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
            webSocket: inspection.webSocket,
            serverSentEvents: serverSentEvents
        )
        publishSnapshot()
    }

    private static func orderedUniqueServerSentEvents(
        _ events: [CapturedServerSentEvent]
    ) -> [CapturedServerSentEvent] {
        var seen: Set<UUID> = []
        return
            events
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.sequenceNumber != $1.sequenceNumber {
                    return $0.sequenceNumber < $1.sequenceNumber
                }
                return $0.receivedAt < $1.receivedAt
            }
    }

    nonisolated private static func accumulateServerSentEventText(
        _ events: [CapturedServerSentEvent],
        reader: any TrafficBodyReading,
        maximumInputBytes: Int64,
        maximumInputBytesPerEvent: Int64,
        maximumOutputBytes: Int
    ) async -> ServerSentEventAccumulatedPreview {
        var accumulator = ServerSentEventTextAccumulator(
            maximumOutputBytes: maximumOutputBytes,
            maximumEventDataBytes: Int(clamping: maximumInputBytesPerEvent)
        )
        var remainingInputBytes = maximumInputBytes
        for event in events {
            guard !Task.isCancelled else {
                break
            }
            guard event.dataByteCount <= maximumInputBytesPerEvent,
                event.dataByteCount <= remainingInputBytes
            else {
                accumulator.skipOversizedEvent()
                continue
            }
            do {
                let data = try await reader.read(event.data)
                guard Int64(data.count) <= maximumInputBytesPerEvent,
                    Int64(data.count) <= remainingInputBytes
                else {
                    accumulator.skipOversizedEvent()
                    continue
                }
                remainingInputBytes -= Int64(data.count)
                accumulator.consume(eventType: event.eventType, data: data)
                if event.isDataTruncated {
                    accumulator.markSourceTruncated()
                }
            } catch {
                accumulator.ignoreEvent()
            }
        }
        return accumulator.preview
    }

    nonisolated private static func serverSentEventAccumulationPresentation(
        _ preview: ServerSentEventAccumulatedPreview,
        visibleEventCount: Int,
        omittedEventCount: Int
    ) -> TrafficBodyPresentation {
        var metadata = [
            countDescription(preview.contributingEventCount, singular: "text delta"),
            countDescription(preview.terminalEventCount, singular: "terminal marker")
        ]
        if preview.ignoredEventCount > 0 {
            metadata.append(
                countDescription(preview.ignoredEventCount, singular: "ignored event")
            )
        }
        if preview.skippedOversizedEventCount > 0 {
            let skippedCount = preview.skippedOversizedEventCount
            metadata.append(
                skippedCount == 1
                    ? "1 event skipped by safety limits"
                    : "\(skippedCount) events skipped by safety limits"
            )
        }
        if omittedEventCount > 0 {
            metadata.append(
                "Derived from the latest \(visibleEventCount) events; \(omittedEventCount) earlier omitted"
            )
        }
        if preview.isTruncated {
            metadata.append("Preview truncated")
        }
        let metadataText = metadata.joined(separator: " • ")
        guard !preview.text.isEmpty else {
            return .none(
                "No supported OpenAI streaming text deltas were found. \(metadataText)."
            )
        }
        return .content(metadata: metadataText, value: preview.text)
    }

    nonisolated private static func countDescription(
        _ count: Int,
        singular: String
    ) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(singular)s"
    }

    nonisolated private static func searchServerSentEvents(
        _ events: [CapturedServerSentEvent],
        query: String,
        reader: any TrafficBodyReading,
        maximumBytes: Int64,
        maximumBytesPerEvent: Int64
    ) async -> (matchIDs: Set<UUID>, skippedLargePayloadCount: Int) {
        var matchIDs: Set<UUID> = []
        var remainingBytes = maximumBytes
        var skippedLargePayloadCount = 0
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        for event in events {
            guard !Task.isCancelled else {
                break
            }
            let metadata = [
                String(event.sequenceNumber),
                event.eventType,
                event.eventID ?? "",
                event.retryMilliseconds.map(String.init) ?? ""
            ].joined(separator: " ")
            if metadata.range(of: query, options: options) != nil {
                matchIDs.insert(event.id)
                continue
            }
            guard event.dataByteCount <= maximumBytesPerEvent,
                event.dataByteCount <= remainingBytes
            else {
                skippedLargePayloadCount += 1
                continue
            }
            do {
                let data = try await reader.read(event.data)
                remainingBytes = max(0, remainingBytes - Int64(data.count))
                if let text = String(data: data, encoding: .utf8),
                    text.range(of: query, options: options) != nil
                {
                    matchIDs.insert(event.id)
                }
            } catch {
                continue
            }
        }
        return (matchIDs, skippedLargePayloadCount)
    }

    private func currentServerSentEventStatusMessage(
        visibleCount: Int,
        isSearching: Bool
    ) -> String? {
        if isSearching {
            return "Searching \(currentServerSentEvents.count) captured Server-Sent Events…"
        }
        if !serverSentEventSearchText.isEmpty {
            var message =
                "\(visibleCount) of \(currentServerSentEvents.count) captured events match."
            if skippedLargeServerSentEventSearchPayloadCount == 1 {
                message += " 1 large event data payload skipped."
            } else if skippedLargeServerSentEventSearchPayloadCount > 1 {
                message +=
                    " \(skippedLargeServerSentEventSearchPayloadCount) large event data payloads skipped."
            }
            if omittedServerSentEventCount == 1 {
                message += " 1 earlier event is outside the visible history."
            } else if omittedServerSentEventCount > 1 {
                message +=
                    " \(omittedServerSentEventCount) earlier events are outside the visible history."
            }
            return message
        }
        if visibleCount == 0 {
            return "No Server-Sent Events were captured."
        }
        guard omittedServerSentEventCount > 0 else {
            return nil
        }
        if omittedServerSentEventCount == 1 {
            return "Showing the latest \(visibleCount) events; 1 earlier event is hidden."
        }
        return
            "Showing the latest \(visibleCount) events; \(omittedServerSentEventCount) earlier events are hidden."
    }

    nonisolated private static func serverSentEventPayloadPresentation(
        _ data: Data,
        event: CapturedServerSentEvent
    ) -> (body: TrafficBodyPresentation, syntax: TrafficServerSentEventPayloadSyntax) {
        let metadata = BodyDisplayFormatter.metadata(for: event.data)
        switch JSONBodyView.render(
            data: data,
            contentType: event.data.contentType,
            contentEncoding: event.data.contentEncoding,
            isTruncated: event.data.isTruncated
        ) {
        case .prettyPrinted(let value):
            return (.content(metadata: metadata, value: value), .json)
        case .unavailable:
            return (
                .content(
                    metadata: metadata,
                    value: BodyDisplayFormatter.render(data, reference: event.data)
                ),
                .plainText
            )
        }
    }

    private static func isServerSentEventStream(_ flow: Flow) -> Bool {
        guard let contentType = flow.response?.headers.firstValue(for: "Content-Type") else {
            return false
        }
        return
            contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "text/event-stream"
    }

    private func applyLoadedBodies(
        request: (
            body: TrafficBodyPresentation,
            image: TrafficImagePresentation,
            hex: TrafficBodyPresentation,
            json: TrafficBodyPresentation,
            jsonTree: TrafficJSONTreePresentation,
            xml: TrafficBodyPresentation,
            form: TrafficBodyPresentation,
            graphql: TrafficBodyPresentation,
            protobuf: TrafficBodyPresentation
        ),
        response: (
            body: TrafficBodyPresentation,
            image: TrafficImagePresentation,
            hex: TrafficBodyPresentation,
            json: TrafficBodyPresentation,
            jsonTree: TrafficJSONTreePresentation,
            xml: TrafficBodyPresentation,
            form: TrafficBodyPresentation,
            graphql: TrafficBodyPresentation,
            protobuf: TrafficBodyPresentation
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
                    image: request.image,
                    hex: request.hex,
                    json: request.json,
                    jsonTree: request.jsonTree,
                    xml: request.xml,
                    form: request.form,
                    graphql: request.graphql,
                    protobuf: request.protobuf,
                    protobufSchema: $0.protobufSchema,
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
                    image: response.image,
                    hex: response.hex,
                    json: response.json,
                    jsonTree: response.jsonTree,
                    xml: response.xml,
                    form: response.form,
                    graphql: response.graphql,
                    protobuf: response.protobuf,
                    protobufSchema: $0.protobufSchema,
                    bodyContentType: $0.bodyContentType
                )
            },
            rules: inspection.rules,
            timing: inspection.timing,
            breakpoint: inspection.breakpoint.map { breakpoint in
                let body: TrafficBodyPresentation
                switch breakpoint.phase {
                case .request:
                    body = request.body
                case .response:
                    body = response.body
                case .webSocketResponse:
                    body = .none("WebSocket frame payloads are edited in the Frames inspector.")
                }
                return TrafficBreakpointInspection(
                    phase: breakpoint.phase,
                    canEditBody: breakpoint.phase != .webSocketResponse
                        && Self.bodyIsEditable(body),
                    webSocketFrame: breakpoint.webSocketFrame
                )
            },
            annotation: inspection.annotation,
            webSocket: inspection.webSocket,
            serverSentEvents: inspection.serverSentEvents
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

    private func refreshBreakpointPresentation(for flow: Flow) {
        guard flow.state.breakpointPhase == .webSocketResponse,
            let breakpointCoordinator
        else {
            return
        }

        breakpointPresentationTask = Task { [weak self] in
            for _ in 0..<100 {
                guard !Task.isCancelled, self?.store.selectedFlowID == flow.id else {
                    return
                }
                if let hit = await breakpointCoordinator.hit(for: flow.id),
                    let frame = hit.webSocketFrame
                {
                    self?.replaceBreakpointInspection(
                        Self.webSocketBreakpointInspection(frame),
                        for: flow.id
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private static func webSocketBreakpointInspection(
        _ frame: WebSocketBreakpointFrame
    ) -> TrafficWebSocketBreakpointInspection {
        let payload: String
        let syntax: TrafficWebSocketPayloadSyntax
        if let data = frame.payload,
            frame.opcode == .text,
            let text = String(data: data, encoding: .utf8)
        {
            payload = text
            syntax = isJSON(data) ? .json : .plainText
        } else if let data = frame.payload {
            payload = HexBodyView.render(data)
            syntax = .binary
        } else {
            payload = "The frame payload is unavailable because it exceeded the capture limit."
            syntax = .plainText
        }

        let pausedMessage =
            "Paused before forwarding server frame #\(frame.sequenceNumber) (\(frame.originalPayloadByteCount) B)."
        let statusMessage =
            frame.editingUnavailableReason.map {
                "\(pausedMessage) \($0)."
            } ?? "\(pausedMessage) Edit the payload, then Continue or Abort."
        return TrafficWebSocketBreakpointInspection(
            sequenceNumber: frame.sequenceNumber,
            opcode: frame.opcode,
            payload: payload,
            syntax: syntax,
            canEditPayload: frame.canEditPayload,
            statusMessage: statusMessage
        )
    }

    private static func isJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private func replaceBreakpointInspection(
        _ webSocketFrame: TrafficWebSocketBreakpointInspection,
        for flowID: FlowID
    ) {
        guard inspection.flowID == flowID,
            inspection.breakpoint?.phase == .webSocketResponse
        else {
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
            breakpoint: TrafficBreakpointInspection(
                phase: .webSocketResponse,
                canEditBody: false,
                webSocketFrame: webSocketFrame
            ),
            annotation: inspection.annotation,
            webSocket: inspection.webSocket,
            serverSentEvents: inspection.serverSentEvents
        )
        publishSnapshot()
    }

    private static func initialInspection(
        for flow: Flow,
        requestProtobufInspection: TrafficProtobufSchemaInspection,
        responseProtobufInspection: TrafficProtobufSchemaInspection
    ) -> TrafficFlowInspection {
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
                image: initialImage(flow.request.body),
                hex: initialHex(flow.request.body),
                json: initialJSON(flow.request.body),
                jsonTree: initialJSONTree(flow.request.body),
                xml: initialXML(flow.request.body),
                form: initialForm(flow.request.body),
                graphql: initialGraphQL(flow.request.body),
                protobuf: initialProtobuf(flow.request.body),
                protobufSchema: requestProtobufInspection,
                bodyContentType: flow.request.body?.contentType
            ),
            response: flow.response.map {
                TrafficMessageInspection(
                    title: "Response",
                    headers: responseHeadersText($0),
                    cookies: responseCookiesText($0.headers),
                    body: initialBody($0.body, emptyMessage: "This response has no body."),
                    image: initialImage($0.body),
                    hex: initialHex($0.body),
                    json: initialJSON($0.body),
                    jsonTree: initialJSONTree($0.body),
                    xml: initialXML($0.body),
                    form: initialForm($0.body),
                    graphql: initialGraphQL($0.body),
                    protobuf: initialProtobuf($0.body),
                    protobufSchema: responseProtobufInspection,
                    bodyContentType: $0.body?.contentType
                )
            },
            rules: rulesText(flow.ruleTraces),
            timing: TrafficTimingInspection(flow: flow),
            breakpoint: flow.state.breakpointPhase.map {
                TrafficBreakpointInspection(phase: $0, canEditBody: false)
            },
            annotation: flow.annotation,
            webSocket: isWebSocket(flow) ? .loading : nil,
            serverSentEvents: isServerSentEventStream(flow) ? .loading : nil
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
            var text = "\(name)\nphase: \(trace.phase.rawValue)\noutcome: \(result)"
            if !trace.logs.isEmpty {
                let logs = trace.logs.map { entry in
                    "  • " + entry.replacingOccurrences(of: "\n", with: "\n    ")
                }.joined(separator: "\n")
                text += "\nlogs:\n\(logs)"
            }
            return text
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

    private static func initialHex(_ reference: BodyReference?) -> TrafficBodyPresentation {
        guard let reference else {
            return .none(HexBodyView.noBodyReason)
        }
        return .loading(BodyDisplayFormatter.metadata(for: reference))
    }

    private static func initialImage(_ reference: BodyReference?) -> TrafficImagePresentation {
        guard let reference else {
            return .none(ImageBodyPreviewBuilder.noBodyReason)
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

    private static func initialProtobuf(_ reference: BodyReference?) -> TrafficBodyPresentation {
        guard let reference else {
            return .none(ProtobufBodyView.notProtobufReason)
        }
        return .loading(BodyDisplayFormatter.metadata(for: reference))
    }

    private static func loadBodies(
        _ reference: BodyReference?,
        grpcEncoding: String?,
        protobufSchema: ProtobufMessageSchema?,
        protobufCatalog: ProtobufSchemaCatalog?,
        reader: any TrafficBodyReading
    ) async -> (
        body: TrafficBodyPresentation,
        image: TrafficImagePresentation,
        hex: TrafficBodyPresentation,
        json: TrafficBodyPresentation,
        jsonTree: TrafficJSONTreePresentation,
        xml: TrafficBodyPresentation,
        form: TrafficBodyPresentation,
        graphql: TrafficBodyPresentation,
        protobuf: TrafficBodyPresentation
    ) {
        guard let reference else {
            return (
                body: .none("No body was captured."),
                image: .none(ImageBodyPreviewBuilder.noBodyReason),
                hex: .none(HexBodyView.noBodyReason),
                json: .none(JSONBodyView.notJSONReason),
                jsonTree: .none(JSONBodyView.notJSONReason),
                xml: .none(XMLBodyView.notXMLReason),
                form: .none(FormBodyView.notFormReason),
                graphql: .none(GraphQLBodyView.notGraphQLReason),
                protobuf: .none(ProtobufBodyView.notProtobufReason)
            )
        }
        let metadata = BodyDisplayFormatter.metadata(for: reference)
        do {
            let data = try await reader.read(reference)
            return await Task.detached(priority: .utility) {
                () -> (
                    body: TrafficBodyPresentation,
                    image: TrafficImagePresentation,
                    hex: TrafficBodyPresentation,
                    json: TrafficBodyPresentation,
                    jsonTree: TrafficJSONTreePresentation,
                    xml: TrafficBodyPresentation,
                    form: TrafficBodyPresentation,
                    graphql: TrafficBodyPresentation,
                    protobuf: TrafficBodyPresentation
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
                    image: ImageBodyPreviewBuilder.render(
                        data,
                        reference: reference,
                        metadata: metadata
                    ),
                    hex: .content(metadata: metadata, value: HexBodyView.render(data)),
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
                    ),
                    protobuf: protobufPresentation(
                        from: data,
                        reference: reference,
                        grpcEncoding: grpcEncoding,
                        schema: protobufSchema,
                        catalog: protobufCatalog,
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
                image: .failed(metadata: metadata, message: error.localizedDescription),
                hex: failed,
                json: failed,
                jsonTree: .failed(error.localizedDescription),
                xml: failed,
                form: failed,
                graphql: failed,
                protobuf: failed
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

    nonisolated private static func protobufPresentation(
        from data: Data,
        reference: BodyReference,
        grpcEncoding: String?,
        schema: ProtobufMessageSchema?,
        catalog: ProtobufSchemaCatalog?,
        metadata: String
    ) -> TrafficBodyPresentation {
        switch ProtobufBodyView.render(
            data: data,
            contentType: reference.contentType,
            contentEncoding: reference.contentEncoding,
            grpcEncoding: grpcEncoding,
            isTruncated: reference.isTruncated,
            schema: schema,
            catalog: catalog
        ) {
        case .decoded(let text):
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

        return HexBodyView.render(data)
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
