import Darwin
import Foundation
import ProxyLensCore

/// An address on this Mac that a device on the same network can be pointed at.
public struct LANInterface: Equatable, Hashable, Sendable {
    public let name: String
    public let address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// Enumerates the addresses worth printing in the device setup instructions.
///
/// IPv4 only, matching the forward listener's bind. Interfaces that exist but cannot carry
/// device traffic — loopback, AirDrop, tunnels, self-assigned addresses — are left out
/// rather than shown as choices that will not work.
public enum LANInterfaceProvider {
    private static let excludedNamePrefixes = ["lo", "awdl", "llw", "utun", "ipsec", "gif", "stf"]

    /// The usable addresses, ordered with ordinary Ethernet and Wi-Fi interfaces first.
    public static func current() -> [LANInterface] {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else {
            return []
        }
        defer { freeifaddrs(addressList) }

        var interfaces: [LANInterface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard
                let socketAddress = entry.pointee.ifa_addr,
                socketAddress.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }

            let name = String(cString: entry.pointee.ifa_name)
            guard
                let address = presentationAddress(of: socketAddress),
                isUsable(name: name, flags: entry.pointee.ifa_flags, address: address)
            else {
                continue
            }

            interfaces.append(LANInterface(name: name, address: address))
        }

        return interfaces.sorted { lhs, rhs in
            let lhsIsEthernet = lhs.name.hasPrefix("en")
            let rhsIsEthernet = rhs.name.hasPrefix("en")
            if lhsIsEthernet != rhsIsEthernet {
                return lhsIsEthernet
            }
            return lhs.name < rhs.name
        }
    }

    /// Whether an interface can carry traffic from a device on the local network.
    static func isUsable(name: String, flags: UInt32, address: String) -> Bool {
        guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0 else {
            return false
        }
        guard flags & UInt32(IFF_LOOPBACK) == 0 else {
            return false
        }
        guard !excludedNamePrefixes.contains(where: { name.hasPrefix($0) }) else {
            return false
        }
        guard !NetworkAddress.isLoopback(address) else {
            return false
        }
        // 169.254.0.0/16 is what macOS assigns when DHCP failed.
        guard !address.hasPrefix("169.254.") else {
            return false
        }
        return true
    }

    private static func presentationAddress(
        of socketAddress: UnsafeMutablePointer<sockaddr>
    ) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            socketAddress,
            socklen_t(socketAddress.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard status == 0 else {
            return nil
        }
        let address = host.withUnsafeBufferPointer { buffer -> String in
            guard let base = buffer.baseAddress else {
                return ""
            }
            return String(cString: base)
        }
        return address.isEmpty ? nil : address
    }
}
