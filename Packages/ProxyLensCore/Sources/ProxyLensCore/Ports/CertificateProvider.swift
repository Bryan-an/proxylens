import Foundation

/// Public certificate material plus an opaque adapter-owned private-key handle.
/// The private key itself must remain in Keychain-backed infrastructure.
public struct CertificateIdentity: Equatable, Hashable, Sendable {
    public let certificateData: Data
    public let privateKeyReference: String

    public init(certificateData: Data, privateKeyReference: String) {
        self.certificateData = certificateData
        self.privateKeyReference = privateKeyReference
    }
}

public protocol CertificateProvider: Sendable {
    func rootCertificate() async throws -> Data
    func leafCertificate(for hostname: String) async throws -> CertificateIdentity
}
