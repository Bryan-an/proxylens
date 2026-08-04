import SwiftUI

struct AppRootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 42))

            Text("ProxyLens")
                .font(.title)

            Text("Project scaffold initialized")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 960, minHeight: 640)
        .padding()
    }
}

#Preview {
    AppRootView()
}
