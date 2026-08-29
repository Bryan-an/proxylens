import Foundation

/// Whether the forward listener accepts connections from other machines on the local
/// network.
///
/// Disabled means the listener stays on loopback, which is the shipped default. Enabling it
/// only changes the bind address: every non-loopback client is still authorized one at a
/// time through ``RemoteAccessGate``.
public struct RemoteAccessConfiguration: Codable, Equatable, Hashable, Sendable {
    /// The address the forward listener binds while remote access is enabled.
    ///
    /// IPv4 only. An IPv6-only local network is out of scope for device onboarding.
    public static let anyIPv4Host = "0.0.0.0"

    public static let disabled = RemoteAccessConfiguration(isEnabled: false)

    public let isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }
}

/// A client the forward listener has accepted but not yet admitted.
public struct RemoteAccessClient: Equatable, Hashable, Sendable {
    /// The normalized peer host, without a port. This is a device's identity.
    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16) {
        self.address = NetworkAddress.normalizedHost(address)
        self.port = port
    }

    public var isLoopback: Bool {
        NetworkAddress.isLoopback(address)
    }
}

public enum RemoteAccessDecision: Equatable, Sendable {
    case allow
    case deny
}

/// Decides whether an accepted connection may be proxied.
///
/// The listener consults this for every accepted forward connection and installs no HTTP
/// pipeline until it answers, so an implementation may suspend while a person decides.
/// Loopback policy lives in the implementation, not in the listener.
public protocol RemoteAccessGate: Sendable {
    func authorize(_ client: RemoteAccessClient) async -> RemoteAccessDecision
}

/// Admits every client. The default for loopback-only setups and for tests.
public struct AllowAllRemoteAccessGate: RemoteAccessGate {
    public init() {}

    public func authorize(_: RemoteAccessClient) async -> RemoteAccessDecision {
        .allow
    }
}
