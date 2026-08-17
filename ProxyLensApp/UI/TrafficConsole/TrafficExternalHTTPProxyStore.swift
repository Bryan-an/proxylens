import Foundation
import ProxyLensCore

enum TrafficExternalHTTPProxyStoreError: Error, Equatable, LocalizedError {
    case invalidPort
    case captureMustBeStopped
    case credentialStoreUnavailable
    case credentialsRequired

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "The external proxy port must be a number between 1 and 65535."
        case .captureMustBeStopped:
            "Stop capture before changing the external proxy."
        case .credentialStoreUnavailable:
            "Secure external proxy credential storage is unavailable."
        case .credentialsRequired:
            "Enter a password for the configured external proxy username."
        }
    }
}

struct TrafficExternalHTTPProxyDraft: Equatable {
    var host: String
    var port: String
    var username: String
    var password: String
    var bypassHosts: String
    var isEnabled: Bool

    init(
        host: String = "127.0.0.1",
        port: String = "8080",
        username: String = "",
        password: String = "",
        bypassHosts: String = "localhost, 127.0.0.1, ::1",
        isEnabled: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.bypassHosts = bypassHosts
        self.isEnabled = isEnabled
    }

    init(configuration: ExternalHTTPProxyConfiguration) {
        self.init(
            host: configuration.endpoint.host,
            port: String(configuration.endpoint.port),
            username: configuration.username ?? "",
            bypassHosts: configuration.bypassHosts.joined(separator: ", "),
            isEnabled: configuration.isEnabled
        )
    }

    func makeConfiguration() throws -> ExternalHTTPProxyConfiguration {
        let normalizedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(normalizedPort), port > 0 else {
            throw TrafficExternalHTTPProxyStoreError.invalidPort
        }
        let bypassHosts = bypassHosts.components(
            separatedBy: CharacterSet(charactersIn: ",\n")
        ).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return try ExternalHTTPProxyConfiguration(
            endpoint: NetworkEndpoint(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port
            ),
            bypassHosts: bypassHosts,
            username: username.isEmpty ? nil : username,
            isEnabled: isEnabled
        )
    }
}

@MainActor
protocol TrafficExternalHTTPProxyStoring: AnyObject {
    var configuration: ExternalHTTPProxyConfiguration { get }
    func save(_ configuration: ExternalHTTPProxyConfiguration) throws
}

@MainActor
final class InMemoryTrafficExternalHTTPProxyStore: TrafficExternalHTTPProxyStoring {
    private(set) var configuration: ExternalHTTPProxyConfiguration

    init(configuration: ExternalHTTPProxyConfiguration = defaultExternalHTTPProxyConfiguration()) {
        self.configuration = configuration
    }

    func save(_ configuration: ExternalHTTPProxyConfiguration) throws {
        self.configuration = configuration
    }
}

@MainActor
final class UserDefaultsTrafficExternalHTTPProxyStore: TrafficExternalHTTPProxyStoring {
    static let defaultKey = "TrafficConsole.externalHTTPProxy"
    private static let maximumDocumentBytes = 16 * 1_024

    private struct Document: Codable {
        let version: Int
        let configuration: ExternalHTTPProxyConfiguration
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var configuration: ExternalHTTPProxyConfiguration {
        guard let data = defaults.data(forKey: key),
            data.count <= Self.maximumDocumentBytes,
            let document = try? JSONDecoder().decode(Document.self, from: data),
            document.version == 1
        else {
            return defaultExternalHTTPProxyConfiguration()
        }
        return document.configuration
    }

    func save(_ configuration: ExternalHTTPProxyConfiguration) throws {
        defaults.set(
            try JSONEncoder().encode(Document(version: 1, configuration: configuration)),
            forKey: key
        )
    }
}

private func defaultExternalHTTPProxyConfiguration() -> ExternalHTTPProxyConfiguration {
    do {
        return try ExternalHTTPProxyConfiguration(
            endpoint: NetworkEndpoint(host: "127.0.0.1", port: 8_080),
            bypassHosts: ["localhost", "127.0.0.1", "::1"]
        )
    } catch {
        preconditionFailure("The built-in external proxy configuration must be valid")
    }
}
