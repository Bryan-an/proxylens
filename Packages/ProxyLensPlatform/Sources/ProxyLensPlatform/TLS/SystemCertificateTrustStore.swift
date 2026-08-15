import Foundation
import ProxyLensCore
@preconcurrency import Security

/// Installs the local interception CA into the macOS user trust domain.
///
/// This actor is separate from `KeychainCertificateProvider` so the SecurityAgent
/// password panel cannot stall leaf minting for live HTTPS traffic.
public actor SystemCertificateTrustStore: CertificateTrustStore {
    /// `errAuthorizationCanceled` from Authorization.h; not always visible via Security.
    private static let authorizationCanceled: OSStatus = -60_006

    private let certificateProvider: KeychainCertificateProvider
    private let fileManager: FileManager

    public init(
        certificateProvider: KeychainCertificateProvider,
        fileManager: FileManager = .default
    ) {
        self.certificateProvider = certificateProvider
        self.fileManager = fileManager
    }

    public func trustState() async throws -> CertificateTrustState {
        guard let root = try await certificateProvider.storedRootCertificateReference() else {
            return .notGenerated
        }

        var copiedSettings: CFArray?
        let status = SecTrustSettingsCopyTrustSettings(root, .user, &copiedSettings)
        if status == errSecItemNotFound {
            return .untrusted
        }
        guard status == errSecSuccess else {
            throw CertificateProviderError.trustSettings(
                operation: "read user-domain trust",
                status: status
            )
        }
        guard let settings = copiedSettings as? [[String: Any]] else {
            return .untrusted
        }
        return Self.trustSettingsGrantUnrestrictedRootTrust(settings)
            ? .trusted
            : .untrusted
    }

    public func installTrust() async throws {
        try await certificateProvider.prepareCertificateAuthority()
        guard let root = try await certificateProvider.storedRootCertificateReference() else {
            throw CertificateProviderError.malformedStoredCertificate
        }
        let status = SecTrustSettingsSetTrustSettings(root, .user, nil)
        try Self.throwIfTrustSettingsFailed(status, operation: "install user-domain trust")
    }

    public func removeTrust() async throws {
        guard let root = try await certificateProvider.storedRootCertificateReference() else {
            return
        }
        let status = SecTrustSettingsRemoveTrustSettings(root, .user)
        if status == errSecItemNotFound {
            return
        }
        try Self.throwIfTrustSettingsFailed(status, operation: "remove user-domain trust")
    }

    public func exportRootCertificate(to url: URL) async throws {
        let pem = try await certificateProvider.rootCertificate()
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try pem.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )
    }

    static func trustSettingsGrantUnrestrictedRootTrust(
        _ settings: [[String: Any]]
    ) -> Bool {
        if settings.isEmpty {
            return true
        }

        return settings.contains { setting in
            guard setting.keys.allSatisfy({ $0 == kSecTrustSettingsResult }) else {
                return false
            }
            guard let value = setting[kSecTrustSettingsResult] else {
                return true
            }
            guard let result = value as? NSNumber else {
                return false
            }
            return result.uint32Value == SecTrustSettingsResult.trustRoot.rawValue
                || result.uint32Value == SecTrustSettingsResult.trustAsRoot.rawValue
        }
    }

    private static func throwIfTrustSettingsFailed(_ status: OSStatus, operation: String) throws {
        if status == errSecSuccess {
            return
        }
        if status == errSecUserCanceled || status == authorizationCanceled {
            throw CertificateProviderError.userCancelled
        }
        throw CertificateProviderError.trustSettings(operation: operation, status: status)
    }
}
