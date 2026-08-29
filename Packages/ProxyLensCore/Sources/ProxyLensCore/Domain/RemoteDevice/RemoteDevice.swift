import Foundation

/// A device on the local network that has connected to the forward listener.
///
/// Identity is the peer IP address. It is the only stable handle available before any
/// traffic is inspected, and it is what the user recognises in the approval prompt.
public struct RemoteDevice: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The normalized peer address. Also the device's identity.
    public let address: String

    /// A name the user gave this device, if any.
    public var name: String?

    /// Whether the user chose to keep admitting this device across sessions.
    public var isTrusted: Bool

    public var firstSeenAt: Date
    public var lastSeenAt: Date

    public var id: String { address }

    public var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return address
        }
        return name
    }

    public init(
        address: String,
        name: String? = nil,
        isTrusted: Bool = false,
        firstSeenAt: Date,
        lastSeenAt: Date? = nil
    ) {
        self.address = NetworkAddress.normalizedHost(address)
        self.name = name
        self.isTrusted = isTrusted
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt ?? firstSeenAt
    }
}
