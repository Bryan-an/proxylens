import Foundation

public struct StringPattern: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case exact
        case wildcard
        case regularExpression
    }

    public let kind: Kind
    public let value: String
    public let caseSensitive: Bool

    public init(kind: Kind, value: String, caseSensitive: Bool = false) {
        self.kind = kind
        self.value = value
        self.caseSensitive = caseSensitive
    }

    public static func exact(_ value: String, caseSensitive: Bool = false) -> StringPattern {
        StringPattern(kind: .exact, value: value, caseSensitive: caseSensitive)
    }

    public static func wildcard(_ value: String, caseSensitive: Bool = false) -> StringPattern {
        StringPattern(kind: .wildcard, value: value, caseSensitive: caseSensitive)
    }

    public static func regularExpression(_ value: String, caseSensitive: Bool = false)
        -> StringPattern
    {
        StringPattern(kind: .regularExpression, value: value, caseSensitive: caseSensitive)
    }

    public func matches(_ candidate: String) -> Bool {
        switch kind {
        case .exact:
            if caseSensitive {
                return candidate == value
            }

            return candidate.caseInsensitiveCompare(value) == .orderedSame
        case .wildcard:
            return matchesRegularExpression(wildcardRegularExpression, candidate: candidate)
        case .regularExpression:
            return matchesRegularExpression(value, candidate: candidate)
        }
    }

    private var wildcardRegularExpression: String {
        let escaped = NSRegularExpression.escapedPattern(for: value)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return "^\(escaped)$"
    }

    private func matchesRegularExpression(_ pattern: String, candidate: String) -> Bool {
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]

        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return false
        }

        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return expression.firstMatch(in: candidate, range: range)?.range == range
    }
}

public indirect enum Matcher: Codable, Equatable, Hashable, Sendable {
    case any
    case host(StringPattern)
    case path(StringPattern)
    case query(StringPattern)
    case method(HTTPMethod)
    case header(name: String, value: StringPattern?)
    case source(StringPattern)
    case status(Int)
    case contentType(StringPattern)
    case graphqlOperation(name: StringPattern?, kind: GraphQLOperationMetadata.Kind?)
    case allOf([Matcher])
    case anyOf([Matcher])
    case not(Matcher)

    public func matches(_ context: RuleMatchContext) -> Bool {
        switch self {
        case .any:
            return true
        case .host(let pattern):
            return context.request?.url.host.map(pattern.matches) ?? false
        case .path(let pattern):
            return context.request.map { pattern.matches($0.url.path.isEmpty ? "/" : $0.url.path) }
                ?? false
        case .query(let pattern):
            return context.request.map { pattern.matches($0.url.query ?? "") } ?? false
        case .method(let method):
            return context.request?.method == method
        case .header(let name, let value):
            let values = context.headers.values(for: name)
            guard !values.isEmpty else {
                return false
            }

            guard let value else {
                return true
            }

            return values.contains(where: value.matches)
        case .source(let pattern):
            guard let source = context.source else {
                return false
            }

            return pattern.matches(source.label) || pattern.matches(source.kind.rawValue)
        case .status(let statusCode):
            return context.response?.statusCode == statusCode
        case .contentType(let pattern):
            return context.contentType.map(pattern.matches) ?? false
        case .graphqlOperation(let name, let kind):
            guard let operation = context.request?.graphqlOperation else {
                return false
            }
            if let kind, operation.kind != kind {
                return false
            }
            return name?.matches(operation.displayName) ?? true
        case .allOf(let matchers):
            return matchers.allSatisfy { $0.matches(context) }
        case .anyOf(let matchers):
            return matchers.contains { $0.matches(context) }
        case .not(let matcher):
            return !matcher.matches(context)
        }
    }
}

public struct RuleMatchContext: Sendable {
    public let request: HTTPRequest?
    public let response: HTTPResponse?
    public let source: FlowSource?

    public init(
        request: HTTPRequest? = nil,
        response: HTTPResponse? = nil,
        source: FlowSource? = nil
    ) {
        self.request = request
        self.response = response
        self.source = source
    }

    public init(flow: Flow) {
        self.init(request: flow.request, response: flow.response, source: flow.source)
    }

    public var headers: HTTPHeaders {
        response?.headers ?? request?.headers ?? HTTPHeaders()
    }

    public var contentType: String? {
        let value = headers.firstValue(for: "Content-Type")
        return value?.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first
            .map(String.init)
    }
}
