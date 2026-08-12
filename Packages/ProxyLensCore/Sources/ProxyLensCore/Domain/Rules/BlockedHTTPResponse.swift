import Foundation

public enum BlockedHTTPResponse: Sendable {
    public static let statusCode = 403
    public static let reasonPhrase = "Forbidden"

    public static func message(reason: String?) -> String {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "Blocked by ProxyLens."
        }
        return trimmed
    }

    public static func make(reason: String?, version: HTTPVersion = .http11) throws -> HTTPResponse
    {
        let text = message(reason: reason) + "\n"
        let body = BodyReference(
            inline: Data(text.utf8),
            metadata: BodyMetadata(contentType: "text/plain; charset=utf-8")
        )
        var headers = HTTPHeaders()
        try headers.append(name: "Content-Type", value: "text/plain; charset=utf-8")
        try headers.append(name: "Content-Length", value: "\(body.byteCount)")
        try headers.append(name: "Connection", value: "close")
        return try HTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: headers,
            body: body,
            version: version
        )
    }
}
