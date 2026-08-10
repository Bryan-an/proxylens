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
        let proxyEngine = NIOProxyEngine(
            eventSink: persistenceSink,
            bodyStore: bodyStore,
            maximumCapturedBodyBytes: databaseConfiguration.maximumCapturedBodyBytes,
            certificateProvider: certificateProvider
        )
        let systemProxyController = MacOSSystemProxyController(
            snapshotURL:
                storageRoot
                .appendingPathComponent("SystemProxy", isDirectory: true)
                .appendingPathComponent("PreviousConfiguration.plist", isDirectory: false)
        )

        self.flowEvents = flowEvents
        self.captureCoordinator = CaptureCoordinator(
            proxyEngine: proxyEngine,
            sessionStore: sessionStore,
            systemProxyController: systemProxyController
        )
    }
}
