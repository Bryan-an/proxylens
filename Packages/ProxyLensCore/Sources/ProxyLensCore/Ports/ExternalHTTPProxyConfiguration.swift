import Foundation

public enum ExternalHTTPProxyConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpointHost
    case invalidEndpointPort
    case tooManyBypassHosts(maximum: Int)
    case invalidBypassHost(String)
    case duplicateBypassHost(String)
    case invalidUsername
    case invalidPassword
    case listenerCollision(NetworkEndpoint)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpointHost:
            "Enter a proxy hostname or IP address without a scheme or path."
        case .invalidEndpointPort:
            "The external proxy port must be between 1 and 65535."
        case .tooManyBypassHosts(let maximum):
            "No more than \(maximum) external proxy bypass hosts may be configured."
        case .invalidBypassHost(let value):
            "Invalid external proxy bypass host: \(value)"
        case .duplicateBypassHost(let value):
            "The external proxy bypass host is duplicated: \(value)"
        case .invalidUsername:
            "The external proxy username is invalid."
        case .invalidPassword:
            "The external proxy password is invalid."
        case .listenerCollision(let endpoint):
            "The external proxy points back to an active local listener at \(endpoint.host):\(endpoint.port)."
        }
    }
}

public struct ExternalHTTPProxyConfiguration: Codable, Equatable, Hashable, Sendable {
    public static let maximumHostLength = 253
    public static let maximumBypassHostCount = 128
    public static let maximumUsernameLength = 1_024

    public let endpoint: NetworkEndpoint
    public let bypassHosts: [String]
    public let username: String?
    public let isEnabled: Bool

    public init(
        endpoint: NetworkEndpoint,
        bypassHosts: [String] = [],
        username: String? = nil,
        isEnabled: Bool = false
    ) throws {
        let endpointHost = try Self.normalizeHost(endpoint.host, allowsWildcard: false)
        guard endpoint.port > 0 else {
            throw ExternalHTTPProxyConfigurationError.invalidEndpointPort
        }
        guard bypassHosts.count <= Self.maximumBypassHostCount else {
            throw ExternalHTTPProxyConfigurationError.tooManyBypassHosts(
                maximum: Self.maximumBypassHostCount
            )
        }

        var normalizedBypassHosts: [String] = []
        var seenBypassHosts = Set<String>()
        for value in bypassHosts {
            let normalized = try Self.normalizeHost(value, allowsWildcard: true)
            guard seenBypassHosts.insert(normalized).inserted else {
                throw ExternalHTTPProxyConfigurationError.duplicateBypassHost(normalized)
            }
            normalizedBypassHosts.append(normalized)
        }

        let normalizedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedUsername,
            normalizedUsername.isEmpty
                || normalizedUsername.count > Self.maximumUsernameLength
                || normalizedUsername.contains(":")
                || Self.containsControlCharacter(normalizedUsername)
        {
            throw ExternalHTTPProxyConfigurationError.invalidUsername
        }

        self.endpoint = NetworkEndpoint(host: endpointHost, port: endpoint.port)
        self.bypassHosts = normalizedBypassHosts
        self.username = normalizedUsername
        self.isEnabled = isEnabled
    }

    public func shouldProxy(host: String) -> Bool {
        guard isEnabled,
            let normalizedHost = try? Self.normalizeHost(host, allowsWildcard: false)
        else {
            return false
        }
        return !bypassHosts.contains { bypass in
            if bypass.hasPrefix("*.") {
                let suffix = String(bypass.dropFirst(2))
                return normalizedHost.hasSuffix(".\(suffix)")
            }
            return normalizedHost == bypass
        }
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case bypassHosts
        case username
        case isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            endpoint: container.decode(NetworkEndpoint.self, forKey: .endpoint),
            bypassHosts: container.decode([String].self, forKey: .bypassHosts),
            username: container.decodeIfPresent(String.self, forKey: .username),
            isEnabled: container.decode(Bool.self, forKey: .isEnabled)
        )
    }

    private static func normalizeHost(_ value: String, allowsWildcard: Bool) throws -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        let wildcardPrefix = allowsWildcard && normalized.hasPrefix("*.")
        let host = wildcardPrefix ? String(normalized.dropFirst(2)) : normalized
        guard !host.isEmpty,
            host.count <= maximumHostLength,
            !host.contains(where: \.isWhitespace),
            !containsControlCharacter(host),
            !host.contains(where: { "/?#@*".contains($0) }),
            !host.hasPrefix("."),
            !host.hasSuffix("."),
            !host.contains("..")
        else {
            if allowsWildcard {
                throw ExternalHTTPProxyConfigurationError.invalidBypassHost(value)
            }
            throw ExternalHTTPProxyConfigurationError.invalidEndpointHost
        }
        return wildcardPrefix ? "*.\(host)" : host
    }

    fileprivate static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public struct ExternalHTTPProxyCredentials: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public static let maximumPasswordLength = 4_096

    public let username: String
    public let password: String

    public init(username: String, password: String) throws {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty,
            normalizedUsername.count <= ExternalHTTPProxyConfiguration.maximumUsernameLength,
            !normalizedUsername.contains(":"),
            !ExternalHTTPProxyConfiguration.containsControlCharacter(normalizedUsername)
        else {
            throw ExternalHTTPProxyConfigurationError.invalidUsername
        }
        guard !password.isEmpty,
            password.count <= Self.maximumPasswordLength,
            !ExternalHTTPProxyConfiguration.containsControlCharacter(password)
        else {
            throw ExternalHTTPProxyConfigurationError.invalidPassword
        }
        self.username = normalizedUsername
        self.password = password
    }

    public var description: String {
        "ExternalHTTPProxyCredentials(username: \(username), password: <redacted>)"
    }

    public var debugDescription: String { description }
}

public protocol ExternalHTTPProxyCredentialStoring: Sendable {
    func credentials(
        for endpoint: NetworkEndpoint,
        username: String
    ) async throws -> ExternalHTTPProxyCredentials?

    func save(
        _ credentials: ExternalHTTPProxyCredentials,
        for endpoint: NetworkEndpoint
    ) async throws

    func removeCredentials(for endpoint: NetworkEndpoint) async throws
}
