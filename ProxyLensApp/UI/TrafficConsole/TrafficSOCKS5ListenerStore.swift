import Foundation
import ProxyLensCore

enum TrafficSOCKS5ListenerStoreError: Error, Equatable, LocalizedError {
    case invalidListenPort
    case captureMustBeStopped

    var errorDescription: String? {
        switch self {
        case .invalidListenPort:
            "The local port must be a number between 1 and 65535."
        case .captureMustBeStopped:
            "Stop capture before changing proxy listeners."
        }
    }
}

struct TrafficSOCKS5ListenerDraft: Equatable {
    var listenHost: String
    var listenPort: String
    var isEnabled: Bool

    init(
        listenHost: String = "127.0.0.1",
        listenPort: String = "1080",
        isEnabled: Bool = false
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.isEnabled = isEnabled
    }

    init(configuration: SOCKS5ListenerConfiguration) {
        self.init(
            listenHost: configuration.listenEndpoint.host,
            listenPort: String(configuration.listenEndpoint.port),
            isEnabled: configuration.isEnabled
        )
    }

    func makeConfiguration() throws -> SOCKS5ListenerConfiguration {
        let normalizedPort = listenPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(normalizedPort), port > 0 else {
            throw TrafficSOCKS5ListenerStoreError.invalidListenPort
        }
        return try SOCKS5ListenerConfiguration(
            listenEndpoint: NetworkEndpoint(
                host: listenHost.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port
            ),
            isEnabled: isEnabled
        )
    }
}

@MainActor
protocol TrafficSOCKS5ListenerStoring: AnyObject {
    var configuration: SOCKS5ListenerConfiguration { get }

    func save(_ configuration: SOCKS5ListenerConfiguration) throws
}

@MainActor
final class InMemoryTrafficSOCKS5ListenerStore: TrafficSOCKS5ListenerStoring {
    private(set) var configuration: SOCKS5ListenerConfiguration

    init(configuration: SOCKS5ListenerConfiguration = defaultSOCKS5Configuration()) {
        self.configuration = configuration
    }

    func save(_ configuration: SOCKS5ListenerConfiguration) throws {
        try validateSOCKS5Configuration(configuration)
        self.configuration = configuration
    }
}

@MainActor
final class UserDefaultsTrafficSOCKS5ListenerStore: TrafficSOCKS5ListenerStoring {
    static let defaultKey = "TrafficConsole.socks5Listener"
    private static let maximumDocumentBytes = 4 * 1_024

    private struct Document: Codable {
        let version: Int
        let configuration: SOCKS5ListenerConfiguration
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var configuration: SOCKS5ListenerConfiguration {
        guard let data = defaults.data(forKey: key),
            data.count <= Self.maximumDocumentBytes,
            let document = try? JSONDecoder().decode(Document.self, from: data),
            document.version == 1,
            (try? validateSOCKS5Configuration(document.configuration)) != nil
        else {
            return defaultSOCKS5Configuration()
        }
        return document.configuration
    }

    func save(_ configuration: SOCKS5ListenerConfiguration) throws {
        try validateSOCKS5Configuration(configuration)
        defaults.set(
            try JSONEncoder().encode(Document(version: 1, configuration: configuration)),
            forKey: key
        )
    }
}

@MainActor
private func validateSOCKS5Configuration(_ configuration: SOCKS5ListenerConfiguration) throws {
    guard configuration.listenEndpoint.port > 0 else {
        throw TrafficSOCKS5ListenerStoreError.invalidListenPort
    }
}

private func defaultSOCKS5Configuration() -> SOCKS5ListenerConfiguration {
    do {
        return try SOCKS5ListenerConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 1_080)
        )
    } catch {
        preconditionFailure("The built-in SOCKS5 listener configuration must be valid")
    }
}
