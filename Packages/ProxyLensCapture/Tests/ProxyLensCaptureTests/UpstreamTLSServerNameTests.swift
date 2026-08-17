import NIOHTTP1
import NIOSSL
import ProxyLensCore
import XCTest

@testable import ProxyLensCapture

/// RFC 6066 forbids an IP address in the SNI extension, and NIOSSL enforces that by throwing.
/// Upstream TLS therefore has to omit the server name for IP-literal destinations while keeping it
/// for every named host.
final class UpstreamTLSServerNameTests: XCTestCase {
    func testIPLiteralDestinationsOmitTheTLSServerName() throws {
        for host in ["192.168.1.5", "127.0.0.1", "::1", "2001:db8::1"] {
            XCTAssertNil(
                try makeTarget(host: host).tlsServerName,
                "expected no SNI for \(host)"
            )
        }
    }

    func testNamedDestinationsKeepTheTLSServerName() throws {
        for host in ["example.com", "api.example.test", "localhost", "1.example.com"] {
            XCTAssertEqual(
                try makeTarget(host: host).tlsServerName,
                host,
                "expected SNI for \(host)"
            )
        }
    }

    /// Pins the NIOSSL behaviour this helper exists to avoid: an IP literal passed as the server
    /// name throws, so every upstream TLS site must go through `tlsServerName`.
    func testUpstreamHandlerAcceptsIPLiteralsOnlyThroughTheHelper() throws {
        let context = try TLSContextFactory.upstreamContext(
            configuration: UpstreamTLSConfiguration()
        )

        for host in ["192.168.1.5", "::1"] {
            let target = try makeTarget(host: host)
            XCTAssertThrowsError(
                try NIOSSLClientHandler(context: context, serverHostname: target.host)
            ) { error in
                XCTAssertEqual(
                    error as? NIOSSLExtraError,
                    .cannotUseIPAddressInSNI,
                    "NIOSSL no longer rejects IP literals in SNI; revisit tlsServerName"
                )
            }
            XCTAssertNoThrow(
                try NIOSSLClientHandler(context: context, serverHostname: target.tlsServerName)
            )
        }

        let named = try makeTarget(host: "example.com")
        XCTAssertNoThrow(
            try NIOSSLClientHandler(context: context, serverHostname: named.tlsServerName)
        )
    }

    /// DNS Spoofing rewrites only the physical `connectionHost`; the logical host still supplies
    /// SNI, so a spoofed named destination must keep sending its server name.
    func testDNSSpoofedNamedDestinationStillSendsTheLogicalServerName() throws {
        let spoofed = try makeTarget(host: "example.com").connecting(to: "203.0.113.7")

        XCTAssertEqual(spoofed.connectionHost, "203.0.113.7")
        XCTAssertEqual(spoofed.tlsServerName, "example.com")
    }

    private func makeTarget(host: String) throws -> ProxyTarget {
        var headers = NIOHTTP1.HTTPHeaders()
        let authority = host.contains(":") ? "[\(host)]" : host
        headers.add(name: "Host", value: authority)
        return try ProxyTarget(
            uri: "/",
            headers: headers,
            tunnelTarget: try ConnectTarget(host: host, port: 443),
            tunnelUsesTLS: true
        )
    }
}
