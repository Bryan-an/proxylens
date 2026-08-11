import SwiftUI

struct AppRootView: View {
    let compositionRoot: Result<CompositionRoot, any Error>

    var body: some View {
        Group {
            switch compositionRoot {
            case .success(let compositionRoot):
                TrafficConsoleView(viewModel: compositionRoot.trafficConsoleViewModel)
                    .task {
                        await compositionRoot.trafficConsoleViewModel.prepare()
                    }
            case .failure(let error):
                ContentUnavailableView {
                    Label("ProxyLens could not initialize", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                }
            }
        }
        .frame(minWidth: 1_100, minHeight: 680)
    }
}

#Preview {
    AppRootView(
        compositionRoot: .failure(
            CocoaError(.fileReadUnknown)
        )
    )
}
