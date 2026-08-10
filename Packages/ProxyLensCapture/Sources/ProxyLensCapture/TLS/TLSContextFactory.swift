import Foundation
import NIOSSL
import ProxyLensCore

public struct UpstreamTLSConfiguration: Equatable, Hashable, Sendable {
    public let additionalTrustRootCertificates: [Data]

    public init(additionalTrustRootCertificates: [Data] = []) {
        self.additionalTrustRootCertificates = additionalTrustRootCertificates
    }
}

enum TLSContextFactory {
    static func serverContext(identity: CertificateIdentity) throws -> NIOSSLContext {
        let certificates = try NIOSSLCertificate.fromPEMBytes(Array(identity.certificateData))
        guard !certificates.isEmpty else {
            throw TLSInterceptionError.emptyCertificateChain
        }
        let privateKey = try NIOSSLPrivateKey(
            bytes: Array(identity.privateKeyData),
            format: .pem
        )
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
        configuration.minimumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: configuration)
    }

    static func upstreamContext(configuration: UpstreamTLSConfiguration) throws -> NIOSSLContext {
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.minimumTLSVersion = .tlsv12

        let certificates = try configuration.additionalTrustRootCertificates.flatMap {
            try NIOSSLCertificate.fromPEMBytes(Array($0))
        }
        if !certificates.isEmpty {
            tlsConfiguration.additionalTrustRoots = [.certificates(certificates)]
        }

        return try NIOSSLContext(configuration: tlsConfiguration)
    }
}

enum TLSInterceptionError: Error, Equatable, LocalizedError, Sendable {
    case emptyCertificateChain
    case missingCertificateProvider
    case missingUpstreamTLSContext

    var errorDescription: String? {
        switch self {
        case .emptyCertificateChain:
            "The certificate provider returned an empty certificate chain"
        case .missingCertificateProvider:
            "HTTPS interception requires a certificate provider"
        case .missingUpstreamTLSContext:
            "HTTPS forwarding requires an upstream TLS context"
        }
    }
}
