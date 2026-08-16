import Foundation
import ProxyLensApplication
import ProxyLensCapture
import ProxyLensCore
import ProxyLensPersistence
import ProxyLensPlatform

@MainActor
final class CompositionRoot {
    let captureCoordinator: CaptureCoordinator
    let flowEvents: FlowEventBus
    let trafficConsoleViewModel: TrafficConsoleViewModel

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
        let certificateProvider = KeychainCertificateProvider()
        let certificateTrustStore = SystemCertificateTrustStore(
            certificateProvider: certificateProvider
        )
        let ruleEngine = RuleEngine()
        let breakpointCoordinator = BreakpointCoordinator()
        let flowSourceResolver = MacOSFlowSourceResolver()
        let proxyEngine = NIOProxyEngine(
            eventSink: persistenceSink,
            bodyStore: bodyStore,
            maximumCapturedBodyBytes: databaseConfiguration.maximumCapturedBodyBytes,
            certificateProvider: certificateProvider,
            ruleSnapshot: ruleEngine.snapshot,
            breakpointGate: breakpointCoordinator,
            flowSourceResolver: flowSourceResolver
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
        let sessionService = SessionService(sessionStore: sessionStore)
        let certificateTrustService = CertificateTrustService(trustStore: certificateTrustStore)

        self.flowEvents = flowEvents
        self.captureCoordinator = captureCoordinator
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
            ruleEngine: ruleEngine,
            breakpointCoordinator: breakpointCoordinator,
            exportService: exportService,
            requestReplayer: replayService,
            sessionService: sessionService,
            certificateTrust: certificateTrustService
        )
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
