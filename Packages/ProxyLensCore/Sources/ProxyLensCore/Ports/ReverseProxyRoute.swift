import Foundation

public enum ReverseProxyRouteError: Error, Equatable, LocalizedError, Sendable {
    case emptyName
    case nameTooLong(maximum: Int)
    case loopbackListenerRequired
    case invalidUpstreamURL
    case absoluteRequestTargetRequired
    case tooManyRoutes(maximum: Int)
    case listenerCollision(NetworkEndpoint)
    case selfReferentialRoute(NetworkEndpoint)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "Reverse proxy routes require a name."
        case .nameTooLong(let maximum):
            "Reverse proxy route names cannot exceed \(maximum) characters."
        case .loopbackListenerRequired:
            "Reverse proxy routes may listen only on 127.0.0.1 or ::1."
        case .invalidUpstreamURL:
            "The upstream must be an absolute HTTP or HTTPS URL without credentials, a query, or a fragment."
        case .absoluteRequestTargetRequired:
            "Reverse proxy requests must use an origin-form target beginning with /."
        case .tooManyRoutes(let maximum):
            "No more than \(maximum) reverse proxy routes may be configured."
        case .listenerCollision(let endpoint):
            "More than one proxy listener uses \(endpoint.host):\(endpoint.port)."
        case .selfReferentialRoute(let endpoint):
            "The reverse proxy route at \(endpoint.host):\(endpoint.port) points to itself."
        }
    }
}

public struct ReverseProxyRoute: Codable, Equatable, Hashable, Sendable {
    public static let maximumRouteCount = 32
    public static let maximumNameLength = 80
    public static let maximumURLLength = 2_048

    public let id: UUID
    public let name: String
    public let listenEndpoint: NetworkEndpoint
    public let upstreamURL: URL
    public let isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        listenEndpoint: NetworkEndpoint,
        upstreamURL: URL,
        isEnabled: Bool = true
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw ReverseProxyRouteError.emptyName
        }
        guard normalizedName.count <= Self.maximumNameLength else {
            throw ReverseProxyRouteError.nameTooLong(maximum: Self.maximumNameLength)
        }
        guard Self.isNumericLoopback(listenEndpoint.host) else {
            throw ReverseProxyRouteError.loopbackListenerRequired
        }

        self.id = id
        self.name = normalizedName
        self.listenEndpoint = listenEndpoint
        self.upstreamURL = try Self.normalizedUpstreamURL(upstreamURL)
        self.isEnabled = isEnabled
    }

    public func resolvedURL(forRequestTarget requestTarget: String) throws -> URL {
        guard requestTarget.hasPrefix("/"),
            requestTarget.count <= Self.maximumURLLength,
            let requestComponents = URLComponents(string: requestTarget),
            requestComponents.scheme == nil,
            requestComponents.host == nil,
            requestComponents.user == nil,
            requestComponents.password == nil,
            requestComponents.fragment == nil
        else {
            throw ReverseProxyRouteError.absoluteRequestTargetRequired
        }

        var resolvedComponents = try upstreamComponents()
        let basePath = resolvedComponents.percentEncodedPath
        let encodedRequestPath = requestComponents.percentEncodedPath
        if basePath.isEmpty || basePath == "/" {
            resolvedComponents.percentEncodedPath = encodedRequestPath
        } else if encodedRequestPath == "/" {
            resolvedComponents.percentEncodedPath = basePath + "/"
        } else {
            resolvedComponents.percentEncodedPath = basePath + encodedRequestPath
        }
        resolvedComponents.percentEncodedQuery = requestComponents.percentEncodedQuery

        guard let resolvedURL = resolvedComponents.url else {
            throw ReverseProxyRouteError.absoluteRequestTargetRequired
        }
        return resolvedURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case listenEndpoint
        case upstreamURL
        case isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            listenEndpoint: container.decode(NetworkEndpoint.self, forKey: .listenEndpoint),
            upstreamURL: container.decode(URL.self, forKey: .upstreamURL),
            isEnabled: container.decode(Bool.self, forKey: .isEnabled)
        )
    }

    static func isLoopback(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1" || normalized == "::1" || normalized == "localhost"
    }

    private static func isNumericLoopback(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1" || normalized == "::1"
    }

    private static func normalizedUpstreamURL(_ url: URL) throws -> URL {
        guard url.absoluteString.count <= maximumURLLength,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.port.map({ (1...65_535).contains($0) }) ?? true
        else {
            throw ReverseProxyRouteError.invalidUpstreamURL
        }

        components.scheme = scheme
        if components.percentEncodedPath.count > 1 {
            while components.percentEncodedPath.hasSuffix("/") {
                components.percentEncodedPath.removeLast()
            }
        }
        guard let normalized = components.url else {
            throw ReverseProxyRouteError.invalidUpstreamURL
        }
        return normalized
    }

    private func upstreamComponents() throws -> URLComponents {
        guard let components = URLComponents(url: upstreamURL, resolvingAgainstBaseURL: false)
        else {
            throw ReverseProxyRouteError.invalidUpstreamURL
        }
        return components
    }

}

extension ProxyConfiguration {
    public func validateReverseProxyRoutes() throws {
        try validateListeners()
    }

    public func validateListeners() throws {
        guard reverseProxyRoutes.count <= ReverseProxyRoute.maximumRouteCount else {
            throw ReverseProxyRouteError.tooManyRoutes(maximum: ReverseProxyRoute.maximumRouteCount)
        }

        var activeListeners = Set<NetworkEndpoint>()
        if let socks5Listener, socks5Listener.isEnabled,
            socks5Listener.listenEndpoint.port != 0
        {
            if listenersCollide(socks5Listener.listenEndpoint, listenEndpoint) {
                throw ReverseProxyRouteError.listenerCollision(socks5Listener.listenEndpoint)
            }
            activeListeners.insert(socks5Listener.listenEndpoint)
        }
        for route in reverseProxyRoutes where route.isEnabled {
            if route.listenEndpoint.port != 0,
                listenersCollide(route.listenEndpoint, listenEndpoint)
                    || activeListeners.contains(where: {
                        listenersCollide($0, route.listenEndpoint)
                    })
            {
                throw ReverseProxyRouteError.listenerCollision(route.listenEndpoint)
            }
            activeListeners.insert(route.listenEndpoint)

            if let upstreamHost = route.upstreamURL.host,
                route.listenEndpoint.port != 0,
                ReverseProxyRoute.isLoopback(upstreamHost),
                effectivePort(for: route.upstreamURL) == Int(route.listenEndpoint.port)
            {
                throw ReverseProxyRouteError.selfReferentialRoute(route.listenEndpoint)
            }
        }

        if let externalHTTPProxy, externalHTTPProxy.isEnabled,
            ReverseProxyRoute.isLoopback(externalHTTPProxy.endpoint.host),
            listenersCollide(externalHTTPProxy.endpoint, listenEndpoint)
                || activeListeners.contains(where: {
                    listenersCollide($0, externalHTTPProxy.endpoint)
                })
        {
            throw ExternalHTTPProxyConfigurationError.listenerCollision(
                externalHTTPProxy.endpoint
            )
        }
    }

    private func listenersCollide(_ lhs: NetworkEndpoint, _ rhs: NetworkEndpoint) -> Bool {
        guard lhs.port != 0, rhs.port != 0, lhs.port == rhs.port else { return false }
        if ReverseProxyRoute.isLoopback(lhs.host), ReverseProxyRoute.isLoopback(rhs.host) {
            return true
        }
        return lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame
    }

    private func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
