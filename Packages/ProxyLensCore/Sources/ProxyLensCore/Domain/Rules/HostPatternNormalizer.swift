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
