import Foundation

/// Serializes and parses request/response start lines and headers for breakpoint editing.
public enum HTTPMessageText: Sendable {
    public static func requestHeaders(_ request: HTTPRequest) -> String {
        let target = request.rawTarget ?? pathAndQuery(request.url)
        return messageText(
            firstLine: "\(request.method.rawValue) \(target) \(request.version.rawValue)",
            headers: request.headers
        )
    }

    public static func responseHeaders(_ response: HTTPResponse) -> String {
        let reason = response.reasonPhrase.map { " \($0)" } ?? ""
        return messageText(
            firstLine: "\(response.version.rawValue) \(response.statusCode)\(reason)",
            headers: response.headers
        )
    }

    public static func parseRequest(
        headersText: String,
        body: Data?,
        original: HTTPRequest
    ) throws -> HTTPRequest {
        let (firstLine, headers) = try parseMessage(headersText)
        let parts = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard parts.count >= 3 else {
            throw ProxyLensError.invalidHTTPMessage("Request line must be METHOD target version")
        }

        let method = HTTPMethod(rawValue: parts[0])
        let target = parts[1]
        let version = try parseVersion(parts[2...].joined(separator: " "))
        let url = try requestURL(target: target, headers: headers, original: original)
        let bodyReference = try resolvedBody(body, original: original.body, headers: headers)
        let synchronizedHeaders = try synchronizedBodyHeaders(
            headers,
            byteCount: bodyReference?.byteCount,
            replacingBody: body != nil
        )

        return HTTPRequest(
            method: method,
            url: url,
            headers: synchronizedHeaders,
            body: bodyReference,
            version: version,
            rawTarget: target
        )
    }

    public static func parseResponse(
        headersText: String,
        body: Data?,
        original: HTTPResponse
    ) throws -> HTTPResponse {
        let (firstLine, headers) = try parseMessage(headersText)
        let parts = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard parts.count >= 2 else {
            throw ProxyLensError.invalidHTTPMessage("Response line must be version status")
        }

        let version = try parseVersion(parts[0])
        guard let statusCode = Int(parts[1]), (100...999).contains(statusCode) else {
            throw ProxyLensError.invalidHTTPMessage("Invalid response status: \(parts[1])")
        }
        let reasonPhrase =
            parts.count > 2 ? parts[2...].joined(separator: " ") : original.reasonPhrase
        let bodyReference = try resolvedBody(body, original: original.body, headers: headers)
        let synchronizedHeaders = try synchronizedBodyHeaders(
            headers,
            byteCount: bodyReference?.byteCount,
            replacingBody: body != nil
        )

        return try HTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: synchronizedHeaders,
            body: bodyReference,
            version: version
        )
    }

    private static func messageText(firstLine: String, headers: HTTPHeaders) -> String {
        let fields = headers.map { "\($0.name): \($0.value)" }
        return ([firstLine] + fields).joined(separator: "\n")
    }

    private static func parseMessage(_ text: String) throws -> (String, HTTPHeaders) {
        let lines =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard let firstLine = lines.first, !firstLine.isEmpty else {
            throw ProxyLensError.invalidHTTPMessage("Message is missing a start line")
        }

        var headers = HTTPHeaders()
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw ProxyLensError.invalidHTTPMessage("Invalid header line: \(line)")
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            try headers.append(name: name, value: value)
        }

        return (firstLine, headers)
    }

    private static func parseVersion(_ token: String) throws -> HTTPVersion {
        switch token.uppercased() {
        case "HTTP/1.0":
            .http10
        case "HTTP/1.1":
            .http11
        default:
            throw ProxyLensError.invalidHTTPMessage("Unsupported HTTP version: \(token)")
        }
    }

    private static func requestURL(
        target: String,
        headers: HTTPHeaders,
        original: HTTPRequest
    ) throws -> URL {
        if let absolute = URL(string: target), let scheme = absolute.scheme,
            scheme.caseInsensitiveCompare("http") == .orderedSame
                || scheme.caseInsensitiveCompare("https") == .orderedSame
        {
            return absolute
        }

        guard target == "*" || target.hasPrefix("/") else {
            throw ProxyLensError.invalidHTTPMessage("Invalid request target: \(target)")
        }

        let host = headers.firstValue(for: "Host") ?? original.url.host ?? ""
        guard !host.isEmpty else {
            throw ProxyLensError.invalidHTTPMessage("Request is missing a Host header")
        }

        let scheme = original.url.scheme ?? "http"
        let path = target == "*" ? "/" : target
        guard let url = URL(string: "\(scheme)://\(host)\(path)") else {
            throw ProxyLensError.invalidURL("\(scheme)://\(host)\(path)")
        }
        return url
    }

    private static func resolvedBody(
        _ body: Data?,
        original: BodyReference?,
        headers: HTTPHeaders
    ) throws -> BodyReference? {
        guard let body else {
            return original
        }

        return BodyReference(
            inline: body,
            metadata: BodyMetadata(
                contentType: headers.firstValue(for: "Content-Type"),
                contentEncoding: headers.firstValue(for: "Content-Encoding")
            )
        )
    }

    private static func synchronizedBodyHeaders(
        _ headers: HTTPHeaders,
        byteCount: Int64?,
        replacingBody: Bool
    ) throws -> HTTPHeaders {
        guard replacingBody, let byteCount else {
            return headers
        }

        return
            try headers
            .removing(name: "Transfer-Encoding")
            .removing(name: "Content-Length")
            .appending(name: "Content-Length", value: "\(byteCount)")
    }

    private static func pathAndQuery(_ url: URL) -> String {
        var result = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            result += "?\(query)"
        }
        return result
    }
}
