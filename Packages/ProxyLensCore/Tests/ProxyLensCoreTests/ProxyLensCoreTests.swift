import Foundation
import XCTest

@testable import ProxyLensCore

final class ProxyLensCoreTests: XCTestCase {
    func testHTTPHeadersPreserveOrderDuplicatesAndCaseInsensitiveLookup() throws {
        let headers = HTTPHeaders([
            try HTTPHeader(name: "Set-Cookie", value: "a=1"),
            try HTTPHeader(name: "Content-Type", value: "application/json"),
            try HTTPHeader(name: "set-cookie", value: "b=2")
        ])

        XCTAssertEqual(headers.count, 3)
        XCTAssertEqual(headers.values(for: "set-cookie"), ["a=1", "b=2"])
        XCTAssertEqual(headers.firstValue(for: "CONTENT-TYPE"), "application/json")
        XCTAssertEqual(headers.map(\.name), ["Set-Cookie", "Content-Type", "set-cookie"])

        let replaced = try headers.replacing(name: "content-type", with: "text/plain")
        XCTAssertEqual(replaced.values(for: "content-type"), ["text/plain"])
        XCTAssertEqual(replaced.values(for: "set-cookie"), ["a=1", "b=2"])
    }

    func testHTTPHeadersRejectInvalidFieldSyntax() {
        XCTAssertThrowsError(try HTTPHeader(name: "Bad Header", value: "value")) { error in
            XCTAssertEqual(error as? ProxyLensError, .invalidHeaderName("Bad Header"))
        }

        XCTAssertThrowsError(try HTTPHeader(name: "X-Test", value: "line\nbreak")) { error in
            XCTAssertEqual(error as? ProxyLensError, .invalidHeaderValue("line\nbreak"))
        }
    }

    func testBodyReferenceKeepsInlineBytesAndMetadata() throws {
        let bytes = Data("raw bytes".utf8)
        let digest = BodyDigest(algorithm: .sha256, value: "abc123")
        let body = BodyReference(
            inline: bytes,
            metadata: BodyMetadata(
                contentType: "application/octet-stream",
                contentEncoding: "identity",
                digest: digest,
                isTruncated: true
            )
        )

        XCTAssertEqual(body.byteCount, Int64(bytes.count))
        XCTAssertEqual(body.storage, .inline(bytes))
        XCTAssertEqual(body.contentType, "application/octet-stream")
        XCTAssertEqual(body.digest, digest)
        XCTAssertTrue(body.isTruncated)
        XCTAssertTrue(body.isInline)

        XCTAssertThrowsError(
            try BodyReference(byteCount: -1, storage: .external(BodyID()))
        ) { error in
            XCTAssertEqual(error as? ProxyLensError, .invalidBodySize(-1))
        }
    }

    func testFlowLifecycleRejectsInvalidTransitionsAndBuildsSummary() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let sessionID = SessionID(
            rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        let body = BodyReference(inline: Data("request".utf8))
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://api.example.com/v1/items?draft=true")!,
            headers: HTTPHeaders([try HTTPHeader(name: "Content-Type", value: "application/json")]),
            body: body
        )
        var flow = Flow(sessionID: sessionID, request: request, startedAt: start)

        XCTAssertEqual(flow.state, .created)
        try flow.transition(to: .receivingRequest)
        try flow.transition(to: .connectingUpstream)
        flow.markRequestHeadersReceived(at: start.addingTimeInterval(0.1))
        flow.markRequestBodyCompleted(at: start.addingTimeInterval(0.2))
        flow.markUpstreamConnected(at: start.addingTimeInterval(0.3))

        let response = try HTTPResponse(
            statusCode: 200,
            headers: HTTPHeaders([try HTTPHeader(name: "Content-Type", value: "application/json")]),
            body: BodyReference(inline: Data("response".utf8))
        )
        flow.attachResponse(response)
        try flow.transition(to: .receivingResponse)
        flow.markResponseHeadersReceived(at: start.addingTimeInterval(0.5))
        flow.markResponseBodyCompleted(at: start.addingTimeInterval(0.8))
        flow.markCompleted(at: start.addingTimeInterval(1.0))
        try flow.transition(to: .completed)

        XCTAssertTrue(flow.state.isTerminal)
        XCTAssertEqual(flow.summary.statusCode, 200)
        XCTAssertEqual(flow.summary.requestByteCount, 7)
        XCTAssertEqual(flow.summary.responseByteCount, 8)
        XCTAssertEqual(flow.summary.totalDuration ?? -1, 1.0, accuracy: 0.0001)

