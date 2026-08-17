import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import ProxyLensCore
import XCTest

@testable import ProxyLensCapture

final class HTTPUpstreamProxyConnectTests: XCTestCase {
    func testAuthenticatedConnectHandshakeTunnelsAfterAFragmentedSuccessResponse() throws {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        let route = try makeRoute(username: "proxy-user", password: "s3cr3t")
        let target = try makeTunnelTarget(host: "example.com", port: 443)
        let didConfigureTunnel = NIOLockedValueBox(false)

        try channel.pipeline.syncOperations.addHandler(
            HTTPUpstreamProxyConnectHandler(
                request: route.connectRequestBytes(
                    to: target,
                    allocator: channel.allocator
                ),
                readyPromise: promise,
                configureTunnel: { tunnel in
                    didConfigureTunnel.withLockedValue { $0 = true }
                    return tunnel.eventLoop.makeSucceededVoidFuture()
                }
            )
        )
        try channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/proxylens-connect"))
            .wait()

        let request = try XCTUnwrap(try channel.readOutbound(as: ByteBuffer.self))
        let requestText = String(buffer: request)
        XCTAssertTrue(requestText.hasPrefix("CONNECT example.com:443 HTTP/1.1\r\n"))
        XCTAssertTrue(requestText.contains("Host: example.com:443\r\n"))
        let token = Data("proxy-user:s3cr3t".utf8).base64EncodedString()
        XCTAssertTrue(requestText.contains("Proxy-Authorization: Basic \(token)\r\n"))
        XCTAssertTrue(requestText.hasSuffix("\r\n\r\n"))

        try channel.writeInbound(buffer(channel, "HTTP/1.1 200 Conn"))
        XCTAssertFalse(didConfigureTunnel.withLockedValue { $0 })
        try channel.writeInbound(buffer(channel, "ection Established\r\nVia: proxy\r\n\r\n"))

        XCTAssertTrue(didConfigureTunnel.withLockedValue { $0 })
        XCTAssertNotNil(try promise.futureResult.wait())
        XCTAssertThrowsError(
            try channel.pipeline.syncOperations.handler(
                type: HTTPUpstreamProxyConnectHandler.self
            )
        )
        _ = try channel.finish()
    }

    func testConnectHandshakeFailsClosedForRejectionsMalformedAndOversizedResponses() throws {
        let cases: [(response: String, expected: HTTPUpstreamProxyConnectError)] = [
            ("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n", .rejected(statusCode: 407)),
            ("HTTP/1.1 502 Bad Gateway\r\n\r\n", .rejected(statusCode: 502)),
            ("NOT-HTTP 200 OK\r\n\r\n", .malformedResponse),
            ("HTTP/1.1 2000 OK\r\n\r\n", .malformedResponse),
            ("HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\n", .unexpectedResponseBody),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", .unexpectedResponseBody),
            ("HTTP/1.1 200 OK\r\n\r\nleftover", .unexpectedResponseBody)
        ]

        for testCase in cases {
            let channel = EmbeddedChannel()
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            try startHandshake(on: channel, promise: promise)

            try? channel.writeInbound(buffer(channel, testCase.response))

            XCTAssertThrowsError(try promise.futureResult.wait()) { error in
                XCTAssertEqual(
                    error as? HTTPUpstreamProxyConnectError,
                    testCase.expected,
                    "response: \(testCase.response.debugDescription)"
                )
            }
            XCTAssertFalse(channel.isActive)
            _ = try? channel.finish()
        }
    }

    func testConnectHandshakeBoundsResponseHeadersAndFailsOnEarlyDisconnect() throws {
        let oversized = EmbeddedChannel()
        let oversizedPromise = oversized.eventLoop.makePromise(of: Channel.self)
        try startHandshake(on: oversized, promise: oversizedPromise)

        let padding = "HTTP/1.1 200 OK\r\nX-Pad: " + String(repeating: "a", count: 32 * 1_024)
        try? oversized.writeInbound(buffer(oversized, padding))

        XCTAssertThrowsError(try oversizedPromise.futureResult.wait()) { error in
            XCTAssertEqual(
                error as? HTTPUpstreamProxyConnectError,
                .responseHeadersTooLarge
            )
        }
        _ = try? oversized.finish()

        let closed = EmbeddedChannel()
        let closedPromise = closed.eventLoop.makePromise(of: Channel.self)
        try startHandshake(on: closed, promise: closedPromise)

        try closed.close().wait()

        XCTAssertThrowsError(try closedPromise.futureResult.wait()) { error in
            XCTAssertEqual(error as? HTTPUpstreamProxyConnectError, .connectionClosed)
        }
    }

