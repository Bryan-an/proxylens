import Foundation

/// Textual host handling shared by the listener, the flow-source resolvers, and the
/// remote-access policy.
///
/// Peer addresses reach ProxyLens in several spellings for the same host: bracketed IPv6
/// literals from URLs, scoped link-local addresses from the kernel, and IPv4-mapped IPv6
/// addresses from dual-stack sockets. Device identity and loopback classification both
/// depend on those collapsing to one value.
public enum NetworkAddress {
    private static let ipv4MappedPrefix = "::ffff:"

    /// Returns the lowercased host with brackets, an IPv6 zone identifier, and an
    /// IPv4-mapped IPv6 prefix removed.
    public static func normalizedHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if value.count >= 2, value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if let zoneStart = value.firstIndex(of: "%") {
            value = String(value[value.startIndex..<zoneStart])
        }
        if value.hasPrefix(ipv4MappedPrefix) {
            let mapped = String(value.dropFirst(ipv4MappedPrefix.count))
            if isIPv4(mapped) {
                value = mapped
            }
        }

        return value
    }

    /// Reports whether the host names this machine over the loopback interface.
    ///
    /// The whole `127.0.0.0/8` block counts, not just `127.0.0.1`, because a client may
    /// bind any address in it.
    public static func isLoopback(_ host: String) -> Bool {
        let normalized = normalizedHost(host)
        guard !normalized.isEmpty else {
            return false
        }
        if normalized == "::1" || normalized == "localhost" {
            return true
        }
        guard isIPv4(normalized) else {
            return false
        }
        return normalized.hasPrefix("127.")
    }

    private static func isIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return false
        }
        return octets.allSatisfy { octet in
            !octet.isEmpty && octet.count <= 3 && UInt8(octet) != nil
        }
    }
}
