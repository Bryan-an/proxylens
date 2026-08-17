import Foundation
import XCTest

@testable import ProxyLensCore

final class SOCKS5ListenerConfigurationTests: XCTestCase {
    func testConfigurationAcceptsOnlyNumericLoopbackEndpoints() throws {
        let ipv4 = try SOCKS5ListenerConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 10_800),
            isEnabled: true
        )
        let ipv6 = try SOCKS5ListenerConfiguration(
            listenEndpoint: NetworkEndpoint(host: "::1", port: 0),
            isEnabled: false
        )

        XCTAssertEqual(ipv4.listenEndpoint.port, 10_800)
        XCTAssertTrue(ipv4.isEnabled)
        XCTAssertEqual(ipv6.listenEndpoint.host, "::1")
        XCTAssertFalse(ipv6.isEnabled)

        for unsafeHost in ["localhost", "0.0.0.0", "::", "192.168.1.9"] {
            XCTAssertThrowsError(
                try SOCKS5ListenerConfiguration(
                    listenEndpoint: NetworkEndpoint(host: unsafeHost, port: 10_800)
                )
            ) { error in
                XCTAssertEqual(error as? SOCKS5ListenerConfigurationError, .loopbackRequired)
            }
        }
    }

    func testProxyConfigurationDecodesLegacyDocumentsWithSOCKSDisabled() throws {
        let legacy = Data(
            #"{"listenEndpoint":{"host":"127.0.0.1","port":9090},"interceptHTTPS":true}"#.utf8
        )

        let configuration = try JSONDecoder().decode(ProxyConfiguration.self, from: legacy)

        XCTAssertNil(configuration.socks5Listener)
        XCTAssertEqual(configuration.reverseProxyRoutes, [])
    }

    func testListenerValidationRejectsForwardAndReverseCollisions() throws {
        let socks = try SOCKS5ListenerConfiguration(
            listenEndpoint: NetworkEndpoint(host: "::1", port: 10_800),
            isEnabled: true
        )
        XCTAssertThrowsError(
            try ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 10_800),
                socks5Listener: socks
            ).validateListeners()
        ) { error in
            XCTAssertEqual(
                error as? ReverseProxyRouteError,
                .listenerCollision(socks.listenEndpoint)
            )
        }

        let reverse = try ReverseProxyRoute(
            name: "API",
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 10_800),
            upstreamURL: try XCTUnwrap(URL(string: "https://api.example.com"))
        )
        XCTAssertThrowsError(
            try ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                reverseProxyRoutes: [reverse],
                socks5Listener: socks
            ).validateListeners()
        ) { error in
            XCTAssertEqual(
                error as? ReverseProxyRouteError,
                .listenerCollision(reverse.listenEndpoint)
            )
        }

        let disabled = try SOCKS5ListenerConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
            isEnabled: false
        )
        XCTAssertNoThrow(
            try ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                socks5Listener: disabled
            ).validateListeners()
        )
    }

    func testConfigurationRoundTripsSOCKSListener() throws {
        let socks = try SOCKS5ListenerConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 10_800),
            isEnabled: true
        )
        let configuration = ProxyConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
            interceptHTTPS: true,
            socks5Listener: socks
        )

        let decoded = try JSONDecoder().decode(
            ProxyConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )

        XCTAssertEqual(decoded, configuration)
    }
}
