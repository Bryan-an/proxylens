import SwiftUI

@main
struct ProxyLensApp: App {
    private let compositionRoot: Result<CompositionRoot, any Error>

    init() {
        compositionRoot = Result {
            try CompositionRoot()
        }
    }

    var body: some Scene {
        WindowGroup("ProxyLens") {
            AppRootView(compositionRoot: compositionRoot)
        }
    }
}
