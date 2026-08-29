import Foundation

public enum TLSInterceptionMode: String, CaseIterable, Codable, Equatable, Hashable,
    Sendable
{
    case interceptAllExcept
    case interceptOnly
}

public enum TLSInterceptionPolicyError: Error, Equatable, LocalizedError, Sendable {
    case invalidEntry(String)
    case duplicateEntry(String)
    case tooManyEntries(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEntry(let entry):
            "\"\(entry)\" is not a valid host pattern."
        case .duplicateEntry(let entry):
            "\"\(entry)\" appears more than once."
        case .tooManyEntries(let maximum):
            "The SSL proxying list supports at most \(maximum) entries."
        }
    }
}

/// Decides per host whether a TLS tunnel is intercepted with the local CA or
/// spliced through untouched. Matching mirrors
/// `ExternalHTTPProxyConfiguration.bypassHosts`: entries are exact hosts or
/// leading `*.` wildcards, and a wildcard never matches the bare apex.
public struct TLSInterceptionPolicy: Codable, Equatable, Hashable, Sendable {
    public static let maximumEntryCount = 256
    public static let maximumHostLength = HostPatternNormalizer.maximumHostLength

    public let mode: TLSInterceptionMode
    public let entries: [String]

    public init() {
        self.mode = .interceptAllExcept
        self.entries = []
    }

    public init(mode: TLSInterceptionMode, entries: [String]) throws {
        guard entries.count <= Self.maximumEntryCount else {
            throw TLSInterceptionPolicyError.tooManyEntries(
                maximum: Self.maximumEntryCount
            )
        }
        var normalizedEntries: [String] = []
        var seen = Set<String>()
        for entry in entries {
            guard let normalized = Self.normalize(entry, allowsWildcard: true)
            else {
                throw TLSInterceptionPolicyError.invalidEntry(entry)
            }
            guard seen.insert(normalized).inserted else {
                throw TLSInterceptionPolicyError.duplicateEntry(normalized)
            }
            normalizedEntries.append(normalized)
        }
        self.mode = mode
        self.entries = normalizedEntries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mode: container.decode(TLSInterceptionMode.self, forKey: .mode),
            entries: container.decode([String].self, forKey: .entries)
        )
    }

    public func matches(host: String) -> Bool {
        guard let normalizedHost = Self.normalize(host, allowsWildcard: false)
        else {
            return false
        }
        return entries.contains { entry in
            if entry.hasPrefix("*.") {
                let suffix = String(entry.dropFirst(2))
                return normalizedHost.hasSuffix(".\(suffix)")
            }
            return normalizedHost == entry
        }
    }

    public func shouldIntercept(host: String) -> Bool {
        switch mode {
        case .interceptAllExcept:
            !matches(host: host)
        case .interceptOnly:
            matches(host: host)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case entries
    }

    private static func normalize(_ value: String, allowsWildcard: Bool)
        -> String?
    {
        HostPatternNormalizer.normalize(value, allowsWildcard: allowsWildcard)
    }
}
