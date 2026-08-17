import XCTest

@testable import ProxyLensCapture

final class SOCKS5HandshakeParserTests: XCTestCase {
    func testFragmentedGreetingAndDomainRequestPreserveApplicationBytes() throws {
        var parser = SOCKS5HandshakeParser()

        XCTAssertEqual(parser.receive([0x05]), [])
        XCTAssertEqual(parser.receive([0x02, 0x02]), [])
        XCTAssertEqual(parser.receive([0x00]), [.write([0x05, 0x00])])

        let domain = Array("example.com".utf8)
        let request =
            [0x05, 0x01, 0x00, 0x03, UInt8(domain.count)] + domain
            + [0x01, 0xbb] + Array("GET / HTTP/1.1\r\n".utf8)
        XCTAssertEqual(
            parser.receive(request),
            [
                .write(SOCKS5HandshakeParser.successReply),
                .connect(
                    try ConnectTarget(host: "example.com", port: 443),
                    leftover: Array("GET / HTTP/1.1\r\n".utf8)
                )
            ]
        )
    }

    func testCoalescedIPv4Negotiation() throws {
        var parser = SOCKS5HandshakeParser()
        let bytes: [UInt8] = [
            0x05, 0x01, 0x00,
            0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x1f, 0x90
        ]

        XCTAssertEqual(
            parser.receive(bytes),
            [
                .write([0x05, 0x00]),
                .write(SOCKS5HandshakeParser.successReply),
                .connect(try ConnectTarget(host: "127.0.0.1", port: 8_080), leftover: [])
            ]
        )
    }

    func testIPv6RequestIsAcceptedWithoutResolution() throws {
        var parser = SOCKS5HandshakeParser()
        XCTAssertEqual(parser.receive([0x05, 0x01, 0x00]), [.write([0x05, 0x00])])
        let address: [UInt8] = [
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 1
        ]

        let actions = parser.receive([0x05, 0x01, 0x00, 0x04] + address + [0x01, 0xbb])

        XCTAssertEqual(actions.first, .write(SOCKS5HandshakeParser.successReply))
        guard case .connect(let target, leftover: let leftover) = actions.last else {
            return XCTFail("Expected an IPv6 CONNECT target")
        }
        XCTAssertEqual(leftover, [])
        XCTAssertEqual(target.host, "2001:db8:0:0:0:0:0:1")
        XCTAssertEqual(target.port, 443)
    }

    func testUnsupportedAuthenticationCommandAndAddressTypeAreRejected() {
        var authParser = SOCKS5HandshakeParser()
        XCTAssertEqual(
            authParser.receive([0x05, 0x01, 0x02]),
            [.write([0x05, 0xff]), .close]
        )

        var bindParser = SOCKS5HandshakeParser()
        _ = bindParser.receive([0x05, 0x01, 0x00])
        XCTAssertEqual(
            bindParser.receive([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0, 80]),
            [.write(SOCKS5HandshakeParser.failureReply(code: 0x07)), .close]
        )

        var addressParser = SOCKS5HandshakeParser()
        _ = addressParser.receive([0x05, 0x01, 0x00])
        XCTAssertEqual(
            addressParser.receive([0x05, 0x01, 0x00, 0x09]),
            [.write(SOCKS5HandshakeParser.failureReply(code: 0x08)), .close]
        )
    }

    func testInvalidReservedByteEmptyDomainAndPortZeroAreRejected() {
        let invalidRequests: [[UInt8]] = [
            [0x05, 0x01, 0x01, 0x01, 127, 0, 0, 1, 0, 80],
            [0x05, 0x01, 0x00, 0x03, 0, 0, 80],
            [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0, 0]
        ]
        for request in invalidRequests {
            var parser = SOCKS5HandshakeParser()
            _ = parser.receive([0x05, 0x01, 0x00])
            XCTAssertEqual(
                parser.receive(request),
                [.write(SOCKS5HandshakeParser.failureReply(code: 0x01)), .close]
            )
        }
    }

    func testNegotiationBufferIsBounded() {
        var parser = SOCKS5HandshakeParser()
        let methods = Array(repeating: UInt8(0x02), count: 254) + [0x00]
        XCTAssertEqual(
            parser.receive([0x05, 0xff] + methods),
            [.write([0x05, 0x00])]
        )
        let domainPrefix: [UInt8] = [0x05, 0x01, 0x00, 0x03, 0xff]

        XCTAssertEqual(
            parser.receive(domainPrefix + Array(repeating: 0x61, count: 255) + [0x01]),
            [.close]
        )
    }
}