    func testRouteBuildsAbsoluteFormTargetsAndStripsClientProxyAuthorization() throws {
        let route = try makeRoute(username: "proxy-user", password: "s3cr3t")
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Host", value: "example.com")
        headers.add(name: "Proxy-Authorization", value: "Basic spoofed")
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/orders?id=7",
            headers: headers
        )

        let forwarded = try route.requestHead(
            forwarding: head,
            to: try makeTarget(uri: "http://example.com/orders?id=7")
        )

        XCTAssertEqual(forwarded.uri, "http://example.com/orders?id=7")
        XCTAssertEqual(forwarded.headers["Host"], ["example.com"])
        let token = Data("proxy-user:s3cr3t".utf8).base64EncodedString()
        XCTAssertEqual(forwarded.headers["Proxy-Authorization"], ["Basic \(token)"])
    }

    func testRouteKeepsTheDefaultPortInConnectTargetsAndRequiresMatchingCredentials() throws {
        let allocator = ByteBufferAllocator()
        let route = try makeRoute()
        let target = try makeTunnelTarget(host: "example.com", port: 443)

        // RFC 9110 requires the authority form to carry an explicit port, even the default one.
        let request = String(buffer: route.connectRequestBytes(to: target, allocator: allocator))
        XCTAssertTrue(request.hasPrefix("CONNECT example.com:443 HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("Host: example.com:443\r\n"))
        XCTAssertFalse(request.contains("Proxy-Authorization"))

        let configuration = try ExternalHTTPProxyConfiguration(
            endpoint: NetworkEndpoint(host: "proxy.example.test", port: 3_128),
            username: "proxy-user",
            isEnabled: true
        )
        XCTAssertThrowsError(
            try ExternalHTTPProxyRoute(configuration: configuration, credentials: nil)
        ) { error in
            XCTAssertEqual(error as? ExternalHTTPProxyRouteError, .credentialsUnavailable)
        }
        XCTAssertThrowsError(
            try ExternalHTTPProxyRoute(
                configuration: configuration,
                credentials: try ExternalHTTPProxyCredentials(
                    username: "someone-else",
                    password: "s3cr3t"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ExternalHTTPProxyRouteError,
                .credentialsDoNotMatchConfiguration
            )
        }
    }

    private func startHandshake(
        on channel: EmbeddedChannel,
        promise: EventLoopPromise<Channel>
    ) throws {
        let route = try makeRoute()
        try channel.pipeline.syncOperations.addHandler(
            HTTPUpstreamProxyConnectHandler(
                request: route.connectRequestBytes(
                    to: try makeTunnelTarget(host: "example.com", port: 443),
                    allocator: channel.allocator
                ),
                readyPromise: promise,
                configureTunnel: { $0.eventLoop.makeSucceededVoidFuture() }
            )
        )
        try channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/proxylens-connect"))
            .wait()
        _ = try channel.readOutbound(as: ByteBuffer.self)
    }

    private func makeRoute(
        username: String? = nil,
        password: String? = nil
    ) throws -> ExternalHTTPProxyRoute {
        let configuration = try ExternalHTTPProxyConfiguration(
            endpoint: NetworkEndpoint(host: "proxy.example.test", port: 3_128),
            bypassHosts: ["localhost", "*.internal.test"],
            username: username,
            isEnabled: true
        )
        let credentials: ExternalHTTPProxyCredentials?
        if let username, let password {
            credentials = try ExternalHTTPProxyCredentials(
                username: username,
                password: password
            )
        } else {
            credentials = nil
        }
        return try ExternalHTTPProxyRoute(
            configuration: configuration,
            credentials: credentials
        )
    }

    private func makeTarget(uri: String) throws -> ProxyTarget {
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Host", value: "example.com")
        return try ProxyTarget(uri: uri, headers: headers)
    }

    private func makeTunnelTarget(host: String, port: Int) throws -> ProxyTarget {
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Host", value: host)
        return try ProxyTarget(
            uri: "/",
            headers: headers,
            tunnelTarget: try ConnectTarget(host: host, port: port),
            tunnelUsesTLS: true
        )
    }

    private func buffer(_ channel: EmbeddedChannel, _ text: String) -> ByteBuffer {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        return buffer
    }
}
