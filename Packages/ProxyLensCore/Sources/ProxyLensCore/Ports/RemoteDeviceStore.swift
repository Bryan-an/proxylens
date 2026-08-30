import Foundation

/// Durable storage for the devices the user has seen and the ones they trust.
///
/// Only trusted devices need to survive a relaunch; the rest are kept so the device list can
/// show what has connected during this session.
public protocol RemoteDeviceStore: Sendable {
    func loadDevices() async -> [RemoteDevice]
    func save(_ devices: [RemoteDevice]) async
}

/// A store that forgets everything on exit. The default for tests and for loopback-only use.
public actor InMemoryRemoteDeviceStore: RemoteDeviceStore {
    private var devices: [RemoteDevice]

    public init(devices: [RemoteDevice] = []) {
        self.devices = devices
    }

    public func loadDevices() async -> [RemoteDevice] {
        devices
    }

    public func save(_ devices: [RemoteDevice]) async {
        self.devices = devices
    }
}
