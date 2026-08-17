import AppKit
import SwiftUI

@MainActor
final class ProxyLensApplicationDelegate: NSObject, NSApplicationDelegate {
    private var shutdown: (@Sendable () async -> Void)?
    private var isTerminating = false

    func configureShutdown(_ shutdown: @escaping @Sendable () async -> Void) {
        self.shutdown = shutdown
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown else {
            return .terminateNow
        }
        guard !isTerminating else {
            return .terminateLater
        }
        isTerminating = true
        Task { @MainActor in
            await shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ProxyLensApp: App {
    @NSApplicationDelegateAdaptor(ProxyLensApplicationDelegate.self)
    private var appDelegate
    private let compositionRoot: Result<CompositionRoot, any Error>

    init() {
        compositionRoot = Result {
            try CompositionRoot()
        }
        if case .success(let compositionRoot) = compositionRoot {
            appDelegate.configureShutdown {
                await compositionRoot.shutdown()
            }
        }
    }

    var body: some Scene {
        WindowGroup("ProxyLens") {
            AppRootView(compositionRoot: compositionRoot)
        }
    }
}
