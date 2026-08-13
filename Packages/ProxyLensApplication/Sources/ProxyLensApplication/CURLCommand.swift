import Foundation
import ProxyLensCore

enum CURLCommand {
    private static let skippedHeaderNames: Set<String> = [
        "content-length",
        "transfer-encoding",
        "connection",
        "keep-alive",
        "proxy-connection",
        "te",
        "trailers",
        "upgrade"
    ]

    static func serialize(
        request: HTTPRequest,
        body: Data?,
        comments: [String] = []
    ) -> String {
        var parts: [String] = comments.map { "# \($0)" }
        var arguments = ["curl", posixSingleQuoted(request.url.absoluteString)]

        if request.method != .get {
            arguments.append("-X")
            arguments.append(posixSingleQuoted(request.method.rawValue))
        }

        for header in request.headers where !shouldSkipHeader(header.name) {
            arguments.append("-H")
            arguments.append(posixSingleQuoted("\(header.name): \(header.value)"))
        }

        if let body {
            arguments.append("--data-binary")
            arguments.append(dataArgument(body))
        }

        parts.append(arguments.joined(separator: " "))
        return parts.joined(separator: "\n")
    }

    private static func shouldSkipHeader(_ name: String) -> Bool {
        skippedHeaderNames.contains(name.lowercased())
    }

    private static func dataArgument(_ data: Data) -> String {
        if !data.contains(0), let text = String(data: data, encoding: .utf8) {
            return posixSingleQuoted(text)
        }

        var escaped = "$'"
        for byte in data {
            escaped.append(String(format: "\\x%02x", byte))
        }
        escaped.append("'")
        return escaped
    }

    private static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
