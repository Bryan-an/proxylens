import Foundation
import ProxyLensCore
import ProxyLensPlatform

enum TrafficRemoteAccessStoreError: Error, Equatable, LocalizedError {
    case captureMustBeStopped

    var errorDescription: String? {
        switch self {
        case .captureMustBeStopped:
            "Stop capture before changing who can reach this proxy."
        }
    }
}

@MainActor
protocol TrafficRemoteAccessStoring: AnyObject {
    var configuration: RemoteAccessConfiguration { get }

    func save(_ configuration: RemoteAccessConfiguration)
}

@MainActor
final class InMemoryTrafficRemoteAccessStore: TrafficRemoteAccessStoring {
    private(set) var configuration: RemoteAccessConfiguration

    init(configuration: RemoteAccessConfiguration = .disabled) {
        self.configuration = configuration
    }

    func save(_ configuration: RemoteAccessConfiguration) {
        self.configuration = configuration
    }
}

@MainActor
final class UserDefaultsTrafficRemoteAccessStore: TrafficRemoteAccessStoring {
    static let defaultKey = "TrafficConsole.remoteAccess"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var configuration: RemoteAccessConfiguration {
        guard
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(RemoteAccessConfiguration.self, from: data)
        else {
            return .disabled
        }
        return decoded
    }

    func save(_ configuration: RemoteAccessConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// Remembers the devices the user trusts across launches.
///
/// A plain class rather than an actor: the approval coordinator reaches it off the main
/// actor, and `UserDefaults` is already thread-safe, so adding isolation here would only
/// make the store harder to hand to that actor.
final class UserDefaultsRemoteDeviceStore: RemoteDeviceStore, @unchecked Sendable {
    static let defaultKey = "TrafficConsole.remoteDevices"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func loadDevices() async -> [RemoteDevice] {
        guard
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode([RemoteDevice].self, from: data)
        else {
            return []
        }
        return decoded
    }

    func save(_ devices: [RemoteDevice]) async {
        guard let data = try? JSONEncoder().encode(devices) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// The addresses of this Mac a device can be pointed at.
protocol TrafficLANAddressProviding: Sendable {
    func currentAddresses() -> [String]
}

struct MacOSLANAddressProvider: TrafficLANAddressProviding {
    func currentAddresses() -> [String] {
        LANInterfaceProvider.current().map(\.address)
    }
}

struct StaticLANAddressProvider: TrafficLANAddressProviding {
    let addresses: [String]

    func currentAddresses() -> [String] {
        addresses
    }
}
