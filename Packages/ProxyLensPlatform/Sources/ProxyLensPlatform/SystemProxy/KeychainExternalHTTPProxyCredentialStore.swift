import Foundation
import ProxyLensCore
@preconcurrency import Security

public enum ExternalHTTPProxyKeychainError: Error, Equatable, LocalizedError, Sendable {
    case operationFailed(operation: String, status: OSStatus)
    case malformedCredentials

    public var errorDescription: String? {
        switch self {
        case .operationFailed(let operation, let status):
            "External proxy Keychain operation '\(operation)' failed with status \(status)."
        case .malformedCredentials:
            "The stored external proxy credentials are malformed."
        }
    }
}

public actor KeychainExternalHTTPProxyCredentialStore: ExternalHTTPProxyCredentialStoring {
    public struct Configuration: Equatable, Sendable {
        public var service: String

        public init(service: String = "com.proxylens.external-http-proxy") {
            self.service = service
        }
    }

    private struct StoredCredentials: Codable {
        let username: String
        let password: String
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func credentials(
        for endpoint: NetworkEndpoint,
        username: String
    ) throws -> ExternalHTTPProxyCredentials? {
        var result: CFTypeRef?
        var query = baseQuery(for: endpoint)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ExternalHTTPProxyKeychainError.operationFailed(
                operation: "load credentials",
                status: status
            )
        }
        guard let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data) else {
            throw ExternalHTTPProxyKeychainError.malformedCredentials
        }
        guard stored.username == username else { return nil }
        guard
            let credentials = try? ExternalHTTPProxyCredentials(
                username: stored.username,
                password: stored.password
            )
        else {
            throw ExternalHTTPProxyKeychainError.malformedCredentials
        }
        return credentials
    }

    public func save(
        _ credentials: ExternalHTTPProxyCredentials,
        for endpoint: NetworkEndpoint
    ) throws {
        let data = try JSONEncoder().encode(
            StoredCredentials(username: credentials.username, password: credentials.password)
        )
        let query = baseQuery(for: endpoint)
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ExternalHTTPProxyKeychainError.operationFailed(
                operation: "update credentials",
                status: updateStatus
            )
        }

        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ExternalHTTPProxyKeychainError.operationFailed(
                operation: "save credentials",
                status: addStatus
            )
        }
    }

    public func removeCredentials(for endpoint: NetworkEndpoint) throws {
        let status = SecItemDelete(baseQuery(for: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExternalHTTPProxyKeychainError.operationFailed(
                operation: "remove credentials",
                status: status
            )
        }
    }

    private func baseQuery(for endpoint: NetworkEndpoint) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: configuration.service,
            kSecAttrAccount: "\(endpoint.host.lowercased()):\(endpoint.port)"
        ]
    }
}
