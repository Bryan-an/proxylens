import Foundation
import ProxyLensCore
import XCTest

@testable import ProxyLensApplication

final class DNSSpoofRuleEngineTests: XCTestCase {
    func testEnginePublishesAValidatedConnectionRule() async throws {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot)

        let rule = try await engine.dnsSpoof(
            host: "api.example.com",
            address: " 127.0.0.1 "
        )

        XCTAssertEqual(rule.name, "DNS spoof api.example.com")
        XCTAssertEqual(rule.priority, 10)
        XCTAssertEqual(rule.phase, .connection)
        XCTAssertEqual(rule.matcher, .host(.exact("api.example.com")))
        XCTAssertEqual(
            rule.action,
            .dnsSpoof(try DNSSpoofSpec(address: "127.0.0.1"))
        )
        XCTAssertEqual(snapshot.currentRules().rules.map(\.id), [rule.id])
    }

    func testEngineRejectsNonLiteralDestinationsWithoutPublishingARule() async {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot)

        do {
            _ = try await engine.dnsSpoof(
                host: "api.example.com",
                address: "localhost"
            )
            XCTFail("Expected a hostname destination to be rejected")
        } catch {
            XCTAssertNotNil(error as? DNSSpoofSpecError)
        }

        XCTAssertTrue(snapshot.currentRules().rules.isEmpty)
    }

    func testDNSRuleRoundTripsInPortableProfiles() async throws {
        let engine = RuleEngine()
        _ = try await engine.dnsSpoof(host: "api.example.com", address: "::1")
        let profile = try await engine.makeProfile(name: "Local API")

        let data = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(RuleProfile.self, from: data)

        XCTAssertEqual(restored, profile)
    }
}
