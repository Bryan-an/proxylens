import Foundation
import ProxyLensCore
@preconcurrency import Security
import SwiftASN1
import X509

/// Installs the local interception CA into the macOS user trust domain.
///
/// This actor is separate from `KeychainCertificateProvider` so the SecurityAgent
/// password panel cannot stall leaf minting for live HTTPS traffic.
public actor SystemCertificateTrustStore: CertificateTrustStore {
    private static let probeHostname = "trust-probe.proxylens.invalid"
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
        return try await isEffectivelyTrusted(root: root) ? .trusted : .untrusted
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

    private func isEffectivelyTrusted(root: SecCertificate) async throws -> Bool {
        let identity = try await certificateProvider.leafCertificate(for: Self.probeHostname)
        let leaf = try Self.secCertificate(fromPEM: identity.certificateData)
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, Self.probeHostname as CFString)
        let status = SecTrustCreateWithCertificates(
            [leaf, root] as CFArray,
            policy,
            &trust
        )
        guard status == errSecSuccess, let trust else {
            throw CertificateProviderError.trustSettings(
                operation: "create trust evaluation",
                status: status
            )
        }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }

    private static func secCertificate(fromPEM data: Data) throws -> SecCertificate {
        do {
            let certificate = try Certificate(pemEncoded: String(decoding: data, as: UTF8.self))
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            let der = Data(serializer.serializedBytes)
            guard let secCertificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw CertificateProviderError.malformedStoredCertificate
            }
            return secCertificate
        } catch let error as CertificateProviderError {
            throw error
        } catch {
            throw CertificateProviderError.certificateGeneration(error.localizedDescription)
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
