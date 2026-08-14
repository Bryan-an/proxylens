import Foundation
import ProxyLensCore

/// Installs, removes, and reports trust for the local interception CA.
public struct CertificateTrustService: Sendable {
    private let trustStore: any CertificateTrustStore

    public init(trustStore: any CertificateTrustStore) {
        self.trustStore = trustStore
    }

    public func state() async throws -> CertificateTrustState {
        try await trustStore.trustState()
    }

    public func install() async throws {
        try await trustStore.installTrust()
    }

    public func remove() async throws {
        try await trustStore.removeTrust()
    }

    public func exportRootCertificate(to url: URL) async throws {
        try await trustStore.exportRootCertificate(to: url)
    }
}
