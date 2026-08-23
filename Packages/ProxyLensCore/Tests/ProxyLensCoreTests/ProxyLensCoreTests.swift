import Foundation
import XCTest

@testable import ProxyLensCore

final class ProxyLensCoreTests: XCTestCase {
    func testScriptExecutionRequestPreservesDuplicateHeadersThroughCodable() throws {
        let request = try ScriptExecutionRequest(
            hook: .request,
            source: "function onRequest(context) {}",
            message: ScriptHTTPMessage(
                method: "POST",
                url: "https://example.test/items",
                headers: [
                    try HTTPHeader(name: "Set-Cookie", value: "first=1"),
                    try HTTPHeader(name: "Set-Cookie", value: "second=2")
                ],
                body: #"{"enabled":true}"#
            )
        )

        let restored = try JSONDecoder().decode(
            ScriptExecutionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(restored, request)
        XCTAssertEqual(restored.message.headers.map(\.value), ["first=1", "second=2"])
    }

    func testScriptExecutionRequestValidatesHookShapeAndSourceLimit() throws {
        XCTAssertThrowsError(
            try ScriptExecutionRequest(
                hook: .request,
                source: "function onRequest(context) {}",
                message: ScriptHTTPMessage(statusCode: 200)
            )
        ) { error in
            XCTAssertEqual(error as? ScriptExecutionError, .invalidRequestMessage)
        }

        XCTAssertThrowsError(
            try ScriptExecutionRequest(
                hook: .response,
                source: String(
                    repeating: "x",
                    count: ScriptExecutionLimits.maximumSourceByteCount + 1
                ),
                message: ScriptHTTPMessage(statusCode: 200)
            )
        ) { error in
            XCTAssertEqual(
                error as? ScriptExecutionError,
                .sourceTooLarge(maximumByteCount: ScriptExecutionLimits.maximumSourceByteCount)
            )
        }
    }

    func testScriptExecutionRequestAcceptsWebSocketURLsAndRejectsOtherSchemes() throws {
        for url in ["ws://example.test/socket", "wss://example.test/socket"] {
            XCTAssertNoThrow(
                try ScriptExecutionRequest(
                    hook: .request,
                    source: "function onRequest(context) {}",
                    message: ScriptHTTPMessage(method: "GET", url: url)
                )
            )
        }

        XCTAssertThrowsError(
            try ScriptExecutionRequest(
                hook: .request,
                source: "function onRequest(context) {}",
                message: ScriptHTTPMessage(method: "GET", url: "file:///tmp/socket")
            )
        ) { error in
            XCTAssertEqual(error as? ScriptExecutionError, .invalidRequestMessage)
        }
    }

    func testRuleTraceLogsRoundTripAndLegacyDecoding() throws {
        let trace = RuleTrace(
            ruleID: RuleID(),
            phase: .requestBody,
            outcome: .applied,
            ruleName: "Rewrite request",
            logs: ["request started", "request updated"]
        )

        let encoded = try JSONEncoder().encode(trace)
        XCTAssertEqual(try JSONDecoder().decode(RuleTrace.self, from: encoded), trace)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "logs")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let restoredLegacy = try JSONDecoder().decode(RuleTrace.self, from: legacyData)
        XCTAssertTrue(restoredLegacy.logs.isEmpty)

        var oversizedObject = legacyObject
        oversizedObject["logs"] = Array(
            repeating: "entry",
            count: ScriptExecutionLimits.maximumLogCount + 1
        )
        let oversizedData = try JSONSerialization.data(withJSONObject: oversizedObject)
        XCTAssertThrowsError(try JSONDecoder().decode(RuleTrace.self, from: oversizedData))
    }

    func testSessionNamesNormalizePersistAndRejectOversizedValues() throws {
        var session = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        try session.rename(to: "  Checkout API debugging  \n")

        XCTAssertEqual(session.name, "Checkout API debugging")
        let encoded = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(Session.self, from: encoded)
        XCTAssertEqual(restored, session)

        try session.rename(to: "   \n")
        XCTAssertNil(session.name)

        XCTAssertThrowsError(
            try session.rename(
                to: String(repeating: "a", count: Session.maximumNameLength + 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? ProxyLensError,
                .sessionNameTooLong(maximum: Session.maximumNameLength)
            )
        }
    }

    func testFlowAnnotationsNormalizeRoundTripAndClearUserMetadata() throws {
        var flow = Flow(
            sessionID: SessionID(),
            request: HTTPRequest(
                method: .get,
                url: URL(string: "https://example.test/annotated")!
            )
        )
        let annotation = try FlowAnnotation(
            comment: "  Investigate the authentication redirect.\n",
            highlight: .yellow,
            isStruckThrough: true
        )

        XCTAssertEqual(annotation.comment, "Investigate the authentication redirect.")
        XCTAssertEqual(annotation.highlight, .yellow)
        XCTAssertTrue(annotation.isStruckThrough)
        XCTAssertFalse(annotation.isEmpty)

        flow.setAnnotation(annotation)
        let encoded = try JSONEncoder().encode(flow)
        let restored = try JSONDecoder().decode(Flow.self, from: encoded)
        XCTAssertEqual(restored.annotation, annotation)

        flow.setAnnotation(nil)
        XCTAssertNil(flow.annotation)
    }

    func testConnectionInfoDecodesLegacySnapshotsWithoutTransportDiagnostics() throws {
        let snapshot = Data(
            #"{"protocolKind":"https","upstreamHost":"legacy.example.com","upstreamPort":443,"tlsIntercepted":true}"#
                .utf8
        )

        let connection = try JSONDecoder().decode(ConnectionInfo.self, from: snapshot)

        XCTAssertEqual(connection.protocolKind, .https)
        XCTAssertEqual(connection.upstreamHost, "legacy.example.com")
        XCTAssertNil(connection.upstreamHTTPVersion)
        XCTAssertNil(connection.isUpstreamConnectionReused)
    }

    func testConnectionInfoTransportDiagnosticsRoundTripAndReplace() throws {
        let connection = ConnectionInfo(
            protocolKind: .https,
            upstreamHost: "api.example.com",
            upstreamPort: 443,
            tlsIntercepted: true,
            upstreamHTTPVersion: .http2,
            isUpstreamConnectionReused: true
        )

        let restored = try JSONDecoder().decode(
            ConnectionInfo.self,
            from: JSONEncoder().encode(connection)
        )

        XCTAssertEqual(restored, connection)
        XCTAssertEqual(restored.upstreamHTTPVersion, .http2)
        XCTAssertEqual(restored.isUpstreamConnectionReused, true)
    }

    func testFlowAnnotationRejectsCommentsAboveTheLocalStorageLimit() {
        XCTAssertThrowsError(
            try FlowAnnotation(
                comment: String(repeating: "a", count: FlowAnnotation.maximumCommentLength + 1),
                highlight: .red
            )
        ) { error in
            XCTAssertEqual(
                error as? ProxyLensError,
                .annotationCommentTooLong(maximum: FlowAnnotation.maximumCommentLength)
            )
        }
    }

    func testFlowAnnotationDecodingEnforcesTheLocalStorageLimit() throws {
        let oversizedComment = String(
            repeating: "a",
            count: FlowAnnotation.maximumCommentLength + 1
        )
        let payload = try JSONEncoder().encode(["comment": oversizedComment])

        XCTAssertThrowsError(try JSONDecoder().decode(FlowAnnotation.self, from: payload)) {
            error in
            XCTAssertEqual(
                error as? ProxyLensError,
                .annotationCommentTooLong(maximum: FlowAnnotation.maximumCommentLength)
            )
        }
    }

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

    func testCapturedWebSocketFramePreservesWireMetadataAndPayloadReference() throws {
        let payload = BodyReference(
            inline: Data(#"{"type":"message","value":42}"#.utf8),
            metadata: BodyMetadata(contentType: "application/json")
        )
        let frame = CapturedWebSocketFrame(
            flowID: FlowID(
                rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!),
            sequenceNumber: 7,
            direction: .clientToServer,
            opcode: .text,
            isFinal: true,
            reservedBits: [.rsv1],
            wasMasked: true,
            payload: payload,
            receivedAt: Date(timeIntervalSince1970: 1_234)
        )

        XCTAssertEqual(frame.sequenceNumber, 7)
        XCTAssertEqual(frame.direction, .clientToServer)
        XCTAssertEqual(frame.opcode, .text)
        XCTAssertEqual(frame.payloadByteCount, Int64(payload.inlineData?.count ?? 0))
        XCTAssertEqual(frame.reservedBits, [.rsv1])
        XCTAssertTrue(frame.wasMasked)

        let encoded = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(CapturedWebSocketFrame.self, from: encoded), frame)
    }

    func testCapturedWebSocketFrameSupportsControlContinuationAndUnknownOpcodes() throws {
        let flowID = FlowID()
        let payload = BodyReference(inline: Data())
        let opcodes: [WebSocketFrameOpcode] = [
            .continuation, .binary, .close, .ping, .pong, .unknown(0xB)
        ]

        for (index, opcode) in opcodes.enumerated() {
            let frame = CapturedWebSocketFrame(
                flowID: flowID,
                sequenceNumber: Int64(index),
                direction: .serverToClient,
                opcode: opcode,
                isFinal: true,
                payload: payload,
                receivedAt: Date(timeIntervalSince1970: Double(index))
            )
            let encoded = try JSONEncoder().encode(frame)
            XCTAssertEqual(
                try JSONDecoder().decode(CapturedWebSocketFrame.self, from: encoded).opcode,
                opcode
            )
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

    func testFlowCanPauseAtRequestAndResponseBreakpoints() throws {
        var flow = Flow(
            sessionID: SessionID(),
            request: HTTPRequest(method: .get, url: URL(string: "http://localhost:8080/")!)
        )

        try flow.transition(to: .receivingRequest)
        try flow.transition(to: .paused(.request))
        XCTAssertEqual(flow.state.breakpointPhase, .request)
        XCTAssertFalse(flow.state.isTerminal)

        try flow.transition(to: .connectingUpstream)
        try flow.transition(to: .receivingResponse)
        try flow.transition(to: .paused(.response))
        XCTAssertEqual(flow.state.breakpointPhase, .response)

        try flow.transition(to: .cancelled)
        XCTAssertEqual(flow.state, .cancelled)
        XCTAssertTrue(flow.state.isTerminal)
    }

    func testFlowCanPreserveAnIncompleteFailure() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "http://localhost:8080/")!)
        var flow = Flow(sessionID: SessionID(), request: request)

        try flow.transition(to: .receivingRequest)
        try flow.transition(to: .failed(.upstreamUnavailable))

        XCTAssertEqual(flow.state, .failed(.upstreamUnavailable))
        XCTAssertTrue(flow.state.isTerminal)
    }

