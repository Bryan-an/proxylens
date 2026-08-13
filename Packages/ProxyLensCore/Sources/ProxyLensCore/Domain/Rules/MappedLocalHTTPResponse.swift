import Foundation

public enum MappedLocalHTTPResponse: Sendable {
    public static func make(
        spec: MapLocalSpec,
        version: HTTPVersion = .http11
    ) throws -> HTTPResponse {
        let contentType =
            spec.body.contentType
            ?? spec.headers.firstValue(for: "Content-Type")
            ?? "application/octet-stream"
        var headers = spec.headers
            .removing(name: "Content-Type")
            .removing(name: "Content-Length")
        try headers.append(name: "Content-Type", value: contentType)
        try headers.append(name: "Content-Length", value: "\(spec.body.byteCount)")
        if !headers.contains(name: "Connection") {
            try headers.append(name: "Connection", value: "close")
        }

        return try HTTPResponse(
            statusCode: spec.statusCode,
            reasonPhrase: spec.reasonPhrase ?? "OK",
            headers: headers,
            body: spec.body,
            version: version
        )
    }
}
