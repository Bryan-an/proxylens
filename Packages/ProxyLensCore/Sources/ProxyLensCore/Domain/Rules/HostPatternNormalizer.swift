import Foundation

enum HostPatternNormalizer {
    static let maximumHostLength = 253

    static func normalize(_ value: String, allowsWildcard: Bool) -> String? {
        var normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        let wildcardPrefix = allowsWildcard && normalized.hasPrefix("*.")
        var host = wildcardPrefix ? String(normalized.dropFirst(2)) : normalized
        // A single trailing dot marks a fully-qualified domain name (e.g. a client
        // dialing "example.com." to bypass search-domain resolution) and is
        // equivalent to the same host without it. Strip exactly one so both forms
        // normalize identically; leave "." and multi-dot trailing runs alone so the
        // emptiness/".." checks below still reject them.
        if host.hasSuffix("."), !host.hasSuffix("..") {
            host = String(host.dropLast())
        }
        guard !host.isEmpty,
            host.count <= maximumHostLength,
            !host.contains(where: \.isWhitespace),
            !containsControlCharacter(host),
            !host.contains(where: { "/?#@*".contains($0) }),
            !host.hasPrefix("."),
            !host.hasSuffix("."),
            !host.contains("..")
        else {
            return nil
        }
        return wildcardPrefix ? "*.\(host)" : host
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}
