import Foundation
import ProxyLensCore
import XCTest

@testable import ProxyLensApplication

final class ProxyLensApplicationTests: XCTestCase {
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
        RecordingBodyWriter()
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
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    func finalize() -> BodyReference {
        BodyReference(inline: buffer)
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
        flows[flow.id] = flow
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
