import Crypto
import Darwin
import Foundation
import ProxyLensCore
@preconcurrency import Security
import SwiftASN1
import X509

/// Creates the local interception CA and short-lived per-host leaf identities.
///
/// The root private key is generated as a non-exportable Keychain key. Leaf
/// keys are generated in memory and returned as PEM only so NIOSSL can serve
/// the corresponding short-lived certificate.
public actor KeychainCertificateProvider: CertificateProvider {
    public struct Configuration: Equatable, Hashable, Sendable {
        public let keychainNamespace: String
        public let rootCommonName: String
        public let rootValidity: TimeInterval
        public let leafValidity: TimeInterval
        public let maximumCachedLeafCertificates: Int

        public init(
            keychainNamespace: String = "com.proxylens.ProxyLens.tls",
            rootCommonName: String = "ProxyLens Local Root CA",
            rootValidity: TimeInterval = 10 * 365 * 24 * 60 * 60,
            leafValidity: TimeInterval = 7 * 24 * 60 * 60,
            maximumCachedLeafCertificates: Int = 256
        ) {
            self.keychainNamespace = keychainNamespace
            self.rootCommonName = rootCommonName
            self.rootValidity = max(rootValidity, 365 * 24 * 60 * 60)
            self.leafValidity = max(leafValidity, 60 * 60)
            self.maximumCachedLeafCertificates = max(1, maximumCachedLeafCertificates)
        }
    }

    private struct RootMaterial {
        let privateKey: Certificate.PrivateKey
        let certificate: Certificate
        let certificateData: Data
    }

    private struct CachedLeaf {
        let identity: CertificateIdentity
        let expiresAt: Date
        var lastAccessedAt: Date
    }

    private let configuration: Configuration
    private var cachedRootMaterial: RootMaterial?
    private var leafCache: [String: CachedLeaf] = [:]

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func rootCertificate() async throws -> Data {
        try rootMaterial().certificateData
    }

    /// Generates the local CA if needed so onboarding can install trust before capture.
    public func prepareCertificateAuthority() async throws {
        _ = try rootMaterial()
    }

    /// Returns the stored root certificate without creating a CA.
    func storedRootCertificateReference() throws -> SecCertificate? {
        if let cachedRootMaterial {
            return try Self.secCertificate(
                fromDERData: try Self.derData(for: cachedRootMaterial.certificate)
            )
        }
        guard let data = try loadRootCertificateData() else {
            return nil
        }
        return try Self.secCertificate(fromDERData: data)
    }

    public func leafCertificate(for hostname: String) async throws -> CertificateIdentity {
        let normalizedHostname = try Self.normalizedHostname(hostname)
        let now = Date()

        if var cached = leafCache[normalizedHostname],
            cached.expiresAt > now.addingTimeInterval(300)
        {
            cached.lastAccessedAt = now
            leafCache[normalizedHostname] = cached
            return cached.identity
        }

        let root = try rootMaterial()
        let leaf = try makeLeafCertificate(
            hostname: normalizedHostname,
            root: root,
            now: now
        )
        leafCache[normalizedHostname] = CachedLeaf(
            identity: leaf,
            expiresAt: now.addingTimeInterval(configuration.leafValidity),
            lastAccessedAt: now
        )
        evictLeafCertificatesIfNeeded()
        return leaf
    }

    /// Removes only the CA material owned by this provider configuration.
    /// This supports reversible onboarding and isolated test cleanup.
    public func removeCertificateAuthority() async throws {
        try deleteKeychainItem(
            query: [
                kSecClass: kSecClassKey,
                kSecAttrApplicationTag: rootPrivateKeyTag,
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom
            ],
            operation: "remove root private key"
        )
        try deleteKeychainItem(
            query: rootCertificateQuery,
            operation: "remove root certificate"
        )
        try deleteKeychainItem(
            query: rootCertificateDataQuery,
            operation: "remove root certificate data"
        )
        cachedRootMaterial = nil
        leafCache.removeAll(keepingCapacity: false)
    }

    func rootPrivateKeyIsExtractableForTesting() throws -> Bool {
        guard let key = try loadRootPrivateKey() else {
            return false
        }
        guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any] else {
            throw CertificateProviderError.keyGeneration("The root key attributes are unavailable")
        }
        return attributes[kSecAttrIsExtractable] as? Bool ?? false
    }

    private var rootPrivateKeyTag: Data {
        Data("\(configuration.keychainNamespace).root-ca.private-key".utf8)
    }

    private var rootCertificateQuery: [CFString: Any] {
        [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: "\(configuration.keychainNamespace).root-ca.certificate"
        ]
    }

    private var rootCertificateDataQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: configuration.keychainNamespace,
            kSecAttrAccount: "root-ca.certificate"
        ]
    }

    private func rootMaterial() throws -> RootMaterial {
        if let cachedRootMaterial {
            return cachedRootMaterial
        }

        let secKey = try loadRootPrivateKey() ?? createRootPrivateKey()
        let privateKey: Certificate.PrivateKey
        do {
            privateKey = try Certificate.PrivateKey(secKey)
        } catch {
            throw CertificateProviderError.keyGeneration(error.localizedDescription)
        }

        if let storedData = try loadRootCertificateData(),
            let storedCertificate = try? Self.certificate(fromDERData: storedData),
            storedCertificate.publicKey == privateKey.publicKey,
            storedCertificate.notValidAfter > Date().addingTimeInterval(30 * 24 * 60 * 60)
        {
            let material = RootMaterial(
                privateKey: privateKey,
                certificate: storedCertificate,
                certificateData: try Self.pemData(for: storedCertificate)
            )
            cachedRootMaterial = material
            return material
        }

        let material = try makeRootMaterial(privateKey: privateKey, now: Date())
        try saveRootCertificateData(try Self.derData(for: material.certificate))
        cachedRootMaterial = material
        return material
    }

    private func makeRootMaterial(privateKey: Certificate.PrivateKey, now: Date) throws
        -> RootMaterial
    {
        do {
            let name = try DistinguishedName {
                OrganizationName("ProxyLens")
                CommonName(configuration.rootCommonName)
            }
            let certificate = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(),
                publicKey: privateKey.publicKey,
                notValidBefore: now.addingTimeInterval(-300),
                notValidAfter: now.addingTimeInterval(configuration.rootValidity),
                issuer: name,
                subject: name,
                extensions: Certificate.Extensions {
                    Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                    Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                    SubjectKeyIdentifier(hash: privateKey.publicKey)
                },
                issuerPrivateKey: privateKey
            )
            return RootMaterial(
                privateKey: privateKey,
                certificate: certificate,
                certificateData: try Self.pemData(for: certificate)
            )
        } catch let error as CertificateProviderError {
            throw error
        } catch {
            throw CertificateProviderError.certificateGeneration(error.localizedDescription)
        }
    }

    private func makeLeafCertificate(hostname: String, root: RootMaterial, now: Date) throws
        -> CertificateIdentity
    {
        do {
            let privateKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
            let subject = try DistinguishedName {
                OrganizationName("ProxyLens")
                CommonName(hostname)
            }
            let rootKeyIdentifier = try root.certificate.extensions.subjectKeyIdentifier?
                .keyIdentifier
            let extendedKeyUsage = try ExtendedKeyUsage([.serverAuth])
            let certificate = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(),
                publicKey: privateKey.publicKey,
                notValidBefore: now.addingTimeInterval(-300),
                notValidAfter: now.addingTimeInterval(configuration.leafValidity),
                issuer: root.certificate.subject,
                subject: subject,
                extensions: Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    Critical(KeyUsage(digitalSignature: true))
                    extendedKeyUsage
                    SubjectAlternativeNames([try Self.generalName(for: hostname)])
                    SubjectKeyIdentifier(hash: privateKey.publicKey)
                    AuthorityKeyIdentifier(keyIdentifier: rootKeyIdentifier)
                },
                issuerPrivateKey: root.privateKey
            )
            let privateKeyPEM = try privateKey.serializeAsPEM().pemString
            return CertificateIdentity(
                certificateData: try Self.pemData(for: certificate),
                privateKeyData: Data(privateKeyPEM.utf8)
            )
        } catch let error as CertificateProviderError {
            throw error
        } catch {
            throw CertificateProviderError.certificateGeneration(error.localizedDescription)
        }
    }

    private func loadRootPrivateKey() throws -> SecKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: rootPrivateKeyTag,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let result else {
            throw CertificateProviderError.keychain(
                operation: "load root private key",
                status: status
            )
        }
        return (result as! SecKey)
    }

    private func createRootPrivateKey() throws -> SecKey {
        let privateAttributes: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: rootPrivateKeyTag,
            kSecAttrIsExtractable: false,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsExtractable: false,
            kSecAttrIsSensitive: true,
            kSecPrivateKeyAttrs: privateAttributes
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let existingKey = try loadRootPrivateKey() {
                return existingKey
            }
            let message =
                error?.takeRetainedValue().localizedDescription ?? "Unknown Security error"
            throw CertificateProviderError.keyGeneration(message)
        }
        return key
    }

    private func loadRootCertificateData() throws -> Data? {
        let data = try copyKeychainData(
            query: rootCertificateQuery,
            operation: "load root certificate"
        )
        if data != nil {
            try deleteKeychainItem(
                query: rootCertificateDataQuery,
                operation: "remove leftover root certificate secret"
            )
        }
        return data
    }

    private func saveRootCertificateData(_ data: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw CertificateProviderError.malformedStoredCertificate
        }
        try deleteKeychainItem(
            query: rootCertificateQuery,
            operation: "replace root certificate"
        )
        try deleteKeychainItem(
            query: rootCertificateDataQuery,
            operation: "remove leftover root certificate secret"
        )

        var certificateItem = rootCertificateQuery
        certificateItem[kSecValueRef] = certificate
        let certificateStatus = SecItemAdd(certificateItem as CFDictionary, nil)
        guard certificateStatus == errSecSuccess else {
            throw CertificateProviderError.keychain(
                operation: "store root certificate",
                status: certificateStatus
            )
        }
    }

    private func copyKeychainData(query: [CFString: Any], operation: String) throws -> Data? {
        var copyQuery = query
        copyQuery[kSecReturnData] = true
        copyQuery[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(copyQuery as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CertificateProviderError.keychain(operation: operation, status: status)
        }
        return data
    }

    private func deleteKeychainItem(query: [CFString: Any], operation: String) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CertificateProviderError.keychain(operation: operation, status: status)
        }
    }

    private func evictLeafCertificatesIfNeeded() {
        while leafCache.count > configuration.maximumCachedLeafCertificates,
            let oldest = leafCache.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt })
        {
            leafCache.removeValue(forKey: oldest.key)
        }
    }

    private static func normalizedHostname(_ hostname: String) throws -> String {
        var value = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") {
            value.removeLast()
        }
        guard !value.isEmpty else {
            throw CertificateProviderError.invalidHostname(hostname)
        }

        if isIPAddress(value) {
            return value
        }

        guard value.utf8.count <= 253 else {
            throw CertificateProviderError.invalidHostname(hostname)
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy(Self.isValidDNSLabel) else {
            throw CertificateProviderError.invalidHostname(hostname)
        }
        return value
    }

    private static func isValidDNSLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.utf8.count <= 63 else {
            return false
        }
        let bytes = Array(label.utf8)
        guard bytes.first.map(Self.isASCIIAlphaNumeric) == true,
            bytes.last.map(Self.isASCIIAlphaNumeric) == true
        else {
            return false
        }
        return bytes.allSatisfy { Self.isASCIIAlphaNumeric($0) || $0 == 45 }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...122).contains(byte)
    }

    private static func isIPAddress(_ hostname: String) -> Bool {
        var ipv4 = in_addr()
        if hostname.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return hostname.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private static func generalName(for hostname: String) throws -> GeneralName {
        var ipv4 = in_addr()
        if hostname.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4) { Array($0) }
            return .ipAddress(ASN1OctetString(contentBytes: bytes[...]))
        }

        var ipv6 = in6_addr()
        if hostname.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return .ipAddress(ASN1OctetString(contentBytes: bytes[...]))
        }

        return .dnsName(hostname)
    }

    private static func pemData(for certificate: Certificate) throws -> Data {
        Data(try certificate.serializeAsPEM().pemString.utf8)
    }

    private static func derData(for certificate: Certificate) throws -> Data {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return Data(serializer.serializedBytes)
    }

    private static func secCertificate(fromDERData data: Data) throws -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw CertificateProviderError.malformedStoredCertificate
        }
        return certificate
    }

    private static func certificate(fromDERData data: Data) throws -> Certificate {
        do {
            return try Certificate(derEncoded: Array(data))
        } catch {
            throw CertificateProviderError.malformedStoredCertificate
        }
    }
}
