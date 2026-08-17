import Foundation
import ProxyLensCore
import XCTest

@testable import ProxyLensApplication

final class ProxyLensApplicationTests: XCTestCase {
    func testCURLImportParsesACommonMultilineJSONRequestWithoutExecutingShellCode()
        throws
    {
        let request = try CURLRequestImporter.parse(
            #"""
            curl 'https://api.example.com/v1/items?draft=1' \
              -X PATCH \
              -H 'Content-Type: application/json' \
              -H 'X-Debug: enabled' \
              --data-raw '{"name":"Ada","enabled":true}' \
              --compressed
            """#
        )

        XCTAssertEqual(request.method, .patch)
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/items?draft=1")
        XCTAssertEqual(request.headers.firstValue(for: "Content-Type"), "application/json")
        XCTAssertEqual(request.headers.firstValue(for: "X-Debug"), "enabled")
        XCTAssertEqual(
            request.body?.inlineData,
            Data(#"{"name":"Ada","enabled":true}"#.utf8)
        )
        XCTAssertEqual(request.headers.firstValue(for: "Content-Length"), "29")
    }

    func testCURLImportAppliesJSONDefaultsAndSupportsAttachedOptions() throws {
        let request = try CURLRequestImporter.parse(
            #"curl --url=https://api.example.com/events -HAccept-Language:en -btoken=abc --json='{"name":"ProxyLens"}'"#
        )

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.headers.firstValue(for: "Accept-Language"), "en")
        XCTAssertEqual(request.headers.firstValue(for: "Cookie"), "token=abc")
        XCTAssertEqual(request.headers.firstValue(for: "Content-Type"), "application/json")
        XCTAssertEqual(request.headers.firstValue(for: "Accept"), "application/json")
        XCTAssertEqual(request.body?.inlineData, Data(#"{"name":"ProxyLens"}"#.utf8))
    }

    func testCURLImportRejectsFileReferencesUnsupportedOptionsAndOversizedInput() {
        for command in [
            "curl https://example.com --data-binary @payload.json",
            "curl https://example.com --cookie @cookies.txt",
            "curl https://example.com --form avatar=@photo.png",
            "curl https://example.com --definitely-not-a-real-option",
            #"curl https://example.com --data-binary $'\xff'"#
        ] {
            XCTAssertThrowsError(try CURLRequestImporter.parse(command))
        }

        XCTAssertThrowsError(
            try CURLRequestImporter.parse(
                "curl https://example.com/" + String(repeating: "a", count: 262_145)
            )
        )
    }

    func testExportServiceBuildsDeterministicOpenAPISpecWithoutSecretHeaderValues()
        async throws
    {
        let first = try Self.exportFlow(
            method: .get,
            url: "https://api.example.com/users?q=ada",
            requestHeaders: [
                ("Authorization", "Bearer secret-token"),
                ("Accept", "application/json")
            ],
            statusCode: 200,
            reasonPhrase: "OK",
            responseHeaders: [("Content-Type", "application/json")],
            responseBody: Data(#"{"id":1,"name":"Ada"}"#.utf8)
        )
        let second = try Self.exportFlow(
            method: .post,
            url: "https://api.example.com/users",
            requestHeaders: [("Content-Type", "application/json")],
            requestBody: Data(#"{"name":"Grace"}"#.utf8),
            statusCode: 201,
            reasonPhrase: "Created",
            responseHeaders: [("Content-Type", "application/json")],
            responseBody: Data(#"{"id":2}"#.utf8)
        )

        let service = ExportService(bodyStore: RecordingBodyStore())
        let data = try await service.openAPI(
            for: [second, first],
            options: OpenAPIExportOptions(title: "Captured API", version: "2026.08")
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix("openapi: \"3.0.3\"\n"))
        XCTAssertTrue(text.contains("title: \"Captured API\""))
        XCTAssertTrue(text.contains("version: \"2026.08\""))
        XCTAssertTrue(text.contains("- url: \"https://api.example.com\""))
        XCTAssertTrue(text.contains("\"/users\":"))
        XCTAssertTrue(text.contains("operationId: \"getUsers\""))
        XCTAssertTrue(text.contains("operationId: \"postUsers\""))
        XCTAssertTrue(text.contains("name: \"q\""))
        XCTAssertTrue(text.contains("\"200\":\n"))
        XCTAssertTrue(text.contains("\"201\":\n"))
        XCTAssertTrue(text.contains("application/json"))
        XCTAssertFalse(text.contains("secret-token"))
        XCTAssertTrue(
            text.range(of: "operationId: \"getUsers\"")!.lowerBound
                < text.range(of: "operationId: \"postUsers\"")!.lowerBound
        )
    }

    func testExportServiceRejectsEmptyAndUnsupportedOpenAPIFlows() async throws {
        let service = ExportService(bodyStore: RecordingBodyStore())

        do {
            _ = try await service.openAPI(for: [])
            XCTFail("Expected an empty OpenAPI export to be rejected")
        } catch let error as OpenAPIExportError {
            XCTAssertEqual(error, .noFlows)
        }

        let connect = try Self.exportFlow(
            method: .connect,
            url: "https://api.example.com/",
            statusCode: 200
        )
        do {
            _ = try await service.openAPI(for: [connect])
            XCTFail("Expected CONNECT to be rejected by OpenAPI export")
        } catch let error as OpenAPIExportError {
            XCTAssertEqual(error, .unsupportedMethod("CONNECT"))
        }
    }

    func testReplayServiceRepeatsTheOriginalRequestAndPersistsTheNewFlow() async throws {
        let original = try Self.exportFlow(
            method: .post,
            url: "https://api.example.com/users",
            requestHeaders: [("Content-Type", "application/json")],
            requestBody: Data(#"{"name":"Ada"}"#.utf8),
            statusCode: 201
        )
        var replayed = Flow(
            sessionID: original.sessionID,
            source: FlowSource(kind: .replay, label: "Replay"),
            request: original.request
        )
        try replayed.transition(to: .receivingRequest)
        try replayed.transition(to: .receivingResponse)
        replayed.attachResponse(
            try HTTPResponse(statusCode: 202, reasonPhrase: "Accepted")
        )
        try replayed.transition(to: .completed)

        let client = RecordingRequestReplayClient(result: replayed)
        let recorder = CallRecorder()
        let store = RecordingSessionStore(sessionID: SessionID(), recorder: recorder)
        let service = ReplayService(client: client, flowStore: store)

        let result = try await service.repeatRequest(original)

        XCTAssertEqual(result, replayed)
        let received = await client.receivedRequests()
        XCTAssertEqual(received.map(\.request), [original.request])
        XCTAssertEqual(received.map(\.sessionID), [original.sessionID])
        let persisted = await store.load(flowID: replayed.id)
        XCTAssertEqual(persisted, replayed)
    }

    func testReplayServicePersistsAReplayCreatedFromAnEditedRequest() async throws {
        let sessionID = SessionID()
        var editedHeaders = HTTPHeaders()
        try editedHeaders.append(name: "Content-Type", value: "application/json")
        try editedHeaders.append(name: "X-Debug", value: "enabled")
        let editedRequest = HTTPRequest(
            method: .patch,
            url: URL(string: "https://api.example.com/users/42")!,
            headers: editedHeaders,
            body: BodyReference(inline: Data(#"{"name":"Grace"}"#.utf8))
        )
        var replayed = Flow(
            sessionID: sessionID,
            source: .replay,
            request: editedRequest
        )
        try replayed.transition(to: .receivingRequest)
        try replayed.transition(to: .receivingResponse)
        replayed.attachResponse(try HTTPResponse(statusCode: 200))
        try replayed.transition(to: .completed)

        let client = RecordingRequestReplayClient(result: replayed)
        let store = RecordingSessionStore(sessionID: sessionID, recorder: CallRecorder())
        let service = ReplayService(client: client, flowStore: store)

        let result = try await service.repeatRequest(editedRequest, sessionID: sessionID)

        XCTAssertEqual(result, replayed)
        let received = await client.receivedRequests()
        XCTAssertEqual(received.map(\.request), [editedRequest])
        XCTAssertEqual(received.map(\.sessionID), [sessionID])
        let persisted = await store.load(flowID: replayed.id)
        XCTAssertEqual(persisted, replayed)
    }

    func testRuleEnginePublishesHostRulesToTheSharedSnapshot() async {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot)

        let blocked = await engine.blockHost("ads.example.com", reason: "tracker")
        let allowed = await engine.allowHost("api.example.com")
        let noCache = await engine.disableCaching(forHost: "cdn.example.com")

        let rules = snapshot.currentRules()
        XCTAssertEqual(rules.rules.map(\.id), [blocked.id, allowed.id] + noCache.map(\.id))
        XCTAssertEqual(
            rules.matchingRules(
                for: RuleMatchContext(
                    request: HTTPRequest(
                        method: .get,
                        url: URL(string: "https://ads.example.com/pixel")!
                    )
                ),
                phase: .requestHeaders
            ).map(\.action),
            [.block(reason: "tracker")]
        )
        XCTAssertEqual(
            rules.matchingRules(
                for: RuleMatchContext(
                    request: HTTPRequest(
                        method: .get,
                        url: URL(string: "https://api.example.com/v1")!
                    )
                ),
                phase: .requestHeaders
            ).map(\.action),
            [.allow]
        )
        XCTAssertEqual(
            rules.matchingRules(
                for: RuleMatchContext(
                    request: HTTPRequest(
                        method: .get,
                        url: URL(string: "https://cdn.example.com/app.js")!
                    )
                ),
                phase: .responseHeaders
            ).map(\.action),
            [.noCache]
        )
    }

    func testRuleEngineLoadsMapLocalFileIntoTheSharedSnapshot() async throws {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot, maximumMapLocalBytes: 1_024)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-map-local-\(UUID().uuidString).json")
        let body = Data(#"{"mapped":true}"#.utf8)
        try body.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let rule = try await engine.mapLocal(
            host: "api.example.com",
            path: "/users?unused=1",
            fileURL: fileURL,
            statusCode: 201
        )

        XCTAssertEqual(rule.name, "Map local api.example.com/users")
        XCTAssertEqual(rule.priority, 15)
        XCTAssertEqual(rule.phase, .requestHeaders)
        guard case .mapLocal(let resourceID) = rule.action else {
            return XCTFail("Expected a map local action")
        }

        let spec = try XCTUnwrap(snapshot.mappedLocal(for: resourceID))
        XCTAssertEqual(spec.statusCode, 201)
        XCTAssertEqual(spec.filePath, fileURL.path)
        XCTAssertEqual(spec.body.contentType, "application/json")
        XCTAssertEqual(spec.body.storage, .inline(body))

        let matching = snapshot.currentRules().matchingRules(
            for: RuleMatchContext(
                request: HTTPRequest(
                    method: .get,
                    url: URL(string: "https://api.example.com/users")!
                )
            ),
            phase: .requestHeaders
        )
        XCTAssertEqual(matching.map(\.id), [rule.id])

        let tooLarge = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-map-local-too-large-\(UUID().uuidString).bin")
        try Data(repeating: 0x61, count: 2_048).write(to: tooLarge)
        defer { try? FileManager.default.removeItem(at: tooLarge) }

        do {
            _ = try await engine.mapLocal(
                host: "api.example.com",
                path: "/huge",
                fileURL: tooLarge
            )
            XCTFail("Expected an oversized Map Local file to be rejected")
        } catch let error as RuleEngineError {
            XCTAssertEqual(
                error,
                .mapLocalFileTooLarge(byteCount: 2_048, maximumByteCount: 1_024)
            )
        }

        await engine.remove(id: rule.id)
        XCTAssertNil(snapshot.mappedLocal(for: resourceID))
        XCTAssertTrue(snapshot.currentRules().rules.isEmpty)
    }

    func testRuleEngineCapturesAndRestoresCompleteRuleProfiles() async throws {
        let sourceSnapshot = MutableRuleSnapshot()
        let sourceEngine = RuleEngine(snapshot: sourceSnapshot, maximumMapLocalBytes: 1_024)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-rule-profile-\(UUID().uuidString).json")
        let body = Data(#"{"profile":true}"#.utf8)
        try body.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        _ = try await sourceEngine.mapLocal(
            host: "api.example.com",
            path: "/profile",
            fileURL: fileURL
        )
        _ = await sourceEngine.blockHost("tracker.example.com")
        let profile = try await sourceEngine.makeProfile(name: "Daily debugging")

        XCTAssertEqual(profile.name, "Daily debugging")
        XCTAssertEqual(profile.rules.rules.count, 2)
        XCTAssertEqual(profile.mappedLocals.count, 1)

        let restoredSnapshot = MutableRuleSnapshot()
        let restoredEngine = RuleEngine(snapshot: restoredSnapshot)
        try await restoredEngine.apply(profile)

        let restoredRules = await restoredEngine.currentRules()
        XCTAssertEqual(restoredRules, profile.rules)
        XCTAssertEqual(
            restoredSnapshot.mappedLocal(for: profile.mappedLocals[0].resourceID),
            profile.mappedLocals[0]
        )
    }

    func testRuleProfileArchiveRoundTripsAPortableVersionedDocument() async throws {
        let service = RuleProfileArchiveService(maximumArchiveByteCount: 4_096)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-rules-\(UUID().uuidString).proxylensrules")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let profile = RuleProfile(
            id: UUID(uuidString: "57E012DC-67E7-486D-95E2-D44DBF15DCCA")!,
            name: "API debugging",
            rules: RuleSet(rules: [await RuleEngine().blockHost("tracker.example.com")]),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        try await service.export(profile, to: fileURL)
        let exportedText = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(exportedText.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(exportedText.contains("\"API debugging\""))

        let imported = try await service.importProfile(from: fileURL)
        XCTAssertEqual(imported, profile)
    }

    func testRuleProfileArchiveRejectsOversizedAndUnsupportedDocuments() async throws {
        let service = RuleProfileArchiveService(maximumArchiveByteCount: 128)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-rules-\(UUID().uuidString).proxylensrules")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try Data(repeating: 0x61, count: 129).write(to: fileURL)
        do {
            _ = try await service.importProfile(from: fileURL)
            XCTFail("Expected the oversized archive to be rejected")
        } catch let error as RuleProfileArchiveError {
            XCTAssertEqual(error, .archiveTooLarge(byteCount: 129, maximumByteCount: 128))
        }

        let unsupported = RuleProfile(
            schemaVersion: RuleProfile.currentSchemaVersion + 1,
            name: "Future rules",
            rules: RuleSet()
        )
        let roomyService = RuleProfileArchiveService()
        do {
            try await roomyService.export(unsupported, to: fileURL)
            XCTFail("Expected the unsupported schema to be rejected")
        } catch let error as RuleProfileArchiveError {
            XCTAssertEqual(
                error,
                .unsupportedSchema(RuleProfile.currentSchemaVersion + 1)
            )
        }

        let resource = MapLocalSpec(
            resourceID: "duplicate-resource",
            body: BodyReference(inline: Data("local".utf8))
        )
        let duplicated = RuleProfile(
            name: "Invalid resources",
            rules: RuleSet(rules: [
                Rule(
                    name: "Map local",
                    phase: .requestHeaders,
                    matcher: .any,
                    action: .mapLocal(resourceID: resource.resourceID)
                )
            ]),
            mappedLocals: [resource, resource]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(duplicated).write(to: fileURL)
        do {
            _ = try await roomyService.importProfile(from: fileURL)
            XCTFail("Expected duplicate embedded resources to be rejected")
        } catch let error as RuleEngineError {
            XCTAssertEqual(error, .duplicateMappedLocalResource(resource.resourceID))
        }
    }

    func testRuleEnginePublishesMapRemoteRules() async throws {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot)
        let destination = URL(string: "http://127.0.0.1:9000/mock/users")!

        let rule = try await engine.mapRemote(
            host: "api.example.com",
            path: "/users?unused=1",
            destination: destination
        )

        XCTAssertEqual(rule.name, "Map remote api.example.com/users")
        XCTAssertEqual(rule.priority, 15)
        XCTAssertEqual(rule.phase, .requestHeaders)
        guard case .mapRemote(let mappedURL) = rule.action else {
            return XCTFail("Expected a map remote action")
        }
        XCTAssertEqual(mappedURL, destination)

        let matching = snapshot.currentRules().matchingRules(
            for: RuleMatchContext(
                request: HTTPRequest(
                    method: .get,
                    url: URL(string: "https://api.example.com/users")!
                )
            ),
            phase: .requestHeaders
        )
        XCTAssertEqual(matching.map(\.id), [rule.id])

        do {
            _ = try await engine.mapRemote(
                host: "api.example.com",
                path: "/ftp",
                destination: URL(string: "ftp://files.example.com/users")!
            )
            XCTFail("Expected an unsupported Map Remote destination to be rejected")
        } catch let error as RuleEngineError {
            XCTAssertEqual(
                error,
                .mapRemoteInvalidDestination("ftp://files.example.com/users")
            )
        }
    }

    func testRuleEnginePublishesRedirectRules() async throws {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot)
        let destination = URL(string: "https://login.example.com/continue")!

        let rule = try await engine.redirect(
            host: "api.example.com",
            path: "/users?unused=1",
            destination: destination
        )

        XCTAssertEqual(rule.name, "Redirect api.example.com/users")
        XCTAssertEqual(rule.priority, 14)
        XCTAssertEqual(rule.phase, .requestHeaders)
        XCTAssertEqual(rule.action, .redirect(url: destination))
        XCTAssertEqual(snapshot.currentRules().rules.map(\.id), [rule.id])

        do {
            _ = try await engine.redirect(
                host: "api.example.com",
                path: "/users",
                destination: URL(string: "file:///tmp/redirect")!
            )
            XCTFail("Expected an unsupported Redirect destination to be rejected")
        } catch let error as RuleEngineError {
            XCTAssertEqual(
                error,
                .redirectInvalidDestination("file:///tmp/redirect")
            )
        }
    }

    func testRuleEnginePublishesHostThrottleRules() async throws {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot)

        let rule = try await engine.throttle(host: "api.example.com", latency: 0.5)

        XCTAssertEqual(rule.name, "Throttle api.example.com (500 ms latency)")
        XCTAssertEqual(rule.priority, 17)
        XCTAssertEqual(rule.phase, .requestHeaders)
        XCTAssertEqual(rule.matcher, .host(.exact("api.example.com")))
        XCTAssertEqual(rule.action, .throttle(ThrottleProfile(latency: 0.5)))
        XCTAssertEqual(snapshot.currentRules().rules.map(\.id), [rule.id])

        let replacementProfile = ThrottleProfile(
            latency: 0.4,
            downloadBytesPerSecond: 100_000,
            uploadBytesPerSecond: 50_000
        )
        let replacement = try await engine.throttle(
            host: "api.example.com",
            profile: replacementProfile,
            label: "Slow 3G"
        )
        XCTAssertEqual(replacement.name, "Throttle api.example.com (Slow 3G)")
        XCTAssertEqual(snapshot.currentRules().rules.map(\.id), [replacement.id])

        await engine.clearThrottle(forHost: "api.example.com")
        XCTAssertTrue(snapshot.currentRules().rules.isEmpty)
    }

    func testRuleEngineRejectsInvalidThrottleLatency() async throws {
        let engine = RuleEngine()

        for latency in [-0.1, .infinity, 60.1] {
            do {
                _ = try await engine.throttle(host: "api.example.com", latency: latency)
                XCTFail("Expected invalid latency \(latency) to be rejected")
            } catch let error as RuleEngineError {
                XCTAssertEqual(error, .invalidThrottleLatency(latency))
            }
        }
    }

    func testRuleEngineRejectsInvalidThrottleBandwidth() async throws {
        let engine = RuleEngine()

        for bandwidth in [0, 1_023, 1_000_000_001] as [Int64] {
            do {
                _ = try await engine.throttle(
                    host: "api.example.com",
                    profile: ThrottleProfile(downloadBytesPerSecond: bandwidth),
                    label: "Custom"
                )
                XCTFail("Expected invalid bandwidth \(bandwidth) to be rejected")
            } catch let error as RuleEngineError {
                XCTAssertEqual(error, .invalidThrottleBandwidth(bandwidth))
            }
        }
    }

    func testRuleEngineRejectsInvalidThrottlePacketLoss() async throws {
        let engine = RuleEngine()

        for percentage in [-0.1, 100.1, .infinity] {
            do {
                _ = try await engine.throttle(
                    host: "api.example.com",
                    profile: ThrottleProfile(packetLossPercentage: percentage),
                    label: "Lossy"
                )
                XCTFail("Expected invalid packet loss \(percentage) to be rejected")
            } catch let error as RuleEngineError {
                XCTAssertEqual(error, .invalidThrottlePacketLoss(percentage))
            }
        }
    }

    func testRuleEngineCanToggleAndRemoveRulesWithoutChangingStableIdentity() async {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot)
        let blocked = await engine.blockHost("api.example.com")
        let allowed = await engine.allowHost("assets.example.com")

        let disabled = await engine.setEnabled(false, for: blocked.id)
        let currentRuleIDs = await engine.currentRules().rules.map(\.id)
        let missing = await engine.setEnabled(true, for: RuleID())

        XCTAssertEqual(disabled?.id, blocked.id)
        XCTAssertEqual(disabled?.enabled, false)
        XCTAssertEqual(currentRuleIDs, [blocked.id, allowed.id])
        XCTAssertEqual(
            snapshot.currentRules().rules.first(where: { $0.id == blocked.id })?.enabled,
            false
        )
        XCTAssertNil(missing)

        await engine.remove(id: allowed.id)
        let remainingRuleIDs = await engine.currentRules().rules.map(\.id)
        XCTAssertEqual(remainingRuleIDs, [blocked.id])
        XCTAssertEqual(snapshot.currentRules().rules.map(\.id), [blocked.id])
    }

    func testRuleEnginePublishesBreakpointRules() async {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot)

        let requestRule = await engine.breakpoint(
            host: "api.example.com",
            path: "/users?unused=1",
            phase: .requestHeaders
        )
        let responseRule = await engine.breakpoint(
            host: "api.example.com",
            path: "/users",
            phase: .responseHeaders
        )

        XCTAssertEqual(requestRule.name, "Breakpoint request api.example.com/users")
        XCTAssertEqual(requestRule.priority, 18)
        XCTAssertEqual(requestRule.phase, .requestHeaders)
        XCTAssertEqual(requestRule.action, .breakpoint)
        XCTAssertEqual(responseRule.name, "Breakpoint response api.example.com/users")
        XCTAssertEqual(responseRule.phase, .responseHeaders)

        let matching = snapshot.currentRules().matchingRules(
            for: RuleMatchContext(
                request: HTTPRequest(
                    method: .get,
                    url: URL(string: "https://api.example.com/users")!
                )
            ),
            phase: .requestHeaders
        )
        XCTAssertEqual(matching.map(\.id), [requestRule.id])
    }

    func testRuleEnginePublishesGraphQLOperationBreakpointRule() async {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot)
        let operation = GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")

        let rule = await engine.breakpoint(graphqlOperation: operation)

        XCTAssertEqual(rule.name, "Breakpoint GraphQL mutation SaveProfile")
        XCTAssertEqual(rule.priority, 18)
        XCTAssertEqual(rule.phase, .requestBody)
        XCTAssertEqual(rule.action, .breakpoint)
        let matching = snapshot.currentRules().matchingRules(
            for: RuleMatchContext(
                request: HTTPRequest(
                    method: .post,
                    url: URL(string: "https://api.example.com/graphql")!,
                    graphqlOperation: operation
                )
            ),
            phase: .requestBody
        )
        XCTAssertEqual(matching.map(\.id), [rule.id])
    }

    func testRuleEnginePublishesGraphQLOperationBlockRule() async {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot)
        let operation = GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")

        let rule = await engine.block(graphqlOperation: operation)

        XCTAssertEqual(rule.name, "Block GraphQL mutation SaveProfile")
        XCTAssertEqual(rule.priority, 10)
        XCTAssertEqual(rule.phase, .requestBody)
        XCTAssertEqual(rule.action, .block(reason: "Blocked GraphQL operation"))
        let matching = snapshot.currentRules().matchingRules(
            for: RuleMatchContext(
                request: HTTPRequest(
                    method: .post,
                    url: URL(string: "https://api.example.com/graphql")!,
                    graphqlOperation: operation
                )
            ),
            phase: .requestBody
        )
        XCTAssertEqual(matching.map(\.id), [rule.id])
    }

    func testRuleEnginePublishesGraphQLOperationMapLocalRule() async throws {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot, maximumMapLocalBytes: 1_024)
        let operation = GraphQLOperationMetadata(kind: .query, name: "Catalog")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-graphql-map-local-\(UUID().uuidString).json")
        let body = Data(#"{"data":{"catalog":[]}}"#.utf8)
        try body.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let rule = try await engine.mapLocal(
            graphqlOperation: operation,
            fileURL: fileURL,
            statusCode: 201
        )

        XCTAssertEqual(rule.name, "Map local GraphQL query Catalog")
        XCTAssertEqual(rule.priority, 15)
        XCTAssertEqual(rule.phase, .requestBody)
        guard case .mapLocal(let resourceID) = rule.action else {
            return XCTFail("Expected a map local action")
        }
        let spec = try XCTUnwrap(snapshot.mappedLocal(for: resourceID))
        XCTAssertEqual(spec.statusCode, 201)
        XCTAssertEqual(spec.body.storage, .inline(body))
        let matching = snapshot.currentRules().matchingRules(
            for: RuleMatchContext(
                request: HTTPRequest(
                    method: .post,
                    url: URL(string: "https://api.example.com/graphql")!,
                    graphqlOperation: operation
                )
            ),
            phase: .requestBody
        )
        XCTAssertEqual(matching.map(\.id), [rule.id])
    }

    func testRuleEnginePublishesGraphQLOperationMapRemoteRule() async throws {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot)
        let operation = GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
        let destination = URL(string: "http://127.0.0.1:9000/graphql")!

        let rule = try await engine.mapRemote(
            graphqlOperation: operation,
            destination: destination
        )

        XCTAssertEqual(rule.name, "Map remote GraphQL mutation SaveProfile")
        XCTAssertEqual(rule.priority, 15)
        XCTAssertEqual(rule.phase, .requestBody)
        XCTAssertEqual(rule.action, .mapRemote(url: destination))
        let matching = snapshot.currentRules().matchingRules(
            for: RuleMatchContext(
                request: HTTPRequest(
                    method: .post,
                    url: URL(string: "https://api.example.com/graphql")!,
                    graphqlOperation: operation
                )
            ),
            phase: .requestBody
        )
        XCTAssertEqual(matching.map(\.id), [rule.id])
    }

    func testRuleEnginePublishesGraphQLOperationBodyReplacementRule() async throws {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot, maximumMapLocalBytes: 1_024)
        let operation = GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-graphql-replace-body-\(UUID().uuidString).json")
        let body = Data(#"{"name":"Ada"}"#.utf8)
        try body.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let rule = try await engine.replaceRequestBody(
            graphqlOperation: operation,
            fileURL: fileURL
        )

        XCTAssertEqual(rule.name, "Replace body GraphQL mutation SaveProfile")
        XCTAssertEqual(rule.priority, 16)
        XCTAssertEqual(rule.phase, .requestBody)
        guard case .replaceBody(let replacement) = rule.action else {
            return XCTFail("Expected a body replacement action")
        }
        XCTAssertEqual(replacement.inlineData, body)
        XCTAssertEqual(replacement.contentType, "application/json")
        let matching = snapshot.currentRules().matchingRules(
            for: RuleMatchContext(
                request: HTTPRequest(
                    method: .post,
                    url: URL(string: "https://api.example.com/graphql")!,
                    graphqlOperation: operation
                )
            ),
            phase: .requestBody
        )
        XCTAssertEqual(matching.map(\.id), [rule.id])

        let tooLarge = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "proxylens-graphql-replace-body-too-large-\(UUID().uuidString).bin")
        try Data(repeating: 0x61, count: 2_048).write(to: tooLarge)
        defer { try? FileManager.default.removeItem(at: tooLarge) }

        do {
            _ = try await engine.replaceRequestBody(
                graphqlOperation: operation,
                fileURL: tooLarge
            )
            XCTFail("Expected an oversized replacement body to be rejected")
        } catch let error as RuleEngineError {
            XCTAssertEqual(
                error,
                .replacementFileTooLarge(byteCount: 2_048, maximumByteCount: 1_024)
            )
        }
    }

    func testRuleEnginePublishesHostPathBodyReplacementRule() async throws {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot, maximumMapLocalBytes: 1_024)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-replace-body-\(UUID().uuidString).txt")
        let body = Data("replacement".utf8)
        try body.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let rule = try await engine.replaceRequestBody(
            host: "api.example.com",
            path: "/users?ignored=1",
            fileURL: fileURL
        )

        XCTAssertEqual(rule.name, "Replace body api.example.com/users")
        XCTAssertEqual(rule.priority, 16)
        XCTAssertEqual(rule.phase, .requestBody)
        guard case .replaceBody(let replacement) = rule.action else {
            return XCTFail("Expected a body replacement action")
        }
        XCTAssertEqual(replacement.inlineData, body)
        XCTAssertEqual(replacement.contentType, "text/plain; charset=utf-8")
        let matching = snapshot.currentRules().matchingRules(
            for: RuleMatchContext(
                request: HTTPRequest(
                    method: .post,
                    url: URL(string: "https://api.example.com/users")!
                )
            ),
            phase: .requestBody
        )
        XCTAssertEqual(matching.map(\.id), [rule.id])
    }

    func testRuleEnginePublishesResponseBodyReplacementRules() async throws {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot, maximumMapLocalBytes: 1_024)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-replace-response-body-\(UUID().uuidString).json")
        let body = Data(#"{"users":[]}"#.utf8)
        try body.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let generic = try await engine.replaceResponseBody(
            host: "api.example.com",
            path: "/users?ignored=1",
            fileURL: fileURL
        )
        let operation = GraphQLOperationMetadata(kind: .query, name: "Users")
        let graphql = try await engine.replaceResponseBody(
            graphqlOperation: operation,
            fileURL: fileURL
        )

        XCTAssertEqual(generic.name, "Replace response body api.example.com/users")
        XCTAssertEqual(generic.phase, .responseBody)
        XCTAssertEqual(graphql.name, "Replace response body GraphQL query Users")
        XCTAssertEqual(graphql.phase, .responseBody)
        for rule in [generic, graphql] {
            guard case .replaceBody(let replacement) = rule.action else {
                return XCTFail("Expected response body replacement actions")
            }
            XCTAssertEqual(replacement.inlineData, body)
            XCTAssertEqual(replacement.contentType, "application/json")
        }

        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://api.example.com/users")!,
            graphqlOperation: operation
        )
        let matching = snapshot.currentRules().matchingRules(
            for: RuleMatchContext(request: request, response: try HTTPResponse(statusCode: 200)),
            phase: .responseBody
        )
        XCTAssertEqual(Set(matching.map(\.id)), Set([generic.id, graphql.id]))
    }

    func testBreakpointCoordinatorWaitsUntilResumeOrAbort() async {
        let coordinator = BreakpointCoordinator()
        let request = HTTPRequest(method: .get, url: URL(string: "http://example.com/pause")!)
        let hit = BreakpointHit(flowID: FlowID(), phase: .request, request: request)

        let paused = Task {
            await coordinator.pause(hit)
        }
        while await coordinator.hit(for: hit.flowID) == nil {
            await Task.yield()
        }

        let pendingHit = await coordinator.hit(for: hit.flowID)
        XCTAssertEqual(pendingHit?.flowID, hit.flowID)
        await coordinator.resume(flowID: hit.flowID, decision: .continue(hit))
        let continued = await paused.value
        XCTAssertEqual(continued, .continue(hit))

        let aborting = Task {
            await coordinator.pause(hit)
        }
        while await coordinator.hit(for: hit.flowID) == nil {
            await Task.yield()
        }
        await coordinator.abortAll()
        let aborted = await aborting.value
        XCTAssertEqual(aborted, .abort)
    }

    func testExportServiceWritesCURLForPOSTJSONThroughTheBodyStore() async throws {
        let body = Data(#"{"name":"ada"}"#.utf8)
        let flow = try Self.exportFlow(
            method: .post,
            url: "https://api.example.com/users?x=1",
            requestHeaders: [
                ("Host", "api.example.com"),
                ("Content-Type", "application/json"),
                ("Content-Length", "14"),
                ("Connection", "close"),
                ("Cookie", "session=abc")
            ],
            requestBody: body,
            statusCode: 201,
            reasonPhrase: "Created",
            responseHeaders: [
                ("Content-Type", "application/json"),
                ("Set-Cookie", "session=abc; Path=/")
            ],
            responseBody: Data(#"{"ok":true}"#.utf8)
        )
        let store = RecordingBodyStore()
        let exporter = ExportService(bodyStore: store)

        let command = try await exporter.curl(for: flow)

        XCTAssertTrue(command.contains("curl 'https://api.example.com/users?x=1'"))
        XCTAssertTrue(command.contains("-X 'POST'"))
        XCTAssertTrue(command.contains("-H 'Content-Type: application/json'"))
        XCTAssertTrue(command.contains("-H 'Cookie: session=abc'"))
        XCTAssertTrue(command.contains("--data-binary '{\"name\":\"ada\"}'"))
        XCTAssertFalse(command.contains("Content-Length"))
        XCTAssertFalse(command.contains("Connection"))
        let readIDs = await store.readIDs()
        XCTAssertEqual(readIDs, [flow.request.body?.id].compactMap { $0 })
    }

    func testExportServiceWritesVersionedWebSocketFramesWithPortablePayloadEncodings()
        async throws
    {
        let flowID = FlowID(
            rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let textFrame = CapturedWebSocketFrame(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            flowID: flowID,
            sequenceNumber: 1,
            direction: .clientToServer,
            opcode: .text,
            isFinal: true,
            wasMasked: true,
            payload: BodyReference(
                inline: Data(#"{"action":"subscribe"}"#.utf8),
                metadata: BodyMetadata(contentType: "text/plain; charset=utf-8")
            ),
            receivedAt: Date(timeIntervalSince1970: 1_786_800_000.125)
        )
        let binaryPayload = Data([0x00, 0x7F, 0xFF])
        let binaryFrame = CapturedWebSocketFrame(
            id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            flowID: flowID,
            sequenceNumber: 2,
            direction: .serverToClient,
            opcode: .binary,
            isFinal: false,
            reservedBits: [.rsv1],
            payload: BodyReference(
                inline: binaryPayload,
                metadata: BodyMetadata(
                    contentType: "application/octet-stream",
                    isTruncated: true
                )
            ),
            receivedAt: Date(timeIntervalSince1970: 1_786_800_001.5)
        )
        let exporter = ExportService(bodyStore: RecordingBodyStore())
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "proxylens-websocket-export-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: destination) }

        try await exporter.writeWebSocketFrames(
            [binaryFrame, textFrame],
            for: flowID,
            exportedAt: Date(timeIntervalSince1970: 1_786_800_010),
            to: destination
        )

        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: destination))
                as? [String: Any]
        )
        XCTAssertEqual(document["format"] as? String, "proxylens-websocket-frames")
        XCTAssertEqual(document["version"] as? Int, 1)
        XCTAssertEqual(document["flowID"] as? String, flowID.description)
        let frames = try XCTUnwrap(document["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.compactMap { $0["sequenceNumber"] as? Int }, [1, 2])
        XCTAssertEqual(frames[0]["direction"] as? String, "sent")
        XCTAssertEqual(frames[0]["opcode"] as? String, "text")
        XCTAssertEqual(frames[0]["payloadEncoding"] as? String, "utf8")
        XCTAssertEqual(frames[0]["payload"] as? String, #"{"action":"subscribe"}"#)
        XCTAssertEqual(frames[1]["direction"] as? String, "received")
        XCTAssertEqual(frames[1]["opcode"] as? String, "binary")
        XCTAssertEqual(frames[1]["payloadEncoding"] as? String, "base64")
        XCTAssertEqual(frames[1]["payload"] as? String, binaryPayload.base64EncodedString())
        XCTAssertEqual(frames[1]["isTruncated"] as? Bool, true)
        XCTAssertEqual(frames[1]["reservedBits"] as? [String], ["RSV1"])
    }

    func testExportServiceEscapesBinaryCURLBodiesAndOmitsGETMethod() async throws {
        let binary = Data([0x00, 0x01, 0xFF])
        var post = try Self.exportFlow(
            method: .post,
            url: "https://api.example.com/upload",
            requestHeaders: [("Content-Type", "application/octet-stream")],
            requestBody: binary,
            statusCode: 200,
            responseBody: Data()
        )
        post.replaceRequest(
            post.request.replacingBody(
                BodyReference(
                    inline: binary,
                    metadata: BodyMetadata(
                        contentType: "application/octet-stream",
                        isTruncated: true
                    )
                )
            )
        )
        let get = try Self.exportFlow(
            method: .get,
            url: "https://api.example.com/health",
            statusCode: 200
        )
        let exporter = ExportService(bodyStore: RecordingBodyStore())

        let binaryCommand = try await exporter.curl(for: post)
        let getCommand = try await exporter.curl(for: get)

        XCTAssertTrue(binaryCommand.contains("--data-binary $'\\x00\\x01\\xff'"))
        XCTAssertTrue(binaryCommand.contains("# Captured request body was truncated"))
        XCTAssertTrue(getCommand.contains("curl 'https://api.example.com/health'"))
        XCTAssertFalse(getCommand.contains("-X"))
        XCTAssertFalse(getCommand.contains("--data-binary"))
    }

    func testExportServiceGeneratesCopyReadyRequestCodeForCommonClients() async throws {
        let body = Data(#"{"name":"ProxyLens","enabled":true}"#.utf8)
        let flow = try Self.exportFlow(
            method: .post,
            url: "https://api.example.com/events?source=desktop",
            requestHeaders: [
                ("Content-Type", "application/json"),
                ("Authorization", "Bearer test-token"),
                ("Content-Length", "35"),
                ("Connection", "keep-alive")
            ],
            requestBody: body,
            statusCode: 201
        )
        let store = RecordingBodyStore()
        let exporter = ExportService(bodyStore: store)

        let generated = try await exporter.requestCodeSnippets(for: flow)
        let snippets = Dictionary(
            uniqueKeysWithValues: generated.map { ($0.language, $0.source) }
        )

        XCTAssertTrue(
            snippets[.curl]?.contains("curl 'https://api.example.com/events?source=desktop'")
                == true)
        XCTAssertTrue(
            snippets[.httpie]?.contains(
                "http 'POST' 'https://api.example.com/events?source=desktop'") == true)
        XCTAssertTrue(
            snippets[.javascriptFetch]?.contains(
                "await fetch(\"https://api.example.com/events?source=desktop\"") == true)
        XCTAssertTrue(snippets[.javascriptAxios]?.contains("await axios.request({") == true)
        XCTAssertTrue(snippets[.pythonRequests]?.contains("requests.request(") == true)
        XCTAssertTrue(
            snippets[.swiftURLSession]?.contains("URLSession.shared.data(for: request)") == true)
        XCTAssertTrue(snippets[.goNetHTTP]?.contains("http.NewRequest(") == true)
        XCTAssertTrue(snippets[.javaHttpClient]?.contains("HttpRequest.newBuilder()") == true)
        for source in snippets.values {
            XCTAssertTrue(source.contains("Authorization"))
            XCTAssertTrue(source.contains("Bearer test-token"))
            XCTAssertFalse(source.contains("Content-Length"))
            XCTAssertFalse(source.contains("Connection"))
        }
        let readIDs = await store.readIDs()
        XCTAssertEqual(readIDs, [flow.request.body?.id].compactMap { $0 })
    }

    func testRequestCodeGenerationPreservesBinaryBodiesWithBase64() async throws {
        let body = Data([0x00, 0x01, 0xFE, 0xFF])
        let flow = try Self.exportFlow(
            method: .put,
            url: "https://api.example.com/binary",
            requestHeaders: [("Content-Type", "application/octet-stream")],
            requestBody: body,
            statusCode: 204
        )
        let exporter = ExportService(bodyStore: RecordingBodyStore())
        let encoded = body.base64EncodedString()

        let javascript = try await exporter.requestCode(for: flow, language: .javascriptFetch)
        let axios = try await exporter.requestCode(for: flow, language: .javascriptAxios)
        let python = try await exporter.requestCode(for: flow, language: .pythonRequests)
        let swift = try await exporter.requestCode(for: flow, language: .swiftURLSession)
        let go = try await exporter.requestCode(for: flow, language: .goNetHTTP)
        let java = try await exporter.requestCode(for: flow, language: .javaHttpClient)

        XCTAssertTrue(javascript.contains("atob(\"\(encoded)\")"))
        XCTAssertTrue(axios.contains("Buffer.from(\"\(encoded)\", \"base64\")"))
        XCTAssertTrue(python.contains("base64.b64decode(\"\(encoded)\")"))
        XCTAssertTrue(swift.contains("Data(base64Encoded: \"\(encoded)\")!"))
        XCTAssertTrue(go.contains("base64.StdEncoding.DecodeString(\"\(encoded)\")"))
        XCTAssertTrue(java.contains("Base64.getDecoder().decode(\"\(encoded)\")"))
    }

    func testExportServiceWritesHARForCompletedAndIncompleteFlows() async throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var completed = try Self.exportFlow(
            method: .post,
            url: "https://api.example.com/users?x=1",
            requestHeaders: [
                ("Content-Type", "application/json"),
                ("Cookie", "a=1; b=2")
            ],
            requestBody: Data(#"{"name":"ada"}"#.utf8),
            statusCode: 201,
            reasonPhrase: "Created",
            responseHeaders: [("Content-Type", "text/plain")],
            responseBody: Data("ok".utf8),
            startedAt: startedAt
        )
        completed.markRequestBodyCompleted(at: Date(timeIntervalSince1970: 1_000.05))
        completed.markUpstreamConnected(at: Date(timeIntervalSince1970: 1_000.06))
        completed.markTLSHandshakeCompleted(at: Date(timeIntervalSince1970: 1_000.08))
        completed.markResponseHeadersReceived(at: Date(timeIntervalSince1970: 1_000.2))
        completed.markResponseBodyCompleted(at: Date(timeIntervalSince1970: 1_000.25))
        completed.markCompleted(at: Date(timeIntervalSince1970: 1_000.3))

        let binary = Data([0x00, 0xFF])
        let binaryFlow = try Self.exportFlow(
            method: .put,
            url: "https://api.example.com/blob",
            requestHeaders: [("Content-Type", "application/octet-stream")],
            requestBody: binary,
            statusCode: 200,
            responseBody: binary
        )

        var failed = Flow(
            sessionID: SessionID(),
            request: HTTPRequest(
                method: .get,
                url: URL(string: "https://api.example.com/drop")!
            ),
            startedAt: startedAt
        )
        try failed.transition(to: .receivingRequest)
        try failed.transition(to: .failed(.upstreamUnavailable))

        let exporter = ExportService(bodyStore: RecordingBodyStore())
        let completedJSON = try Self.harObject(try await exporter.har(for: completed))
        let binaryJSON = try Self.harObject(try await exporter.har(for: binaryFlow))
        let failedJSON = try Self.harObject(try await exporter.har(for: failed))

        let completedLog = try XCTUnwrap(completedJSON["log"] as? [String: Any])
        XCTAssertEqual(completedLog["version"] as? String, "1.2")
        let creator = try XCTUnwrap(completedLog["creator"] as? [String: Any])
        XCTAssertEqual(creator["name"] as? String, "ProxyLens")
        let completedEntry = try XCTUnwrap((completedLog["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(completedEntry["startedDateTime"] as? String, "1970-01-01T00:16:40.000Z")
        XCTAssertEqual(
            try XCTUnwrap(completedEntry["time"] as? NSNumber).doubleValue,
            300,
            accuracy: 0.001
        )
        let request = try XCTUnwrap(completedEntry["request"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "POST")
        XCTAssertEqual(request["url"] as? String, "https://api.example.com/users?x=1")
        XCTAssertEqual(request["httpVersion"] as? String, "HTTP/1.1")
        let query = try XCTUnwrap(request["queryString"] as? [[String: Any]])
        XCTAssertEqual(query.first?["name"] as? String, "x")
        XCTAssertEqual(query.first?["value"] as? String, "1")
        let cookies = try XCTUnwrap(request["cookies"] as? [[String: Any]])
        XCTAssertEqual(cookies.map { $0["name"] as? String }, ["a", "b"])
        let postData = try XCTUnwrap(request["postData"] as? [String: Any])
        XCTAssertEqual(postData["mimeType"] as? String, "application/json")
        XCTAssertEqual(postData["text"] as? String, #"{"name":"ada"}"#)
        XCTAssertNil(postData["encoding"])
        let response = try XCTUnwrap(completedEntry["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? Int, 201)
        XCTAssertEqual(response["statusText"] as? String, "Created")
        let content = try XCTUnwrap(response["content"] as? [String: Any])
        XCTAssertEqual(content["text"] as? String, "ok")
        let timings = try XCTUnwrap(completedEntry["timings"] as? [String: Any])
        let send = try XCTUnwrap(timings["send"] as? NSNumber).doubleValue
        let connect = try XCTUnwrap(timings["connect"] as? NSNumber).doubleValue
        let wait = try XCTUnwrap(timings["wait"] as? NSNumber).doubleValue
        let receive = try XCTUnwrap(timings["receive"] as? NSNumber).doubleValue
        let ssl = try XCTUnwrap(timings["ssl"] as? NSNumber).doubleValue
        let time = try XCTUnwrap(completedEntry["time"] as? NSNumber).doubleValue
        XCTAssertEqual(send, 50, accuracy: 0.001)
        XCTAssertEqual(connect, 30, accuracy: 0.001)
        XCTAssertEqual(wait, 120, accuracy: 0.001)
        XCTAssertEqual(receive, 100, accuracy: 0.001)
        XCTAssertEqual(ssl, 20, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(connect, ssl)
        XCTAssertEqual(try XCTUnwrap(timings["blocked"] as? NSNumber).doubleValue, -1)
        XCTAssertEqual(try XCTUnwrap(timings["dns"] as? NSNumber).doubleValue, -1)
        XCTAssertEqual(time, send + connect + wait + receive, accuracy: 0.001)

        let binaryRequest = try XCTUnwrap(
            ((binaryJSON["log"] as? [String: Any])?["entries"] as? [[String: Any]])?.first?[
                "request"
            ] as? [String: Any]
        )
        let binaryPost = try XCTUnwrap(binaryRequest["postData"] as? [String: Any])
        XCTAssertEqual(binaryPost["encoding"] as? String, "base64")
        XCTAssertEqual(binaryPost["text"] as? String, binary.base64EncodedString())

        let failedEntry = try XCTUnwrap(
            ((failedJSON["log"] as? [String: Any])?["entries"] as? [[String: Any]])?.first
        )
        XCTAssertEqual((failedEntry["time"] as? NSNumber)?.doubleValue, 0)
        let failedResponse = try XCTUnwrap(failedEntry["response"] as? [String: Any])
        XCTAssertEqual(failedResponse["status"] as? Int, 0)
        XCTAssertEqual(
            failedEntry["comment"] as? String,
            "Response was not captured. Flow failed: The upstream was unavailable"
        )
        let failedTimings = try XCTUnwrap(failedEntry["timings"] as? [String: Any])
        XCTAssertEqual((failedTimings["send"] as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((failedTimings["wait"] as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((failedTimings["receive"] as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((failedTimings["connect"] as? NSNumber)?.doubleValue, -1)
        XCTAssertEqual((failedTimings["ssl"] as? NSNumber)?.doubleValue, -1)
    }

    func testExportServiceWritesSessionHARInSuppliedCaptureOrder() async throws {
        let first = try Self.exportFlow(
            method: .post,
            url: "https://api.example.com/first",
            requestHeaders: [("Content-Type", "application/json")],
            requestBody: Data(#"{"step":1}"#.utf8),
            statusCode: 201,
            responseHeaders: [("Content-Type", "application/json")],
            responseBody: Data(#"{"created":true}"#.utf8),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = try Self.exportFlow(
            method: .get,
            url: "https://api.example.com/second",
            statusCode: 204,
            startedAt: Date(timeIntervalSince1970: 1_001)
        )
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-har-export-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("Checkout.har")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try Data("stale".utf8).write(to: fileURL)

        let exporter = ExportService(bodyStore: RecordingBodyStore())
        try await exporter.writeHAR(for: [first, second], to: fileURL)

        let json = try Self.harObject(Data(contentsOf: fileURL))
        let log = try XCTUnwrap(json["log"] as? [String: Any])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(
            entries.compactMap { ($0["request"] as? [String: Any])?["url"] as? String },
            [
                "https://api.example.com/first",
                "https://api.example.com/second"
            ]
        )
        let firstRequest = try XCTUnwrap(entries.first?["request"] as? [String: Any])
        let firstPostData = try XCTUnwrap(firstRequest["postData"] as? [String: Any])
        XCTAssertEqual(firstPostData["text"] as? String, #"{"step":1}"#)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directoryURL.path),
            ["Checkout.har"]
        )
    }

    func testExportServiceKeepsExistingHARWhenSessionExportFails() async throws {
        var flow = try Self.exportFlow(
            method: .post,
            url: "https://api.example.com/missing-body",
            statusCode: 200
        )
        flow.attachRequestBody(
            try BodyReference(
                externalID: BodyID(),
                byteCount: 10,
                metadata: BodyMetadata(contentType: "application/octet-stream")
            )
        )
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-har-failure-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("Existing.har")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let original = Data("existing HAR".utf8)
        try original.write(to: fileURL)

        let exporter = ExportService(bodyStore: RecordingBodyStore())
        do {
            try await exporter.writeHAR(for: [flow], to: fileURL)
            XCTFail("Expected the missing body to fail session export")
        } catch {
            XCTAssertEqual(
                error.localizedDescription, "Unsupported operation: Missing exported body")
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directoryURL.path),
            ["Existing.har"]
        )
    }

    func testHARImportCreatesInspectableStoppedSessionFromTextAndBase64Bodies() async throws {
        let recorder = CallRecorder()
        let sessionStore = RecordingSessionStore(sessionID: SessionID(), recorder: recorder)
        let bodyStore = RecordingBodyStore()
        let importer = HARImportService(sessionStore: sessionStore, bodyStore: bodyStore)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Checkout debugging.har")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data(
            """
            {
              "log": {
                "version": "1.2",
                "creator": { "name": "Browser", "version": "1" },
                "entries": [
                  {
                    "startedDateTime": "2026-08-16T15:00:00.000Z",
                    "time": 42,
                    "request": {
                      "method": "POST",
                      "url": "https://api.example.test/checkout?currency=USD",
                      "httpVersion": "HTTP/2",
                      "headers": [
                        { "name": "Content-Type", "value": "application/json" },
                        { "name": "X-Trace", "value": "first" },
                        { "name": "X-Trace", "value": "second" }
                      ],
                      "postData": {
                        "mimeType": "application/json",
                        "text": "{\\"operationName\\":\\"Checkout\\",\\"query\\":\\"mutation Checkout { checkout { id } }\\"}"
                      }
                    },
                    "response": {
                      "status": 201,
                      "statusText": "Created",
                      "httpVersion": "HTTP/2",
                      "headers": [
                        { "name": "Content-Type", "value": "application/octet-stream" }
                      ],
                      "content": {
                        "size": 3,
                        "mimeType": "application/octet-stream",
                        "text": "AAH/",
                        "encoding": "base64"
                      }
                    },
                    "timings": { "send": 2, "wait": 30, "receive": 10 }
                  },
                  {
                    "startedDateTime": "2026-08-16T15:00:01.000Z",
                    "time": 0,
                    "request": {
                      "method": "GET",
                      "url": "http://api.example.test/incomplete",
                      "httpVersion": "HTTP/1.1",
                      "headers": []
                    },
                    "response": {
                      "status": 0,
                      "statusText": "",
                      "httpVersion": "HTTP/1.1",
                      "headers": [],
                      "content": { "size": 0, "mimeType": "" }
                    },
                    "timings": { "send": 0, "wait": 0, "receive": 0 },
                    "comment": "Connection closed before a response"
                  }
                ]
              }
            }
            """.utf8
        ).write(to: fileURL)

        let imported = try await importer.importHAR(from: fileURL)

        XCTAssertEqual(imported.session.name, "Checkout debugging")
        XCTAssertEqual(imported.session.state, .stopped)
        XCTAssertEqual(imported.session.flowCount, 2)
        XCTAssertEqual(imported.flows.count, 2)
        let completed = imported.flows[0]
        XCTAssertEqual(completed.source.kind, .importedSession)
        XCTAssertEqual(completed.request.method, .post)
        XCTAssertEqual(completed.request.version, .http2)
        XCTAssertEqual(completed.request.headers.values(for: "X-Trace"), ["first", "second"])
        XCTAssertEqual(completed.response?.statusCode, 201)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(try XCTUnwrap(completed.timing.totalDuration), 0.042, accuracy: 0.0001)
        let requestBody = try await bodyStore.read(try XCTUnwrap(completed.request.body))
        let responseBody = try await bodyStore.read(try XCTUnwrap(completed.response?.body))
        XCTAssertEqual(
            requestBody,
            Data(
                #"{"operationName":"Checkout","query":"mutation Checkout { checkout { id } }"}"#
                    .utf8
            )
        )
        XCTAssertEqual(
            completed.request.graphqlOperation,
            GraphQLOperationMetadata(kind: .mutation, name: "Checkout")
        )
        XCTAssertEqual(responseBody, Data([0x00, 0x01, 0xFF]))
        XCTAssertEqual(completed.response?.body?.contentType, "application/octet-stream")

        let incomplete = imported.flows[1]
        XCTAssertNil(incomplete.response)
        XCTAssertEqual(
            incomplete.state,
            .failed(.unknown("Connection closed before a response"))
        )
        let persistedSession = await sessionStore.loadSession(sessionID: imported.session.id)
        let persistedFlows = await sessionStore.listFlows(in: imported.session.id)
        XCTAssertEqual(persistedSession, imported.session)
        XCTAssertEqual(persistedFlows.count, 2)
    }

    func testHARImportRejectsOversizedFilesBeforeCreatingASession() async throws {
        let sessionStore = RecordingSessionStore(sessionID: SessionID(), recorder: CallRecorder())
        let importer = HARImportService(
            sessionStore: sessionStore,
            bodyStore: RecordingBodyStore(),
            maximumFileByteCount: 8
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized.har")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data(#"{"log":{"version":"1.2","entries":[]}}"#.utf8).write(to: fileURL)

        do {
            _ = try await importer.importHAR(from: fileURL)
            XCTFail("Expected the bounded reader to reject the HAR file")
        } catch {
            XCTAssertEqual(error as? HARImportError, .fileTooLarge(maximumByteCount: 8))
        }
        let sessions = await sessionStore.listSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testPortableSessionRoundTripsMetadataAnnotationsAndAuthoritativeBodies() async throws {
        let sourceSessionID = SessionID()
        var sourceSession = Session(
            id: sourceSessionID,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        try sourceSession.rename(to: "Checkout investigation")
        sourceSession.stop(at: Date(timeIntervalSince1970: 1_010))

        let requestBytes = Data(#"{"cart":["coffee"]}"#.utf8)
        let responseBytes = Data(#"{"accepted":true}"#.utf8)
        let requestMetadata = BodyMetadata(
            digest: BodyDigest(
                algorithm: .sha256,
                value: "f986d5ef2bbadb3ff0fb8b5773a7a548011f6d41f157573b31f978a82e1ade5a"
            )
        )
        let responseMetadata = BodyMetadata(
            digest: BodyDigest(
                algorithm: .sha256,
                value: "11a49f853eb8befe94fef278d487125cd20930b9e41c4c0934394443e7f00878"
            )
        )
        var requestHeaders = HTTPHeaders()
        try requestHeaders.append(name: "Content-Type", value: "application/json")
        var responseHeaders = HTTPHeaders()
        try responseHeaders.append(name: "Content-Type", value: "application/json")
        var sourceFlow = Flow(
            sessionID: sourceSessionID,
            source: FlowSource(
                kind: .desktopProxy,
                label: "Desktop proxy",
                clientAddress: "127.0.0.1:51234"
            ),
            request: HTTPRequest(
                method: .post,
                url: URL(string: "https://shop.example.com/checkout")!,
                headers: requestHeaders,
                body: BodyReference(inline: requestBytes, metadata: requestMetadata)
            ),
            connection: ConnectionInfo(
                protocolKind: .https,
                upstreamHost: "shop.example.com",
                upstreamPort: 443,
                tlsIntercepted: true
            ),
            startedAt: Date(timeIntervalSince1970: 1_001)
        )
        try sourceFlow.transition(to: .receivingRequest)
        sourceFlow.markRequestHeadersReceived(at: Date(timeIntervalSince1970: 1_001.1))
        sourceFlow.markRequestBodyCompleted(at: Date(timeIntervalSince1970: 1_001.2))
        try sourceFlow.transition(to: .receivingResponse)
        sourceFlow.attachResponse(
            try HTTPResponse(
                statusCode: 201,
                reasonPhrase: "Created",
                headers: responseHeaders,
                body: BodyReference(inline: responseBytes, metadata: responseMetadata)
            )
        )
        sourceFlow.markResponseHeadersReceived(at: Date(timeIntervalSince1970: 1_001.3))
        sourceFlow.markResponseBodyCompleted(at: Date(timeIntervalSince1970: 1_001.4))
        sourceFlow.setAnnotation(
            try FlowAnnotation(
                comment: "Keep this response",
                highlight: .green,
                isStruckThrough: false
            )
        )
        try sourceFlow.transition(to: .completed)
        sourceFlow.markCompleted(at: Date(timeIntervalSince1970: 1_001.5))

        let sourceStore = RecordingSessionStore(
            sessionID: sourceSessionID,
            recorder: CallRecorder()
        )
        await sourceStore.seed(session: sourceSession, flows: [sourceFlow])
        let sourceBodies = RecordingBodyStore()
        let exporter = PortableSessionService(
            sessionStore: sourceStore,
            bodyStore: sourceBodies
        )
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("round-trip-\(UUID().uuidString).proxylens", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        try await exporter.exportSession(sessionID: sourceSessionID, to: packageURL)

        let importedSessionID = SessionID()
        let importedStore = RecordingSessionStore(
            sessionID: importedSessionID,
            recorder: CallRecorder()
        )
        let importedBodies = RecordingBodyStore()
        let importer = PortableSessionService(
            sessionStore: importedStore,
            bodyStore: importedBodies
        )
        let result = try await importer.importSession(from: packageURL)

        XCTAssertEqual(result.session.id, importedSessionID)
        XCTAssertEqual(result.session.name, sourceSession.name)
        XCTAssertEqual(result.session.startedAt, sourceSession.startedAt)
        XCTAssertEqual(result.session.endedAt, sourceSession.endedAt)
        XCTAssertEqual(result.session.state, .stopped)
        XCTAssertEqual(result.session.flowCount, 1)
        let importedFlow = try XCTUnwrap(result.flows.first)
        XCTAssertNotEqual(importedFlow.id, sourceFlow.id)
        XCTAssertEqual(importedFlow.sessionID, importedSessionID)
        XCTAssertEqual(importedFlow.source, sourceFlow.source)
        XCTAssertEqual(importedFlow.request.method, sourceFlow.request.method)
        XCTAssertEqual(importedFlow.request.url, sourceFlow.request.url)
        XCTAssertEqual(importedFlow.request.headers, sourceFlow.request.headers)
        XCTAssertEqual(importedFlow.response?.statusCode, sourceFlow.response?.statusCode)
        XCTAssertEqual(importedFlow.response?.headers, sourceFlow.response?.headers)
        XCTAssertEqual(importedFlow.connection, sourceFlow.connection)
        XCTAssertEqual(importedFlow.timing, sourceFlow.timing)
        XCTAssertEqual(importedFlow.state, sourceFlow.state)
        XCTAssertEqual(importedFlow.annotation, sourceFlow.annotation)
        let importedRequestBytes = try await importedBodies.read(
            try XCTUnwrap(importedFlow.request.body)
        )
        let importedResponseBytes = try await importedBodies.read(
            try XCTUnwrap(importedFlow.response?.body)
        )
        XCTAssertEqual(importedRequestBytes, requestBytes)
        XCTAssertEqual(importedResponseBytes, responseBytes)
    }

    func testPortableSessionExportPreservesExistingPackageWhenBodyLoadingFails() async throws {
        let sessionID = SessionID()
        var session = Session(id: sessionID, startedAt: Date(timeIntervalSince1970: 2_000))
        session.stop(at: Date(timeIntervalSince1970: 2_001))
        let missingBody = try BodyReference(
            externalID: BodyID(),
            byteCount: 4,
            metadata: BodyMetadata(
                contentType: "application/octet-stream",
                digest: BodyDigest(
                    algorithm: .sha256,
                    value: "03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4"
                )
            )
        )
        let flow = Flow(
            sessionID: sessionID,
            request: HTTPRequest(
                method: .post,
                url: URL(string: "https://example.com/upload")!,
                body: missingBody
            )
        )
        let store = RecordingSessionStore(sessionID: sessionID, recorder: CallRecorder())
        await store.seed(session: session, flows: [flow])
        let service = PortableSessionService(
            sessionStore: store,
            bodyStore: RecordingBodyStore()
        )
        let parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-atomic-\(UUID().uuidString)", isDirectory: true)
        let packageURL = parentURL.appendingPathComponent("existing.proxylens", isDirectory: true)
        let markerURL = packageURL.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: markerURL)
        defer { try? FileManager.default.removeItem(at: parentURL) }

        await assertThrowsErrorAsync(
            try await service.exportSession(sessionID: sessionID, to: packageURL)
        )

        XCTAssertEqual(try Data(contentsOf: markerURL), Data("keep".utf8))
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
        XCTAssertEqual(siblingNames, ["existing.proxylens"])
    }

    func testPortableSessionExportReplacesAnExistingPackageAfterACompleteWrite() async throws {
        let sessionID = SessionID()
        var session = Session(id: sessionID, startedAt: Date(timeIntervalSince1970: 2_500))
        try session.rename(to: "Replacement")
        session.stop(at: Date(timeIntervalSince1970: 2_501))
        let store = RecordingSessionStore(sessionID: sessionID, recorder: CallRecorder())
        await store.seed(session: session)
        let service = PortableSessionService(
            sessionStore: store,
            bodyStore: RecordingBodyStore()
        )
        let parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-replace-\(UUID().uuidString)", isDirectory: true)
        let packageURL = parentURL.appendingPathComponent("existing.proxylens", isDirectory: true)
        let markerURL = packageURL.appendingPathComponent("old.txt")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: markerURL)
        defer { try? FileManager.default.removeItem(at: parentURL) }

        try await service.exportSession(sessionID: sessionID, to: packageURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: packageURL.appendingPathComponent("manifest.json").path
            )
        )
    }

    func testPortableSessionExportEnforcesTheCumulativeBodyLimit() async throws {
        let sessionID = SessionID()
        var session = Session(id: sessionID, startedAt: Date(timeIntervalSince1970: 3_000))
        session.stop(at: Date(timeIntervalSince1970: 3_001))
        var flow = Flow(
            sessionID: sessionID,
            request: HTTPRequest(
                method: .post,
                url: URL(string: "https://example.com/limited")!,
                body: BodyReference(
                    inline: Data("1234".utf8),
                    metadata: BodyMetadata(
                        digest: BodyDigest(
                            algorithm: .sha256,
                            value:
                                "03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4"
                        )
                    )
                )
            )
        )
        flow.attachResponse(
            try HTTPResponse(
                statusCode: 200,
                body: BodyReference(
                    inline: Data("5678".utf8),
                    metadata: BodyMetadata(
                        digest: BodyDigest(
                            algorithm: .sha256,
                            value:
                                "f8638b979b2f4f793ddb6dbd197e0ee25a7a6ea32b0ae22f5e3c5d119d839e75"
                        )
                    )
                )
            )
        )
        let store = RecordingSessionStore(sessionID: sessionID, recorder: CallRecorder())
        await store.seed(session: session, flows: [flow])
        let service = PortableSessionService(
            sessionStore: store,
            bodyStore: RecordingBodyStore(),
            maximumPackageBodyByteCount: 7
        )
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("too-large-\(UUID().uuidString).proxylens", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        await assertThrowsErrorAsync(
            try await service.exportSession(sessionID: sessionID, to: packageURL)
        ) { error in
            XCTAssertEqual(error as? PortableSessionError, .packageTooLarge(maximumByteCount: 7))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
    }

    func testPortableSessionImportRejectsSymlinkedBodiesAndRollsBack() async throws {
        let sourceSessionID = SessionID()
        var sourceSession = Session(
            id: sourceSessionID,
            startedAt: Date(timeIntervalSince1970: 4_000)
        )
        sourceSession.stop(at: Date(timeIntervalSince1970: 4_001))
        let sourceFlow = Flow(
            sessionID: sourceSessionID,
            request: HTTPRequest(
                method: .post,
                url: URL(string: "https://example.com/unsafe")!,
                body: BodyReference(
                    inline: Data("safe".utf8),
                    metadata: BodyMetadata(
                        digest: BodyDigest(
                            algorithm: .sha256,
                            value:
                                "8b3369944dd2a3fab39e32d1aeb1f763946a458ae3e6368a46432adc8f3a0860"
                        )
                    )
                )
            )
        )
        let sourceStore = RecordingSessionStore(
            sessionID: sourceSessionID,
            recorder: CallRecorder()
        )
        await sourceStore.seed(session: sourceSession, flows: [sourceFlow])
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsafe-\(UUID().uuidString).proxylens", isDirectory: true)
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).body")
        defer {
            try? FileManager.default.removeItem(at: packageURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        try await PortableSessionService(
            sessionStore: sourceStore,
            bodyStore: RecordingBodyStore()
        ).exportSession(sessionID: sourceSessionID, to: packageURL)
        try Data("unsafe".utf8).write(to: outsideURL)
        let bodyURL =
            packageURL
            .appendingPathComponent("bodies", isDirectory: true)
            .appendingPathComponent("00000000-request.body")
        try FileManager.default.removeItem(at: bodyURL)
        try FileManager.default.createSymbolicLink(at: bodyURL, withDestinationURL: outsideURL)

        let importedStore = RecordingSessionStore(
            sessionID: SessionID(),
            recorder: CallRecorder()
        )
        let importer = PortableSessionService(
            sessionStore: importedStore,
            bodyStore: RecordingBodyStore()
        )

        await assertThrowsErrorAsync(try await importer.importSession(from: packageURL)) { error in
            guard case .invalidPackage = error as? PortableSessionError else {
                return XCTFail("Expected an unsafe-file package error, got \(error)")
            }
        }
        let remainingSessions = await importedStore.listSessions()
        XCTAssertTrue(remainingSessions.isEmpty)
    }

    func testPortableSessionImportRejectsBodiesWithoutADigest() async throws {
        let sourceSessionID = SessionID()
        var sourceSession = Session(id: sourceSessionID)
        sourceSession.stop()
        let body = BodyReference(
            inline: Data("safe".utf8),
            metadata: BodyMetadata(
                digest: BodyDigest(
                    algorithm: .sha256,
                    value: "8b3369944dd2a3fab39e32d1aeb1f763946a458ae3e6368a46432adc8f3a0860"
                )
            )
        )
        let sourceFlow = Flow(
            sessionID: sourceSessionID,
            request: HTTPRequest(
                method: .post,
                url: URL(string: "https://example.com/missing-digest")!,
                body: body
            )
        )
        let sourceStore = RecordingSessionStore(
            sessionID: sourceSessionID,
            recorder: CallRecorder()
        )
        await sourceStore.seed(session: sourceSession, flows: [sourceFlow])
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "missing-digest-\(UUID().uuidString).proxylens", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        try await PortableSessionService(
            sessionStore: sourceStore,
            bodyStore: RecordingBodyStore()
        ).exportSession(sessionID: sourceSessionID, to: packageURL)

        let metadataURL = packageURL.appendingPathComponent("flows/00000000.json")
        var metadata = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))
                as? [String: Any]
        )
        var requestBody = try XCTUnwrap(metadata["requestBody"] as? [String: Any])
        requestBody.removeValue(forKey: "digest")
        metadata["requestBody"] = requestBody
        try JSONSerialization.data(withJSONObject: metadata).write(
            to: metadataURL, options: .atomic)

        let importedStore = RecordingSessionStore(
            sessionID: SessionID(),
            recorder: CallRecorder()
        )
        await assertThrowsErrorAsync(
            try await PortableSessionService(
                sessionStore: importedStore,
                bodyStore: RecordingBodyStore()
            ).importSession(from: packageURL)
        ) { error in
            guard case .invalidPackage = error as? PortableSessionError else {
                return XCTFail("Expected a missing-digest package error, got \(error)")
            }
        }
        let remainingSessions = await importedStore.listSessions()
        XCTAssertTrue(remainingSessions.isEmpty)
    }

    func testPortableSessionTurnsLiveFlowSnapshotsIntoOfflineFailures() async throws {
        let sourceSessionID = SessionID()
        let sourceSession = Session(
            id: sourceSessionID,
            startedAt: Date(timeIntervalSince1970: 5_000)
        )
        var sourceFlow = Flow(
            sessionID: sourceSessionID,
            request: HTTPRequest(
                method: .get,
                url: URL(string: "https://example.com/live")!
            ),
            startedAt: Date(timeIntervalSince1970: 5_001)
        )
        try sourceFlow.transition(to: .receivingRequest)
        let sourceStore = RecordingSessionStore(
            sessionID: sourceSessionID,
            recorder: CallRecorder()
        )
        await sourceStore.seed(session: sourceSession, flows: [sourceFlow])
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString).proxylens", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        try await PortableSessionService(
            sessionStore: sourceStore,
            bodyStore: RecordingBodyStore()
        ).exportSession(sessionID: sourceSessionID, to: packageURL)
        let importedStore = RecordingSessionStore(
            sessionID: SessionID(),
            recorder: CallRecorder()
        )

        let result = try await PortableSessionService(
            sessionStore: importedStore,
            bodyStore: RecordingBodyStore()
        ).importSession(from: packageURL)

        let importedFlow = try XCTUnwrap(result.flows.first)
        guard case .failed(.unknown(let message)) = importedFlow.state else {
            return XCTFail("Expected a terminal imported snapshot, got \(importedFlow.state)")
        }
        XCTAssertEqual(message, "Session was exported before this flow completed")
        XCTAssertTrue(importedFlow.state.isTerminal)
        XCTAssertNotNil(importedFlow.timing.completedAt)
    }

    func testSessionServiceLoadsWorkspaceFlowsOldestFirstAndClearsEverySession() async throws {
        let recorder = CallRecorder()
        let sessionStore = RecordingSessionStore(sessionID: SessionID(), recorder: recorder)
        let olderSession = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newerSession = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        let olderFlow = Flow(
            sessionID: olderSession.id,
            request: HTTPRequest(
                method: .get,
                url: URL(string: "https://older.example.test/")!
            ),
            startedAt: Date(timeIntervalSince1970: 10)
        )
        let newerFlow = Flow(
            sessionID: newerSession.id,
            request: HTTPRequest(
                method: .get,
                url: URL(string: "https://newer.example.test/")!
            ),
            startedAt: Date(timeIntervalSince1970: 20)
        )
        await sessionStore.seed(session: newerSession, flows: [newerFlow])
        await sessionStore.seed(session: olderSession, flows: [olderFlow])
        let service = SessionService(sessionStore: sessionStore)

        let loaded = try await service.loadWorkspace()
        XCTAssertEqual(loaded.map(\.id), [olderFlow.id, newerFlow.id])

        try await service.clearWorkspace()
        let remainingFlows = try await service.loadWorkspace()
        let remainingSessions = await sessionStore.listSessions()
        XCTAssertTrue(remainingFlows.isEmpty)
        XCTAssertTrue(remainingSessions.isEmpty)
    }

    func testSessionServiceReusesTheNewestSessionAndCreatesOneForAnEmptyWorkspace()
        async throws
    {
        let recorder = CallRecorder()
        let createdSessionID = SessionID()
        let sessionStore = RecordingSessionStore(
            sessionID: createdSessionID,
            recorder: recorder
        )
        let olderSession = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newerSession = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        await sessionStore.seed(session: olderSession, flows: [])
        await sessionStore.seed(session: newerSession, flows: [])
        let service = SessionService(sessionStore: sessionStore)

        let reusedSessionID = try await service.sessionIDForNewFlow()

        XCTAssertEqual(reusedSessionID, newerSession.id)

        try await service.clearWorkspace()
        let newSessionID = try await service.sessionIDForNewFlow()

        XCTAssertEqual(newSessionID, createdSessionID)
        let createdSession = await sessionStore.loadSession(sessionID: createdSessionID)
        XCTAssertEqual(createdSession?.state, .stopped)
        let calls = await recorder.snapshot()
        XCTAssertEqual(Array(calls.suffix(2)), ["session.create", "session.stop"])
    }

    func testSessionServiceUpdatesAndClearsFlowAnnotations() async throws {
        let sessionID = SessionID()
        let sessionStore = RecordingSessionStore(sessionID: sessionID, recorder: CallRecorder())
        let flow = Flow(
            sessionID: sessionID,
            request: HTTPRequest(
                method: .get,
                url: URL(string: "https://annotations.example.test/important")!
            )
        )
        await sessionStore.seed(session: Session(id: sessionID), flows: [flow])
        let service = SessionService(sessionStore: sessionStore)
        let annotation = try FlowAnnotation(
            comment: "Investigate this response",
            highlight: .yellow,
            isStruckThrough: true
        )

        let updated = try await service.updateAnnotation(annotation, for: flow.id)

        XCTAssertEqual(updated?.annotation, annotation)
        let persisted = await sessionStore.load(flowID: flow.id)
        XCTAssertEqual(persisted?.annotation, annotation)

        let cleared = try await service.updateAnnotation(nil, for: flow.id)
        XCTAssertNil(cleared?.annotation)
    }

    func testSessionServiceListsRenamesAndRemovesInactiveSessions() async throws {
        let sessionStore = RecordingSessionStore(
            sessionID: SessionID(),
            recorder: CallRecorder()
        )
        var older = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        older.stop(at: Date(timeIntervalSince1970: 1_100))
        let recording = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        await sessionStore.seed(session: older)
        await sessionStore.seed(session: recording)
        let service = SessionService(sessionStore: sessionStore)

        let sessions = try await service.loadSessions()

        XCTAssertEqual(sessions.map(\.id), [recording.id, older.id])
        let renamed = try await service.renameSession(
            sessionID: older.id,
            to: "  Login investigation  "
        )
        XCTAssertEqual(renamed?.name, "Login investigation")
        let persisted = await sessionStore.loadSession(sessionID: older.id)
        XCTAssertEqual(persisted?.name, "Login investigation")

        do {
            _ = try await service.renameSession(sessionID: recording.id, to: "Active capture")
            XCTFail("Expected a recording session rename to be protected")
        } catch let error as ProxyLensError {
            XCTAssertEqual(error, .cannotRenameRecordingSession)
        }

        do {
            try await service.removeSession(sessionID: recording.id)
            XCTFail("Expected a recording session to be protected")
        } catch let error as ProxyLensError {
            XCTAssertEqual(error, .cannotRemoveRecordingSession)
        }

        try await service.removeSession(sessionID: older.id)
        let remaining = try await service.loadSessions()
        XCTAssertEqual(remaining.map(\.id), [recording.id])
    }

    func testCertificateTrustServiceDelegatesInstallRemoveExportAndState() async throws {
        let store = RecordingCertificateTrustStore(state: .notGenerated)
        let service = CertificateTrustService(trustStore: store)
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-trust-export-\(UUID().uuidString).pem")
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let initial = try await service.state()
        XCTAssertEqual(initial, .notGenerated)

        try await service.exportRootCertificate(to: exportURL)
        let afterExport = try await service.state()
        XCTAssertEqual(afterExport, .untrusted)
        let exported = await store.exportedURLs()
        XCTAssertEqual(exported, [exportURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        try await service.install()
        let trusted = try await service.state()
        XCTAssertEqual(trusted, .trusted)

        try await service.remove()
        let untrusted = try await service.state()
        XCTAssertEqual(untrusted, .untrusted)
    }

    func testStartUsesCreatedSessionAndStopRestoresDependenciesInOrder() async throws {
        let recorder = CallRecorder()
        let sessionID = SessionID()
        let sessionStore = RecordingSessionStore(sessionID: sessionID, recorder: recorder)
        let proxyEngine = RecordingProxyEngine(
            endpoint: NetworkEndpoint(host: "127.0.0.1", port: 58_080),
            recorder: recorder
        )
        let systemProxy = RecordingSystemProxyController(recorder: recorder)
        let now = Date(timeIntervalSince1970: 1_000)
        let coordinator = CaptureCoordinator(
            proxyEngine: proxyEngine,
            sessionStore: sessionStore,
            systemProxyController: systemProxy,
            timeSource: FixedTimeSource(date: now)
        )
        let configuration = Self.captureConfiguration()

        let context = try await coordinator.start(configuration: configuration)

        XCTAssertEqual(context.sessionID, sessionID)
        XCTAssertEqual(context.startedAt, now)
        XCTAssertEqual(context.endpoint, NetworkEndpoint(host: "127.0.0.1", port: 58_080))
        let receivedSessionIDs = await proxyEngine.receivedSessionIDs()
        XCTAssertEqual(receivedSessionIDs, [sessionID])
        let createdSession = await sessionStore.loadSession(sessionID: sessionID)
        XCTAssertEqual(createdSession?.state, .recording)
        let appliedConfigurations = await systemProxy.appliedConfigurations()
        XCTAssertEqual(
            appliedConfigurations,
            [
                SystemProxyConfiguration(
                    httpEndpoint: context.endpoint,
                    httpsEndpoint: context.endpoint,
                    bypassDomains: configuration.bypassDomains
                )
            ]
        )
        let startupCalls = await recorder.snapshot()
        XCTAssertEqual(
            startupCalls,
            [
                "proxy.recover",
                "session.recover",
                "proxy.prepare",
                "session.create",
                "engine.start",
                "proxy.apply"
            ]
        )

        try await coordinator.stop()

        let stoppedSession = await sessionStore.loadSession(sessionID: sessionID)
        XCTAssertEqual(stoppedSession?.state, .stopped)
        let finalState = await coordinator.state()
        XCTAssertEqual(finalState, .stopped)
        let allCalls = await recorder.snapshot()
        XCTAssertEqual(
            allCalls,
            startupCalls + ["proxy.restore", "engine.stop", "session.stop"]
        )
    }

    func testLifecycleRejectsReentrantAndInvalidTransitions() async throws {
        let recorder = CallRecorder()
        let enteredStart = AsyncGate()
        let resumeStart = AsyncGate()
        let proxyEngine = RecordingProxyEngine(
            endpoint: NetworkEndpoint(host: "127.0.0.1", port: 58_081),
            recorder: recorder,
            enteredStart: enteredStart,
            resumeStart: resumeStart
        )
        let coordinator = CaptureCoordinator(
            proxyEngine: proxyEngine,
            sessionStore: RecordingSessionStore(sessionID: SessionID(), recorder: recorder),
            systemProxyController: RecordingSystemProxyController(recorder: recorder)
        )
        let configuration = Self.captureConfiguration()

        let startTask = Task {
            try await coordinator.start(configuration: configuration)
        }
        await enteredStart.wait()

        do {
            _ = try await coordinator.start(configuration: configuration)
            XCTFail("Expected a second start to be rejected")
        } catch let error as CaptureCoordinatorError {
            guard case .invalidTransition(action: "start", state: "starting") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            try await coordinator.stop()
            XCTFail("Expected stop during startup to be rejected")
        } catch let error as CaptureCoordinatorError {
            guard case .invalidTransition(action: "stop", state: "starting") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await resumeStart.open()
        _ = try await startTask.value

        do {
            _ = try await coordinator.start(configuration: configuration)
            XCTFail("Expected start while running to be rejected")
        } catch let error as CaptureCoordinatorError {
            guard case .invalidTransition(action: "start", state: "running") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try await coordinator.stop()

        do {
            try await coordinator.stop()
            XCTFail("Expected a second stop to be rejected")
        } catch let error as CaptureCoordinatorError {
            guard case .invalidTransition(action: "stop", state: "stopped") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFlowEventBusMulticastsImmutableSnapshots() async throws {
        let bus = FlowEventBus()
        let firstStream = await bus.events(bufferingPolicy: .unbounded)
        let secondStream = await bus.events(bufferingPolicy: .unbounded)
        let flow = Flow(
            sessionID: SessionID(),
            request: HTTPRequest(
                method: .get,
                url: URL(string: "http://example.test/")!
            )
        )
        let event = FlowEvent.started(flow)

        await bus.publish(event)

        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()
        let firstEvent = await firstIterator.next()
        let secondEvent = await secondIterator.next()
        XCTAssertEqual(firstEvent, event)
        XCTAssertEqual(secondEvent, event)
        let subscriptionCount = await bus.subscriptionCount()
        XCTAssertEqual(subscriptionCount, 2)

        await bus.finish()
        let finishedSubscriptionCount = await bus.subscriptionCount()
        XCTAssertEqual(finishedSubscriptionCount, 0)
    }

    func testWebSocketFrameEventBusMulticastsCapturedFrames() async {
        let bus = WebSocketFrameEventBus()
        let firstStream = await bus.frames(bufferingPolicy: .unbounded)
        let secondStream = await bus.frames(bufferingPolicy: .unbounded)
        let frame = CapturedWebSocketFrame(
            flowID: FlowID(),
            sequenceNumber: 1,
            direction: .clientToServer,
            opcode: .text,
            isFinal: true,
            wasMasked: true,
            payload: BodyReference(inline: Data(#"{"message":"hello"}"#.utf8)),
            receivedAt: Date(timeIntervalSince1970: 123)
        )

        await bus.publish(frame)

        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()
        let firstFrame = await firstIterator.next()
        let secondFrame = await secondIterator.next()
        XCTAssertEqual(firstFrame, frame)
        XCTAssertEqual(secondFrame, frame)
        let subscriptionCount = await bus.subscriptionCount()
        XCTAssertEqual(subscriptionCount, 2)

        await bus.finish()
        let finishedSubscriptionCount = await bus.subscriptionCount()
        XCTAssertEqual(finishedSubscriptionCount, 0)
    }

    func testStartupFailureRollsBackProxyEngineAndSession() async throws {
        let recorder = CallRecorder()
        let sessionID = SessionID()
        let sessionStore = RecordingSessionStore(sessionID: sessionID, recorder: recorder)
        let proxyEngine = RecordingProxyEngine(
            endpoint: NetworkEndpoint(host: "127.0.0.1", port: 58_082),
            recorder: recorder
        )
        let systemProxy = RecordingSystemProxyController(
            recorder: recorder,
            failsApply: true
        )
        let coordinator = CaptureCoordinator(
            proxyEngine: proxyEngine,
            sessionStore: sessionStore,
            systemProxyController: systemProxy
        )

        do {
            _ = try await coordinator.start(configuration: Self.captureConfiguration())
            XCTFail("Expected system proxy activation to fail")
        } catch let error as CaptureCoordinatorError {
            guard
                case .startupFailed(
                    stage: .systemProxyActivation,
                    message: _,
                    rollbackFailures: []
                ) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let calls = await recorder.snapshot()
        XCTAssertEqual(
            calls,
            [
                "proxy.recover",
                "session.recover",
                "proxy.prepare",
                "session.create",
                "engine.start",
                "proxy.apply",
                "proxy.restore",
                "engine.stop",
                "session.stop"
            ]
        )
        let engineIsRunning = await proxyEngine.isRunning()
        XCTAssertFalse(engineIsRunning)
        let proxyIsActive = await systemProxy.isActive()
        XCTAssertFalse(proxyIsActive)
        let session = await sessionStore.loadSession(sessionID: sessionID)
        XCTAssertEqual(session?.state, .stopped)
        let state = await coordinator.state()
        guard case .failed = state else {
            return XCTFail("Expected the coordinator to retain its startup failure")
        }
    }

    func testFailedProxyRestoreKeepsListenerAndSessionRunning() async throws {
        let recorder = CallRecorder()
        let sessionID = SessionID()
        let sessionStore = RecordingSessionStore(sessionID: sessionID, recorder: recorder)
        let proxyEngine = RecordingProxyEngine(
            endpoint: NetworkEndpoint(host: "127.0.0.1", port: 58_083),
            recorder: recorder
        )
        let systemProxy = RecordingSystemProxyController(recorder: recorder)
        let coordinator = CaptureCoordinator(
            proxyEngine: proxyEngine,
            sessionStore: sessionStore,
            systemProxyController: systemProxy
        )
        _ = try await coordinator.start(configuration: Self.captureConfiguration())
        await systemProxy.setFailsRestore(true)

        do {
            try await coordinator.stop()
            XCTFail("Expected system proxy restoration to fail")
        } catch let error as CaptureCoordinatorError {
            guard case .stopFailed(stage: .systemProxyRestoration, message: _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let engineIsRunning = await proxyEngine.isRunning()
        XCTAssertTrue(engineIsRunning)
        let session = await sessionStore.loadSession(sessionID: sessionID)
        XCTAssertEqual(session?.state, .recording)
        let state = await coordinator.state()
        guard case .running = state else {
            return XCTFail("Expected capture to remain running after restore failed")
        }

        await systemProxy.setFailsRestore(false)
        try await coordinator.stop()
        let stoppedEngine = await proxyEngine.isRunning()
        XCTAssertFalse(stoppedEngine)
    }

    func testLaunchRecoveryRestoresInterruptedProxyAndSessionBeforeCaptureStarts()
        async throws
    {
        let recorder = CallRecorder()
        let interruptedSessionID = SessionID()
        let newSessionID = SessionID()
        let sessionStore = RecordingSessionStore(sessionID: newSessionID, recorder: recorder)
        await sessionStore.seedRecordingSession(id: interruptedSessionID)
        let systemProxy = RecordingSystemProxyController(
            recorder: recorder,
            startsActive: true
        )
        let coordinator = CaptureCoordinator(
            proxyEngine: RecordingProxyEngine(
                endpoint: NetworkEndpoint(host: "127.0.0.1", port: 58_084),
                recorder: recorder
            ),
            sessionStore: sessionStore,
            systemProxyController: systemProxy
        )

        try await coordinator.recoverInterruptedCapture()

        let recoveredSession = await sessionStore.loadSession(
            sessionID: interruptedSessionID
        )
        XCTAssertEqual(recoveredSession?.state, .interrupted)
        let launchRecoveryCalls = await recorder.snapshot()
        XCTAssertEqual(launchRecoveryCalls, ["proxy.recover", "session.recover"])
        let stateAfterRecovery = await coordinator.state()
        XCTAssertEqual(stateAfterRecovery, .stopped)
        let proxyIsActive = await systemProxy.isActive()
        XCTAssertFalse(proxyIsActive)

        _ = try await coordinator.start(configuration: Self.captureConfiguration())

        let callsAfterStart = await recorder.snapshot()
        let createIndex = try XCTUnwrap(callsAfterStart.firstIndex(of: "session.create"))
        let finalRecoveryIndex = try XCTUnwrap(
            callsAfterStart.lastIndex(of: "session.recover")
        )
        XCTAssertLessThan(finalRecoveryIndex, createIndex)

        try await coordinator.stop()
    }

    private static func captureConfiguration() -> CaptureConfiguration {
        CaptureConfiguration(
            proxy: ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                interceptHTTPS: false
            )
        )
    }

    private static func exportFlow(
        method: HTTPMethod,
        url: String,
        requestHeaders: [(String, String)] = [],
        requestBody: Data? = nil,
        statusCode: Int? = nil,
        reasonPhrase: String? = nil,
        responseHeaders: [(String, String)] = [],
        responseBody: Data? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> Flow {
        var requestHeaderFields = HTTPHeaders()
        for (name, value) in requestHeaders {
            try requestHeaderFields.append(name: name, value: value)
        }
        let requestReference = requestBody.map { data in
            BodyReference(
                inline: data,
                metadata: BodyMetadata(
                    contentType: requestHeaderFields.firstValue(for: "Content-Type")
                )
            )
        }
        var flow = Flow(
            sessionID: SessionID(),
            request: HTTPRequest(
                method: method,
                url: URL(string: url)!,
                headers: requestHeaderFields,
                body: requestReference
            ),
            startedAt: startedAt
        )
        try flow.transition(to: .receivingRequest)
        guard let statusCode else {
            return flow
        }

        var responseHeaderFields = HTTPHeaders()
        for (name, value) in responseHeaders {
            try responseHeaderFields.append(name: name, value: value)
        }
        let responseReference = responseBody.map { data in
            BodyReference(
                inline: data,
                metadata: BodyMetadata(
                    contentType: responseHeaderFields.firstValue(for: "Content-Type")
                )
            )
        }
        try flow.transition(to: .receivingResponse)
        flow.attachResponse(
            try HTTPResponse(
                statusCode: statusCode,
                reasonPhrase: reasonPhrase,
                headers: responseHeaderFields,
                body: responseReference
            )
        )
        try flow.transition(to: .completed)
        return flow
    }

    private static func harObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProxyLensError.unsupportedOperation("HAR JSON was not an object")
        }
        return object
    }
}

private enum TestFailure: LocalizedError {
    case expected

    var errorDescription: String? {
        "Expected test failure"
    }
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        verify(error)
    }
}

private actor CallRecorder {
    private var calls: [String] = []

    func append(_ call: String) {
        calls.append(call)
    }

    func snapshot() -> [String] {
        calls
    }
}

private actor RecordingBodyStore: BodyStore {
    private var ids: [BodyID] = []

    func beginWrite(
        metadata: BodyMetadata,
        maximumByteCount: Int64?
    ) async throws -> any BodyWriter {
        RecordingBodyWriter(metadata: metadata, maximumByteCount: maximumByteCount)
    }

    func read(_ reference: BodyReference) async throws -> Data {
        ids.append(reference.id)
        if case .inline(let data) = reference.storage {
            return data
        }
        throw ProxyLensError.unsupportedOperation("Missing exported body")
    }

    func remove(_ reference: BodyReference) async {}

    func readIDs() -> [BodyID] {
        ids
    }
}

private actor RecordingBodyWriter: BodyWriter {
    private let metadata: BodyMetadata
    private let maximumByteCount: Int64?
    private var buffer = Data()
    private var isTruncated = false

    init(metadata: BodyMetadata, maximumByteCount: Int64?) {
        self.metadata = metadata
        self.maximumByteCount = maximumByteCount
    }

    func append(_ data: Data) {
        guard let maximumByteCount else {
            buffer.append(data)
            return
        }
        let remainingByteCount = max(0, maximumByteCount - Int64(buffer.count))
        guard Int64(data.count) <= remainingByteCount else {
            buffer.append(data.prefix(Int(remainingByteCount)))
            isTruncated = true
            return
        }
        buffer.append(data)
    }

    func finalize() -> BodyReference {
        BodyReference(
            inline: buffer,
            metadata: BodyMetadata(
                contentType: metadata.contentType,
                contentEncoding: metadata.contentEncoding,
                digest: metadata.digest,
                isTruncated: metadata.isTruncated || isTruncated
            )
        )
    }

    func cancel() {}
}

private actor RecordingRequestReplayClient: RequestReplayClient {
    private let result: Flow
    private var requests: [(request: HTTPRequest, sessionID: SessionID)] = []

    init(result: Flow) {
        self.result = result
    }

    func replay(_ request: HTTPRequest, sessionID: SessionID) throws -> Flow {
        requests.append((request, sessionID))
        return result
    }

    func receivedRequests() -> [(request: HTTPRequest, sessionID: SessionID)] {
        requests
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

private struct FixedTimeSource: TimeSource {
    let date: Date

    func now() -> Date {
        date
    }
}

private actor RecordingProxyEngine: ProxyEngine {
    private let endpoint: NetworkEndpoint
    private let recorder: CallRecorder
    private let enteredStart: AsyncGate?
    private let resumeStart: AsyncGate?
    private var currentState = ProxyEngineState.stopped
    private var sessionIDs: [SessionID] = []

    init(
        endpoint: NetworkEndpoint,
        recorder: CallRecorder,
        enteredStart: AsyncGate? = nil,
        resumeStart: AsyncGate? = nil
    ) {
        self.endpoint = endpoint
        self.recorder = recorder
        self.enteredStart = enteredStart
        self.resumeStart = resumeStart
    }

    func start(configuration _: ProxyConfiguration, sessionID: SessionID) async throws {
        await recorder.append("engine.start")
        currentState = .starting
        sessionIDs.append(sessionID)
        await enteredStart?.open()
        await resumeStart?.wait()
        currentState = .running(endpoint)
    }

    func stop() async {
        await recorder.append("engine.stop")
        currentState = .stopped
    }

    func state() -> ProxyEngineState {
        currentState
    }

    func receivedSessionIDs() -> [SessionID] {
        sessionIDs
    }

    func isRunning() -> Bool {
        if case .running = currentState {
            return true
        }
        return false
    }
}

private actor RecordingSystemProxyController: SystemProxyController {
    private let recorder: CallRecorder
    private let failsApply: Bool
    private var failsRestore: Bool
    private var active: Bool
    private var prepared = false
    private var configurations: [SystemProxyConfiguration] = []

    init(
        recorder: CallRecorder,
        failsApply: Bool = false,
        failsRestore: Bool = false,
        startsActive: Bool = false
    ) {
        self.recorder = recorder
        self.failsApply = failsApply
        self.failsRestore = failsRestore
        self.active = startsActive
        self.prepared = startsActive
    }

    func recoverInterruptedConfiguration() async throws {
        await recorder.append("proxy.recover")
        active = false
        prepared = false
    }

    func prepareForProxyActivation() async throws {
        await recorder.append("proxy.prepare")
        prepared = true
    }

    func apply(_ configuration: SystemProxyConfiguration) async throws {
        await recorder.append("proxy.apply")
        configurations.append(configuration)
        active = true
        if failsApply {
            throw TestFailure.expected
        }
    }

    func restorePreviousConfiguration() async throws {
        await recorder.append("proxy.restore")
        if failsRestore {
            throw TestFailure.expected
        }
        active = false
        prepared = false
    }

    func setFailsRestore(_ value: Bool) {
        failsRestore = value
    }

    func appliedConfigurations() -> [SystemProxyConfiguration] {
        configurations
    }

    func isActive() -> Bool {
        active
    }
}

private actor RecordingSessionStore: SessionStore {
    private let sessionID: SessionID
    private let recorder: CallRecorder
    private var sessions: [SessionID: Session] = [:]
    private var flows: [FlowID: Flow] = [:]

    init(sessionID: SessionID, recorder: CallRecorder) {
        self.sessionID = sessionID
        self.recorder = recorder
    }

    func prepareForCaptureStart() async throws {
        await recorder.append("session.recover")
        for (id, var session) in sessions where session.state == .recording {
            session.interrupt(at: Date(timeIntervalSince1970: 900))
            sessions[id] = session
        }
    }

    func createSession(startedAt: Date) async throws -> Session {
        await recorder.append("session.create")
        let session = Session(id: sessionID, startedAt: startedAt)
        sessions[session.id] = session
        return session
    }

    func saveSession(_ session: Session) {
        sessions[session.id] = session
    }

    func loadSession(sessionID: SessionID) -> Session? {
        sessions[sessionID]
    }

    func listSessions() -> [Session] {
        Array(sessions.values)
    }

    func listAllFlows() -> [Flow] {
        Array(flows.values)
    }

    func stopSession(sessionID: SessionID, at date: Date) async throws {
        await recorder.append("session.stop")
        guard var session = sessions[sessionID] else {
            return
        }
        session.stop(at: date)
        sessions[sessionID] = session
    }

    func removeSession(sessionID: SessionID) {
        sessions.removeValue(forKey: sessionID)
        flows = flows.filter { $0.value.sessionID != sessionID }
    }

    func save(_ flow: Flow) {
        let isNewFlow = flows[flow.id] == nil
        flows[flow.id] = flow
        if isNewFlow, var session = sessions[flow.sessionID] {
            session.registerFlow()
            sessions[flow.sessionID] = session
        }
    }

    func load(flowID: FlowID) -> Flow? {
        flows[flowID]
    }

    func listFlows(in sessionID: SessionID) -> [Flow] {
        flows.values.filter { $0.sessionID == sessionID }
    }

    func listSummaries(in sessionID: SessionID) -> [FlowSummary] {
        listFlows(in: sessionID).map(\.summary)
    }

    func remove(flowID: FlowID) {
        flows.removeValue(forKey: flowID)
    }

    func seed(session: Session, flows: [Flow] = []) {
        sessions[session.id] = session
        for flow in flows {
            self.flows[flow.id] = flow
        }
    }

    func seedRecordingSession(id: SessionID) {
        sessions[id] = Session(id: id, startedAt: Date(timeIntervalSince1970: 800))
    }
}

private actor RecordingCertificateTrustStore: CertificateTrustStore {
    private var state: CertificateTrustState
    private var exported: [URL] = []

    init(state: CertificateTrustState) {
        self.state = state
    }

    func trustState() -> CertificateTrustState {
        state
    }

    func installTrust() {
        state = .trusted
    }

    func removeTrust() {
        if state != .notGenerated {
            state = .untrusted
        }
    }

    func exportRootCertificate(to url: URL) throws {
        if state == .notGenerated {
            state = .untrusted
        }
        exported.append(url)
        try Data("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n".utf8)
            .write(to: url)
    }

    func exportedURLs() -> [URL] {
        exported
    }
}
