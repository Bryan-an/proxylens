import Foundation

/// PEM-encoded leaf certificate material used for a single intercepted hostname.
///
/// Only short-lived leaf private keys may cross this boundary. The root CA private
/// key must remain inside the certificate-provider adapter and must never be
/// returned as part of this value.
public struct CertificateIdentity: Equatable, Hashable, Sendable {
    public let certificateData: Data
    public let privateKeyData: Data

    public init(certificateData: Data, privateKeyData: Data) {
        self.certificateData = certificateData
        self.privateKeyData = privateKeyData
    }
}

public protocol CertificateProvider: Sendable {
    /// Returns the PEM-encoded public root CA certificate.
    func rootCertificate() async throws -> Data

    /// Returns a PEM-encoded leaf certificate and short-lived leaf private key.
    func leafCertificate(for hostname: String) async throws -> CertificateIdentity
}
