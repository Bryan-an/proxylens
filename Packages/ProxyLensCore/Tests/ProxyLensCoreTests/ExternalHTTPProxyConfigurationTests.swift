import Foundation
import XCTest

@testable import ProxyLensCore

final class ExternalHTTPProxyConfigurationTests: XCTestCase {
    func testConfigurationNormalizesEndpointAndBypassHosts() throws {
        let configuration = try ExternalHTTPProxyConfiguration(
            endpoint: NetworkEndpoint(host: " Proxy.Example.COM ", port: 8_080),
            bypassHosts: [" API.Example.com ", "*.Internal.Example.com", "::1"],
            username: " proxy-user ",
            isEnabled: true
        )

        XCTAssertEqual(
            configuration.endpoint, NetworkEndpoint(host: "proxy.example.com", port: 8_080))
        XCTAssertEqual(
            configuration.bypassHosts,
            ["api.example.com", "*.internal.example.com", "::1"]
        )
        XCTAssertEqual(configuration.username, "proxy-user")
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertFalse(configuration.shouldProxy(host: "api.example.com"))
        XCTAssertFalse(configuration.shouldProxy(host: "cdn.internal.example.com"))
        XCTAssertTrue(configuration.shouldProxy(host: "internal.example.com"))
        XCTAssertTrue(configuration.shouldProxy(host: "public.example.com"))
    }

    func testConfigurationRejectsUnsafeOrUnboundedValues() throws {
        for host in ["", "http://proxy.example.com", "user@proxy.example.com", "proxy example.com"]
        {
            XCTAssertThrowsError(
                try ExternalHTTPProxyConfiguration(
                    endpoint: NetworkEndpoint(host: host, port: 8_080)
                ),
                host
            )
        }
        XCTAssertThrowsError(
            try ExternalHTTPProxyConfiguration(
                endpoint: NetworkEndpoint(host: "proxy.example.com", port: 0)
            )
        )
        for bypass in ["https://example.com", "foo*bar.example", "user@example.com", "/local"] {
            XCTAssertThrowsError(
                try ExternalHTTPProxyConfiguration(
                    endpoint: NetworkEndpoint(host: "proxy.example.com", port: 8_080),
                    bypassHosts: [bypass]
                ),
                bypass
            )
        }
        XCTAssertThrowsError(
            try ExternalHTTPProxyConfiguration(
                endpoint: NetworkEndpoint(host: "proxy.example.com", port: 8_080),
                bypassHosts: ["example.com", "EXAMPLE.COM"]
            )
        )
        XCTAssertThrowsError(
            try ExternalHTTPProxyConfiguration(
                endpoint: NetworkEndpoint(host: "proxy.example.com", port: 8_080),
                bypassHosts: (0...ExternalHTTPProxyConfiguration.maximumBypassHostCount).map {
                    "host\($0).example.com"
                }
            )
        )
        XCTAssertThrowsError(
            try ExternalHTTPProxyConfiguration(
                endpoint: NetworkEndpoint(host: "proxy.example.com", port: 8_080),
                username: "bad:user"
            )
        )
    }

    func testDisabledConfigurationNeverRoutesAndCredentialsValidateWithoutDescriptionLeak() throws {
        let configuration = try ExternalHTTPProxyConfiguration(
            endpoint: NetworkEndpoint(host: "proxy.example.com", port: 8_080),
            isEnabled: false
        )
        XCTAssertFalse(configuration.shouldProxy(host: "public.example.com"))

        let credentials = try ExternalHTTPProxyCredentials(
            username: "proxy-user",
            password: "super-secret"
        )
        XCTAssertEqual(credentials.username, "proxy-user")
        XCTAssertEqual(credentials.password, "super-secret")
        XCTAssertFalse(String(describing: credentials).contains("super-secret"))
        XCTAssertThrowsError(
            try ExternalHTTPProxyCredentials(username: "proxy:user", password: "secret")
        )
    }

    func testProxyConfigurationRoundTripsNonSecretSettingsAndDecodesLegacyDocuments() throws {
        let external = try ExternalHTTPProxyConfiguration(
            endpoint: NetworkEndpoint(host: "proxy.example.com", port: 3_128),
            bypassHosts: ["localhost", "*.example.test"],
            username: "proxy-user",
            isEnabled: true
        )
        let configuration = ProxyConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
            externalHTTPProxy: external
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ProxyConfiguration.self,
                from: JSONEncoder().encode(configuration)
            ),
            configuration
        )

        let legacy = Data(
            #"{"listenEndpoint":{"host":"127.0.0.1","port":9090},"interceptHTTPS":true}"#.utf8
        )
        XCTAssertNil(
            try JSONDecoder().decode(ProxyConfiguration.self, from: legacy).externalHTTPProxy
        )
    }

    func testEnabledExternalProxyCannotPointAtAnActiveLocalListener() throws {
        let external = try ExternalHTTPProxyConfiguration(
            endpoint: NetworkEndpoint(host: "localhost", port: 9_090),
            isEnabled: true
        )
        XCTAssertThrowsError(
            try ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
                externalHTTPProxy: external
            ).validateListeners()
        ) { error in
            XCTAssertEqual(
                error as? ExternalHTTPProxyConfigurationError,
                .listenerCollision(external.endpoint)
            )
        }
    }
}
