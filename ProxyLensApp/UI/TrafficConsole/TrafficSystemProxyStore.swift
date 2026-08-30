import Foundation

enum TrafficSystemProxyStoreError: Error, Equatable, LocalizedError {
    case captureMustBeStopped

    var errorDescription: String? {
        switch self {
        case .captureMustBeStopped:
            "Stop capture before changing the system proxy setting."
        }
    }
}

/// Whether starting capture also points the macOS system proxy at ProxyLens.
///
/// Turning it off avoids the administrator authentication macOS requires for every network
/// configuration change — its authorization right caches credentials for only 30 seconds —
/// at the cost of capturing only what is pointed at the proxy explicitly.
@MainActor
protocol TrafficSystemProxyStoring: AnyObject {
    var configuresSystemProxy: Bool { get }

    func save(configuresSystemProxy: Bool)
}

@MainActor
final class InMemoryTrafficSystemProxyStore: TrafficSystemProxyStoring {
    private(set) var configuresSystemProxy: Bool

    init(configuresSystemProxy: Bool = true) {
        self.configuresSystemProxy = configuresSystemProxy
    }

    func save(configuresSystemProxy: Bool) {
        self.configuresSystemProxy = configuresSystemProxy
    }
}

@MainActor
final class UserDefaultsTrafficSystemProxyStore: TrafficSystemProxyStoring {
    static let defaultKey = "TrafficConsole.configuresSystemProxy"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var configuresSystemProxy: Bool {
        // Absent means never chosen, which keeps the behaviour ProxyLens has always had.
        guard defaults.object(forKey: key) != nil else {
            return true
        }
        return defaults.bool(forKey: key)
    }

    func save(configuresSystemProxy: Bool) {
        defaults.set(configuresSystemProxy, forKey: key)
    }
}
