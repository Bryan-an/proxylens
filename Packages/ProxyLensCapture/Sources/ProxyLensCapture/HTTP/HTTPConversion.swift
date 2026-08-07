import NIOHTTP1
import ProxyLensCore

enum HTTPConversion {
    static func coreHeaders(from headers: NIOHTTP1.HTTPHeaders) throws -> ProxyLensCore.HTTPHeaders
    {
        var result = ProxyLensCore.HTTPHeaders()

        for (name, value) in headers {
            try result.append(name: name, value: value)
        }

        return result
    }

    static func coreVersion(from version: NIOHTTP1.HTTPVersion) throws -> ProxyLensCore.HTTPVersion
    {
        guard version.major == 1, version.minor == 0 || version.minor == 1 else {
            throw ProxyLensError.unsupportedOperation("HTTP version \(version)")
        }

        return version.minor == 0 ? .http10 : .http11
    }

    static func sanitizedRequestHeaders(_ headers: NIOHTTP1.HTTPHeaders) -> NIOHTTP1.HTTPHeaders {
        var result = NIOHTTP1.HTTPHeaders()

        for (name, value) in headers where !hopByHopHeaders.contains(name.lowercased()) {
            result.add(name: name, value: value)
        }

        result.add(name: "Connection", value: "close")
        return result
    }

    static func sanitizedResponseHead(_ head: NIOHTTP1.HTTPResponseHead)
        -> NIOHTTP1.HTTPResponseHead
    {
        var result = head
        var headers = NIOHTTP1.HTTPHeaders()

        for (name, value) in head.headers where !hopByHopHeaders.contains(name.lowercased()) {
            headers.add(name: name, value: value)
        }

        headers.add(name: "Connection", value: "close")
        result.headers = headers
        return result
    }

    static func sanitizedTrailers(_ trailers: NIOHTTP1.HTTPHeaders?) -> NIOHTTP1.HTTPHeaders? {
        guard let trailers else {
            return nil
        }

        var result = NIOHTTP1.HTTPHeaders()
        for (name, value) in trailers where !hopByHopHeaders.contains(name.lowercased()) {
            result.add(name: name, value: value)
        }
        return result
    }

    private static let hopByHopHeaders: Set<String> = [
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade"
    ]
}
