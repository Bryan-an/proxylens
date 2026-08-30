import Foundation
import XCTest

@testable import ProxyLensCore

final class CertificateDistributionTests: XCTestCase {
    func testOriginFormPathsMapToResources() {
        XCTAssertEqual(route("/ssl"), .setupPage)
        XCTAssertEqual(route("/"), .setupPage)
        XCTAssertEqual(route("/ssl/"), .setupPage)
        XCTAssertEqual(route("/ssl?platform=ios"), .setupPage)
        XCTAssertEqual(route("/proxylens.crt"), .derCertificate)
        XCTAssertEqual(route("/proxylens.pem"), .pemCertificate)
        XCTAssertNil(route("/anything-else"))
        XCTAssertNil(route("/ssl/deeper"))
    }

    func testAbsoluteFormMatchesOnlyTheReservedHost() {
        XCTAssertEqual(route("http://proxy.lens/ssl"), .setupPage)
        XCTAssertEqual(route("http://proxy.lens"), .setupPage)
        XCTAssertEqual(route("http://PROXY.LENS:9090/proxylens.crt"), .derCertificate)
        XCTAssertNil(route("http://example.com/ssl"))
        XCTAssertNil(route("http://example.com/proxylens.crt"))
        XCTAssertNil(route("https://proxy.lens/ssl"))
    }

    func testTunnelledAndReverseProxyRequestsNeverMatch() {
        XCTAssertNil(
            CertificateDistribution.resource(
                requestTarget: "/ssl",
                isTunnelled: true,
                isReverseProxyListener: false
            )
        )
        XCTAssertNil(
            CertificateDistribution.resource(
                requestTarget: "/ssl",
                isTunnelled: false,
                isReverseProxyListener: true
            )
        )
        XCTAssertNil(
            CertificateDistribution.resource(
                requestTarget: "http://proxy.lens/ssl",
                isTunnelled: true,
                isReverseProxyListener: false
            )
        )
    }

    func testDEREncodingStripsPEMArmour() throws {
        let der = Data([0x30, 0x82, 0x01, 0x02, 0x03, 0x04, 0x05])
        let pem = Data(
            """
            -----BEGIN CERTIFICATE-----
            \(der.base64EncodedString())
            -----END CERTIFICATE-----

            """.utf8
        )

        XCTAssertEqual(try CertificateDistribution.derEncodedCertificate(fromPEM: pem), der)
    }

    func testDEREncodingRejectsMaterialThatIsNotACertificate() {
        XCTAssertThrowsError(
            try CertificateDistribution.derEncodedCertificate(fromPEM: Data("not a pem".utf8))
        )
        XCTAssertThrowsError(
            try CertificateDistribution.derEncodedCertificate(
                fromPEM: Data(
                    """
                    -----BEGIN PRIVATE KEY-----
                    QUJD
                    -----END PRIVATE KEY-----
                    """.utf8
                )
            )
        )
        XCTAssertThrowsError(
            try CertificateDistribution.derEncodedCertificate(
                fromPEM: Data(
                    """
                    -----BEGIN CERTIFICATE-----
                    not base64 $$$
                    -----END CERTIFICATE-----
                    """.utf8
                )
            )
        )
    }

    func testSetupURLUsesTheProxyEndpoint() {
        XCTAssertEqual(
            CertificateSetupPage.setupURL(proxyHost: "192.168.1.7", proxyPort: 9_090),
            "http://192.168.1.7:9090/ssl"
        )
    }

    func testSetupPageCarriesTheEndpointAndCertificateLinks() {
        let html = CertificateSetupPage.html(proxyHost: "192.168.1.7", proxyPort: 9_090)

        XCTAssertTrue(html.contains("192.168.1.7"))
        XCTAssertTrue(html.contains("9090"))
        XCTAssertTrue(html.contains(CertificateDistribution.derCertificatePath))
        XCTAssertTrue(html.contains(CertificateDistribution.pemCertificatePath))
        XCTAssertTrue(html.lowercased().contains("ios"))
        XCTAssertTrue(html.lowercased().contains("android"))
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
    }

    func testSetupPageEscapesTheHostItIsGiven() {
        let html = CertificateSetupPage.html(proxyHost: "<script>alert(1)</script>", proxyPort: 1)

        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    private func route(_ requestTarget: String) -> CertificateDistributionResource? {
        CertificateDistribution.resource(
            requestTarget: requestTarget,
            isTunnelled: false,
            isReverseProxyListener: false
        )
    }
}
