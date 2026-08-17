import NIOHTTP1
import XCTest

@testable import ProxyLensCapture

final class DNSSpoofRoutingTests: XCTestCase {
    func testPhysicalDestinationDoesNotChangeLogicalHTTPIdentity() throws {
        let target = try ProxyTarget(
            uri: "https://api.example.com:9443/items?id=7",
            headers: HTTPHeaders()
        )

        let routed = target.connecting(to: "127.0.0.1")

        XCTAssertEqual(routed.connectionHost, "127.0.0.1")
        XCTAssertEqual(routed.host, "api.example.com")
        XCTAssertEqual(routed.hostHeader, "api.example.com:9443")
        XCTAssertEqual(routed.url.absoluteString, target.url.absoluteString)
        XCTAssertEqual(routed.originForm, "/items?id=7")
        XCTAssertTrue(routed.usesTLS)
    }

    func testConnectionIdentitySeparatesDifferentPhysicalDestinations() throws {
        let target = try ProxyTarget(
            uri: "https://api.example.com/items",
            headers: HTTPHeaders()
        )

        XCTAssertNotEqual(
            target.connecting(to: "127.0.0.1").connectionIdentity,
            target.connecting(to: "::1").connectionIdentity
        )
        XCTAssertEqual(
            target.connecting(to: "127.0.0.1").connectionIdentity.logicalHost,
            "api.example.com"
        )
    }
}
