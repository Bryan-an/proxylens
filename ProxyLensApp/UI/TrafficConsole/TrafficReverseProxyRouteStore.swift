import Foundation
import ProxyLensCore

enum TrafficReverseProxyRouteStoreError: Error, Equatable, LocalizedError {
    case invalidListenPort
    case captureMustBeStopped

    var errorDescription: String? {
        switch self {
        case .invalidListenPort:
            "The local port must be a number between 1 and 65535."
        case .captureMustBeStopped:
            "Stop capture before changing reverse proxy listeners."
        }
    }
}

struct TrafficReverseProxyRouteDraft: Equatable {
    var id: UUID?
    var name: String
    var listenHost: String
    var listenPort: String
    var upstreamURL: String
    var isEnabled: Bool

    init(
        id: UUID? = nil,
        name: String = "",
        listenHost: String = "127.0.0.1",
        listenPort: String = "8080",
        upstreamURL: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.upstreamURL = upstreamURL
        self.isEnabled = isEnabled
    }

    init(route: ReverseProxyRoute) {
        self.init(
            id: route.id,
            name: route.name,
            listenHost: route.listenEndpoint.host,
            listenPort: String(route.listenEndpoint.port),
            upstreamURL: route.upstreamURL.absoluteString,
            isEnabled: route.isEnabled
        )
    }

    func makeRoute() throws -> ReverseProxyRoute {
        let normalizedPort = listenPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(normalizedPort), port > 0 else {
            throw TrafficReverseProxyRouteStoreError.invalidListenPort
        }
        let normalizedURL = upstreamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalizedURL) else {
            throw ReverseProxyRouteError.invalidUpstreamURL
        }
        return try ReverseProxyRoute(
            id: id ?? UUID(),
            name: name,
            listenEndpoint: NetworkEndpoint(
                host: listenHost.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port
            ),
            upstreamURL: url,
            isEnabled: isEnabled
        )
    }
}

@MainActor
protocol TrafficReverseProxyRouteStoring: AnyObject {
    var routes: [ReverseProxyRoute] { get }

    func save(_ route: ReverseProxyRoute) throws
    func remove(id: UUID)
}

@MainActor
final class InMemoryTrafficReverseProxyRouteStore: TrafficReverseProxyRouteStoring {
    private(set) var routes: [ReverseProxyRoute]

    init(routes: [ReverseProxyRoute] = []) {
        self.routes = routes
    }

    func save(_ route: ReverseProxyRoute) throws {
        routes = try updatedRoutes(routes, saving: route)
    }

    func remove(id: UUID) {
        routes.removeAll { $0.id == id }
    }
}

@MainActor
final class UserDefaultsTrafficReverseProxyRouteStore: TrafficReverseProxyRouteStoring {
    static let defaultKey = "TrafficConsole.reverseProxyRoutes"

    private struct Document: Codable {
        let version: Int
        let routes: [ReverseProxyRoute]
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var routes: [ReverseProxyRoute] {
        guard let data = defaults.data(forKey: key),
            let document = try? JSONDecoder().decode(Document.self, from: data),
            document.version == 1,
            document.routes.count <= ReverseProxyRoute.maximumRouteCount,
            (try? validate(document.routes)) != nil
        else {
            return []
        }
        return document.routes
    }

    func save(_ route: ReverseProxyRoute) throws {
        let updated = try updatedRoutes(routes, saving: route)
        defaults.set(
            try JSONEncoder().encode(Document(version: 1, routes: updated)),
            forKey: key
        )
    }

    func remove(id: UUID) {
        let remaining = routes.filter { $0.id != id }
        if remaining.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(Document(version: 1, routes: remaining)) {
            defaults.set(data, forKey: key)
        }
    }
}

@MainActor
private func updatedRoutes(
    _ routes: [ReverseProxyRoute],
    saving route: ReverseProxyRoute
) throws -> [ReverseProxyRoute] {
    var result = routes
    if let index = result.firstIndex(where: { $0.id == route.id }) {
        result[index] = route
    } else {
        result.append(route)
    }
    try validate(result)
    return result
}

@MainActor
private func validate(_ routes: [ReverseProxyRoute]) throws {
    let configuration = ProxyConfiguration(
        listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
        interceptHTTPS: false,
        reverseProxyRoutes: routes
    )
    try configuration.validateReverseProxyRoutes()
}
