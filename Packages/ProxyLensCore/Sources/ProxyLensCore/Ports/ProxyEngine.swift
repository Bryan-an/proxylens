import Foundation

public struct NetworkEndpoint: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public enum SOCKS5ListenerConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case loopbackRequired

    public var errorDescription: String? {
        switch self {
        case .loopbackRequired:
            "The SOCKS5 listener may bind only to 127.0.0.1 or ::1."
        }
    }
}

public struct SOCKS5ListenerConfiguration: Codable, Equatable, Hashable, Sendable {
    public let listenEndpoint: NetworkEndpoint
    public let isEnabled: Bool

    public init(listenEndpoint: NetworkEndpoint, isEnabled: Bool = false) throws {
        let host = listenEndpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host == "127.0.0.1" || host == "::1" else {
            throw SOCKS5ListenerConfigurationError.loopbackRequired
        }
        self.listenEndpoint = NetworkEndpoint(host: host, port: listenEndpoint.port)
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case listenEndpoint
        case isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            listenEndpoint: container.decode(NetworkEndpoint.self, forKey: .listenEndpoint),
            isEnabled: container.decode(Bool.self, forKey: .isEnabled)
        )
    }
}

public struct ProxyConfiguration: Codable, Equatable, Hashable, Sendable {
    public let listenEndpoint: NetworkEndpoint
    public let interceptHTTPS: Bool
    public let reverseProxyRoutes: [ReverseProxyRoute]
    public let socks5Listener: SOCKS5ListenerConfiguration?
    public let externalHTTPProxy: ExternalHTTPProxyConfiguration?

    public init(
        listenEndpoint: NetworkEndpoint,
        interceptHTTPS: Bool = true,
        reverseProxyRoutes: [ReverseProxyRoute] = []
    ) {
        self.init(
            listenEndpoint: listenEndpoint,
            interceptHTTPS: interceptHTTPS,
            reverseProxyRoutes: reverseProxyRoutes,
            socks5Listener: nil,
            externalHTTPProxy: nil
        )
    }

    public init(
        listenEndpoint: NetworkEndpoint,
        interceptHTTPS: Bool = true,
        reverseProxyRoutes: [ReverseProxyRoute] = [],
        socks5Listener: SOCKS5ListenerConfiguration?
    ) {
        self.init(
            listenEndpoint: listenEndpoint,
            interceptHTTPS: interceptHTTPS,
            reverseProxyRoutes: reverseProxyRoutes,
            socks5Listener: socks5Listener,
            externalHTTPProxy: nil
        )
    }

    public init(
        listenEndpoint: NetworkEndpoint,
        interceptHTTPS: Bool = true,
        reverseProxyRoutes: [ReverseProxyRoute] = [],
        externalHTTPProxy: ExternalHTTPProxyConfiguration?
    ) {
        self.init(
            listenEndpoint: listenEndpoint,
            interceptHTTPS: interceptHTTPS,
            reverseProxyRoutes: reverseProxyRoutes,
            socks5Listener: nil,
            externalHTTPProxy: externalHTTPProxy
        )
    }

    public init(
        listenEndpoint: NetworkEndpoint,
        interceptHTTPS: Bool = true,
        reverseProxyRoutes: [ReverseProxyRoute] = [],
        socks5Listener: SOCKS5ListenerConfiguration?,
        externalHTTPProxy: ExternalHTTPProxyConfiguration?
    ) {
        self.listenEndpoint = listenEndpoint
        self.interceptHTTPS = interceptHTTPS
        self.reverseProxyRoutes = reverseProxyRoutes
        self.socks5Listener = socks5Listener
        self.externalHTTPProxy = externalHTTPProxy
    }

    private enum CodingKeys: String, CodingKey {
        case listenEndpoint
        case interceptHTTPS
        case reverseProxyRoutes
        case socks5Listener
        case externalHTTPProxy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            listenEndpoint: try container.decode(NetworkEndpoint.self, forKey: .listenEndpoint),
            interceptHTTPS: try container.decode(Bool.self, forKey: .interceptHTTPS),
            reverseProxyRoutes: try container.decodeIfPresent(
                [ReverseProxyRoute].self,
                forKey: .reverseProxyRoutes
            ) ?? [],
            socks5Listener: try container.decodeIfPresent(
                SOCKS5ListenerConfiguration.self,
                forKey: .socks5Listener
            ),
            externalHTTPProxy: try container.decodeIfPresent(
                ExternalHTTPProxyConfiguration.self,
                forKey: .externalHTTPProxy
            )
        )
        try validateListeners()
    }
}

public enum ProxyEngineState: Codable, Equatable, Hashable, Sendable {
    case stopped
    case starting
    case running(NetworkEndpoint)
    case stopping
    case failed(String)
}

public protocol ProxyEngine: Sendable {
    func start(configuration: ProxyConfiguration, sessionID: SessionID) async throws
    func stop() async
    func state() async -> ProxyEngineState
}
