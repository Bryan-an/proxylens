import Foundation
import XCTest

@testable import ProxyLensCore

final class DNSSpoofTests: XCTestCase {
    func testSpecAcceptsCanonicalIPv4AndIPv6Literals() throws {
        XCTAssertEqual(try DNSSpoofSpec(address: " 127.0.0.1 ").address, "127.0.0.1")
        XCTAssertEqual(try DNSSpoofSpec(address: "2001:0DB8::1").address, "2001:0db8::1")
    }

    func testSpecRejectsHostnamesPortsZonesAndMalformedAddresses() {
        for address in [
            "localhost",
            "127.0.0.1:8080",
            "[::1]",
            "fe80::1%en0",
            "192.168.1",
            "192.168.001.1",
            "2001::db8::1",
            ""
        ] {
            XCTAssertThrowsError(try DNSSpoofSpec(address: address), address)
        }
    }

    func testSpecRejectsInvalidPersistedValues() throws {
        let invalid = Data(#"{"address":"resolver.example.com"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DNSSpoofSpec.self, from: invalid))

        let original = try DNSSpoofSpec(address: "::1")
        let restored = try JSONDecoder().decode(
            DNSSpoofSpec.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(restored, original)
    }

    func testPlannerAppliesOnlyTheFirstConnectionPhaseDNSSpoofRule() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://api.example.com/items")!
        )
        let firstID = RuleID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let secondID = RuleID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let rules = RuleSet(rules: [
            Rule(
                id: secondID,
                name: "Second destination",
                priority: 20,
                phase: .connection,
                matcher: .host(.exact("api.example.com")),
                action: .dnsSpoof(try DNSSpoofSpec(address: "::1"))
            ),
            Rule(
                id: firstID,
                name: "First destination",
                priority: 10,
                phase: .connection,
                matcher: .host(.exact("api.example.com")),
                action: .dnsSpoof(try DNSSpoofSpec(address: "127.0.0.1"))
            )
        ])

        let plan = RulePlanner.plan(
            rules: rules,
            context: RuleMatchContext(request: request),
            phase: .connection
        )

        XCTAssertEqual(plan.dnsSpoofAddress, "127.0.0.1")
        XCTAssertEqual(plan.traces.map(\.ruleID), [firstID, secondID])
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyDNSSpoofedReason)
            ]
        )
    }

    func testPlannerSkipsDNSSpoofOutsideConnectionPhase() throws {
        let rule = Rule(
            name: "Wrong phase",
            phase: .requestHeaders,
            action: .dnsSpoof(try DNSSpoofSpec(address: "127.0.0.1"))
        )

        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [rule]),
            context: RuleMatchContext(
                request: HTTPRequest(
                    method: .get,
                    url: URL(string: "https://api.example.com")!
                )
            ),
            phase: .requestHeaders
        )

        XCTAssertNil(plan.dnsSpoofAddress)
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [.skipped(reason: RulePlanner.Decision.dnsSpoofPhaseReason)]
        )
    }
}
