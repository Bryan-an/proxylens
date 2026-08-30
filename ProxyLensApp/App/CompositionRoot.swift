import Foundation
import ProxyLensApplication
import ProxyLensCapture
import ProxyLensCore
import ProxyLensPersistence
import ProxyLensPlatform

extension GRDBSessionStore: TrafficWebSocketFrameLoading {}
extension GRDBSessionStore: TrafficServerSentEventLoading {}

@MainActor
final class CompositionRoot {
    let captureCoordinator: CaptureCoordinator
    let flowEvents: FlowEventBus
    let trafficConsoleViewModel: TrafficConsoleViewModel
    private let webSocketConnectionClient: NIOWebSocketConnectionClient

    init(fileManager: FileManager = .default) throws {
        let storageRoot = try Self.storageRoot(fileManager: fileManager)
        let databaseConfiguration = DatabaseConfiguration(
            databaseURL: storageRoot.appendingPathComponent("Capture.sqlite", isDirectory: false),
            bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies", isDirectory: true)
        )
        let database = try DatabaseController(configuration: databaseConfiguration)
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let flowEvents = FlowEventBus()
        let persistenceSink = PersistingFlowEventSink(
            flowStore: sessionStore,
            downstream: flowEvents
        )
        let webSocketFrameEvents = WebSocketFrameEventBus()
        let webSocketFramePersistenceSink = PersistingWebSocketFrameEventSink(
            frameStore: sessionStore,
            downstream: webSocketFrameEvents
        )
        let serverSentEventEvents = ServerSentEventEventBus()
        let serverSentEventPersistenceSink = PersistingServerSentEventEventSink(
            eventStore: sessionStore,
            downstream: serverSentEventEvents
        )
        let certificateProvider = KeychainCertificateProvider()
        let certificateTrustStore = SystemCertificateTrustStore(
            certificateProvider: certificateProvider
        )
        let ruleEngine = RuleEngine()
        let breakpointCoordinator = BreakpointCoordinator()
        let flowSourceResolver = MacOSFlowSourceResolver()
        let remoteDeviceStore = UserDefaultsRemoteDeviceStore()
        let remoteDeviceCoordinator = RemoteDeviceCoordinator(store: remoteDeviceStore)
        let externalHTTPProxyCredentialStore = KeychainExternalHTTPProxyCredentialStore()
        let scriptExecutor = Bundle.main.executableURL.map {
            ProcessJavaScriptExecutor(workerExecutableURL: $0)
        }
        let tlsInterceptionPolicy = MutableTLSInterceptionPolicy()
        let proxyEngine = NIOProxyEngine(
            eventSink: persistenceSink,
            serverSentEventEventSink: serverSentEventPersistenceSink,
            webSocketFrameEventSink: webSocketFramePersistenceSink,
            bodyStore: bodyStore,
            maximumCapturedBodyBytes: databaseConfiguration.maximumCapturedBodyBytes,
            certificateProvider: certificateProvider,
            ruleSnapshot: ruleEngine.snapshot,
            tlsInterceptionPolicy: tlsInterceptionPolicy,
            scriptExecutor: scriptExecutor,
            breakpointGate: breakpointCoordinator,
            flowSourceResolver: flowSourceResolver,
            remoteAccessGate: remoteDeviceCoordinator,
            externalHTTPProxyCredentialStore: externalHTTPProxyCredentialStore
        )
        let systemProxyController = MacOSSystemProxyController(
            snapshotURL:
                storageRoot
                .appendingPathComponent("SystemProxy", isDirectory: true)
                .appendingPathComponent("PreviousConfiguration.plist", isDirectory: false)
        )

        let captureCoordinator = CaptureCoordinator(
            proxyEngine: proxyEngine,
            sessionStore: sessionStore,
            systemProxyController: systemProxyController
        )
        let bodyReader = FlowBodyReader(bodyStore: bodyStore)
        let exportService = ExportService(bodyStore: bodyStore)
        let requestReplayClient = NIORequestReplayClient(
            bodyStore: bodyStore,
            maximumCapturedBodyBytes: databaseConfiguration.maximumCapturedBodyBytes
        )
        let replayService = ReplayService(
            client: requestReplayClient,
            flowStore: sessionStore
        )
        let webSocketConnectionClient = NIOWebSocketConnectionClient(
            eventSink: persistenceSink,
            webSocketFrameEventSink: webSocketFramePersistenceSink,
            bodyStore: bodyStore,
            maximumCapturedFrameBytes: databaseConfiguration.maximumCapturedBodyBytes,
            maximumWebSocketFrameBytes: Int(
                clamping: databaseConfiguration.maximumCapturedBodyBytes
            )
        )
        let webSocketComposeService = WebSocketComposeService(
            transmitters: [proxyEngine, webSocketConnectionClient],
            connectionClient: webSocketConnectionClient
        )
        let sessionService = SessionService(sessionStore: sessionStore)
        let harImporter = HARImportService(
            sessionStore: sessionStore,
            bodyStore: bodyStore,
            maximumBodyByteCount: databaseConfiguration.maximumCapturedBodyBytes
        )
        let portableSessionService = PortableSessionService(
            sessionStore: sessionStore,
            bodyStore: bodyStore,
            maximumBodyByteCount: databaseConfiguration.maximumCapturedBodyBytes
        )
        let certificateTrustService = CertificateTrustService(trustStore: certificateTrustStore)
        let ruleProfileStore = FileRuleProfileStore(
            directoryURL: storageRoot.appendingPathComponent("RuleProfiles", isDirectory: true)
        )
        let ruleProfileArchive = RuleProfileArchiveService()
        let protobufDescriptorStore = FileTrafficProtobufDescriptorStore(
            directoryURL: storageRoot.appendingPathComponent(
                "ProtobufDescriptors",
                isDirectory: true
            )
        )

        self.flowEvents = flowEvents
        self.captureCoordinator = captureCoordinator
        self.webSocketConnectionClient = webSocketConnectionClient
        self.trafficConsoleViewModel = TrafficConsoleViewModel(
            captureController: captureCoordinator,
            eventSource: flowEvents,
            bodyReader: bodyReader,
            captureConfiguration: CaptureConfiguration(
                proxy: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                    interceptHTTPS: true
                )
            ),
            webSocketFrameLoader: sessionStore,
            webSocketFrameEventSource: webSocketFrameEvents,
            webSocketComposer: webSocketComposeService,
            serverSentEventLoader: sessionStore,
            serverSentEventEventSource: serverSentEventEvents,
            ruleEngine: ruleEngine,
            breakpointCoordinator: breakpointCoordinator,
            exportService: exportService,
            requestReplayer: replayService,
            sessionService: sessionService,
            harImporter: harImporter,
            portableSessionTransfer: portableSessionService,
            certificateTrust: certificateTrustService,
            ruleProfileStore: ruleProfileStore,
            ruleProfileArchive: ruleProfileArchive,
            pinnedDomainsStore: UserDefaultsTrafficPinnedDomainsStore(),
            protobufDescriptorStore: protobufDescriptorStore,
            reverseProxyRouteStore: UserDefaultsTrafficReverseProxyRouteStore(),
            socks5ListenerStore: UserDefaultsTrafficSOCKS5ListenerStore(),
            externalHTTPProxyStore: UserDefaultsTrafficExternalHTTPProxyStore(),
            externalHTTPProxyCredentialStore: externalHTTPProxyCredentialStore,
            customFilterPresetStore: UserDefaultsTrafficCustomFilterPresetStore(),
            sslProxyingStore: UserDefaultsTrafficSSLProxyingStore(),
            tlsInterceptionPolicySink: tlsInterceptionPolicy,
            systemProxyStore: UserDefaultsTrafficSystemProxyStore(),
            remoteAccessStore: UserDefaultsTrafficRemoteAccessStore(),
            remoteAccessController: remoteDeviceCoordinator,
            lanAddressProvider: MacOSLANAddressProvider()
        )
    }

    func shutdown() async {
        await webSocketConnectionClient.shutdown()
    }

    private static func storageRoot(fileManager: FileManager) throws -> URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let flagIndex = arguments.firstIndex(of: "-ProxyLensStorageRoot") {
            let pathIndex = arguments.index(after: flagIndex)
            if pathIndex < arguments.endIndex {
                let override = URL(fileURLWithPath: arguments[pathIndex], isDirectory: true)
                try fileManager.createDirectory(at: override, withIntermediateDirectories: true)
                return override
            }
        }

        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupportURL.appendingPathComponent("ProxyLens", isDirectory: true)
    }
}
