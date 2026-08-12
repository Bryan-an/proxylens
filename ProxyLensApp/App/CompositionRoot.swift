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
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let storageRoot =
            applicationSupportURL
            .appendingPathComponent("ProxyLens", isDirectory: true)
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
        let ruleEngine = RuleEngine()
        let proxyEngine = NIOProxyEngine(
            eventSink: persistenceSink,
            bodyStore: bodyStore,
            maximumCapturedBodyBytes: databaseConfiguration.maximumCapturedBodyBytes,
            certificateProvider: certificateProvider,
            ruleSnapshot: ruleEngine.snapshot
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
            ruleEngine: ruleEngine
        )
    }
}
