import Foundation
import XCTest

@testable import ProxyLensCore

final class RemoteAccessTests: XCTestCase {
    func testNormalizedHostUnwrapsBracketsZonesAndMappedIPv4() {
        XCTAssertEqual(NetworkAddress.normalizedHost("[::1]"), "::1")
        XCTAssertEqual(NetworkAddress.normalizedHost("FE80::1%en0"), "fe80::1")
        XCTAssertEqual(NetworkAddress.normalizedHost("[fe80::1%en0]"), "fe80::1")
        XCTAssertEqual(NetworkAddress.normalizedHost("::ffff:192.168.1.7"), "192.168.1.7")
        XCTAssertEqual(NetworkAddress.normalizedHost("  192.168.1.7 "), "192.168.1.7")
    }

    func testLoopbackClassification() {
        XCTAssertTrue(NetworkAddress.isLoopback("127.0.0.1"))
        XCTAssertTrue(NetworkAddress.isLoopback("127.4.5.6"))
        XCTAssertTrue(NetworkAddress.isLoopback("[::1]"))
        XCTAssertTrue(NetworkAddress.isLoopback("::ffff:127.0.0.1"))
        XCTAssertTrue(NetworkAddress.isLoopback("localhost"))
        XCTAssertFalse(NetworkAddress.isLoopback("192.168.1.7"))
        XCTAssertFalse(NetworkAddress.isLoopback("0.0.0.0"))
        XCTAssertFalse(NetworkAddress.isLoopback("fe80::1"))
        XCTAssertFalse(NetworkAddress.isLoopback(""))
    }

    func testRemoteAccessIsDisabledByDefault() {
        XCTAssertFalse(RemoteAccessConfiguration.disabled.isEnabled)
        XCTAssertFalse(RemoteAccessConfiguration().isEnabled)
        XCTAssertEqual(RemoteAccessConfiguration.anyIPv4Host, "0.0.0.0")
    }

    func testForwardListenHostSwitchesWithRemoteAccess() {
        let loopback = ProxyConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090)
        )
        XCTAssertEqual(loopback.forwardListenHost, "127.0.0.1")
        XCTAssertFalse(loopback.remoteAccess.isEnabled)

        let remote = ProxyConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
            remoteAccess: RemoteAccessConfiguration(isEnabled: true)
        )
        XCTAssertEqual(remote.forwardListenHost, "0.0.0.0")
        XCTAssertEqual(remote.listenEndpoint.host, "127.0.0.1")
    }

    func testRemoteAccessSurvivesConfigurationCoding() throws {
        let configuration = ProxyConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090),
            interceptHTTPS: true,
            reverseProxyRoutes: [],
            socks5Listener: nil,
            externalHTTPProxy: nil,
            remoteAccess: RemoteAccessConfiguration(isEnabled: true)
        )

        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(ProxyConfiguration.self, from: encoded)

        XCTAssertEqual(decoded, configuration)
        XCTAssertTrue(decoded.remoteAccess.isEnabled)
    }

    func testLegacyProxyConfigurationDecodesWithRemoteAccessDisabled() throws {
        let legacy = Data(
            #"{"listenEndpoint":{"host":"127.0.0.1","port":9090},"interceptHTTPS":true}"#.utf8
        )

        let decoded = try JSONDecoder().decode(ProxyConfiguration.self, from: legacy)

        XCTAssertFalse(decoded.remoteAccess.isEnabled)
        XCTAssertEqual(decoded.forwardListenHost, "127.0.0.1")
    }

    func testAllowAllGateAllowsEveryClient() async {
        let gate = AllowAllRemoteAccessGate()

        let decision = await gate.authorize(
            RemoteAccessClient(address: "192.168.1.7", port: 51_000)
        )

        XCTAssertEqual(decision, .allow)
    }

    func testRemoteAccessClientNormalizesItsAddress() {
        let client = RemoteAccessClient(address: "::ffff:192.168.1.7", port: 51_000)

        XCTAssertEqual(client.address, "192.168.1.7")
        XCTAssertEqual(client.port, 51_000)
    }
}
