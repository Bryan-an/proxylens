import Foundation

enum HostPatternNormalizer {
    static let maximumHostLength = 253

    static func normalize(_ value: String, allowsWildcard: Bool) -> String? {
        var normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        // A single trailing dot marks a fully-qualified domain name (e.g. a client
        // dialing "example.com." to bypass search-domain resolution) and is
        // equivalent to the same host without it. Strip exactly one, before the bracket
        // check below, so a bracket-wrapped literal is still recognized as such. Skip the
        // strip when the dot directly follows a closing bracket ("[::1]."): a trailing
        // dot has no FQDN meaning on an IP literal, so leaving it in place lets the
        // ordinary hasSuffix(".") guard below reject the value outright, exactly as any
        // trailing dot was rejected before this exception existed. Also leave "." and
        // multi-dot trailing runs alone so the emptiness/".." checks below still reject
        // them.
        if normalized.hasSuffix("."), !normalized.hasSuffix(".."),
            !normalized.hasSuffix("].")
        {
            normalized = String(normalized.dropLast())
        }
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        let wildcardPrefix = allowsWildcard && normalized.hasPrefix("*.")
        let host = wildcardPrefix ? String(normalized.dropFirst(2)) : normalized
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
