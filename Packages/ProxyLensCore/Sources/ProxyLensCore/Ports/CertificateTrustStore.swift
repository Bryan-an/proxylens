import Foundation

/// Effective trust of the local interception CA, as a TLS client would observe it.
public enum CertificateTrustState: Equatable, Sendable {
    /// No root CA has been generated yet.
    case notGenerated
    /// A root CA exists but macOS does not trust it for TLS.
    case untrusted
    /// A TLS client using the system trust store would accept a leaf issued by the CA.
    case trusted
}

/// Errors produced while installing, removing, or evaluating CA trust.
public enum CertificateTrustError: Error, Equatable, LocalizedError, Sendable {
    /// The user dismissed the macOS authentication panel.
    case userCancelled

    public static let cancelledDescription = "The certificate trust change was cancelled."

    public var errorDescription: String? {
        switch self {
        case .userCancelled:
            Self.cancelledDescription
        }
    }
}

/// Installs, removes, and reports trust for the local interception CA.
public protocol CertificateTrustStore: Sendable {
    func trustState() async throws -> CertificateTrustState
    func installTrust() async throws
    func removeTrust() async throws
    func exportRootCertificate(to url: URL) async throws
}
