public enum NoCacheHeaders: Sendable {
    public static func applyingToRequest(_ headers: HTTPHeaders) throws -> HTTPHeaders {
        var result =
            headers
            .removing(name: "If-Modified-Since")
            .removing(name: "If-None-Match")
            .removing(name: "If-Unmodified-Since")
            .removing(name: "If-Match")
            .removing(name: "If-Range")
        result = try result.replacing(name: "Cache-Control", with: "no-cache")
        return try result.replacing(name: "Pragma", with: "no-cache")
    }

    public static func applyingToResponse(_ headers: HTTPHeaders) throws -> HTTPHeaders {
        var result =
            headers
            .removing(name: "Age")
            .removing(name: "ETag")
            .removing(name: "Last-Modified")
        result = try result.replacing(
            name: "Cache-Control",
            with: "no-store, no-cache, must-revalidate, max-age=0"
        )
        result = try result.replacing(name: "Pragma", with: "no-cache")
        return try result.replacing(name: "Expires", with: "0")
    }
}
