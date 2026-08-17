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

    static func nioHeaders(from headers: ProxyLensCore.HTTPHeaders) -> NIOHTTP1.HTTPHeaders {
        var result = NIOHTTP1.HTTPHeaders()
        for field in headers {
            result.add(name: field.name, value: field.value)
        }
        return result
    }

    static func coreVersion(from version: NIOHTTP1.HTTPVersion) throws -> ProxyLensCore.HTTPVersion
    {
        switch (version.major, version.minor) {
        case (1, 0):
            return .http10
        case (1, 1):
            return .http11
        case (2, 0):
            return .http2
        default:
            throw ProxyLensError.unsupportedOperation("HTTP version \(version)")
        }
    }

    static func upstreamVersion(for downstreamVersion: NIOHTTP1.HTTPVersion) -> NIOHTTP1.HTTPVersion
    {
        downstreamVersion.major == 2 ? .http1_1 : downstreamVersion
    }

    static func nioVersion(from version: ProxyLensCore.HTTPVersion) -> NIOHTTP1.HTTPVersion {
        switch version {
        case .http10:
            return .http1_0
        case .http11:
            return .http1_1
        case .http2:
            return NIOHTTP1.HTTPVersion(major: 2, minor: 0)
        case .http3:
            return NIOHTTP1.HTTPVersion(major: 3, minor: 0)
        }
    }

    static func sanitizedRequestHeaders(
        _ headers: NIOHTTP1.HTTPHeaders,
        preservingWebSocketUpgrade: Bool = false
    ) -> NIOHTTP1.HTTPHeaders {
        var result = NIOHTTP1.HTTPHeaders()

        for (name, value) in headers where !hopByHopHeaders.contains(name.lowercased()) {
            result.add(name: name, value: value)
        }

        if preservingWebSocketUpgrade {
            result.add(name: "Connection", value: "Upgrade")
            result.add(name: "Upgrade", value: "websocket")
        } else {
            result.add(name: "Connection", value: "close")
        }
        return result
    }

    static func sanitizedResponseHead(
        _ head: NIOHTTP1.HTTPResponseHead,
        preservingWebSocketUpgrade: Bool = false
    )
        -> NIOHTTP1.HTTPResponseHead
    {
        var result = head
        var headers = NIOHTTP1.HTTPHeaders()

        for (name, value) in head.headers where !hopByHopHeaders.contains(name.lowercased()) {
            headers.add(name: name, value: value)
        }

        if preservingWebSocketUpgrade {
            headers.add(name: "Connection", value: "Upgrade")
            headers.add(name: "Upgrade", value: "websocket")
        } else {
            headers.add(name: "Connection", value: "close")
        }
        result.headers = headers
        return result
    }

    static func isWebSocketUpgradeRequest(_ head: HTTPRequestHead) -> Bool {
        isWebSocketUpgradeHeaders(head.headers)
    }

    static func isWebSocketUpgradeHeaders(_ headers: NIOHTTP1.HTTPHeaders) -> Bool {
        headerContainsToken(headers[canonicalForm: "Connection"], token: "upgrade")
            && headerContainsToken(headers[canonicalForm: "Upgrade"], token: "websocket")
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

    private static func headerContainsToken<Values: Sequence>(
        _ values: Values,
        token: String
    ) -> Bool where Values.Element: StringProtocol {
        values.contains { value in
            value.split(separator: ",").contains {
                String($0).trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(token) == .orderedSame
            }
        }
    }
}
