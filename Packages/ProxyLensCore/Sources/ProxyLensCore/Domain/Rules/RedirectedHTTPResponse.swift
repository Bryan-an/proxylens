import Foundation

public enum RedirectedHTTPResponse: Sendable {
    public static let statusCode = 307
    public static let reasonPhrase = "Temporary Redirect"

    public static func make(
        destination: URL,
        version: HTTPVersion = .http11
    ) throws -> HTTPResponse {
        var headers = HTTPHeaders()
        try headers.append(name: "Location", value: destination.absoluteString)
        try headers.append(name: "Content-Length", value: "0")
        try headers.append(name: "Connection", value: "close")
        return try HTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: headers,
            version: version
        )
    }
}
