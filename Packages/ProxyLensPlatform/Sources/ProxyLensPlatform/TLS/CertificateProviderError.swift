import Foundation
import Security

public enum CertificateProviderError: Error, Equatable, LocalizedError, Sendable {
    case certificateGeneration(String)
    case invalidHostname(String)
    case keyGeneration(String)
    case keychain(operation: String, status: OSStatus)
    case malformedStoredCertificate

    public var errorDescription: String? {
        switch self {
        case .certificateGeneration(let message):
            "Certificate generation failed: \(message)"
        case .invalidHostname(let hostname):
            "Invalid TLS hostname: \(hostname)"
        case .keyGeneration(let message):
            "Private-key generation failed: \(message)"
        case .keychain(let operation, let status):
            "Keychain operation '\(operation)' failed with status \(status)"
        case .malformedStoredCertificate:
            "The stored ProxyLens root certificate is malformed"
        }
    }
}
