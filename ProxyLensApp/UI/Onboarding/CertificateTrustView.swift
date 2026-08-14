import AppKit
import ProxyLensCore
import SwiftUI
import UniformTypeIdentifiers

struct CertificateTrustView: View {
    @ObservedObject var viewModel: TrafficConsoleViewModel
    let onDismiss: () -> Void

    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HTTPS Certificate")
                .font(.title2.weight(.semibold))

            Text(
                """
                ProxyLens decrypts HTTPS by issuing certificates from a local certificate authority stored in your Keychain. macOS apps and browsers will reject those certificates until this Mac trusts that authority.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                """
                Install and Trust asks macOS for your login password and adds the certificate to this user account only. The app stays unprivileged.

                If you prefer to install it yourself, save the certificate and open it in Keychain Access, then set Trust → When using this certificate to Always Trust.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Install and Trust") {
                    Task { await install() }
                }
                .disabled(isWorking || viewModel.snapshot.certificateTrust == .trusted)
                .keyboardShortcut(.defaultAction)

                Button("Save Certificate…") {
                    Task { await saveCertificate() }
                }
                .disabled(isWorking)

                Button("Remove Trust") {
                    Task { await remove() }
                }
                .disabled(isWorking || viewModel.snapshot.certificateTrust != .trusted)

                Spacer()

                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 360)
        .disabled(isWorking)
    }

    private var statusTitle: String {
        switch viewModel.snapshot.certificateTrust {
        case .trusted:
            "Trusted"
        case .untrusted:
            "Not trusted"
        case .notGenerated, nil:
            "Not created"
        }
    }

    private var statusDetail: String {
        switch viewModel.snapshot.certificateTrust {
        case .trusted:
            "This Mac trusts the ProxyLens local certificate. HTTPS capture can decrypt traffic from apps that use the system trust store."
        case .untrusted:
            "The local HTTPS certificate is not trusted. HTTPS capture will fail until you install it."
        case .notGenerated, nil:
            "The local HTTPS certificate has not been created yet. Install and Trust generates it and adds it to this user account."
        }
    }

    private func install() async {
        await run {
            try await viewModel.installCertificateTrust()
        }
    }

    private func remove() async {
        await run {
            try await viewModel.removeCertificateTrust()
        }
    }

    private func saveCertificate() async {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Save ProxyLens Root Certificate"
        panel.nameFieldStringValue = "ProxyLens-Root-CA.pem"
        if let pemType = UTType(filenameExtension: "pem") {
            panel.allowedContentTypes = [pemType]
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        await run {
            try await viewModel.exportRootCertificate(to: url)
        }
    }

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
