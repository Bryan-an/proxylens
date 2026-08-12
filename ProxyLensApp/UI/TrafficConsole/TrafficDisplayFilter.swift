import Foundation
import ProxyLensCore

enum TrafficMethodFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case get
    case post
    case put
    case patch
    case delete
    case head
    case options
    case connect
    case other

    func matches(_ method: HTTPMethod) -> Bool {
        switch self {
        case .all:
            true
        case .other:
            !Self.knownMethods.contains(method.rawValue)
        default:
            method.rawValue == rawValue.uppercased()
        }
    }

    private static let knownMethods = Set(
        allCases.lazy.filter { $0 != .all && $0 != .other }.map { $0.rawValue.uppercased() }
    )
}

enum TrafficStatusFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case informational
    case success
    case redirection
    case clientError
    case serverError
    case pending

    func matches(_ statusCode: Int?) -> Bool {
        switch self {
        case .all:
            true
        case .informational:
            statusCode.map { (100..<200).contains($0) } ?? false
        case .success:
            statusCode.map { (200..<300).contains($0) } ?? false
        case .redirection:
            statusCode.map { (300..<400).contains($0) } ?? false
        case .clientError:
            statusCode.map { (400..<500).contains($0) } ?? false
        case .serverError:
            statusCode.map { (500..<600).contains($0) } ?? false
        case .pending:
            statusCode == nil
        }
    }
}

enum TrafficContentTypeFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case json
    case html
    case xml
    case text
    case image
    case media
    case binary
    case other

    func matches(_ contentType: String?) -> Bool {
        guard self != .all else {
            return true
        }
        guard let contentType else {
            return self == .other
        }
        return Self.category(for: contentType) == self
    }

    private static func category(for contentType: String) -> TrafficContentTypeFilter {
        let mediaType =
            contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if mediaType == "application/json" || mediaType.hasSuffix("+json") {
            return .json
        }
        if mediaType == "text/html" || mediaType == "application/xhtml+xml" {
            return .html
        }
        if mediaType == "application/xml" || mediaType == "text/xml" || mediaType.hasSuffix("+xml")
        {
            return .xml
        }
        if mediaType.hasPrefix("image/") {
            return .image
        }
        if mediaType.hasPrefix("audio/") || mediaType.hasPrefix("video/") {
            return .media
        }
        if mediaType.hasPrefix("text/")
            || mediaType == "application/x-www-form-urlencoded"
            || mediaType == "application/javascript"
            || mediaType == "application/graphql"
        {
            return .text
        }
        if mediaType == "application/octet-stream"
            || mediaType == "application/pdf"
            || mediaType == "application/zip"
            || mediaType.hasSuffix("+protobuf")
        {
            return .binary
        }
        return .other
    }
}

enum TrafficOriginFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case desktopProxy
    case importedSession
    case replay

    func matches(_ kind: FlowSourceKind) -> Bool {
        switch self {
        case .all:
            true
        case .desktopProxy:
            kind == .desktopProxy
        case .importedSession:
            kind == .importedSession
        case .replay:
            kind == .replay
        }
    }
}

struct TrafficDisplayFilter: Equatable, Sendable {
    var searchText = ""
    var method: TrafficMethodFilter = .all
    var status: TrafficStatusFilter = .all
    var contentType: TrafficContentTypeFilter = .all
    var origin: TrafficOriginFilter = .all

    static let all = TrafficDisplayFilter()

    var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || method != .all
            || status != .all
            || contentType != .all
            || origin != .all
    }

    func matches(_ flow: Flow) -> Bool {
        matches(
            flow,
            searchableText: Self.searchableText(for: flow),
            searchTokens: normalizedSearchTokens
        )
    }

    var normalizedSearchTokens: [String] {
        searchText
            .split(whereSeparator: \.isWhitespace)
            .map { Self.normalized(String($0)) }
    }

    func matches(
        _ flow: Flow,
        searchableText: String,
        searchTokens: [String]
    ) -> Bool {
        method.matches(flow.request.method)
            && status.matches(flow.response?.statusCode)
            && contentType.matches(Self.contentType(for: flow))
            && origin.matches(flow.source.kind)
            && searchTokens.allSatisfy(searchableText.contains)
    }

    static func searchableText(for flow: Flow) -> String {
        normalized(searchFields(for: flow).joined(separator: "\n"))
    }

    private static func contentType(for flow: Flow) -> String? {
        flow.response?.body?.contentType
            ?? flow.response?.headers.firstValue(for: "Content-Type")
            ?? flow.request.body?.contentType
            ?? flow.request.headers.firstValue(for: "Content-Type")
    }

    private static func searchFields(for flow: Flow) -> [String] {
        var fields = [
            flow.request.method.rawValue,
            flow.request.url.absoluteString,
            flow.request.version.rawValue,
            flow.request.rawTarget ?? "",
            flow.source.kind.rawValue,
            flow.source.label,
            flow.source.clientAddress ?? "",
            String(describing: flow.state)
        ]
        fields.append(contentsOf: headerFields(flow.request.headers))
        appendBodyMetadata(flow.request.body, to: &fields)

        if let connection = flow.connection {
            fields.append(contentsOf: [
                connection.protocolKind.rawValue,
                connection.upstreamHost,
                String(connection.upstreamPort),
                connection.tlsIntercepted ? "TLS intercepted" : "TLS passthrough"
            ])
        }
        if let response = flow.response {
            fields.append(String(response.statusCode))
            fields.append(response.reasonPhrase ?? "")
            fields.append(response.version.rawValue)
            fields.append(contentsOf: headerFields(response.headers))
            appendBodyMetadata(response.body, to: &fields)
        }
        return fields
    }

    private static func headerFields(_ headers: HTTPHeaders) -> [String] {
        headers.flatMap { [$0.name, $0.value] }
    }

    private static func appendBodyMetadata(_ body: BodyReference?, to fields: inout [String]) {
        guard let body else {
            return
        }
        fields.append(contentsOf: [
            body.contentType ?? "",
            body.contentEncoding ?? "",
            body.digest?.value ?? "",
            String(body.byteCount),
            body.isTruncated ? "truncated" : "complete"
        ])
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
