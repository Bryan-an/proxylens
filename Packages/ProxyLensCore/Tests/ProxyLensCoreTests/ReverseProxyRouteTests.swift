import Foundation
import XCTest

@testable import ProxyLensCore

final class ReverseProxyRouteTests: XCTestCase {
    func testRouteNormalizesAndResolvesOriginFormAgainstBasePath() throws {
        let route = try ReverseProxyRoute(
            name: "  Local API  ",
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 8_080),
            upstreamURL: try XCTUnwrap(URL(string: "https://api.example.com:8443/v1/"))
        )

        XCTAssertEqual(route.name, "Local API")
        XCTAssertEqual(route.upstreamURL.absoluteString, "https://api.example.com:8443/v1")
        XCTAssertTrue(route.isEnabled)
        XCTAssertEqual(
            try route.resolvedURL(forRequestTarget: "/users%20active?id=7").absoluteString,
            "https://api.example.com:8443/v1/users%20active?id=7"
        )
        XCTAssertEqual(
            try route.resolvedURL(forRequestTarget: "/").absoluteString,
            "https://api.example.com:8443/v1/"
        )
    }

    func testRouteRejectsUnsafeOrAmbiguousConfiguration() throws {
        let validEndpoint = NetworkEndpoint(host: "127.0.0.1", port: 8_080)

        XCTAssertThrowsError(
            try ReverseProxyRoute(
                name: " ",
                listenEndpoint: validEndpoint,
                upstreamURL: try XCTUnwrap(URL(string: "https://api.example.com"))
            )
        )
        XCTAssertThrowsError(
            try ReverseProxyRoute(
                name: "LAN",
                listenEndpoint: NetworkEndpoint(host: "0.0.0.0", port: 8_080),
                upstreamURL: try XCTUnwrap(URL(string: "https://api.example.com"))
            )
        )

        for unsafeURL in [
            "ftp://api.example.com",
            "https://user:secret@api.example.com",
            "https://api.example.com/v1?token=secret",
            "https://api.example.com/v1#fragment"
        ] {
            XCTAssertThrowsError(
                try ReverseProxyRoute(
                    name: "Unsafe",
                    listenEndpoint: validEndpoint,
                    upstreamURL: try XCTUnwrap(URL(string: unsafeURL))
                ),
                unsafeURL
            )
        }

        let route = try ReverseProxyRoute(
            name: "Safe",
            listenEndpoint: validEndpoint,
            upstreamURL: try XCTUnwrap(URL(string: "http://api.example.com"))
        )
        XCTAssertThrowsError(try route.resolvedURL(forRequestTarget: "http://attacker.test/"))
        XCTAssertThrowsError(try route.resolvedURL(forRequestTarget: "relative"))
    }

    func testRouteAndConfigurationDecodingRevalidatePersistedData() throws {
        let route = try ReverseProxyRoute(
            name: "Local API",
            listenEndpoint: NetworkEndpoint(host: "::1", port: 8_080),
            upstreamURL: try XCTUnwrap(URL(string: "http://api.example.com/base")),
            isEnabled: false
        )
        let data = try JSONEncoder().encode(route)
        XCTAssertEqual(try JSONDecoder().decode(ReverseProxyRoute.self, from: data), route)

        let invalid = Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","name":"Unsafe","listenEndpoint":{"host":"0.0.0.0","port":8080},"upstreamURL":"https:\/\/api.example.com","isEnabled":true}"#
                .utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(ReverseProxyRoute.self, from: invalid))

        let legacy = Data(
            #"{"listenEndpoint":{"host":"127.0.0.1","port":9090},"interceptHTTPS":true}"#.utf8
        )
        let configuration = try JSONDecoder().decode(ProxyConfiguration.self, from: legacy)
        XCTAssertEqual(configuration.reverseProxyRoutes, [])
    }

    func testConfigurationRejectsCollisionsLoopsAndExcessiveRoutes() throws {
        let first = try ReverseProxyRoute(
            name: "First",
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 8_080),
            upstreamURL: try XCTUnwrap(URL(string: "https://api.example.com"))
        )
        let duplicate = try ReverseProxyRoute(
            name: "Duplicate",
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 8_080),
            upstreamURL: try XCTUnwrap(URL(string: "https://other.example.com"))
        )
        let disabledDuplicate = try ReverseProxyRoute(
            name: "Disabled",
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 8_080),
            upstreamURL: try XCTUnwrap(URL(string: "https://disabled.example.com")),
            isEnabled: false
        )

        XCTAssertNoThrow(
            try ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                reverseProxyRoutes: [first, disabledDuplicate]
            ).validateReverseProxyRoutes()
        )
        XCTAssertThrowsError(
            try ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                reverseProxyRoutes: [first, duplicate]
            ).validateReverseProxyRoutes()
        )

        let listenerCollision = try ReverseProxyRoute(
            name: "Forward collision",
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
            upstreamURL: try XCTUnwrap(URL(string: "https://api.example.com"))
        )
        XCTAssertThrowsError(
            try ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                reverseProxyRoutes: [listenerCollision]
            ).validateReverseProxyRoutes()
        )

        let selfLoop = try ReverseProxyRoute(
            name: "Loop",
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 8_081),
            upstreamURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8081"))
        )
        XCTAssertThrowsError(
            try ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                reverseProxyRoutes: [selfLoop]
            ).validateReverseProxyRoutes()
        )

        let tooMany = try (0...ReverseProxyRoute.maximumRouteCount).map { index in
            try ReverseProxyRoute(
                name: "Route \(index)",
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: UInt16(10_000 + index)),
                upstreamURL: try XCTUnwrap(URL(string: "https://api\(index).example.com"))
            )
        }
        XCTAssertThrowsError(
            try ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                reverseProxyRoutes: tooMany
            ).validateReverseProxyRoutes()
        )
    }
}