        XCTAssertThrowsError(try flow.transition(to: .receivingRequest)) { error in
            guard case .invalidFlowTransition(let from, let to) = error as? ProxyLensError else {
                return XCTFail("Expected an invalid flow transition error")
            }

            XCTAssertEqual(from, .completed)
            XCTAssertEqual(to, .receivingRequest)
        }
    }

    func testFlowCanPreserveAnIncompleteFailure() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "http://localhost:8080/")!)
        var flow = Flow(sessionID: SessionID(), request: request)

        try flow.transition(to: .receivingRequest)
        try flow.transition(to: .failed(.upstreamUnavailable))

        XCTAssertEqual(flow.state, .failed(.upstreamUnavailable))
        XCTAssertTrue(flow.state.isTerminal)
    }

    func testFlowTimingCalculatesPhaseDurations() {
        let start = Date(timeIntervalSince1970: 2_000)
        var timing = FlowTiming(startedAt: start)

        timing.markRequestBodyCompleted(at: start.addingTimeInterval(0.25))
        timing.markResponseHeadersReceived(at: start.addingTimeInterval(0.5))
        timing.markResponseBodyCompleted(at: start.addingTimeInterval(1.25))
        timing.markCompleted(at: start.addingTimeInterval(1.5))

        XCTAssertEqual(timing.requestDuration ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(timing.timeToFirstByte ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(timing.responseDuration ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(timing.totalDuration ?? -1, 1.5, accuracy: 0.0001)
    }

    func testMatchersSupportURLHeadersCompositionAndResponseValues() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://api.example.com/v1/items?draft=true")!,
            headers: HTTPHeaders([
                try HTTPHeader(name: "X-Debug", value: "enabled")
            ])
        )
        let response = try HTTPResponse(
            statusCode: 201,
            headers: HTTPHeaders([
                try HTTPHeader(name: "Content-Type", value: "application/json; charset=utf-8")
            ])
        )
        let context = RuleMatchContext(
            request: request,
            response: response,
            source: FlowSource(kind: .desktopProxy, label: "Browser")
        )

        XCTAssertTrue(Matcher.host(.exact("API.EXAMPLE.COM")).matches(context))
        XCTAssertTrue(Matcher.path(.wildcard("/v1/*")).matches(context))
        XCTAssertTrue(Matcher.query(.exact("draft=true")).matches(context))
        XCTAssertTrue(Matcher.method(.get).matches(context))
        XCTAssertTrue(Matcher.status(201).matches(context))
        XCTAssertTrue(Matcher.contentType(.exact("application/json")).matches(context))
        XCTAssertTrue(Matcher.source(.exact("browser")).matches(context))

        let requestHeaderContext = RuleMatchContext(request: request)
        XCTAssertTrue(
            Matcher.header(name: "x-debug", value: .exact("ENABLED")).matches(requestHeaderContext)
        )

        let composed = Matcher.allOf([
            .host(.wildcard("*.example.com")),
            .method(.get),
            .not(.status(500))
        ])
        XCTAssertTrue(composed.matches(context))
        XCTAssertFalse(Matcher.anyOf([.status(400), .status(500)]).matches(context))
    }

    func testRuleSetFiltersDisabledRulesAndOrdersByPriority() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "https://example.com/")!)
        let context = RuleMatchContext(request: request)
        let first = Rule(
            id: RuleID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            name: "first",
            priority: 20,
            phase: .requestHeaders,
            action: .allow
        )
        let second = Rule(
            id: RuleID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            name: "second",
            priority: 10,
            phase: .requestHeaders,
            action: .block(reason: "test")
        )
        let disabled = Rule(
            name: "disabled",
            enabled: false,
            priority: 0,
            phase: .requestHeaders,
            action: .breakpoint
        )

        let rules = RuleSet(rules: [first, disabled, second])

        XCTAssertEqual(rules.orderedRules.map(\.name), ["disabled", "second", "first"])
        XCTAssertEqual(
            rules.matchingRules(for: context, phase: .requestHeaders).map(\.name),
            ["second", "first"]
        )
    }

    func testRulePlannerAppliesBlockAllowAndNoCacheInPriorityOrder() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://ads.example.com/pixel.gif")!
        )
        let context = RuleMatchContext(request: request)
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let allowID = RuleID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let blockID = RuleID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let noCacheID = RuleID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let mapLocalID = RuleID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        let rules = RuleSet(rules: [
            Rule(
                id: noCacheID,
                name: "No cache ads",
                priority: 0,
                phase: .requestHeaders,
                matcher: .host(.exact("ads.example.com")),
                action: .noCache
            ),
            Rule(
                id: allowID,
                name: "Allow ads",
                priority: 10,
                phase: .requestHeaders,
                matcher: .host(.exact("ads.example.com")),
                action: .allow
            ),
            Rule(
                id: blockID,
                name: "Block ads",
                priority: 20,
                phase: .requestHeaders,
                matcher: .any,
                action: .block(reason: "blocked by default")
            ),
            Rule(
                id: mapLocalID,
                name: "Map local ads",
                priority: 30,
                phase: .requestHeaders,
                matcher: .host(.exact("ads.example.com")),
                action: .mapLocal(resourceID: "pixel.json")
            )
        ])

        let plan = RulePlanner.plan(
            rules: rules,
            context: context,
            phase: .requestHeaders,
            recordedAt: recordedAt
        )

        XCTAssertFalse(plan.shouldBlock)
        XCTAssertNil(plan.blockReason)
        XCTAssertTrue(plan.applyNoCache)
        XCTAssertEqual(plan.traces.map(\.ruleID), [noCacheID, allowID, blockID, mapLocalID])
        XCTAssertEqual(
            plan.traces.map(\.ruleName),
            ["No cache ads", "Allow ads", "Block ads", "Map local ads"]
        )
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [
                .applied,
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyDecidedReason),
                .skipped(reason: RulePlanner.Decision.alreadyDecidedReason)
            ]
        )
        XCTAssertTrue(plan.traces.allSatisfy { $0.recordedAt == recordedAt })
        XCTAssertTrue(plan.traces.allSatisfy { $0.phase == .requestHeaders })
    }

    func testRulePlannerAppliesNoCacheAfterAllowOrBlock() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://cdn.example.com/app.js")!
        )
        let context = RuleMatchContext(request: request)
        let allowThenNoCache = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Allow cdn",
                    priority: 0,
                    phase: .requestHeaders,
                    matcher: .host(.exact("cdn.example.com")),
                    action: .allow
                ),
                Rule(
                    name: "No cache cdn",
                    priority: 20,
                    phase: .requestHeaders,
                    matcher: .host(.exact("cdn.example.com")),
                    action: .noCache
                )
            ]),
            context: context,
            phase: .requestHeaders
        )

        XCTAssertFalse(allowThenNoCache.shouldBlock)
        XCTAssertTrue(allowThenNoCache.applyNoCache)
        XCTAssertEqual(
            allowThenNoCache.traces.map(\.outcome),
            [.applied, .applied]
        )

        let blockThenNoCache = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Block cdn",
                    priority: 10,
                    phase: .requestHeaders,
                    matcher: .host(.exact("cdn.example.com")),
                    action: .block(reason: "blocked host")
                ),
                Rule(
                    name: "No cache cdn",
                    priority: 20,
                    phase: .requestHeaders,
                    matcher: .host(.exact("cdn.example.com")),
                    action: .noCache
                )
            ]),
            context: context,
            phase: .requestHeaders
        )

        XCTAssertTrue(blockThenNoCache.shouldBlock)
        XCTAssertTrue(blockThenNoCache.applyNoCache)
        XCTAssertEqual(
            blockThenNoCache.traces.map(\.outcome),
            [.applied, .applied]
        )
    }

    func testRulePlannerSkipsUnimplementedActions() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "https://example.com/")!)
        let rule = Rule(
            name: "Map remote",
            phase: .requestHeaders,
            action: .mapRemote(url: URL(string: "https://other.example.com/")!)
        )
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [rule]),
            context: RuleMatchContext(request: request),
            phase: .requestHeaders
        )

        XCTAssertFalse(plan.shouldBlock)
        XCTAssertFalse(plan.applyNoCache)
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [.skipped(reason: RulePlanner.Decision.unimplementedActionReason)]
        )
    }

    func testRulePlannerBlocksWhenNoAllowRuleMatchesFirst() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://tracker.example.com/collect")!
        )
        let block = Rule(
            name: "Block tracker",
            priority: 0,
            phase: .requestHeaders,
            matcher: .host(.exact("tracker.example.com")),
            action: .block(reason: "tracker")
        )
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [block]),
            context: RuleMatchContext(request: request),
            phase: .requestHeaders
        )

        XCTAssertTrue(plan.shouldBlock)
        XCTAssertEqual(plan.blockReason, "tracker")
        XCTAssertEqual(plan.traces.map(\.outcome), [.applied])
    }

    func testRulePlannerSkipsBlockAllowOutsideRequestHeaders() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "https://example.com/")!)
        let response = try HTTPResponse(statusCode: 200)
        let block = Rule(
            name: "Late block",
            phase: .responseHeaders,
            action: .block(reason: "too late")
        )
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [block]),
            context: RuleMatchContext(request: request, response: response),
            phase: .responseHeaders
        )

        XCTAssertFalse(plan.shouldBlock)
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [.skipped(reason: RulePlanner.Decision.blockAllowPhaseReason)]
        )
    }

    func testNoCacheHeadersRewriteRequestAndResponse() throws {
        let requestHeaders = HTTPHeaders([
            try HTTPHeader(name: "Accept", value: "text/html"),
            try HTTPHeader(name: "If-None-Match", value: "\"abc\""),
            try HTTPHeader(name: "If-Modified-Since", value: "Wed, 21 Oct 2015 07:28:00 GMT"),
            try HTTPHeader(name: "Cache-Control", value: "max-age=60")
        ])
        let rewrittenRequest = try NoCacheHeaders.applyingToRequest(requestHeaders)
        XCTAssertEqual(rewrittenRequest.firstValue(for: "Accept"), "text/html")
        XCTAssertEqual(rewrittenRequest.firstValue(for: "Cache-Control"), "no-cache")
        XCTAssertEqual(rewrittenRequest.firstValue(for: "Pragma"), "no-cache")
        XCTAssertFalse(rewrittenRequest.contains(name: "If-None-Match"))
        XCTAssertFalse(rewrittenRequest.contains(name: "If-Modified-Since"))

        let responseHeaders = HTTPHeaders([
            try HTTPHeader(name: "Content-Type", value: "text/html"),
            try HTTPHeader(name: "ETag", value: "\"abc\""),
            try HTTPHeader(name: "Age", value: "12"),
            try HTTPHeader(name: "Last-Modified", value: "Wed, 21 Oct 2015 07:28:00 GMT"),
            try HTTPHeader(name: "Cache-Control", value: "public, max-age=3600")
        ])
        let rewrittenResponse = try NoCacheHeaders.applyingToResponse(responseHeaders)
        XCTAssertEqual(rewrittenResponse.firstValue(for: "Content-Type"), "text/html")
        XCTAssertEqual(
            rewrittenResponse.firstValue(for: "Cache-Control"),
            "no-store, no-cache, must-revalidate, max-age=0"
        )
        XCTAssertEqual(rewrittenResponse.firstValue(for: "Pragma"), "no-cache")
        XCTAssertEqual(rewrittenResponse.firstValue(for: "Expires"), "0")
        XCTAssertFalse(rewrittenResponse.contains(name: "ETag"))
        XCTAssertFalse(rewrittenResponse.contains(name: "Age"))
        XCTAssertFalse(rewrittenResponse.contains(name: "Last-Modified"))
    }

    func testFlowCanServeALocalResponseWithoutConnectingUpstream() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "http://blocked.example.com/")!)
        var flow = Flow(sessionID: SessionID(), request: request)
        try flow.transition(to: .receivingRequest)
        try flow.transition(to: .receivingResponse)

        let response = try HTTPResponse(statusCode: 403, reasonPhrase: "Forbidden")
        flow.attachResponse(response)
        try flow.transition(to: .completed)

        XCTAssertEqual(flow.state, .completed)
        XCTAssertEqual(flow.response?.statusCode, 403)
    }

    func testMutableRuleSnapshotPublishesReplacements() {
        let snapshot = MutableRuleSnapshot()
        XCTAssertEqual(snapshot.currentRules(), RuleSet())

        let rule = Rule(name: "Block ads", phase: .requestHeaders, action: .block(reason: "ads"))
        snapshot.replace(RuleSet(rules: [rule]))
        XCTAssertEqual(snapshot.currentRules().rules.map(\.name), ["Block ads"])
    }

    func testFlowRoundTripsThroughCodable() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://example.com/health")!,
            headers: HTTPHeaders([try HTTPHeader(name: "Accept", value: "application/json")])
        )
        var original = Flow(sessionID: SessionID(), request: request)
        original.appendRuleTrace(
            RuleTrace(ruleID: RuleID(), phase: .requestHeaders, outcome: .matched)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Flow.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