    func testFlowApplicationUsesStableGroupingIdentifiers() {
        XCTAssertEqual(
            FlowApplication(
                name: "Safari",
                bundleIdentifier: "COM.APPLE.SAFARI",
                bundlePath: "/Applications/Other.app",
                executablePath: "/bin/other"
            ).groupingIdentifier,
            "bundle:com.apple.safari"
        )
        XCTAssertEqual(
            FlowApplication(name: "curl", executablePath: "/usr/bin/curl").groupingIdentifier,
            "executable:/usr/bin/curl"
        )
    }

    func testFlowSourceDecodesSnapshotsWrittenBeforeApplicationAttribution() throws {
        let source = try JSONDecoder().decode(
            FlowSource.self,
            from: Data(#"{"kind":"desktopProxy","label":"Desktop proxy"}"#.utf8)
        )

        XCTAssertEqual(source, .desktopProxy)
        XCTAssertNil(source.application)
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

    func testGraphQLOperationMatcherSupportsNamesKindsAndCodableRoundTrips() throws {
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://api.example.com/graphql")!,
            graphqlOperation: GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
        )
        let context = RuleMatchContext(request: request)
        let matcher = Matcher.graphqlOperation(
            name: .exact("saveprofile"),
            kind: .mutation
        )

        XCTAssertTrue(matcher.matches(context))
        XCTAssertTrue(
            Matcher.graphqlOperation(name: nil, kind: .mutation).matches(context)
        )
        XCTAssertFalse(
            Matcher.graphqlOperation(name: .exact("LoadProfile"), kind: nil).matches(context)
        )
        XCTAssertFalse(
            Matcher.graphqlOperation(name: nil, kind: .query).matches(context)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(Matcher.self, from: JSONEncoder().encode(matcher)),
            matcher
        )
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
        XCTAssertEqual(plan.mapLocalResourceID, "pixel.json")
        XCTAssertNil(plan.mapRemoteURL)
        XCTAssertFalse(plan.shouldBreakpoint)
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
                .applied
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

    func testRulePlannerAppliesMapLocalAfterAllowAndSkipsAfterBlock() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://api.example.com/users")!
        )
        let context = RuleMatchContext(request: request)
        let allowThenMap = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Allow api",
                    priority: 0,
                    phase: .requestHeaders,
                    matcher: .host(.exact("api.example.com")),
                    action: .allow
                ),
                Rule(
                    name: "Map local users",
                    priority: 15,
                    phase: .requestHeaders,
                    matcher: .path(.exact("/users")),
                    action: .mapLocal(resourceID: "users.json")
                )
            ]),
            context: context,
            phase: .requestHeaders
        )

        XCTAssertFalse(allowThenMap.shouldBlock)
        XCTAssertEqual(allowThenMap.mapLocalResourceID, "users.json")
        XCTAssertEqual(allowThenMap.traces.map(\.outcome), [.applied, .applied])

        let mapThenBlock = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map local users",
                    priority: 5,
                    phase: .requestHeaders,
                    matcher: .path(.exact("/users")),
                    action: .mapLocal(resourceID: "users.json")
                ),
                Rule(
                    name: "Block all",
                    priority: 10,
                    phase: .requestHeaders,
                    action: .block(reason: "blocked by default")
                )
            ]),
            context: context,
            phase: .requestHeaders
        )

        XCTAssertFalse(mapThenBlock.shouldBlock)
        XCTAssertEqual(mapThenBlock.mapLocalResourceID, "users.json")
        XCTAssertEqual(
            mapThenBlock.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyDecidedReason)
            ]
        )

        let blockThenMap = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Block api",
                    priority: 10,
                    phase: .requestHeaders,
                    matcher: .host(.exact("api.example.com")),
                    action: .block(reason: "blocked host")
                ),
                Rule(
                    name: "Map local users",
                    priority: 15,
                    phase: .requestHeaders,
                    matcher: .path(.exact("/users")),
                    action: .mapLocal(resourceID: "users.json")
                )
            ]),
            context: context,
            phase: .requestHeaders
        )

        XCTAssertTrue(blockThenMap.shouldBlock)
        XCTAssertNil(blockThenMap.mapLocalResourceID)
        XCTAssertEqual(
            blockThenMap.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyDecidedReason)
            ]
        )

        let firstMapWins = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map local first",
                    priority: 10,
                    phase: .requestHeaders,
                    action: .mapLocal(resourceID: "first.json")
                ),
                Rule(
                    name: "Map local second",
                    priority: 20,
                    phase: .requestHeaders,
                    action: .mapLocal(resourceID: "second.json")
                )
            ]),
            context: context,
            phase: .requestHeaders
        )
        XCTAssertEqual(firstMapWins.mapLocalResourceID, "first.json")
        XCTAssertEqual(
            firstMapWins.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyMappedReason)
            ]
        )
    }

    func testRulePlannerSkipsMapLocalOutsideRequestHeaders() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "https://example.com/users")!)
        let response = try HTTPResponse(statusCode: 200)
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Late map local",
                    phase: .responseHeaders,
                    action: .mapLocal(resourceID: "users.json")
                )
            ]),
            context: RuleMatchContext(request: request, response: response),
            phase: .responseHeaders
        )

        XCTAssertNil(plan.mapLocalResourceID)
        XCTAssertNil(plan.mapRemoteURL)
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [.skipped(reason: RulePlanner.Decision.mapLocalPhaseReason)]
        )
    }

    func testRulePlannerAppliesMapRemoteAfterAllowAndSkipsAfterBlock() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://api.example.com/users")!
        )
        let context = RuleMatchContext(request: request)
        let staging = URL(string: "http://staging.example.com/")!
        let allowThenMap = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Allow api",
                    priority: 0,
                    phase: .requestHeaders,
                    matcher: .host(.exact("api.example.com")),
                    action: .allow
                ),
                Rule(
                    name: "Map remote users",
                    priority: 15,
                    phase: .requestHeaders,
                    matcher: .path(.exact("/users")),
                    action: .mapRemote(url: staging)
                )
            ]),
            context: context,
            phase: .requestHeaders
        )

        XCTAssertFalse(allowThenMap.shouldBlock)
        XCTAssertNil(allowThenMap.mapLocalResourceID)
        XCTAssertEqual(allowThenMap.mapRemoteURL, staging)
        XCTAssertEqual(allowThenMap.traces.map(\.outcome), [.applied, .applied])

        let mapThenBlock = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map remote users",
                    priority: 5,
                    phase: .requestHeaders,
                    matcher: .path(.exact("/users")),
                    action: .mapRemote(url: staging)
                ),
                Rule(
                    name: "Block all",
                    priority: 10,
                    phase: .requestHeaders,
                    action: .block(reason: "blocked by default")
                )
            ]),
            context: context,
            phase: .requestHeaders
        )

        XCTAssertFalse(mapThenBlock.shouldBlock)
        XCTAssertEqual(mapThenBlock.mapRemoteURL, staging)
        XCTAssertEqual(
            mapThenBlock.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyDecidedReason)
            ]
        )

        let blockThenMap = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Block api",
                    priority: 10,
                    phase: .requestHeaders,
                    matcher: .host(.exact("api.example.com")),
                    action: .block(reason: "blocked host")
                ),
                Rule(
                    name: "Map remote users",
                    priority: 15,
                    phase: .requestHeaders,
                    matcher: .path(.exact("/users")),
                    action: .mapRemote(url: staging)
                )
            ]),
            context: context,
            phase: .requestHeaders
        )

        XCTAssertTrue(blockThenMap.shouldBlock)
        XCTAssertNil(blockThenMap.mapRemoteURL)
        XCTAssertEqual(
            blockThenMap.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyDecidedReason)
            ]
        )

        let other = URL(string: "http://other.example.com/")!
        let firstMapWins = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map remote first",
                    priority: 10,
                    phase: .requestHeaders,
                    action: .mapRemote(url: staging)
                ),
                Rule(
                    name: "Map remote second",
                    priority: 20,
                    phase: .requestHeaders,
                    action: .mapRemote(url: other)
                )
            ]),
            context: context,
            phase: .requestHeaders
        )
        XCTAssertEqual(firstMapWins.mapRemoteURL, staging)
        XCTAssertEqual(
            firstMapWins.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyMappedReason)
            ]
        )
    }

    func testRulePlannerTreatsMapLocalAndMapRemoteAsMutuallyExclusive() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "https://api.example.com/users")!)
        let context = RuleMatchContext(request: request)
        let staging = URL(string: "http://staging.example.com/")!

        let localThenRemote = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map local users",
                    priority: 10,
                    phase: .requestHeaders,
                    action: .mapLocal(resourceID: "users.json")
                ),
                Rule(
                    name: "Map remote users",
                    priority: 20,
                    phase: .requestHeaders,
                    action: .mapRemote(url: staging)
                )
            ]),
            context: context,
            phase: .requestHeaders
        )
        XCTAssertEqual(localThenRemote.mapLocalResourceID, "users.json")
        XCTAssertNil(localThenRemote.mapRemoteURL)
        XCTAssertEqual(
            localThenRemote.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyMappedReason)
            ]
        )

        let remoteThenLocal = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map remote users",
                    priority: 10,
                    phase: .requestHeaders,
                    action: .mapRemote(url: staging)
                ),
                Rule(
                    name: "Map local users",
                    priority: 20,
                    phase: .requestHeaders,
                    action: .mapLocal(resourceID: "users.json")
                )
            ]),
            context: context,
            phase: .requestHeaders
        )
        XCTAssertNil(remoteThenLocal.mapLocalResourceID)
        XCTAssertEqual(remoteThenLocal.mapRemoteURL, staging)
        XCTAssertEqual(
            remoteThenLocal.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyMappedReason)
            ]
        )
    }

    func testRulePlannerSkipsMapRemoteOutsideRequestPhases() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "https://example.com/users")!)
        let response = try HTTPResponse(statusCode: 200)
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Late map remote",
                    phase: .responseHeaders,
                    action: .mapRemote(url: URL(string: "http://staging.example.com/")!)
                )
            ]),
            context: RuleMatchContext(request: request, response: response),
            phase: .responseHeaders
        )

        XCTAssertNil(plan.mapRemoteURL)
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [.skipped(reason: RulePlanner.Decision.mapRemotePhaseReason)]
        )
    }

    func testRulePlannerAppliesFirstRedirectDuringRequestHeaders() throws {
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://api.example.com/v1/users")!
        )
        let first = URL(string: "https://login.example.com/continue")!
        let second = URL(string: "https://other.example.com/")!
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Redirect users",
                    priority: 10,
                    phase: .requestHeaders,
                    action: .redirect(url: first)
                ),
                Rule(
                    name: "Redirect fallback",
                    priority: 20,
                    phase: .requestHeaders,
                    action: .redirect(url: second)
                ),
                Rule(
                    name: "Block fallback",
                    priority: 30,
                    phase: .requestHeaders,
                    action: .block(reason: "blocked")
                )
            ]),
            context: RuleMatchContext(request: request),
            phase: .requestHeaders
        )

        XCTAssertEqual(plan.redirectURL, first)
        XCTAssertFalse(plan.shouldBlock)
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyRedirectedReason),
                .skipped(reason: RulePlanner.Decision.alreadyDecidedReason)
            ]
        )
    }

    func testRedirectedHTTPResponsePreservesMethodWithTemporaryRedirect() throws {
        let destination = URL(string: "https://login.example.com/continue?from=proxy")!

        let response = try RedirectedHTTPResponse.make(destination: destination)

        XCTAssertEqual(response.statusCode, 307)
        XCTAssertEqual(response.reasonPhrase, "Temporary Redirect")
        XCTAssertEqual(response.headers.firstValue(for: "Location"), destination.absoluteString)
        XCTAssertEqual(response.headers.firstValue(for: "Content-Length"), "0")
        XCTAssertEqual(response.headers.firstValue(for: "Connection"), "close")
        XCTAssertNil(response.body)
    }

    func testRulePlannerAppliesFirstThrottleDuringRequestHeaders() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://api.example.com/v1/users")!
        )
        let first = ThrottleProfile(latency: 0.2)
        let second = ThrottleProfile(latency: 1)
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Slow API",
                    priority: 10,
                    phase: .requestHeaders,
                    action: .throttle(first)
                ),
                Rule(
                    name: "Slower API",
                    priority: 20,
                    phase: .requestHeaders,
                    action: .throttle(second)
                )
            ]),
            context: RuleMatchContext(request: request),
            phase: .requestHeaders
        )

        XCTAssertEqual(plan.throttleProfile, first)
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyThrottledReason)
            ]
        )
    }

    func testThrottleProfileDefaultsLegacyPacketLossAndSamplesRequestsDeterministically() throws {
        let legacy = try JSONDecoder().decode(
            ThrottleProfile.self,
            from: Data(#"{"latency":0.2}"#.utf8)
        )
        XCTAssertEqual(legacy, ThrottleProfile(latency: 0.2))

        let lowSample = FlowID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        )
        let highSample = FlowID(
            rawValue: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        )
        let profile = ThrottleProfile(packetLossPercentage: 50)

        XCTAssertTrue(profile.dropsRequest(flowID: lowSample))
        XCTAssertFalse(profile.dropsRequest(flowID: highSample))
        XCTAssertFalse(ThrottleProfile().dropsRequest(flowID: lowSample))
        XCTAssertTrue(ThrottleProfile(packetLossPercentage: 100).dropsRequest(flowID: highSample))
    }

    func testRulePlannerSkipsThrottleOutsideRequestHeaders() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "https://example.com/")!)
        let response = try HTTPResponse(statusCode: 200)
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Late throttle",
                    phase: .responseHeaders,
                    action: .throttle(ThrottleProfile(latency: 0.2))
                )
            ]),
            context: RuleMatchContext(request: request, response: response),
            phase: .responseHeaders
        )

        XCTAssertNil(plan.throttleProfile)
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [.skipped(reason: RulePlanner.Decision.throttlePhaseReason)]
        )
    }

    func testMappedRemoteHTTPRequestPreservesPathForOriginDestinations() throws {
        let mapped = try MappedRemoteHTTPRequest.make(
            originalURL: URL(string: "https://api.example.com/v1/users?x=one%20two")!,
            destination: URL(string: "http://127.0.0.1:9000")!
        )

        XCTAssertEqual(mapped.host, "127.0.0.1")
        XCTAssertEqual(mapped.port, 9_000)
        XCTAssertFalse(mapped.usesTLS)
        XCTAssertEqual(mapped.originForm, "/v1/users?x=one%20two")
        XCTAssertEqual(mapped.hostHeader, "127.0.0.1:9000")
        XCTAssertEqual(mapped.url.absoluteString, "http://127.0.0.1:9000/v1/users?x=one%20two")
    }

    func testMappedRemoteHTTPRequestReplacesPathAndScheme() throws {
        let mapped = try MappedRemoteHTTPRequest.make(
            originalURL: URL(string: "http://api.example.com/v1/users?x=1")!,
            destination: URL(string: "https://staging.example.com/mock/users")!
        )

        XCTAssertEqual(mapped.host, "staging.example.com")
        XCTAssertEqual(mapped.port, 443)
        XCTAssertTrue(mapped.usesTLS)
        XCTAssertEqual(mapped.originForm, "/mock/users")
        XCTAssertEqual(mapped.hostHeader, "staging.example.com")
        XCTAssertEqual(mapped.url.absoluteString, "https://staging.example.com/mock/users")
    }

    func testMappedRemoteHTTPRequestRejectsUnsupportedDestinations() {
        XCTAssertThrowsError(
            try MappedRemoteHTTPRequest.make(
                originalURL: URL(string: "https://api.example.com/users")!,
                destination: URL(string: "ftp://files.example.com/users")!
            )
        )
        XCTAssertThrowsError(
            try MappedRemoteHTTPRequest.make(
                originalURL: URL(string: "https://api.example.com/users")!,
                destination: URL(string: "/relative")!
            )
        )
    }

    func testHTTPMessageTextRoundTripsRequestAndResponseEdits() throws {
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://api.example.com/v1/users?x=1")!,
            headers: HTTPHeaders([
                try HTTPHeader(name: "Host", value: "api.example.com"),
                try HTTPHeader(name: "Content-Type", value: "application/json")
            ]),
            body: BodyReference(inline: Data(#"{"name":"ada"}"#.utf8)),
            rawTarget: "/v1/users?x=1"
        )
        let parsedRequest = try HTTPMessageText.parseRequest(
            headersText: """
                PATCH /v1/users/1 HTTP/1.1
                Host: api.example.com
                Content-Type: application/json
                X-Debug: 1
                """,
            body: Data(#"{"name":"grace"}"#.utf8),
            original: request
        )

        XCTAssertEqual(parsedRequest.method, .patch)
        XCTAssertEqual(parsedRequest.url.absoluteString, "https://api.example.com/v1/users/1")
        XCTAssertEqual(parsedRequest.headers.firstValue(for: "X-Debug"), "1")
        XCTAssertEqual(parsedRequest.headers.firstValue(for: "Content-Length"), "16")
        XCTAssertEqual(parsedRequest.body?.inlineData, Data(#"{"name":"grace"}"#.utf8))

        let unchanged = try HTTPMessageText.parseRequest(
            headersText: HTTPMessageText.requestHeaders(request),
            body: nil,
            original: request
        )
        XCTAssertEqual(unchanged.method, .post)
        XCTAssertEqual(unchanged.body, request.body)
        XCTAssertNil(unchanged.headers.firstValue(for: "Content-Length"))

        let response = try HTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: HTTPHeaders([try HTTPHeader(name: "Content-Type", value: "text/plain")]),
            body: BodyReference(inline: Data("hello".utf8))
        )
        let parsedResponse = try HTTPMessageText.parseResponse(
            headersText: """
                HTTP/1.1 201 Created
                Content-Type: text/plain
                """,
            body: Data("created".utf8),
            original: response
        )
        XCTAssertEqual(parsedResponse.statusCode, 201)
        XCTAssertEqual(parsedResponse.reasonPhrase, "Created")
        XCTAssertEqual(parsedResponse.headers.firstValue(for: "Content-Length"), "7")
        XCTAssertEqual(parsedResponse.body?.inlineData, Data("created".utf8))
    }

    func testHTTPMessageTextParsesAComposedAbsoluteRequestWithoutAnOriginal() throws {
        let request = try HTTPMessageText.parseRequest(
            headersText: """
                POST https://api.example.com/v1/events?source=compose HTTP/1.1
                Content-Type: application/json
                """,
            body: Data(#"{"ok":true}"#.utf8)
        )

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(
            request.url.absoluteString,
            "https://api.example.com/v1/events?source=compose"
        )
        XCTAssertEqual(
            request.rawTarget,
            "https://api.example.com/v1/events?source=compose"
        )
        XCTAssertEqual(request.headers.firstValue(for: "Content-Length"), "11")
        XCTAssertEqual(request.body?.inlineData, Data(#"{"ok":true}"#.utf8))

        XCTAssertThrowsError(
            try HTTPMessageText.parseRequest(
                headersText: "GET /v1/events HTTP/1.1\nHost: api.example.com",
                body: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? ProxyLensError,
                .invalidHTTPMessage(
                    "A composed request must use an absolute HTTP or HTTPS URL"
                )
            )
        }
        XCTAssertThrowsError(
            try HTTPMessageText.parseRequest(
                headersText: "GET https:/missing-host HTTP/1.1",
                body: nil
            )
        )
    }

    func testHTTPMessageTextRejectsAnInvalidEditedRequestMethod() throws {
        let original = HTTPRequest(
            method: .get,
            url: URL(string: "https://api.example.com/users")!
        )

        XCTAssertThrowsError(
            try HTTPMessageText.parseRequest(
                headersText: "G\u{0001}ET /users HTTP/1.1\nHost: api.example.com",
                body: nil,
                original: original
            )
        ) { error in
            XCTAssertEqual(
                error as? ProxyLensError,
                .invalidHTTPMessage("Invalid request method: G\u{0001}ET")
            )
        }
    }

    func testMappedLocalHTTPResponseUsesFileBodyAndHeaders() throws {
        let body = BodyReference(
            inline: Data(#"{"ok":true}"#.utf8),
            metadata: BodyMetadata(contentType: "application/json")
        )
        let spec = MapLocalSpec(
            resourceID: "users.json",
            filePath: "/tmp/users.json",
            statusCode: 201,
            reasonPhrase: "Created",
            headers: HTTPHeaders([try HTTPHeader(name: "X-Mapped", value: "local")]),
            body: body
        )
        let response = try MappedLocalHTTPResponse.make(spec: spec)

        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(response.reasonPhrase, "Created")
        XCTAssertEqual(response.headers.firstValue(for: "Content-Type"), "application/json")
        XCTAssertEqual(response.headers.firstValue(for: "Content-Length"), "11")
        XCTAssertEqual(response.headers.firstValue(for: "Connection"), "close")
        XCTAssertEqual(response.headers.firstValue(for: "X-Mapped"), "local")
        XCTAssertEqual(response.body, body)
    }

    func testRulePlannerAppliesBreakpointOnRequestAndResponseHeaders() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://api.example.com/users")!
        )
        let requestPlan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Breakpoint users",
                    phase: .requestHeaders,
                    matcher: .path(.exact("/users")),
                    action: .breakpoint
                )
            ]),
            context: RuleMatchContext(request: request),
            phase: .requestHeaders
        )

        XCTAssertTrue(requestPlan.shouldBreakpoint)
        XCTAssertEqual(requestPlan.traces.map(\.outcome), [.applied])

        let response = try HTTPResponse(statusCode: 200)
        let responsePlan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Breakpoint users response",
                    phase: .responseHeaders,
                    matcher: .path(.exact("/users")),
                    action: .breakpoint
                )
            ]),
            context: RuleMatchContext(request: request, response: response),
            phase: .responseHeaders
        )

        XCTAssertTrue(responsePlan.shouldBreakpoint)
        XCTAssertEqual(responsePlan.traces.map(\.outcome), [.applied])
    }

    func testRulePlannerAppliesBreakpointDuringRequestBodyPhase() {
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://api.example.com/graphql")!,
            graphqlOperation: GraphQLOperationMetadata(kind: .query, name: "Catalog")
        )
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Breakpoint GraphQL Catalog",
                    phase: .requestBody,
                    matcher: .graphqlOperation(name: .exact("Catalog"), kind: .query),
                    action: .breakpoint
                )
            ]),
            context: RuleMatchContext(request: request),
            phase: .requestBody
        )

        XCTAssertTrue(plan.shouldBreakpoint)
        XCTAssertEqual(plan.traces.map(\.outcome), [.applied])
    }

    func testRulePlannerAppliesBlockDuringRequestBodyPhase() {
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://api.example.com/graphql")!,
            graphqlOperation: GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
        )
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Block GraphQL mutation SaveProfile",
                    phase: .requestBody,
                    matcher: .graphqlOperation(name: .exact("SaveProfile"), kind: .mutation),
                    action: .block(reason: "Blocked GraphQL operation")
                )
            ]),
            context: RuleMatchContext(request: request),
            phase: .requestBody
        )

        XCTAssertTrue(plan.shouldBlock)
        XCTAssertEqual(plan.blockReason, "Blocked GraphQL operation")
        XCTAssertEqual(plan.traces.map(\.outcome), [.applied])
    }

    func testRulePlannerAppliesMapLocalDuringRequestBodyPhase() {
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://api.example.com/graphql")!,
            graphqlOperation: GraphQLOperationMetadata(kind: .query, name: "Catalog")
        )
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map local GraphQL query Catalog",
                    phase: .requestBody,
                    matcher: .graphqlOperation(name: .exact("Catalog"), kind: .query),
                    action: .mapLocal(resourceID: "catalog.json")
                )
            ]),
            context: RuleMatchContext(request: request),
            phase: .requestBody
        )

        XCTAssertEqual(plan.mapLocalResourceID, "catalog.json")
        XCTAssertEqual(plan.traces.map(\.outcome), [.applied])
    }

    func testRulePlannerAppliesMapRemoteDuringRequestBodyPhase() {
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://api.example.com/graphql")!,
            graphqlOperation: GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
        )
        let destination = URL(string: "http://127.0.0.1:9000")!
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map remote GraphQL mutation SaveProfile",
                    phase: .requestBody,
                    matcher: .graphqlOperation(name: .exact("SaveProfile"), kind: .mutation),
                    action: .mapRemote(url: destination)
                )
            ]),
            context: RuleMatchContext(request: request),
            phase: .requestBody
        )

        XCTAssertEqual(plan.mapRemoteURL, destination)
        XCTAssertEqual(plan.traces.map(\.outcome), [.applied])
    }

    func testRulePlannerAppliesFirstBodyReplacementDuringRequestBodyPhase() {
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://api.example.com/graphql")!,
            graphqlOperation: GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
        )
        let firstBody = BodyReference(
            inline: Data(#"{"name":"Ada"}"#.utf8),
            metadata: BodyMetadata(contentType: "application/json")
        )
        let secondBody = BodyReference(inline: Data("ignored".utf8))
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Replace body GraphQL mutation SaveProfile",
                    priority: 16,
                    phase: .requestBody,
                    matcher: .graphqlOperation(name: .exact("SaveProfile"), kind: .mutation),
                    action: .replaceBody(body: firstBody)
                ),
                Rule(
                    name: "Replace body again",
                    priority: 17,
                    phase: .requestBody,
                    action: .replaceBody(body: secondBody)
                )
            ]),
            context: RuleMatchContext(request: request),
            phase: .requestBody
        )

        XCTAssertEqual(plan.replacementBody, firstBody)
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyReplacedBodyReason)
            ]
        )
    }

    func testRulePlannerAppliesFirstBodyReplacementDuringResponseBodyPhase() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://api.example.com/users")!
        )
        let response = try HTTPResponse(statusCode: 200)
        let firstBody = BodyReference(
            inline: Data(#"{"users":[]}"#.utf8),
            metadata: BodyMetadata(contentType: "application/json")
        )
        let secondBody = BodyReference(inline: Data("ignored".utf8))
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Replace users response",
                    priority: 16,
                    phase: .responseBody,
                    matcher: .status(200),
                    action: .replaceBody(body: firstBody)
                ),
                Rule(
                    name: "Replace response again",
                    priority: 17,
                    phase: .responseBody,
                    action: .replaceBody(body: secondBody)
                )
            ]),
            context: RuleMatchContext(request: request, response: response),
            phase: .responseBody
        )

        XCTAssertEqual(plan.replacementBody, firstBody)
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyReplacedBodyReason)
            ]
        )
    }

    func testRulePlannerPlansBodyScriptsInPriorityOrderWithoutPrematureTraces() throws {
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://api.example.com/users")!
        )
        let first = Rule(
            name: "Normalize request",
            priority: 20,
            phase: .requestBody,
            action: .script(try ScriptRuleSpec(source: "function onRequest(context) {}"))
        )
        let second = Rule(
            name: "Add metadata",
            priority: 30,
            phase: .requestBody,
            action: .script(try ScriptRuleSpec(source: "function onRequest(context) {}"))
        )

        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [second, first]),
            context: RuleMatchContext(request: request),
            phase: .requestBody
        )

        XCTAssertEqual(plan.scripts.map(\.ruleID), [first.id, second.id])
        XCTAssertEqual(plan.scripts.map(\.ruleName), [first.name, second.name])
        XCTAssertTrue(plan.traces.isEmpty)
    }

    func testRulePlannerPlansScriptsInBothHeaderPhases() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://api.example.com/users")!
        )
        let response = try HTTPResponse(statusCode: 200)
        let requestRule = Rule(
            name: "Request header script",
            phase: .requestHeaders,
            action: .script(try ScriptRuleSpec(source: "function onRequest(context) {}"))
        )
        let responseRule = Rule(
            name: "Response header script",
            phase: .responseHeaders,
            action: .script(try ScriptRuleSpec(source: "function onResponse(context) {}"))
        )

        let requestPlan = RulePlanner.plan(
            rules: RuleSet(rules: [requestRule]),
            context: RuleMatchContext(request: request),
            phase: .requestHeaders
        )
        let responsePlan = RulePlanner.plan(
            rules: RuleSet(rules: [responseRule]),
            context: RuleMatchContext(request: request, response: response),
            phase: .responseHeaders
        )

        XCTAssertEqual(requestPlan.scripts.map(\.ruleID), [requestRule.id])
        XCTAssertTrue(requestPlan.traces.isEmpty)
        XCTAssertEqual(responsePlan.scripts.map(\.ruleID), [responseRule.id])
        XCTAssertTrue(responsePlan.traces.isEmpty)
    }

    func testRulePlannerSkipsBreakpointAfterBlockOrMapLocal() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://api.example.com/users")!
        )
        let context = RuleMatchContext(request: request)
        let blocked = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Block users",
                    priority: 0,
                    phase: .requestHeaders,
                    action: .block(reason: "blocked")
                ),
                Rule(
                    name: "Breakpoint users",
                    priority: 20,
                    phase: .requestHeaders,
                    action: .breakpoint
                )
            ]),
            context: context,
            phase: .requestHeaders
        )
        XCTAssertTrue(blocked.shouldBlock)
        XCTAssertFalse(blocked.shouldBreakpoint)
        XCTAssertEqual(
            blocked.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyDecidedReason)
            ]
        )

        let mapped = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map local users",
                    priority: 0,
                    phase: .requestHeaders,
                    action: .mapLocal(resourceID: "users.json")
                ),
                Rule(
                    name: "Breakpoint users",
                    priority: 20,
                    phase: .requestHeaders,
                    action: .breakpoint
                )
            ]),
            context: context,
            phase: .requestHeaders
        )
        XCTAssertEqual(mapped.mapLocalResourceID, "users.json")
        XCTAssertFalse(mapped.shouldBreakpoint)
        XCTAssertEqual(
            mapped.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyMappedReason)
            ]
        )
    }

    func testRulePlannerAppliesBreakpointAfterAllowAndMapRemote() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://api.example.com/users")!
        )
        let staging = URL(string: "http://staging.example.com/")!
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Allow api",
                    priority: 0,
                    phase: .requestHeaders,
                    action: .allow
                ),
                Rule(
                    name: "Map remote users",
                    priority: 15,
                    phase: .requestHeaders,
                    action: .mapRemote(url: staging)
                ),
                Rule(
                    name: "Breakpoint users",
                    priority: 18,
                    phase: .requestHeaders,
                    action: .breakpoint
                )
            ]),
            context: RuleMatchContext(request: request),
            phase: .requestHeaders
        )

        XCTAssertFalse(plan.shouldBlock)
        XCTAssertEqual(plan.mapRemoteURL, staging)
        XCTAssertTrue(plan.shouldBreakpoint)
        XCTAssertEqual(plan.traces.map(\.outcome), [.applied, .applied, .applied])
    }

    func testRulePlannerKeepsTheFirstMatchingBreakpoint() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "https://example.com/")!)
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "First breakpoint",
                    priority: 10,
                    phase: .requestHeaders,
                    action: .breakpoint
                ),
                Rule(
                    name: "Second breakpoint",
                    priority: 20,
                    phase: .requestHeaders,
                    action: .breakpoint
                )
            ]),
            context: RuleMatchContext(request: request),
            phase: .requestHeaders
        )

        XCTAssertTrue(plan.shouldBreakpoint)
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [
                .applied,
                .skipped(reason: RulePlanner.Decision.alreadyPausedReason)
            ]
        )
    }

    func testRulePlannerSkipsBreakpointOutsideSupportedPhases() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "https://example.com/")!)
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [
                Rule(
                    name: "Late breakpoint",
                    phase: .responseBody,
                    action: .breakpoint
                )
            ]),
            context: RuleMatchContext(request: request),
            phase: .responseBody
        )

        XCTAssertFalse(plan.shouldBreakpoint)
        XCTAssertEqual(
            plan.traces.map(\.outcome),
            [.skipped(reason: RulePlanner.Decision.breakpointPhaseReason)]
        )
    }

    func testRulePlannerAppliesBreakpointToWebSocketFrames() throws {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "wss://socket.example.com/events")!
        )
        let response = try HTTPResponse(statusCode: 101)
        let rule = Rule(
            name: "Pause incoming messages",
            phase: .webSocketFrame,
            matcher: .host(.exact("socket.example.com")),
            action: .breakpoint
        )

        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [rule]),
            context: RuleMatchContext(request: request, response: response),
            phase: .webSocketFrame
        )

        XCTAssertTrue(plan.shouldBreakpoint)
        XCTAssertEqual(plan.traces.map(\.phase), [.webSocketFrame])
        XCTAssertEqual(plan.traces.map(\.outcome), [.applied])
    }

    func testWebSocketBreakpointFrameAllowsOnlyBoundedCompletePlainTextEdits() throws {
        let frame = WebSocketBreakpointFrame(
            sequenceNumber: 7,
            opcode: .text,
            isFinal: true,
            payload: Data(#"{"state":"before"}"#.utf8),
            originalPayloadByteCount: 18,
            maximumEditablePayloadBytes: 64
        )

        XCTAssertTrue(frame.canEditPayload)
        XCTAssertNil(frame.editingUnavailableReason)
        let edited = try frame.replacingPayload(Data(#"{"state":"after"}"#.utf8))
        XCTAssertEqual(edited.payload, Data(#"{"state":"after"}"#.utf8))

        XCTAssertThrowsError(
            try frame.replacingPayload(Data(repeating: 0x61, count: 65))
        )

        for readOnly in [
            WebSocketBreakpointFrame(
                sequenceNumber: 8,
                opcode: .binary,
                isFinal: true,
                payload: Data([0x01]),
                originalPayloadByteCount: 1,
                maximumEditablePayloadBytes: 64
            ),
            WebSocketBreakpointFrame(
                sequenceNumber: 9,
                opcode: .text,
                isFinal: false,
                payload: Data("part".utf8),
                originalPayloadByteCount: 4,
                maximumEditablePayloadBytes: 64
            ),
            WebSocketBreakpointFrame(
                sequenceNumber: 10,
                opcode: .text,
                isFinal: true,
                reservedBits: .rsv1,
                payload: Data("compressed".utf8),
                originalPayloadByteCount: 10,
                maximumEditablePayloadBytes: 64
            )
        ] {
            XCTAssertFalse(readOnly.canEditPayload)
            XCTAssertNotNil(readOnly.editingUnavailableReason)
        }

        XCTAssertTrue(WebSocketBreakpointFrame.isEligibleDataOpcode(.text))
        XCTAssertTrue(WebSocketBreakpointFrame.isEligibleDataOpcode(.binary))
        XCTAssertTrue(WebSocketBreakpointFrame.isEligibleDataOpcode(.continuation))
        XCTAssertFalse(WebSocketBreakpointFrame.isEligibleDataOpcode(.ping))
        XCTAssertFalse(WebSocketBreakpointFrame.isEligibleDataOpcode(.pong))
        XCTAssertFalse(WebSocketBreakpointFrame.isEligibleDataOpcode(.close))
    }

    func testRulePlannerSkipsUnimplementedActions() throws {
        let request = HTTPRequest(method: .get, url: URL(string: "https://example.com/")!)
        let rule = Rule(
            name: "Annotate",
            phase: .requestHeaders,
            action: .annotate(message: "Review later")
        )
        let plan = RulePlanner.plan(
            rules: RuleSet(rules: [rule]),
            context: RuleMatchContext(request: request),
            phase: .requestHeaders
        )

        XCTAssertFalse(plan.shouldBlock)
        XCTAssertFalse(plan.applyNoCache)
        XCTAssertFalse(plan.shouldBreakpoint)
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

    func testMutableRuleSnapshotPublishesMappedLocalResources() {
        let spec = MapLocalSpec(
            resourceID: "users.json",
            body: BodyReference(
                inline: Data(#"{"ok":true}"#.utf8),
                metadata: BodyMetadata(contentType: "application/json")
            )
        )
        let snapshot = MutableRuleSnapshot(mappedLocals: [spec])
        XCTAssertEqual(snapshot.mappedLocal(for: "users.json"), spec)

        snapshot.retainMappedLocals([])
        XCTAssertNil(snapshot.mappedLocal(for: "users.json"))

        snapshot.replaceMappedLocal(spec)
        XCTAssertEqual(snapshot.mappedLocal(for: "users.json")?.body.byteCount, 11)
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

    func testJSONBodyViewPrettyPrintsObjectsAndArrays() throws {
        let object = JSONBodyView.render(
            data: Data(#"{"z":1,"a":2,"url":"https://example.com/a"}"#.utf8),
            contentType: "application/json; charset=utf-8",
            contentEncoding: nil
        )
        guard case .prettyPrinted(let objectText) = object else {
            return XCTFail("expected pretty-printed object, got \(object)")
        }
        XCTAssertTrue(objectText.contains("\n"))
        XCTAssertTrue(objectText.contains(#""a""#))
        XCTAssertTrue(objectText.contains(#""z""#))
        XCTAssertTrue(objectText.contains("https://example.com/a"))
        XCTAssertFalse(objectText.contains("\\/"))

        let array = JSONBodyView.render(
            data: Data(#"[2,1]"#.utf8),
            contentType: "application/json",
            contentEncoding: "identity"
        )
        guard case .prettyPrinted(let arrayText) = array else {
            return XCTFail("expected pretty-printed array, got \(array)")
        }
        XCTAssertTrue(arrayText.contains("\n"))
        XCTAssertTrue(arrayText.contains("1"))
        XCTAssertTrue(arrayText.contains("2"))
    }

    func testHexBodyViewFormatsOffsetsHexColumnsAndPrintableASCIIWithinItsBound() {
        let firstLine = Data(Array(0...15).map(UInt8.init))
        XCTAssertEqual(
            HexBodyView.render(firstLine),
            "00000000  00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f  |................|"
        )

        XCTAssertEqual(
            HexBodyView.render(Data([0x20, 0x41, 0x7E, 0x7F])),
            "00000000  20 41 7e 7f                                       | A~.            |"
        )

        let oversized = Data(repeating: 0x41, count: HexBodyView.maximumDisplayedByteCount + 1)
        let rendered = HexBodyView.render(oversized)
        XCTAssertTrue(rendered.hasPrefix("00000000  41 41"))
        XCTAssertTrue(rendered.contains("0000fff0  41 41"))
        XCTAssertTrue(rendered.hasSuffix("[Displaying the first 65.5 KB of 65.5 KB.]"))
        XCTAssertFalse(rendered.contains("00010000"))
    }

    func testProtobufBodyViewDecodesSchemaLessWireValuesWithoutChangingBytes() {
        let payload = Data([
            0x08, 0x96, 0x01,
            0x12, 0x05, 0x68, 0x65, 0x6C, 0x6C, 0x6F,
            0x1A, 0x02, 0x08, 0x07,
            0x25, 0x00, 0x00, 0x80, 0x3F,
            0x2A, 0x04, 0xDE, 0xAD, 0xBE, 0xEF,
            0x31, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F
        ])

        let result = ProtobufBodyView.render(
            data: payload,
            contentType: "application/x-protobuf; messageType=Example",
            contentEncoding: nil
        )

        guard case .decoded(let text) = result else {
            return XCTFail("expected a schema-less Protobuf view, got \(result)")
        }
        XCTAssertTrue(text.contains("1  varint   150"))
        XCTAssertTrue(text.contains("2  string   \"hello\""))
        XCTAssertTrue(text.contains("3  message  2 B"))
        XCTAssertTrue(text.contains("  1  varint   7"))
        XCTAssertTrue(text.contains("4  fixed32"))
        XCTAssertTrue(text.contains("float 1"))
        XCTAssertTrue(text.contains("5  bytes    de ad be ef"))
        XCTAssertTrue(text.contains("6  fixed64"))
        XCTAssertTrue(text.contains("double 1"))
        XCTAssertEqual(payload[0], 0x08)
        XCTAssertEqual(payload.count, 34)
    }

    func testProtobufBodyViewRejectsUndeclaredMalformedTruncatedAndOversizedBodies() {
        let valid = Data([0x08, 0x01])
        XCTAssertEqual(
            ProtobufBodyView.render(
                data: valid,
                contentType: "application/octet-stream",
                contentEncoding: nil
            ),
            .unavailable(reason: ProtobufBodyView.notProtobufReason)
        )

        let incomplete = Data([0x0A, 0x05, 0x41])
        let malformed = ProtobufBodyView.render(
            data: incomplete,
            contentType: "application/protobuf",
            contentEncoding: nil
        )
        guard case .unavailable(let malformedReason) = malformed else {
            return XCTFail("expected invalid Protobuf, got \(malformed)")
        }
        XCTAssertTrue(malformedReason.hasPrefix("Invalid Protobuf:"))
        XCTAssertEqual(
            ProtobufBodyView.render(
                data: incomplete,
                contentType: "application/protobuf",
                contentEncoding: nil,
                isTruncated: true
            ),
            .unavailable(reason: ProtobufBodyView.truncatedReason)
        )

        let oversized = Data(
            repeating: 0,
            count: ProtobufBodyView.maximumDecodedByteCount + 1
        )
        XCTAssertEqual(
            ProtobufBodyView.render(
                data: oversized,
                contentType: "application/protobuf",
                contentEncoding: nil
            ),
            .unavailable(reason: ProtobufBodyView.exceedsDisplayLimitReason)
        )

        var tooManyFields = Data()
        for _ in 0...ProtobufBodyView.maximumFieldCount {
            tooManyFields.append(contentsOf: [0x08, 0x01])
        }
        XCTAssertEqual(
            ProtobufBodyView.render(
                data: tooManyFields,
                contentType: "application/protobuf",
                contentEncoding: nil
            ),
            .unavailable(reason: ProtobufBodyView.fieldLimitReason)
        )
    }

    func testProtobufBodyViewBoundsNestedMessageDecoding() {
        var nested = Data([0x08, 0x01])
        for _ in 0...ProtobufBodyView.maximumNestingDepth {
            XCTAssertLessThan(nested.count, 128)
            var parent = Data([0x0A, UInt8(nested.count)])
            parent.append(nested)
            nested = parent
        }

        let result = ProtobufBodyView.render(
            data: nested,
            contentType: "application/protobuf",
            contentEncoding: nil
        )

        guard case .decoded(let text) = result else {
            return XCTFail("expected bounded nested Protobuf output, got \(result)")
        }
        XCTAssertLessThanOrEqual(
            text.components(separatedBy: "message").count - 1,
            ProtobufBodyView.maximumNestingDepth
        )
        XCTAssertTrue(text.contains("bytes"))
    }

    func testProtobufBodyViewDecodesLengthPrefixedGRPCMessages() {
        let firstMessage = Data([0x08, 0x96, 0x01])
        let secondMessage = Data([0x12, 0x05, 0x68, 0x65, 0x6C, 0x6C, 0x6F])
        var body = Data([0x00, 0x00, 0x00, 0x00, UInt8(firstMessage.count)])
        body.append(firstMessage)
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00, UInt8(secondMessage.count)])
        body.append(secondMessage)

        let result = ProtobufBodyView.render(
            data: body,
            contentType: "application/grpc+proto",
            contentEncoding: nil
        )

        guard case .decoded(let text) = result else {
            return XCTFail("expected framed gRPC messages, got \(result)")
        }
        XCTAssertTrue(text.contains("Message 1 · 3 B · uncompressed"))
        XCTAssertTrue(text.contains("1  varint   150"))
        XCTAssertTrue(text.contains("Message 2 · 7 B · uncompressed"))
        XCTAssertTrue(text.contains("2  string   \"hello\""))
    }

    func testProtobufBodyViewDecodesExplicitlyCompressedGRPCMessages() throws {
        let message = Data([0x08, 0x2A])
        let compressed = try HTTPContentCoding.encode(message, contentEncoding: "gzip")
        var body = Data([0x01])
        let length = UInt32(compressed.count).bigEndian
        withUnsafeBytes(of: length) { body.append(contentsOf: $0) }
        body.append(compressed)

        let result = ProtobufBodyView.render(
            data: body,
            contentType: "application/grpc",
            contentEncoding: nil,
            grpcEncoding: "gzip"
        )

        guard case .decoded(let text) = result else {
            return XCTFail("expected compressed gRPC message, got \(result)")
        }
        XCTAssertTrue(text.contains("Message 1 · 2 B · gzip"))
        XCTAssertTrue(text.contains("1  varint   42"))
    }

    func testProtobufBodyViewRejectsMalformedGRPCFrames() {
        let truncatedFrame = Data([0x00, 0x00, 0x00, 0x00, 0x02, 0x08])
        let invalidFlag = Data([0x02, 0x00, 0x00, 0x00, 0x00])
        let compressedWithoutEncoding = Data([0x01, 0x00, 0x00, 0x00, 0x00])

        for body in [truncatedFrame, invalidFlag, compressedWithoutEncoding] {
            let result = ProtobufBodyView.render(
                data: body,
                contentType: "application/grpc+proto",
                contentEncoding: nil
            )
            guard case .unavailable(let reason) = result else {
                return XCTFail("expected malformed gRPC frame rejection, got \(result)")
            }
            XCTAssertTrue(reason.hasPrefix("Invalid Protobuf:"))
        }

        XCTAssertEqual(
            ProtobufBodyView.render(
                data: truncatedFrame,
                contentType: "application/grpc+proto",
                contentEncoding: nil,
                isTruncated: true
            ),
            .unavailable(reason: ProtobufBodyView.truncatedReason)
        )
    }

    func testProtobufBodyViewBoundsGRPCMessageCountAndExplainsUnsupportedCompression() {
        var tooManyMessages = Data()
        for _ in 0...ProtobufBodyView.maximumGRPCMessageCount {
            tooManyMessages.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00])
        }
        XCTAssertEqual(
            ProtobufBodyView.render(
                data: tooManyMessages,
                contentType: "application/grpc",
                contentEncoding: nil
            ),
            .unavailable(reason: ProtobufBodyView.grpcMessageLimitReason)
        )

        let unsupported = ProtobufBodyView.render(
            data: Data([0x01, 0x00, 0x00, 0x00, 0x02, 0xDE, 0xAD]),
            contentType: "application/grpc+proto",
            contentEncoding: nil,
            grpcEncoding: "snappy"
        )
        guard case .decoded(let text) = unsupported else {
            return XCTFail(
                "expected an explicit unsupported-compression summary, got \(unsupported)")
        }
        XCTAssertTrue(text.contains("Message 1 · 2 B · snappy (compressed)"))
        XCTAssertTrue(text.contains("unsupported grpc-encoding \"snappy\""))
    }

    func testJSONPathBodyViewResolvesKeysIndexesAndWildcards() {
        let json =
            #"{"users":[{"name":"Ada","roles":["admin","owner"]},{"name":"Lin","roles":["reader"]}],"meta":{"count":2}}"#

        XCTAssertEqual(
            JSONPathBodyView.evaluate(json: json, query: "$.users[0].name"),
            .matches([.init(path: "$.users[0].name", value: #""Ada""#)])
        )
        XCTAssertEqual(
            JSONPathBodyView.evaluate(json: json, query: "$.users[*].name"),
            .matches([
                .init(path: "$.users[0].name", value: #""Ada""#),
                .init(path: "$.users[1].name", value: #""Lin""#)
            ])
        )
        XCTAssertEqual(
            JSONPathBodyView.evaluate(json: json, query: "$['meta']['count']"),
            .matches([.init(path: "$.meta.count", value: "2")])
        )
        XCTAssertEqual(
            JSONPathBodyView.evaluate(json: json, query: "$.users[0].roles[*]"),
            .matches([
                .init(path: "$.users[0].roles[0]", value: #""admin""#),
                .init(path: "$.users[0].roles[1]", value: #""owner""#)
            ])
        )
    }

    func testJSONPathBodyViewReportsInvalidQueriesAndBounds() {
        XCTAssertEqual(
            JSONPathBodyView.evaluate(json: "{}", query: ""),
            .unavailable(reason: JSONPathBodyView.emptyQueryReason)
        )
        guard
            case .unavailable(let reason) = JSONPathBodyView.evaluate(
                json: "{}",
                query: "users"
            )
        else {
            return XCTFail("expected invalid JSONPath")
        }
        XCTAssertTrue(reason.contains("must start with '$'"))

        guard
            case .unavailable(let unsupported) = JSONPathBodyView.evaluate(
                json: "{}",
                query: "$..users"
            )
        else {
            return XCTFail("expected unsupported recursive descent")
        }
        XCTAssertTrue(unsupported.contains("recursive descent"))

        let oversized = String(repeating: "x", count: JSONPathBodyView.maximumInputByteCount + 1)
        XCTAssertEqual(
            JSONPathBodyView.evaluate(json: oversized, query: "$"),
            .unavailable(reason: JSONPathBodyView.exceedsDisplayLimitReason)
        )

        let tooDeepQuery =
            "$" + String(repeating: ".value", count: JSONPathBodyView.maximumDepth + 1)
        if case .unavailable(let reason) = JSONPathBodyView.evaluate(
            json: "{}", query: tooDeepQuery)
        {
            XCTAssertTrue(reason.contains("maximum depth"))
        } else {
            XCTFail("expected an explicit depth bound")
        }
    }

    func testJQBodyViewProjectsFiltersAndIteratesDeterministically() {
        let json =
            #"{"users":[{"name":"Ada","active":true,"score":12,"alias":null},{"name":"Lin","active":false,"score":20,"alias":"L"},{"name":"Mo","active":true,"score":9,"alias":null}],"meta":{"count":3}}"#

        XCTAssertEqual(
            JQBodyView.evaluate(
                json: json,
                query: ".users[] | select(.active == true) | .name"
            ),
            .values([#""Ada""#, #""Mo""#])
        )
        XCTAssertEqual(
            JQBodyView.evaluate(
                json: json,
                query: ".users[] | select(.score >= 12) | .score"
            ),
            .values(["12", "20"])
        )
        XCTAssertEqual(
            JQBodyView.evaluate(
                json: json,
                query: #".users[] | select(.name != "Lin") | .name"#
            ),
            .values([#""Ada""#, #""Mo""#])
        )
        XCTAssertEqual(
            JQBodyView.evaluate(
                json: json,
                query: ".users[] | select(.alias == null) | .name"
            ),
            .values([#""Ada""#, #""Mo""#])
        )
        XCTAssertEqual(
            JQBodyView.evaluate(json: #"{"b":2,"a":1}"#, query: ".[]"),
            .values(["1", "2"])
        )
        XCTAssertEqual(
            JQBodyView.evaluate(json: json, query: ".[\"meta\"].count"),
            .values(["3"])
        )
        XCTAssertEqual(
            JQBodyView.evaluate(json: json, query: ".users[1].missing"),
            .values([])
        )
        XCTAssertEqual(
            JQBodyView.evaluate(json: json, query: "."),
            JQBodyView.evaluate(json: json, query: " . ")
        )
    }

    func testJQBodyViewRejectsUnsupportedSyntaxAndBoundsEveryResource() throws {
        XCTAssertEqual(
            JQBodyView.evaluate(json: "{}", query: ""),
            .unavailable(reason: JQBodyView.emptyQueryReason)
        )

        for query in ["map(.id)", ".items |", "select(.name)", ".[-1]"] {
            guard case .unavailable(let reason) = JQBodyView.evaluate(json: "{}", query: query)
            else {
                return XCTFail("expected unsupported jq query: \(query)")
            }
            XCTAssertTrue(reason.contains("jq"))
        }

        let oversizedInput = String(repeating: "x", count: JQBodyView.maximumInputByteCount + 1)
        XCTAssertEqual(
            JQBodyView.evaluate(json: oversizedInput, query: "."),
            .unavailable(reason: JQBodyView.exceedsDisplayLimitReason)
        )

        let oversizedQuery = String(repeating: ".a", count: 2_049)
        XCTAssertGreaterThan(oversizedQuery.utf8.count, JQBodyView.maximumQueryByteCount)
        XCTAssertEqual(
            JQBodyView.evaluate(json: "{}", query: oversizedQuery),
            .unavailable(reason: JQBodyView.queryLimitReason)
        )

        let tooManyStages = Array(
            repeating: ".",
            count: JQBodyView.maximumPipelineStageCount + 1
        ).joined(separator: " | ")
        XCTAssertEqual(
            JQBodyView.evaluate(json: "{}", query: tooManyStages),
            .unavailable(reason: JQBodyView.pipelineLimitReason)
        )

        let tooDeep = String(repeating: ".a", count: JQBodyView.maximumTraversalDepth + 1)
        XCTAssertEqual(
            JQBodyView.evaluate(json: "{}", query: tooDeep),
            .unavailable(reason: JQBodyView.traversalLimitReason)
        )

        let expanded = Array(repeating: 1, count: JQBodyView.maximumValueCount + 1)
        let expandedJSON = try XCTUnwrap(
            String(
                data: JSONSerialization.data(withJSONObject: expanded),
                encoding: .utf8
            )
        )
        XCTAssertEqual(
            JQBodyView.evaluate(json: expandedJSON, query: ".[]"),
            .unavailable(reason: JQBodyView.valueLimitReason)
        )

        let oversizedValue = String(
            repeating: "x",
            count: JQBodyView.maximumRenderedOutputByteCount + 1
        )
        let oversizedOutputJSON = try XCTUnwrap(
            String(
                data: JSONSerialization.data(
                    withJSONObject: oversizedValue, options: .fragmentsAllowed),
                encoding: .utf8
            )
        )
        XCTAssertEqual(
            JQBodyView.evaluate(json: oversizedOutputJSON, query: "."),
            .unavailable(reason: JQBodyView.renderedOutputLimitReason)
        )
    }

    func testJSONBodyViewAcceptsSuffixJSONTypesAndSniffsCompactPayloads() {
        let problem = JSONBodyView.render(
            data: Data(#"{"title":"gone"}"#.utf8),
            contentType: "application/problem+json",
            contentEncoding: nil
        )
        guard case .prettyPrinted(let problemText) = problem else {
            return XCTFail("expected pretty-printed problem+json, got \(problem)")
        }
        XCTAssertTrue(problemText.contains(#""title""#))

        let sniffed = JSONBodyView.render(
            data: Data(#"{"ok":true}"#.utf8),
            contentType: "text/plain",
            contentEncoding: nil
        )
        guard case .prettyPrinted(let sniffedText) = sniffed else {
            return XCTFail("expected sniffed JSON, got \(sniffed)")
        }
        XCTAssertTrue(sniffedText.contains(#""ok""#))
        XCTAssertTrue(sniffedText.contains("true"))
    }

    func testJSONBodyViewReportsInvalidJSONTruncationAndSizeLimits() {
        let invalid = JSONBodyView.render(
            data: Data(#"{"ok":"#.utf8),
            contentType: "application/json",
            contentEncoding: nil
        )
        guard case .unavailable(let invalidReason) = invalid else {
            return XCTFail("expected invalid JSON, got \(invalid)")
        }
        XCTAssertTrue(invalidReason.hasPrefix("Invalid JSON:"))

        let notJSON = JSONBodyView.render(
            data: Data("hello".utf8),
            contentType: "text/plain",
            contentEncoding: nil
        )
        XCTAssertEqual(notJSON, .unavailable(reason: JSONBodyView.notJSONReason))

        let emptyJSON = JSONBodyView.render(
            data: Data(),
            contentType: "application/json",
            contentEncoding: nil
        )
        XCTAssertEqual(
            emptyJSON,
            .unavailable(reason: JSONBodyView.invalidJSONReason("The body is empty."))
        )

        let emptyPlain = JSONBodyView.render(
            data: Data(),
            contentType: "text/plain",
            contentEncoding: nil
        )
        XCTAssertEqual(emptyPlain, .unavailable(reason: JSONBodyView.notJSONReason))

        let truncated = JSONBodyView.render(
            data: Data(#"{"ok":"#.utf8),
            contentType: "application/json",
            contentEncoding: nil,
            isTruncated: true
        )
        XCTAssertEqual(truncated, .unavailable(reason: JSONBodyView.truncatedReason))

        let oversized = Data(
            repeating: UInt8(ascii: "x"),
            count: JSONBodyView.maximumDecodedByteCount + 1
        )
        let limited = JSONBodyView.render(
            data: Data("{\"a\":\"".utf8) + oversized + Data("\"}".utf8),
            contentType: "application/json",
            contentEncoding: nil
        )
        XCTAssertEqual(limited, .unavailable(reason: JSONBodyView.exceedsDisplayLimitReason))
    }

    func testJSONBodyViewUnwrapsGzipAndDeflateOnlyForDerivedInspection() throws {
        let compact = Data(#"{"z":1,"a":2}"#.utf8)
        let gzipped = try ZlibContentEncoding.compress(compact, format: .gzip)
        let deflated = try ZlibContentEncoding.compress(compact, format: .zlib)
        XCTAssertNotEqual(gzipped, compact)

        let asRaw = JSONBodyView.render(
            data: gzipped,
            contentType: "application/octet-stream",
            contentEncoding: nil
        )
        XCTAssertEqual(asRaw, .unavailable(reason: JSONBodyView.notJSONReason))

        let fromGzip = JSONBodyView.render(
            data: gzipped,
            contentType: "application/json",
            contentEncoding: "gzip"
        )
        guard case .prettyPrinted(let gzipText) = fromGzip else {
            return XCTFail("expected gzip JSON, got \(fromGzip)")
        }
        XCTAssertTrue(gzipText.contains(#""a""#))
        XCTAssertTrue(gzipText.contains(#""z""#))

        let fromDeflate = JSONBodyView.render(
            data: deflated,
            contentType: "application/json",
            contentEncoding: "deflate"
        )
        guard case .prettyPrinted(let deflateText) = fromDeflate else {
            return XCTFail("expected deflate JSON, got \(fromDeflate)")
        }
        XCTAssertTrue(deflateText.contains(#""a""#))

        let brotli = JSONBodyView.render(
            data: compact,
            contentType: "application/json",
            contentEncoding: "br"
        )
        XCTAssertEqual(
            brotli,
            .unavailable(reason: JSONBodyView.unsupportedContentEncodingReason("br"))
        )

        let truncatedBrotli = JSONBodyView.render(
            data: compact,
            contentType: "application/json",
            contentEncoding: "br",
            isTruncated: true
        )
        XCTAssertEqual(
            truncatedBrotli,
            .unavailable(reason: JSONBodyView.unsupportedContentEncodingReason("br"))
        )

        let truncatedGzip = JSONBodyView.render(
            data: Data([0x1F, 0x8B, 0x08]),
            contentType: "application/json",
            contentEncoding: "gzip",
            isTruncated: true
        )
        XCTAssertEqual(truncatedGzip, .unavailable(reason: JSONBodyView.truncatedReason))

        let payload =
            Data("{\"a\":\"".utf8)
            + Data(repeating: UInt8(ascii: "x"), count: JSONBodyView.maximumDecodedByteCount + 8)
            + Data("\"}".utf8)
        let gzipBomb = try ZlibContentEncoding.compress(payload, format: .gzip)
        XCTAssertLessThan(gzipBomb.count, JSONBodyView.maximumDecodedByteCount)
        let exploded = JSONBodyView.render(
            data: gzipBomb,
            contentType: "application/json",
            contentEncoding: "gzip"
        )
        XCTAssertEqual(exploded, .unavailable(reason: JSONBodyView.exceedsDisplayLimitReason))
    }

    func testXMLBodyViewPrettyPrintsDeclaredAndSniffedDocumentsWithoutExternalEntities() {
        let declared = XMLBodyView.render(
            data: Data(#"<?xml version="1.0"?><root><item id="1">Ada</item><empty/></root>"#.utf8),
            contentType: "application/problem+xml; charset=utf-8",
            contentEncoding: nil
        )
        guard case .prettyPrinted(let declaredText) = declared else {
            return XCTFail("expected pretty-printed XML, got \(declared)")
        }
        XCTAssertTrue(declaredText.contains("<root>\n"))
        XCTAssertTrue(declaredText.contains("  <item id=\"1\">Ada</item>"))

        let sniffed = XMLBodyView.render(
            data: Data("<status><ok>true</ok></status>".utf8),
            contentType: "text/plain",
            contentEncoding: nil
        )
        guard case .prettyPrinted(let sniffedText) = sniffed else {
            return XCTFail("expected sniffed XML, got \(sniffed)")
        }
        XCTAssertTrue(sniffedText.contains("<ok>true</ok>"))

        let externalEntity = XMLBodyView.render(
            data: Data(
                #"<!DOCTYPE root [<!ENTITY local SYSTEM "file:///etc/hosts">]><root>&local;</root>"#
                    .utf8
            ),
            contentType: "application/xml",
            contentEncoding: nil
        )
        switch externalEntity {
        case .prettyPrinted(let safeText):
            XCTAssertFalse(safeText.contains("localhost"))
        case .unavailable(let reason):
            XCTAssertEqual(reason, XMLBodyView.documentTypeReason)
        }
    }

    func testXMLBodyViewAndFormBodyViewReportInvalidTruncatedAndDecodedContent() {
        let invalidXML = XMLBodyView.render(
            data: Data("<root>".utf8),
            contentType: "application/xml",
            contentEncoding: nil
        )
        guard case .unavailable(let invalidReason) = invalidXML else {
            return XCTFail("expected invalid XML, got \(invalidXML)")
        }
        XCTAssertTrue(invalidReason.hasPrefix("Invalid XML:"))

        XCTAssertEqual(
            XMLBodyView.render(
                data: Data("<root>".utf8),
                contentType: "application/xml",
                contentEncoding: nil,
                isTruncated: true
            ),
            .unavailable(reason: XMLBodyView.truncatedReason)
        )

        let form = FormBodyView.render(
            data: Data("name=ProxyLens+App&tag=one&tag=two&empty=&flag".utf8),
            contentType: "application/x-www-form-urlencoded; charset=utf-8",
            contentEncoding: nil
        )
        XCTAssertEqual(
            form,
            .decoded("name=ProxyLens App\ntag=one\ntag=two\nempty=\nflag=")
        )
        XCTAssertEqual(
            FormBodyView.render(
                data: Data("name=ProxyLens".utf8),
                contentType: "text/plain",
                contentEncoding: nil
            ),
            .unavailable(reason: FormBodyView.notFormReason)
        )
    }

    func testFormBodyViewDecodesBoundedMultipartFieldsAndSummarizesFiles() {
        let boundary = "ProxyLensBoundary"
        let prefix = "--\(boundary)\r\n"
        let body =
            Data(
                (prefix
                    + "Content-Disposition: form-data; name=\"name\"\r\n\r\n"
                    + "ProxyLens App\r\n"
                    + prefix
                    + "Content-Disposition: form-data; name=\"tag\"\r\n\r\n"
                    + "one\r\n"
                    + prefix
                    + "Content-Disposition: form-data; name=\"tag\"\r\n\r\n"
                    + "two\r\n"
                    + prefix
                    + "Content-Disposition: form-data; name=\"avatar\"; filename=\"icon.png\"\r\n"
                    + "Content-Type: image/png\r\n\r\n").utf8
            )
            + Data([0x89, 0x50, 0x4E, 0x47])
            + Data("\r\n--\(boundary)--\r\n".utf8)

        XCTAssertEqual(
            FormBodyView.render(
                data: body,
                contentType: "multipart/form-data; boundary=\"\(boundary)\"",
                contentEncoding: nil
            ),
            .decoded(
                "name=ProxyLens App\ntag=one\ntag=two\navatar=[File \"icon.png\", image/png, 4 B]"
            )
        )
    }

    func testFormBodyViewRejectsMalformedMultipartAndReportsTruncatedCapture() {
        XCTAssertEqual(
            FormBodyView.render(
                data: Data("ignored".utf8),
                contentType: "multipart/form-data",
                contentEncoding: nil
            ),
            .unavailable(reason: FormBodyView.missingMultipartBoundaryReason)
        )

        let incomplete = Data(
            "--test\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nvalue".utf8
        )
        let malformed = FormBodyView.render(
            data: incomplete,
            contentType: "multipart/form-data; boundary=test",
            contentEncoding: nil
        )
        guard case .unavailable(let reason) = malformed else {
            return XCTFail("expected invalid multipart data, got \(malformed)")
        }
        XCTAssertTrue(reason.hasPrefix("Invalid multipart form:"))
        XCTAssertEqual(
            FormBodyView.render(
                data: incomplete,
                contentType: "multipart/form-data; boundary=test",
                contentEncoding: nil,
                isTruncated: true
            ),
            .unavailable(reason: FormBodyView.truncatedReason)
        )
    }

    func testGraphQLBodyViewFormatsJSONEnvelopeAndVariables() {
        let envelope = Data(
            #"{"operationName":"GetUser","query":"query GetUser($id: ID!) { user(id: $id) { id name } }","variables":{"id":"42"}}"#
                .utf8
        )

        let result = GraphQLBodyView.render(
            data: envelope,
            contentType: "application/json; charset=utf-8",
            contentEncoding: nil
        )
        guard case .formatted(let text) = result else {
            return XCTFail("expected formatted GraphQL, got \(result)")
        }
        XCTAssertTrue(text.hasPrefix("Operation: GetUser\n\n"))
        XCTAssertTrue(text.contains("query GetUser($id: ID!) {\n"))
        XCTAssertTrue(text.contains("  user(id: $id) {\n"))
        XCTAssertTrue(text.contains("    id\n    name\n"))
        XCTAssertTrue(text.contains("\nVariables:\n"))
        XCTAssertTrue(text.contains(#""id" : "42""#))
    }

    func testGraphQLBodyViewFormatsDeclaredSourceWithoutChangingStringValues() {
        let source =
            #"query Search { search(text: "a { brace }") { ...ResultFields } } fragment ResultFields on Result { id title }"#
        let result = GraphQLBodyView.render(
            data: Data(source.utf8),
            contentType: "application/graphql",
            contentEncoding: nil
        )
        guard case .formatted(let text) = result else {
            return XCTFail("expected formatted GraphQL, got \(result)")
        }
        XCTAssertTrue(text.hasPrefix("Operation: Search\n\n"))
        XCTAssertTrue(text.contains(#"search(text: "a { brace }") {"#))
        XCTAssertTrue(text.contains("...ResultFields"))
        XCTAssertTrue(text.contains("fragment ResultFields on Result {\n"))
    }

    func testGraphQLBodyViewRejectsUnrelatedInvalidAndTruncatedPayloads() {
        XCTAssertEqual(
            GraphQLBodyView.render(
                data: Data(#"{"status":"ok"}"#.utf8),
                contentType: "application/json",
                contentEncoding: nil
            ),
            .unavailable(reason: GraphQLBodyView.notGraphQLReason)
        )

        let invalid = GraphQLBodyView.render(
            data: Data(#"{"query":42}"#.utf8),
            contentType: "application/json",
            contentEncoding: nil
        )
        guard case .unavailable(let invalidReason) = invalid else {
            return XCTFail("expected invalid GraphQL envelope, got \(invalid)")
        }
        XCTAssertTrue(invalidReason.hasPrefix("Invalid GraphQL request:"))

        XCTAssertEqual(
            GraphQLBodyView.render(
                data: Data("query Viewer { viewer { id".utf8),
                contentType: "application/graphql",
                contentEncoding: nil,
                isTruncated: true
            ),
            .unavailable(reason: GraphQLBodyView.truncatedReason)
        )
    }

    func testGraphQLBodyViewExtractsNamedAndAnonymousOperationMetadata() {
        let namedEnvelope = Data(
            #"{"operationName":"UpdateProfile","query":"mutation UpdateProfile($name: String!) { updateProfile(name: $name) { id } }","variables":{"name":"Ada"}}"#
                .utf8
        )

        XCTAssertEqual(
            GraphQLBodyView.operationMetadata(
                data: namedEnvelope,
                contentType: "application/json",
                contentEncoding: nil
            ),
            GraphQLOperationMetadata(kind: .mutation, name: "UpdateProfile")
        )
        XCTAssertEqual(
            GraphQLBodyView.operationMetadata(
                data: Data("{ viewer { id } }".utf8),
                contentType: "application/graphql",
                contentEncoding: nil
            ),
            GraphQLOperationMetadata(kind: .query, name: nil)
        )
        XCTAssertNil(
            GraphQLBodyView.operationMetadata(
                data: Data(#"{"status":"ok"}"#.utf8),
                contentType: "application/json",
                contentEncoding: nil
            )
        )
    }

    func testHTTPRequestTracksGraphQLOperationAndDecodesOlderSnapshots() throws {
        let body = BodyReference(
            inline: Data(#"{"query":"subscription Activity { activity { id } }"}"#.utf8),
            metadata: BodyMetadata(contentType: "application/json")
        )
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://api.example.com/graphql")!,
            body: body
        )

        XCTAssertEqual(
            request.graphqlOperation,
            GraphQLOperationMetadata(kind: .subscription, name: "Activity")
        )
        XCTAssertEqual(
            request.replacingHeaders(HTTPHeaders()).graphqlOperation, request.graphqlOperation)
        XCTAssertNil(request.replacingBody(nil).graphqlOperation)

        let encoded = try JSONEncoder().encode(request)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "graphqlOperation")
        let olderSnapshot = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(HTTPRequest.self, from: olderSnapshot)
        XCTAssertNil(decoded.graphqlOperation)
    }

    func testHTTPContentCodingRoundTripsGzipAndBoundsDecodedOutput() throws {
        let body = Data(#"{"value":"editable"}"#.utf8)
        let encoded = try HTTPContentCoding.encode(body, contentEncoding: "gzip")

        XCTAssertNotEqual(encoded, body)
        XCTAssertEqual(
            try HTTPContentCoding.decode(
                encoded,
                contentEncoding: "gzip",
                maximumOutputByteCount: body.count
            ),
            body
        )
        XCTAssertThrowsError(
            try HTTPContentCoding.decode(
                encoded,
                contentEncoding: "gzip",
                maximumOutputByteCount: body.count - 1
            )
        ) { error in
            XCTAssertEqual(error as? HTTPContentCoding.CodingError, .exceedsLimit)
        }
    }

    func testTLSInterceptionPolicyDefaultsToInterceptingEverything() {
        let policy = TLSInterceptionPolicy()
        XCTAssertEqual(policy.mode, .interceptAllExcept)
        XCTAssertTrue(policy.entries.isEmpty)
        XCTAssertTrue(policy.shouldIntercept(host: "api.example.com"))
        XCTAssertTrue(policy.shouldIntercept(host: "127.0.0.1"))
    }

    func testTLSInterceptionPolicyExcludeModeMatchesExactAndWildcardEntries()
        throws
    {
        let policy = try TLSInterceptionPolicy(
            mode: .interceptAllExcept,
            entries: ["pinned.example.com", "*.apple.com"]
        )
        XCTAssertFalse(policy.shouldIntercept(host: "pinned.example.com"))
        XCTAssertFalse(policy.shouldIntercept(host: "PINNED.example.com"))
        XCTAssertFalse(policy.shouldIntercept(host: "push.apple.com"))
        XCTAssertFalse(policy.shouldIntercept(host: "a.b.apple.com"))
        XCTAssertTrue(policy.shouldIntercept(host: "apple.com"))
        XCTAssertTrue(policy.shouldIntercept(host: "example.com"))
        XCTAssertTrue(policy.matches(host: "pinned.example.com"))
        XCTAssertFalse(policy.matches(host: "example.com"))
    }

    func testTLSInterceptionPolicyInterceptOnlyModeInterceptsOnlyListedHosts()
        throws
    {
        let policy = try TLSInterceptionPolicy(
            mode: .interceptOnly,
            entries: ["*.dev.internal"]
        )
        XCTAssertTrue(policy.shouldIntercept(host: "api.dev.internal"))
        XCTAssertFalse(policy.shouldIntercept(host: "example.com"))
        XCTAssertFalse(policy.shouldIntercept(host: "dev.internal"))
    }

    func testTLSInterceptionPolicyNormalizesEntriesAndRejectsInvalidOnes()
        throws
    {
        let policy = try TLSInterceptionPolicy(
            mode: .interceptAllExcept,
            entries: ["  Pinned.Example.COM ", "[::1]"]
        )
        XCTAssertEqual(policy.entries, ["pinned.example.com", "::1"])
        XCTAssertFalse(policy.shouldIntercept(host: "::1"))

        XCTAssertThrowsError(
            try TLSInterceptionPolicy(mode: .interceptAllExcept, entries: ["bad host"])
        )
        XCTAssertThrowsError(
            try TLSInterceptionPolicy(mode: .interceptAllExcept, entries: ["a..b"])
        )
        XCTAssertThrowsError(
            try TLSInterceptionPolicy(mode: .interceptAllExcept, entries: ["a.com", "A.com"])
        ) { error in
            XCTAssertEqual(
                error as? TLSInterceptionPolicyError, .duplicateEntry("a.com")
            )
        }
        let tooMany = (0..<(TLSInterceptionPolicy.maximumEntryCount + 1))
            .map { "h\($0).example" }
        XCTAssertThrowsError(
            try TLSInterceptionPolicy(mode: .interceptAllExcept, entries: tooMany)
        ) { error in
            XCTAssertEqual(
                error as? TLSInterceptionPolicyError,
                .tooManyEntries(maximum: TLSInterceptionPolicy.maximumEntryCount)
            )
        }
    }

    func testHostPatternNormalizerStripsASingleTrailingDotButNotMoreOrLone()
        throws
    {
        XCTAssertEqual(
            HostPatternNormalizer.normalize("example.com.", allowsWildcard: false),
            "example.com"
        )
        XCTAssertEqual(
            HostPatternNormalizer.normalize("*.example.com.", allowsWildcard: true),
            "*.example.com"
        )
        XCTAssertNil(HostPatternNormalizer.normalize(".", allowsWildcard: false))
        XCTAssertNil(
            HostPatternNormalizer.normalize("example.com..", allowsWildcard: false)
        )
        // A trailing dot has no FQDN meaning on a bracketed IPv6 literal, and must not be
        // stripped in a way that unmasks the brackets (which would otherwise normalize to
        // "::1" or leave "[::1]" with its brackets literally in the string, neither of
        // which any real dialed host ever equals). Rejected outright, same as before the
        // trailing-dot exception existed.
        XCTAssertNil(HostPatternNormalizer.normalize("[::1].", allowsWildcard: false))
    }

    func testTLSInterceptionPolicyMatchesATrailingDotFQDNAgainstAPlainEntryAndBack()
        throws
    {
        let exclusion = try TLSInterceptionPolicy(
            mode: .interceptAllExcept,
            entries: ["example.com"]
        )
        XCTAssertFalse(exclusion.shouldIntercept(host: "example.com."))

        let fqdnEntry = try TLSInterceptionPolicy(
            mode: .interceptAllExcept,
            entries: ["example.com."]
        )
        XCTAssertEqual(fqdnEntry.entries, ["example.com"])
        XCTAssertFalse(fqdnEntry.shouldIntercept(host: "example.com"))
    }

    func testTLSInterceptionPolicyCodableRoundTripsAndRejectsMalformedDocuments()
        throws
    {
        let policy = try TLSInterceptionPolicy(
            mode: .interceptOnly,
            entries: ["*.example.com"]
        )
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(
            TLSInterceptionPolicy.self,
            from: data
        )
        XCTAssertEqual(decoded, policy)

        let malformed = Data(
            #"{"mode":"interceptOnly","entries":["bad host"]}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TLSInterceptionPolicy.self,
                from: malformed
            )
        )
    }

    func testMutableTLSInterceptionPolicyReplacesLivePolicy() throws {
        let box = MutableTLSInterceptionPolicy()
        XCTAssertTrue(box.currentPolicy().shouldIntercept(host: "example.com"))
        box.replace(
            try TLSInterceptionPolicy(
                mode: .interceptAllExcept,
                entries: ["example.com"]
            )
        )
        XCTAssertFalse(box.currentPolicy().shouldIntercept(host: "example.com"))
    }
}
