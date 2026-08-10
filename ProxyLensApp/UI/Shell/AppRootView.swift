import SwiftUI

struct AppRootView: View {
    let compositionRoot: Result<CompositionRoot, any Error>
    @State private var recoveryFailure: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 42))

            Text("ProxyLens")
                .font(.title)

            switch compositionRoot {
            case .success:
                if let recoveryFailure {
                    Text("ProxyLens could not restore the previous capture state")
                        .foregroundStyle(.red)
                    Text(recoveryFailure)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Capture control plane ready")
                        .foregroundStyle(.secondary)
                }
            case .failure(let error):
                Text("ProxyLens could not initialize")
                    .foregroundStyle(.red)
                Text(error.localizedDescription)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .padding()
        .task {
            guard case .success(let compositionRoot) = compositionRoot else {
                return
            }
            do {
                try await compositionRoot.captureCoordinator.recoverInterruptedCapture()
            } catch {
                recoveryFailure = error.localizedDescription
            }
        }
    }
}

#Preview {
    AppRootView(
        compositionRoot: .failure(
            CocoaError(.fileReadUnknown)
        )
    )
}
