import NIOCore
import NIOHTTP1
import ProxyLensCore
import XCTest

@testable import ProxyLensCapture

/// IPv6 literal destinations reach `ConnectTarget` from two directions: a client `CONNECT
/// [::1]:8443` request target and a SOCKS5 request carrying raw address bytes. Both must produce
/// the same unbracketed stored host, and every URL built from it must bracket it again.
final class IPv6ConnectTargetTests: XCTestCase {
    func testConnectAuthorityAcceptsBracketedIPv6LiteralsAndStoresThemUnbracketed() throws {
        let explicitPort = try ConnectTarget(authority: "[::1]:8443")
        XCTAssertEqual(explicitPort.host, "::1")
        XCTAssertEqual(explicitPort.port, 8_443)

        let defaultPort = try ConnectTarget(authority: "[2001:db8::1]")
        XCTAssertEqual(defaultPort.host, "2001:db8::1")
        XCTAssertEqual(defaultPort.port, 443)

        // A SOCKS5 request supplies the same address without brackets; both spellings converge.
        XCTAssertEqual(try ConnectTarget(host: "[::1]", port: 8_443), explicitPort)
        XCTAssertEqual(try ConnectTarget(host: "::1", port: 8_443), explicitPort)
    }

    func testConnectAuthorityStillRejectsMalformedBracketedHosts() throws {
        for authority in ["[]", "[]:8443", "[::1", "::1]:8443", "[[::1]]:8443"] {
            XCTAssertThrowsError(
                try ConnectTarget(authority: authority),
                "accepted malformed authority: \(authority)"
            )
        }
        XCTAssertThrowsError(try ConnectTarget(host: "[]", port: 8_443))
    }

    func testTunneledProxyTargetBuildsABracketedURLAndHostHeaderForIPv6() throws {
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Host", value: "[::1]:8443")
        let target = try ProxyTarget(
            uri: "/orders?id=7",
            headers: headers,
            tunnelTarget: try ConnectTarget(authority: "[::1]:8443"),
            tunnelUsesTLS: true
        )

        XCTAssertEqual(target.host, "::1")
        XCTAssertEqual(target.port, 8_443)
        XCTAssertEqual(target.url.absoluteString, "https://[::1]:8443/orders?id=7")
        XCTAssertEqual(target.hostHeader, "[::1]:8443")
        XCTAssertEqual(target.originForm, "/orders?id=7")
    }

    func testTunneledProxyTargetOmitsTheDefaultPortFromTheIPv6URL() throws {
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Host", value: "[2001:db8::1]")
        let target = try ProxyTarget(
            uri: "/",
            headers: headers,
            tunnelTarget: try ConnectTarget(authority: "[2001:db8::1]"),
            tunnelUsesTLS: true
        )

        XCTAssertEqual(target.url.absoluteString, "https://[2001:db8::1]/")
        XCTAssertEqual(target.hostHeader, "[2001:db8::1]")
    }

    func testExternalProxyBuildsABracketedIPv6ConnectRequest() throws {
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Host", value: "[::1]:8443")
        let target = try ProxyTarget(
            uri: "/",
            headers: headers,
            tunnelTarget: try ConnectTarget(authority: "[::1]:8443"),
            tunnelUsesTLS: true
        )
        let route = try ExternalHTTPProxyRoute(
            configuration: try ExternalHTTPProxyConfiguration(
                endpoint: NetworkEndpoint(host: "proxy.example.test", port: 3_128),
                isEnabled: true
            ),
            credentials: nil
        )

        let request = String(
            buffer: route.connectRequestBytes(to: target, allocator: ByteBufferAllocator())
        )

        XCTAssertTrue(request.hasPrefix("CONNECT [::1]:8443 HTTP/1.1\r\n"), request)
        XCTAssertTrue(request.contains("Host: [::1]:8443\r\n"), request)
    }
}
