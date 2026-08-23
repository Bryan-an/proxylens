import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import NIOTLS
import NIOWebSocket
import ProxyLensApplication
import ProxyLensCore
import ProxyLensPersistence
import ProxyLensPlatform
import XCTest

@testable import ProxyLensCapture

final class ProxyLensCaptureTests: XCTestCase {
    func testEventStreamCapturePersistsDerivedEventsWithoutChangingRawResponse() async throws {
        let rawStream = "id: 41\nevent: update\ndata: first\ndata: second\n\ndata: done\n\n"
        let upstream = try await TestHTTPServer.start(
            responseBody: rawStream,
            extraResponseHeaders: [("Content-Type", "text/event-stream; charset=utf-8")]
        )
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensSSEIntegrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let flowEvents = RecordingFlowEventSink()
        let serverSentEvents = RecordingServerSentEventSink()
        let engine = NIOProxyEngine(
            eventSink: PersistingFlowEventSink(
                flowStore: sessionStore,
                downstream: flowEvents
            ),
            serverSentEventEventSink: PersistingServerSentEventEventSink(
                eventStore: sessionStore,
                downstream: serverSentEvents
            ),
            bodyStore: bodyStore
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/events",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data(rawStream.utf8))
            await flowEvents.waitForFinished()
            try await eventually("two captured Server-Sent Events") {
                await serverSentEvents.events().count == 2
            }
            let capturedFlowEvents = await flowEvents.snapshot()
            let finishedFlow = try XCTUnwrap(
                capturedFlowEvents.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            let rawResponseBody = try XCTUnwrap(finishedFlow.response?.body)
            let persistedRawResponse = try await bodyStore.read(rawResponseBody)
            XCTAssertEqual(persistedRawResponse, Data(rawStream.utf8))

            let persistedEvents = try await sessionStore.listServerSentEvents(for: finishedFlow.id)
            XCTAssertEqual(persistedEvents.map(\.sequenceNumber), [1, 2])
            XCTAssertEqual(persistedEvents.map(\.eventType), ["update", "message"])
            XCTAssertEqual(persistedEvents.map(\.eventID), ["41", "41"])
            var payloads: [Data] = []
            for event in persistedEvents {
                payloads.append(try await bodyStore.read(event.data))
            }
            XCTAssertEqual(payloads, [Data("first\nsecond".utf8), Data("done".utf8)])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testGzipEventStreamCaptureDecodesDerivedEventsAndPreservesCompressedRawResponse()
        async throws
    {
        let eventStream = Data("id: 7\ndata: compressed\n\ndata: stream\n\n".utf8)
        let compressedStream = try HTTPContentCoding.encode(
            eventStream,
            contentEncoding: "gzip"
        )
        let upstream = try await TestHTTPServer.start(
            responseData: compressedStream,
            extraResponseHeaders: [
                ("Content-Type", "text/event-stream"),
                ("Content-Encoding", "gzip")
            ]
        )
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensCompressedSSETests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let flowEvents = RecordingFlowEventSink()
        let serverSentEvents = RecordingServerSentEventSink()
        let engine = NIOProxyEngine(
            eventSink: PersistingFlowEventSink(
                flowStore: sessionStore,
                downstream: flowEvents
            ),
            serverSentEventEventSink: PersistingServerSentEventEventSink(
                eventStore: sessionStore,
                downstream: serverSentEvents
            ),
            bodyStore: bodyStore
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/compressed-events",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, compressedStream)
            await flowEvents.waitForFinished()
            try await eventually("two captured compressed Server-Sent Events") {
                await serverSentEvents.events().count == 2
            }
            let capturedFlowEvents = await flowEvents.snapshot()
            let finishedFlow = try XCTUnwrap(
                capturedFlowEvents.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            let rawResponseBody = try XCTUnwrap(finishedFlow.response?.body)
            let persistedRawResponse = try await bodyStore.read(rawResponseBody)
            XCTAssertEqual(persistedRawResponse, compressedStream)

            let persistedEvents = try await sessionStore.listServerSentEvents(for: finishedFlow.id)
            XCTAssertEqual(persistedEvents.map(\.sequenceNumber), [1, 2])
            XCTAssertEqual(persistedEvents.map(\.eventID), ["7", "7"])
            var payloads: [Data] = []
            for event in persistedEvents {
                payloads.append(try await bodyStore.read(event.data))
            }
            XCTAssertEqual(payloads, [Data("compressed".utf8), Data("stream".utf8)])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testCorruptCompressedEventStreamKeepsRawResponseInspectable() async throws {
        let corruptStream = Data("not-a-gzip-stream".utf8)
        let upstream = try await TestHTTPServer.start(
            responseData: corruptStream,
            extraResponseHeaders: [
                ("Content-Type", "text/event-stream"),
                ("Content-Encoding", "gzip")
            ]
        )
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensCorruptSSETests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let flowEvents = RecordingFlowEventSink()
        let serverSentEvents = RecordingServerSentEventSink()
        let engine = NIOProxyEngine(
            eventSink: flowEvents,
            serverSentEventEventSink: serverSentEvents,
            bodyStore: bodyStore
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/corrupt-events",
                through: proxyEndpoint
            )
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, corruptStream)

            await flowEvents.waitForFinished()
            let capturedFlowEvents = await flowEvents.snapshot()
            let finishedFlow = try XCTUnwrap(
                capturedFlowEvents.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            let rawResponseBody = try XCTUnwrap(finishedFlow.response?.body)
            let persistedRawResponse = try await bodyStore.read(rawResponseBody)
            XCTAssertEqual(persistedRawResponse, corruptStream)
            let capturedEvents = await serverSentEvents.events()
            XCTAssertEqual(capturedEvents, [])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testWebSocketUpgradeRelaysAndPersistsBidirectionalFrames() async throws {
        let upstream = try await TestWebSocketServer.start()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensWebSocketIntegrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let flowEvents = RecordingFlowEventSink()
        let frameEvents = RecordingWebSocketFrameSink()
        let engine = NIOProxyEngine(
            eventSink: PersistingFlowEventSink(
                flowStore: sessionStore,
                downstream: flowEvents
            ),
            webSocketFrameEventSink: PersistingWebSocketFrameEventSink(
                frameStore: sessionStore,
                downstream: frameEvents
            ),
            bodyStore: bodyStore
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await WebSocketTestClient.exchange(
                url: "ws://127.0.0.1:\(upstream.endpoint.port)/echo",
                through: proxyEndpoint,
                message: "hello"
            )

            XCTAssertEqual(response, "echo:hello")
            try await eventually("two persisted WebSocket frames") {
                await frameEvents.frames().count >= 2
            }
            try await eventually("a finished WebSocket flow") {
                await flowEvents.snapshot().contains { event in
                    if case .finished = event {
                        return true
                    }
                    return false
                }
            }
            let events = await flowEvents.snapshot()
            let finishedFlow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            let frames = try await sessionStore.listWebSocketFrames(for: finishedFlow.id)

            XCTAssertEqual(finishedFlow.connection?.protocolKind, .webSocket)
            XCTAssertEqual(finishedFlow.state, .completed)
            XCTAssertEqual(frames.map(\.sequenceNumber), [1, 2])
            XCTAssertEqual(frames.map(\.direction), [.clientToServer, .serverToClient])
            XCTAssertEqual(frames.map(\.opcode), [.text, .text])
            XCTAssertEqual(frames.map(\.wasMasked), [true, false])
            var payloads: [Data] = []
            for frame in frames {
                payloads.append(try await bodyStore.read(frame.payload))
            }
            XCTAssertEqual(payloads, [Data("hello".utf8), Data("echo:hello".utf8)])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testWebSocketResponseBreakpointEditsForwardedTextAndPreservesCapturedBytes()
        async throws
    {
        let upstream = try await TestWebSocketServer.start()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensWebSocketBreakpointTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let flowEvents = RecordingFlowEventSink()
        let frameEvents = RecordingWebSocketFrameSink()
        let coordinator = BreakpointCoordinator()
        let rules = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Pause WebSocket responses",
                    phase: .webSocketFrame,
                    matcher: .path(.exact("/echo")),
                    action: .breakpoint
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: PersistingFlowEventSink(
                flowStore: sessionStore,
                downstream: flowEvents
            ),
            webSocketFrameEventSink: PersistingWebSocketFrameEventSink(
                frameStore: sessionStore,
                downstream: frameEvents
            ),
            bodyStore: bodyStore,
            ruleSnapshot: rules,
            breakpointGate: coordinator
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let upstreamPort = upstream.endpoint.port
            let exchange = Task {
                try await WebSocketTestClient.exchangeDetails(
                    url: "ws://127.0.0.1:\(upstreamPort)/echo",
                    through: proxyEndpoint,
                    initialMessage: "hello",
                    expectedResponseCount: 1
                )
            }
            await flowEvents.waitForFlow { $0.state == .paused(.webSocketResponse) }
            let pausedFlowSnapshot = await flowEvents.lastFlow {
                $0.state == .paused(.webSocketResponse)
            }
            let pausedFlow = try XCTUnwrap(pausedFlowSnapshot)
            var pendingHitSnapshot = await coordinator.hit(for: pausedFlow.id)
            for _ in 0..<100 where pendingHitSnapshot == nil {
                try await Task.sleep(for: .milliseconds(10))
                pendingHitSnapshot = await coordinator.hit(for: pausedFlow.id)
            }
            let pendingHit = try XCTUnwrap(pendingHitSnapshot)
            let pendingFrame = try XCTUnwrap(pendingHit.webSocketFrame)
            XCTAssertEqual(pendingFrame.opcode, .text)
            XCTAssertEqual(pendingFrame.payload, Data("echo:hello".utf8))
            XCTAssertTrue(pendingFrame.canEditPayload)

            try await eventually("the original response frame is captured before resume") {
                await frameEvents.frames().contains {
                    $0.flowID == pausedFlow.id && $0.direction == .serverToClient
                }
            }
            let editedFrame = try pendingFrame.replacingPayload(Data("edited".utf8))
            let editedHit = BreakpointHit(
                flowID: pendingHit.flowID,
                phase: pendingHit.phase,
                request: pendingHit.request,
                response: pendingHit.response,
                webSocketFrame: editedFrame
            )
            await coordinator.resume(
                flowID: pausedFlow.id,
                decision: .continue(editedHit)
            )

            let result = try await exchange.value
            XCTAssertEqual(result.responses, ["edited"])
            try await eventually("the WebSocket flow finishes after the client closes") {
                await flowEvents.snapshot().contains {
                    $0.flow.id == pausedFlow.id && $0.flow.state == .completed
                }
            }
            let capturedFrames = try await sessionStore.listWebSocketFrames(for: pausedFlow.id)
            let capturedResponse = try XCTUnwrap(
                capturedFrames.first { $0.direction == .serverToClient }
            )
            let capturedPayload = try await bodyStore.read(capturedResponse.payload)
            XCTAssertEqual(capturedPayload, Data("echo:hello".utf8))
            let completedFlowSnapshot = await flowEvents.lastFlow {
                $0.id == pausedFlow.id && $0.state == .completed
            }
            let completedFlow = try XCTUnwrap(completedFlowSnapshot)
            XCTAssertEqual(completedFlow.ruleTraces.map(\.phase), [.webSocketFrame])
            XCTAssertEqual(completedFlow.ruleTraces.map(\.outcome), [.applied])
        } catch {
            await coordinator.abortAll()
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testAbortingWebSocketResponseBreakpointClosesBothPeersAndFailsFlow() async throws {
        let upstream = try await TestWebSocketServer.start()
        let flowEvents = RecordingFlowEventSink()
        let coordinator = BreakpointCoordinator()
        let engine = NIOProxyEngine(
            eventSink: flowEvents,
            ruleSnapshot: MutableRuleSnapshot(
                rules: RuleSet(rules: [
                    Rule(
                        name: "Pause WebSocket responses",
                        phase: .webSocketFrame,
                        matcher: .path(.exact("/echo")),
                        action: .breakpoint
                    )
                ])
            ),
            breakpointGate: coordinator
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let upstreamPort = upstream.endpoint.port
            let exchange = Task {
                try await WebSocketTestClient.exchangeDetails(
                    url: "ws://127.0.0.1:\(upstreamPort)/echo",
                    through: proxyEndpoint,
                    initialMessage: "hello",
                    expectedResponseCount: 1
                )
            }
            await flowEvents.waitForFlow { $0.state == .paused(.webSocketResponse) }
            let pausedFlowSnapshot = await flowEvents.lastFlow {
                $0.state == .paused(.webSocketResponse)
            }
            let pausedFlow = try XCTUnwrap(pausedFlowSnapshot)
            try await eventually("the WebSocket breakpoint gate to register") {
                await coordinator.hit(for: pausedFlow.id) != nil
            }
            await coordinator.abort(flowID: pausedFlow.id)

            do {
                _ = try await exchange.value
                XCTFail("Expected abort to close the downstream WebSocket")
            } catch {
                // The downstream peer observes the deliberate connection close.
            }
            try await eventually("an explicitly failed WebSocket flow") {
                guard
                    let failedFlow = await flowEvents.lastFlow(where: {
                        $0.id == pausedFlow.id && $0.state.isTerminal
                    })
                else {
                    return false
                }
                return failedFlow.state
                    == .failed(.protocolError("Aborted at WebSocket response breakpoint"))
            }
            let isConnectionOpen = await engine.isConnectionOpen(for: pausedFlow.id)
            XCTAssertFalse(isConnectionOpen)
        } catch {
            await coordinator.abortAll()
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testWebSocketResponseBreakpointLetsControlFramesPassBeforePausingData() async throws {
        let upstream = try await TestWebSocketServer.start()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensWebSocketControlBreakpointTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let flowEvents = RecordingFlowEventSink()
        let frameEvents = RecordingWebSocketFrameSink()
        let coordinator = BreakpointCoordinator()
        let engine = NIOProxyEngine(
            eventSink: flowEvents,
            webSocketFrameEventSink: frameEvents,
            bodyStore: bodyStore,
            ruleSnapshot: MutableRuleSnapshot(
                rules: RuleSet(rules: [
                    Rule(
                        name: "Pause WebSocket responses",
                        phase: .webSocketFrame,
                        matcher: .path(.exact("/ping")),
                        action: .breakpoint
                    )
                ])
            ),
            breakpointGate: coordinator
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let upstreamPort = upstream.endpoint.port
            let exchange = Task {
                try await WebSocketTestClient.exchangeDetails(
                    url: "ws://127.0.0.1:\(upstreamPort)/ping",
                    through: proxyEndpoint,
                    initialMessage: "trigger",
                    expectedResponseCount: 1
                )
            }
            await flowEvents.waitForFlow { $0.state == .paused(.webSocketResponse) }
            let pausedFlowSnapshot = await flowEvents.lastFlow {
                $0.state == .paused(.webSocketResponse)
            }
            let pausedFlow = try XCTUnwrap(pausedFlowSnapshot)
            var pendingHit = await coordinator.hit(for: pausedFlow.id)
            for _ in 0..<100 where pendingHit == nil {
                try await Task.sleep(for: .milliseconds(10))
                pendingHit = await coordinator.hit(for: pausedFlow.id)
            }
            let hit = try XCTUnwrap(pendingHit)
            XCTAssertEqual(hit.webSocketFrame?.opcode, .text)
            XCTAssertEqual(hit.webSocketFrame?.payload, Data("pong-received".utf8))
            try await eventually("ping and pong control frames to pass without pausing") {
                let frames = await frameEvents.frames()
                return frames.contains { $0.opcode == .ping }
                    && frames.contains { $0.opcode == .pong }
            }

            await coordinator.resume(flowID: pausedFlow.id, decision: .continue(hit))
            let result = try await exchange.value
            XCTAssertEqual(result.responses, ["pong-received"])
        } catch {
            await coordinator.abortAll()
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testWebSocketHandshakeScriptsRewriteSafeRequestAndResponseFields() async throws {
        let upstream = try await TestWebSocketServer.start()
        let flowEvents = RecordingFlowEventSink()
        let scriptExecutor = StubScriptExecutor { request in
            switch request.hook {
            case .request:
                XCTAssertTrue(request.message.url?.hasPrefix("ws://") == true)
                let url = try XCTUnwrap(URL(string: try XCTUnwrap(request.message.url)))
                var components = try XCTUnwrap(
                    URLComponents(url: url, resolvingAgainstBaseURL: false))
                components.path = "/scripted"
                return try ScriptExecutionResult(
                    hook: .request,
                    message: ScriptHTTPMessage(
                        method: request.message.method,
                        url: try XCTUnwrap(components.url).absoluteString,
                        headers: request.message.headers + [
                            try HTTPHeader(name: "X-ProxyLens-WebSocket", value: "request")
                        ]
                    ),
                    logs: ["WebSocket request handshake updated"]
                )
            case .response:
                return try ScriptExecutionResult(
                    hook: .response,
                    message: ScriptHTTPMessage(
                        statusCode: request.message.statusCode,
                        headers: request.message.headers + [
                            try HTTPHeader(name: "X-ProxyLens-WebSocket", value: "response")
                        ]
                    ),
                    logs: ["WebSocket response handshake updated"]
                )
            }
        }
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Rewrite WebSocket request handshake",
                    priority: 10,
                    phase: .requestHeaders,
                    matcher: .header(name: "Upgrade", value: .exact("websocket")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onRequest(context) {}")
                    )
                ),
                Rule(
                    name: "Rewrite WebSocket response handshake",
                    priority: 10,
                    phase: .responseHeaders,
                    matcher: .header(name: "Upgrade", value: .exact("websocket")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onResponse(context) {}")
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: flowEvents,
            ruleSnapshot: snapshot,
            scriptExecutor: scriptExecutor
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let result = try await WebSocketTestClient.exchangeDetails(
                url: "ws://127.0.0.1:\(upstream.endpoint.port)/echo",
                through: proxyEndpoint,
                initialMessage: "hello",
                expectedResponseCount: 1
            )

            XCTAssertEqual(result.responses, ["echo:hello"])
            XCTAssertEqual(upstream.requestURI, "/scripted")
            XCTAssertEqual(upstream.requestHeader("X-ProxyLens-WebSocket"), "request")
            XCTAssertEqual(result.header("X-ProxyLens-WebSocket"), "response")
            await flowEvents.waitForFinished()
            let completedFlow = await flowEvents.lastFlow { $0.state == .completed }
            let flow = try XCTUnwrap(completedFlow)
            XCTAssertEqual(flow.request.url.path, "/echo")
            XCTAssertNil(flow.request.headers.firstValue(for: "X-ProxyLens-WebSocket"))
            XCTAssertNil(flow.response?.headers.firstValue(for: "X-ProxyLens-WebSocket"))
            XCTAssertEqual(flow.ruleTraces.map(\.outcome), [.applied, .applied])
            XCTAssertEqual(
                flow.ruleTraces.map(\.logs),
                [
                    ["WebSocket request handshake updated"],
                    ["WebSocket response handshake updated"]
                ]
            )
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testWebSocketHandshakeScriptsFailOpenForCriticalFieldMutations() async throws {
        let upstream = try await TestWebSocketServer.start()
        let flowEvents = RecordingFlowEventSink()
        let scriptExecutor = StubScriptExecutor { request in
            switch request.hook {
            case .request:
                return try ScriptExecutionResult(
                    hook: .request,
                    message: ScriptHTTPMessage(
                        method: "POST",
                        url: request.message.url,
                        headers: request.message.headers.filter {
                            $0.name.caseInsensitiveCompare("Sec-WebSocket-Key") != .orderedSame
                        } + [
                            try HTTPHeader(name: "Sec-WebSocket-Key", value: "invalid"),
                            try HTTPHeader(name: "X-Must-Not-Apply", value: "request")
                        ]
                    )
                )
            case .response:
                return try ScriptExecutionResult(
                    hook: .response,
                    message: ScriptHTTPMessage(
                        statusCode: 200,
                        headers: request.message.headers + [
                            try HTTPHeader(name: "X-Must-Not-Apply", value: "response")
                        ]
                    )
                )
            }
        }
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Invalid WebSocket request handshake",
                    priority: 10,
                    phase: .requestHeaders,
                    matcher: .header(name: "Upgrade", value: .exact("websocket")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onRequest(context) {}")
                    )
                ),
                Rule(
                    name: "Invalid WebSocket response handshake",
                    priority: 10,
                    phase: .responseHeaders,
                    matcher: .header(name: "Upgrade", value: .exact("websocket")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onResponse(context) {}")
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: flowEvents,
            ruleSnapshot: snapshot,
            scriptExecutor: scriptExecutor
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let result = try await WebSocketTestClient.exchangeDetails(
                url: "ws://127.0.0.1:\(upstream.endpoint.port)/echo",
                through: proxyEndpoint,
                initialMessage: "hello",
                expectedResponseCount: 1
            )

            XCTAssertEqual(result.responses, ["echo:hello"])
            XCTAssertNil(upstream.requestHeader("X-Must-Not-Apply"))
            XCTAssertNil(result.header("X-Must-Not-Apply"))
            await flowEvents.waitForFinished()
            let completedFlow = await flowEvents.lastFlow { $0.state == .completed }
            let flow = try XCTUnwrap(completedFlow)
            XCTAssertEqual(flow.ruleTraces.count, 2)
            for trace in flow.ruleTraces {
                guard case .failed(let message) = trace.outcome else {
                    return XCTFail("Expected protected WebSocket mutation to fail open")
                }
                XCTAssertTrue(message.contains("WebSocket handshake"))
            }
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testProxyEngineSendsAnAuthoredFrameThroughTheSelectedLiveWebSocket() async throws {
        let upstream = try await TestWebSocketServer.start()
        let flowEvents = RecordingFlowEventSink()
        let engine = NIOProxyEngine(eventSink: flowEvents)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let upstreamPort = upstream.endpoint.port
            let responsesTask = Task {
                try await WebSocketTestClient.exchangeMessages(
                    url: "ws://127.0.0.1:\(upstreamPort)/echo",
                    through: proxyEndpoint,
                    initialMessage: "hello",
                    expectedResponseCount: 2
                )
            }
            await flowEvents.waitForFlow {
                $0.connection?.protocolKind == .webSocket
            }
            let connectedFlow = await flowEvents.lastFlow {
                $0.connection?.protocolKind == .webSocket
            }
            let flow = try XCTUnwrap(connectedFlow)

            let isOpenBeforeSend = await engine.isConnectionOpen(for: flow.id)
            XCTAssertTrue(isOpenBeforeSend)
            try await engine.send(
                WebSocketFrameTransmission(
                    flowID: flow.id,
                    direction: .clientToServer,
                    opcode: .text,
                    payload: Data("composed".utf8)
                )
            )
            let responses = try await responsesTask.value
            XCTAssertEqual(Set(responses), Set(["echo:hello", "echo:composed"]))

            await flowEvents.waitForFinished()
            let isOpenAfterClose = await engine.isConnectionOpen(for: flow.id)
            XCTAssertFalse(isOpenAfterClose)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testDirectWebSocketClientConnectsReplaysAndPersistsASeparateLiveFlow() async throws {
        let upstream = try await TestWebSocketServer.start()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensWebSocketClientTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let flowEvents = RecordingFlowEventSink()
        let frameEvents = RecordingWebSocketFrameSink()
        let client = NIOWebSocketConnectionClient(
            eventSink: PersistingFlowEventSink(
                flowStore: sessionStore,
                downstream: flowEvents
            ),
            webSocketFrameEventSink: PersistingWebSocketFrameEventSink(
                frameStore: sessionStore,
                downstream: frameEvents
            ),
            bodyStore: bodyStore,
            maximumWebSocketFrameBytes: 1_024
        )
        let sessionID = SessionID()

        do {
            let flow = try await client.connect(
                HTTPRequest(
                    method: .get,
                    url: try XCTUnwrap(
                        URL(string: "ws://127.0.0.1:\(upstream.endpoint.port)/echo")
                    )
                ),
                initialMessage: WebSocketClientMessage(
                    opcode: .text,
                    payload: Data("hello".utf8)
                ),
                sessionID: sessionID
            )

            XCTAssertEqual(flow.sessionID, sessionID)
            XCTAssertEqual(flow.source.kind, .replay)
            XCTAssertEqual(flow.connection?.protocolKind, .webSocket)
            XCTAssertFalse(flow.state.isTerminal)
            let isOpenAfterConnect = await client.isConnectionOpen(for: flow.id)
            XCTAssertTrue(isOpenAfterConnect)

            try await eventually("initial and echoed direct WebSocket frames") {
                await frameEvents.frames().count >= 2
            }
            try await client.send(
                WebSocketFrameTransmission(
                    flowID: flow.id,
                    direction: .clientToServer,
                    opcode: .text,
                    payload: Data("again".utf8)
                )
            )
            try await eventually("composed and echoed direct WebSocket frames") {
                await frameEvents.frames().count >= 4
            }

            let frames = try await sessionStore.listWebSocketFrames(for: flow.id)
            XCTAssertEqual(frames.map(\.sequenceNumber), [1, 2, 3, 4])
            XCTAssertEqual(
                frames.map(\.direction),
                [.clientToServer, .serverToClient, .clientToServer, .serverToClient]
            )
            XCTAssertEqual(frames.map(\.wasMasked), [true, false, true, false])
            var payloads: [Data] = []
            for frame in frames {
                payloads.append(try await bodyStore.read(frame.payload))
            }
            XCTAssertEqual(
                payloads,
                [
                    Data("hello".utf8), Data("echo:hello".utf8),
                    Data("again".utf8), Data("echo:again".utf8)
                ]
            )

            await client.disconnect(flowID: flow.id)
            try await eventually("finished direct WebSocket flow") {
                await flowEvents.snapshot().contains { event in
                    event.flow.id == flow.id && event.flow.state.isTerminal
                }
            }
            let isOpenAfterDisconnect = await client.isConnectionOpen(for: flow.id)
            XCTAssertFalse(isOpenAfterDisconnect)
            let persistedFlow = try await sessionStore.load(flowID: flow.id)
            let persisted = try XCTUnwrap(persistedFlow)
            XCTAssertEqual(persisted.state, .completed)
        } catch {
            await client.shutdown()
            await upstream.stop()
            throw error
        }

        await client.shutdown()
        await upstream.stop()
    }

    func testDirectWebSocketClientConnectsWithVerifiedTLS() async throws {
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.websocket-client-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: "localhost")
        let upstream = try await TestWebSocketServer.startTLS(identity: upstreamIdentity)
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensSecureWebSocketClientTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let frameEvents = RecordingWebSocketFrameSink()
        let client = NIOWebSocketConnectionClient(
            eventSink: PersistingFlowEventSink(flowStore: sessionStore),
            webSocketFrameEventSink: PersistingWebSocketFrameEventSink(
                frameStore: sessionStore,
                downstream: frameEvents
            ),
            bodyStore: bodyStore,
            maximumWebSocketFrameBytes: 1_024,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            )
        )

        do {
            let flow = try await client.connect(
                HTTPRequest(
                    method: .get,
                    url: try XCTUnwrap(
                        URL(string: "wss://localhost:\(upstream.endpoint.port)/echo")
                    )
                ),
                initialMessage: WebSocketClientMessage(
                    opcode: .text,
                    payload: Data("secure".utf8)
                ),
                sessionID: SessionID()
            )

            XCTAssertEqual(flow.source.kind, .replay)
            XCTAssertEqual(flow.connection?.protocolKind, .secureWebSocket)
            XCTAssertNotNil(flow.timing.tlsHandshakeCompletedAt)
            let isOpen = await client.isConnectionOpen(for: flow.id)
            XCTAssertTrue(isOpen)
            try await eventually("secure WebSocket request and echo") {
                await frameEvents.frames().count >= 2
            }
            let frames = try await sessionStore.listWebSocketFrames(for: flow.id)
            var payloads: [Data] = []
            for frame in frames {
                payloads.append(try await bodyStore.read(frame.payload))
            }
            XCTAssertEqual(payloads, [Data("secure".utf8), Data("echo:secure".utf8)])
            await client.disconnect(flowID: flow.id)
        } catch {
            await upstream.stop()
            await client.shutdown()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await upstream.stop()
        await client.shutdown()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testDirectWebSocketClientRejectsFailedUpgradeAndUnsupportedSendDirections() async throws {
        let upstream = try await TestWebSocketServer.start()
        let flowEvents = RecordingFlowEventSink()
        let client = NIOWebSocketConnectionClient(
            eventSink: flowEvents,
            maximumWebSocketFrameBytes: 4
        )

        do {
            do {
                _ = try await client.connect(
                    HTTPRequest(
                        method: .get,
                        url: try XCTUnwrap(
                            URL(string: "ws://127.0.0.1:\(upstream.endpoint.port)/missing")
                        )
                    ),
                    initialMessage: nil,
                    sessionID: SessionID()
                )
                XCTFail("Expected the rejected upgrade to fail")
            } catch let error as WebSocketConnectionError {
                XCTAssertEqual(error, .upgradeRejected(statusCode: 404))
            }
            try await eventually("failed direct WebSocket flow") {
                await flowEvents.snapshot().contains { $0.flow.state.isTerminal }
            }

            let unknownFlowID = FlowID()
            do {
                try await client.send(
                    WebSocketFrameTransmission(
                        flowID: unknownFlowID,
                        direction: .serverToClient,
                        opcode: .text,
                        payload: Data("x".utf8)
                    )
                )
                XCTFail("Expected a client connection to reject To Client")
            } catch let error as WebSocketConnectionError {
                XCTAssertEqual(error, .clientDirectionRequired)
            }
        } catch {
            await client.shutdown()
            await upstream.stop()
            throw error
        }

        await client.shutdown()
        await upstream.stop()
    }

    func testDirectWebSocketClientTimesOutAnIncompleteUpgrade() async throws {
        let upstream = try await TestHTTPServer.startHanging()
        let flowEvents = RecordingFlowEventSink()
        let client = NIOWebSocketConnectionClient(
            eventSink: flowEvents,
            handshakeTimeout: .milliseconds(50)
        )

        do {
            do {
                _ = try await client.connect(
                    HTTPRequest(
                        method: .get,
                        url: try XCTUnwrap(
                            URL(string: "ws://127.0.0.1:\(upstream.endpoint.port)/hang")
                        )
                    ),
                    initialMessage: nil,
                    sessionID: SessionID()
                )
                XCTFail("Expected the incomplete upgrade to time out")
            } catch let error as WebSocketConnectionError {
                XCTAssertEqual(error, .timeout)
            }
            try await eventually("timed-out direct WebSocket flow") {
                await flowEvents.snapshot().contains { $0.flow.state.isTerminal }
            }
        } catch {
            await client.shutdown()
            await upstream.stop()
            throw error
        }

        await client.shutdown()
        await upstream.stop()
    }

    func testDirectWebSocketClientEchoesAndCapturesPeerClose() async throws {
        let upstream = try await TestWebSocketServer.start()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensWebSocketPeerCloseTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let flowEvents = RecordingFlowEventSink()
        let client = NIOWebSocketConnectionClient(
            eventSink: PersistingFlowEventSink(
                flowStore: sessionStore,
                downstream: flowEvents
            ),
            webSocketFrameEventSink: PersistingWebSocketFrameEventSink(
                frameStore: sessionStore
            ),
            bodyStore: bodyStore
        )

        do {
            let flow = try await client.connect(
                HTTPRequest(
                    method: .get,
                    url: try XCTUnwrap(
                        URL(string: "ws://127.0.0.1:\(upstream.endpoint.port)/close")
                    )
                ),
                initialMessage: WebSocketClientMessage(
                    opcode: .text,
                    payload: Data("finish".utf8)
                ),
                sessionID: SessionID()
            )

            try await eventually("peer-closed direct WebSocket flow") {
                await flowEvents.snapshot().contains { event in
                    event.flow.id == flow.id && event.flow.state.isTerminal
                }
            }
            let frames = try await sessionStore.listWebSocketFrames(for: flow.id)
            XCTAssertEqual(frames.map(\.opcode), [.text, .close, .close])
            XCTAssertEqual(
                frames.map(\.direction),
                [.clientToServer, .serverToClient, .clientToServer]
            )
            XCTAssertEqual(frames.map(\.wasMasked), [true, false, true])
            let isOpen = await client.isConnectionOpen(for: flow.id)
            XCTAssertFalse(isOpen)
        } catch {
            await client.shutdown()
            await upstream.stop()
            throw error
        }

        await client.shutdown()
        await upstream.stop()
    }

    func testDirectWebSocketClientAnswersAndCapturesServerPing() async throws {
        let upstream = try await TestWebSocketServer.start()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensWebSocketPingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let frameEvents = RecordingWebSocketFrameSink()
        let client = NIOWebSocketConnectionClient(
            eventSink: PersistingFlowEventSink(flowStore: sessionStore),
            webSocketFrameEventSink: PersistingWebSocketFrameEventSink(
                frameStore: sessionStore,
                downstream: frameEvents
            ),
            bodyStore: bodyStore,
            maximumWebSocketFrameBytes: 1_024
        )

        do {
            let flow = try await client.connect(
                HTTPRequest(
                    method: .get,
                    url: try XCTUnwrap(
                        URL(string: "ws://127.0.0.1:\(upstream.endpoint.port)/ping")
                    )
                ),
                initialMessage: WebSocketClientMessage(
                    opcode: .text,
                    payload: Data("trigger".utf8)
                ),
                sessionID: SessionID()
            )

            do {
                try await eventually("captured ping, pong, and acknowledgement") {
                    await frameEvents.frames().count >= 4
                }
            } catch {
                let observedFrames = await frameEvents.frames()
                XCTFail(
                    "Timed out with frames: \(observedFrames.map { "\($0.sequenceNumber) \($0.direction) \($0.opcode)" })"
                )
                await client.shutdown()
                await upstream.stop()
                return
            }
            let frames = try await sessionStore.listWebSocketFrames(for: flow.id)
            XCTAssertEqual(frames.map(\.sequenceNumber), [1, 2, 3, 4])
            XCTAssertEqual(frames.map(\.opcode), [.text, .ping, .pong, .text])
            XCTAssertEqual(
                frames.map(\.direction),
                [.clientToServer, .serverToClient, .clientToServer, .serverToClient]
            )
            XCTAssertEqual(frames.map(\.wasMasked), [true, false, true, false])
            var payloads: [Data] = []
            for frame in frames {
                payloads.append(try await bodyStore.read(frame.payload))
            }
            XCTAssertEqual(
                payloads,
                [
                    Data("trigger".utf8), Data("health".utf8), Data("health".utf8),
                    Data("pong-received".utf8)
                ]
            )
            await client.disconnect(flowID: flow.id)
            try await eventually("closed ping test WebSocket") {
                await client.isConnectionOpen(for: flow.id) == false
            }
        } catch {
            await client.shutdown()
            await upstream.stop()
            throw error
        }

        await client.shutdown()
        await upstream.stop()
    }

    func testWebSocketRelayUnmasksClientPayloadAndRemasksItForUpstream() throws {
        var maskedPayload = ByteBufferAllocator().buffer(capacity: 5)
        maskedPayload.writeString("hello")
        let original = WebSocketFrame(
            fin: true,
            rsv1: true,
            opcode: .text,
            maskKey: [1, 2, 3, 4],
            data: maskedPayload
        )
        var encoded = ByteBufferAllocator().buffer(capacity: 32)
        let encoder = WebSocketFrameEncoder()
        let encoderChannel = EmbeddedChannel(handler: encoder)
        try encoderChannel.writeOutbound(original)
        while var part = try encoderChannel.readOutbound(as: ByteBuffer.self) {
            encoded.writeBuffer(&part)
        }
        _ = try encoderChannel.finish()
        let decoderChannel = EmbeddedChannel(
            handler: ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 1_024))
        )
        try decoderChannel.writeInbound(encoded)
        let decoded = try XCTUnwrap(decoderChannel.readInbound(as: WebSocketFrame.self))

        let forwarded = WebSocketFrameRelay.forwardedFrame(
            decoded,
            direction: .clientToServer
        )

        XCTAssertTrue(forwarded.fin)
        XCTAssertTrue(forwarded.rsv1)
        XCTAssertEqual(forwarded.opcode, .text)
        XCTAssertNotNil(forwarded.maskKey)
        XCTAssertEqual(String(decoding: forwarded.data.readableBytesView, as: UTF8.self), "hello")
        _ = try decoderChannel.finish()
    }

    func testWebSocketFrameRecorderPersistsBoundedPayloadAndPublishesMetadata()
        async throws
    {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensWebSocketFrameTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies"),
                inlineBodyThreshold: 2,
                maximumCapturedBodyBytes: 4
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let sink = RecordingWebSocketFrameSink()
        let recorder = WebSocketFrameRecorder(
            bodyStore: bodyStore,
            maximumCapturedFrameBytes: 4,
            eventSink: sink
        )
        var data = ByteBufferAllocator().buffer(capacity: 5)
        data.writeString("hello")
        let frame = WebSocketFrame(fin: true, opcode: .text, data: data)
        let flowID = FlowID()

        try await recorder.record(
            frame,
            flowID: flowID,
            sequenceNumber: 7,
            direction: .serverToClient,
            receivedAt: Date(timeIntervalSince1970: 50)
        )

        let frames = await sink.frames()
        let captured = try XCTUnwrap(frames.first)
        XCTAssertEqual(captured.flowID, flowID)
        XCTAssertEqual(captured.sequenceNumber, 7)
        XCTAssertEqual(captured.opcode, .text)
        XCTAssertEqual(captured.direction, .serverToClient)
        XCTAssertEqual(captured.payload.byteCount, 4)
        XCTAssertTrue(captured.payload.isTruncated)
        let persistedPayload = try await bodyStore.read(captured.payload)
        XCTAssertEqual(persistedPayload, Data("hell".utf8))
    }

    func testStreamingBodyRecorderDiscoversGraphQLOperationForExternalBody() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensGraphQLCaptureTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies"),
                inlineBodyThreshold: 4,
                maximumCapturedBodyBytes: 1_024
            )
        )
        let recorder = StreamingBodyRecorder(
            bodyStore: FileBodyStore(database: database),
            metadata: BodyMetadata(contentType: "application/json"),
            maximumByteCount: 1_024,
            discoversGraphQLOperation: true
        )
        let body = Data(
            #"{"query":"query SearchCatalog { catalog { id } }"}"#.utf8
        )

        try await recorder.append(body.prefix(17))
        try await recorder.append(body.dropFirst(17))
        let finalizedReference = try await recorder.finalize()
        let reference = try XCTUnwrap(finalizedReference)
        let operation = await recorder.graphqlOperation(for: reference)

        XCTAssertFalse(reference.isInline)
        XCTAssertEqual(
            operation,
            GraphQLOperationMetadata(kind: .query, name: "SearchCatalog")
        )
    }

    func testRequestReplayClientRepeatsHTTPPostAndCapturesTheResponse() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "replayed")
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensReplayTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies"),
                inlineBodyThreshold: 4,
                maximumCapturedBodyBytes: 1_024
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let requestBytes = Data(#"{"name":"Ada"}"#.utf8)
        let originalBody = try await bodyStore.put(
            requestBytes,
            metadata: BodyMetadata(contentType: "application/json")
        )
        var headers = ProxyLensCore.HTTPHeaders()
        try headers.append(name: "Host", value: "stale.example.com")
        try headers.append(name: "Content-Type", value: "application/json")
        try headers.append(name: "Content-Length", value: "999")
        try headers.append(name: "Proxy-Connection", value: "keep-alive")
        let sessionID = SessionID()
        let client = NIORequestReplayClient(
            bodyStore: bodyStore,
            maximumCapturedBodyBytes: 1_024
        )

        do {
            let flow = try await client.replay(
                HTTPRequest(
                    method: .post,
                    url: URL(
                        string: "http://127.0.0.1:\(upstream.endpoint.port)/echo?source=replay"
                    )!,
                    headers: headers,
                    body: originalBody
                ),
                sessionID: sessionID
            )

            XCTAssertEqual(flow.sessionID, sessionID)
            XCTAssertEqual(flow.source, .replay)
            XCTAssertEqual(flow.state, .completed)
            XCTAssertEqual(flow.response?.statusCode, 200)
            XCTAssertEqual(flow.connection?.protocolKind, .http)
            XCTAssertFalse(flow.connection?.tlsIntercepted ?? true)
            XCTAssertEqual(upstream.requestURI, "/echo?source=replay")
            XCTAssertEqual(
                upstream.requestHeader("Host"),
                "127.0.0.1:\(upstream.endpoint.port)"
            )
            XCTAssertEqual(upstream.requestHeader("Content-Length"), "\(requestBytes.count)")
            XCTAssertNil(upstream.requestHeader("Proxy-Connection"))

            let replayBody = try XCTUnwrap(flow.request.body)
            XCTAssertNotEqual(replayBody.id, originalBody.id)
            let persistedReplayBody = try await bodyStore.read(replayBody)
            XCTAssertEqual(persistedReplayBody, requestBytes)
            let responseBody = try XCTUnwrap(flow.response?.body)
            let persistedResponseBody = try await bodyStore.read(responseBody)
            XCTAssertEqual(
                persistedResponseBody,
                Data("replayed:{\"name\":\"Ada\"}".utf8)
            )

            let oversizedBody = Data(repeating: 0x61, count: 1_025)
            do {
                _ = try await client.replay(
                    HTTPRequest(
                        method: .post,
                        url: URL(
                            string: "http://127.0.0.1:\(upstream.endpoint.port)/too-large"
                        )!,
                        body: BodyReference(inline: oversizedBody)
                    ),
                    sessionID: sessionID
                )
                XCTFail("Expected an oversized replay body to be rejected")
            } catch let error as RequestReplayError {
                XCTAssertEqual(
                    error,
                    .requestBodyTooLarge(byteCount: 1_025, maximumByteCount: 1_024)
                )
            }
            XCTAssertEqual(upstream.requestCount, 1)
        } catch {
            await upstream.stop()
            throw error
        }

        await upstream.stop()
    }

    func testRequestReplayClientRepeatsHTTPSWithVerifiedTLS() async throws {
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.replay-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTPS(
            responseBody: "secure replay",
            identity: upstreamIdentity
        )
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensSecureReplayTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let client = NIORequestReplayClient(
            bodyStore: bodyStore,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            )
        )

        do {
            let flow = try await client.replay(
                HTTPRequest(
                    method: .get,
                    url: URL(
                        string: "https://localhost:\(upstream.endpoint.port)/secure"
                    )!
                ),
                sessionID: SessionID()
            )

            XCTAssertEqual(flow.state, .completed)
            XCTAssertEqual(flow.source, .replay)
            XCTAssertEqual(flow.connection?.protocolKind, .https)
            XCTAssertFalse(flow.connection?.tlsIntercepted ?? true)
            XCTAssertEqual(flow.response?.statusCode, 200)
            let responseBody = try XCTUnwrap(flow.response?.body)
            let persistedResponseBody = try await bodyStore.read(responseBody)
            XCTAssertEqual(persistedResponseBody, Data("secure replay".utf8))
        } catch {
            await upstream.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await upstream.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testRequestReplayClientRecordsTimeoutAsAFailedFlow() async throws {
        let upstream = try await TestHTTPServer.startHanging()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensReplayTimeoutTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let client = NIORequestReplayClient(
            bodyStore: FileBodyStore(database: database),
            responseTimeout: .milliseconds(50)
        )

        do {
            let flow = try await client.replay(
                HTTPRequest(
                    method: .get,
                    url: URL(string: "http://127.0.0.1:\(upstream.endpoint.port)/hang")!
                ),
                sessionID: SessionID()
            )

            XCTAssertEqual(flow.state, .failed(.timeout))
            XCTAssertEqual(flow.source, .replay)
        } catch {
            await upstream.stop()
            throw error
        }

        await upstream.stop()
    }

    func testProxyTargetSupportsAbsoluteAndOriginFormRequests() throws {
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Host", value: "127.0.0.1:8080")

        let absoluteTarget = try ProxyTarget(
            uri: "http://example.com/api/items?query=one%20two",
            headers: headers
        )
        XCTAssertEqual(absoluteTarget.host, "example.com")
        XCTAssertEqual(absoluteTarget.port, 80)
        XCTAssertEqual(absoluteTarget.originForm, "/api/items?query=one%20two")

        let originTarget = try ProxyTarget(uri: "/health?ready=true", headers: headers)
        XCTAssertEqual(originTarget.host, "127.0.0.1")
        XCTAssertEqual(originTarget.port, 8080)
        XCTAssertEqual(originTarget.originForm, "/health?ready=true")

        let mapped = try MappedRemoteHTTPRequest.make(
            originalURL: URL(string: "http://api.example.com/v1/users?x=1")!,
            destination: URL(string: "https://staging.example.com:8443")!
        )
        let mappedTarget = ProxyTarget(mapped)
        XCTAssertEqual(mappedTarget.host, "staging.example.com")
        XCTAssertEqual(mappedTarget.port, 8_443)
        XCTAssertTrue(mappedTarget.usesTLS)
        XCTAssertEqual(mappedTarget.originForm, "/v1/users?x=1")
    }

    func testHTTPConversionPreservesHTTP2DownstreamAndUsesHTTP11Upstream() throws {
        let downstreamVersion = NIOHTTP1.HTTPVersion(major: 2, minor: 0)

        XCTAssertEqual(try HTTPConversion.coreVersion(from: downstreamVersion), .http2)
        XCTAssertEqual(
            HTTPConversion.upstreamVersion(for: downstreamVersion),
            NIOHTTP1.HTTPVersion.http1_1
        )
        XCTAssertEqual(
            HTTPConversion.nioVersion(from: .http2),
            downstreamVersion
        )
    }

    func testHTTPConversionRejectsUnsupportedDownstreamVersion() {
        XCTAssertThrowsError(
            try HTTPConversion.coreVersion(
                from: NIOHTTP1.HTTPVersion(major: 3, minor: 0)
            )
        )
    }

    func testConnectDoesNotRejectCONNECTWhenInterceptionIsDisabled() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            HTTPProxyHandler(
                sessionID: SessionID(),
                eventSink: NoOpFlowEventSink(),
                maxPendingRequestBytes: 1024
            )
        )

        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Host", value: "example.com:443")
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .CONNECT,
            uri: "example.com:443",
            headers: headers
        )

        // Deliberately stop after the head: completing the CONNECT (`.end`) would make the
        // handler dial the origin through a real `ClientBootstrap`, which requires a
        // `SelectableEventLoop` and fatal-errors immediately against `EmbeddedChannel`'s
        // `EmbeddedEventLoop`. The head alone already proves the regression this test
        // guards against: no eager 501/503 the moment CONNECT is no longer intercepted.
        // The end-to-end tunnel behavior is covered by the engine-level tests above.
        _ = try channel.writeInbound(HTTPServerRequestPart.head(head))

        XCTAssertNil(try channel.readOutbound(as: HTTPServerResponsePart.self))
    }

    func testEngineStartsOnEphemeralPortAndStops() async throws {
        let engine = NIOProxyEngine()
        let configuration = ProxyConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
            interceptHTTPS: false
        )

        try await engine.start(configuration: configuration, sessionID: SessionID())

        let runningState = await engine.state()
        guard case .running(let endpoint) = runningState else {
            return XCTFail("Expected the proxy engine to be running")
        }
        XCTAssertGreaterThan(endpoint.port, 0)

        await engine.stop()
        let stoppedState = await engine.state()
        XCTAssertEqual(stoppedState, .stopped)
    }

    func testHTTPForwardingPublishesCompletedFlow() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream response")
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(eventSink: eventSink)
        let sessionID = SessionID()

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: sessionID
            )

            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/hello?from=proxy",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("upstream response".utf8))

            await eventSink.waitForFinished()
            let events = await eventSink.snapshot()
            XCTAssertTrue(
                events.contains { event in
                    if case .started = event {
                        return true
                    }
                    return false
                })

            let finishedFlow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first)

            XCTAssertEqual(finishedFlow.state, .completed)
            XCTAssertEqual(finishedFlow.sessionID, sessionID)
            XCTAssertEqual(finishedFlow.request.method, .get)
            XCTAssertEqual(finishedFlow.request.url.path, "/hello")
            XCTAssertEqual(finishedFlow.response?.statusCode, 200)
            XCTAssertEqual(finishedFlow.connection?.upstreamPort, upstream.endpoint.port)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPDNSSpoofConnectsToLiteralWhilePreservingLogicalRequestIdentity() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "spoofed upstream")
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Local API destination",
                    priority: 10,
                    phase: .connection,
                    matcher: .host(.exact("dns-spoof.test")),
                    action: .dnsSpoof(try DNSSpoofSpec(address: "127.0.0.1"))
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://dns-spoof.test:\(upstream.endpoint.port)/items?id=7",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("spoofed upstream".utf8))
            XCTAssertEqual(upstream.requestURI, "/items?id=7")
            XCTAssertEqual(
                upstream.requestHeader("Host"),
                "dns-spoof.test:\(upstream.endpoint.port)"
            )

            await eventSink.waitForFinished()
            let events = await eventSink.snapshot()
            let finishedFlow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    guard case .finished(let flow) = event else {
                        return nil
                    }
                    return flow
                }.first
            )
            XCTAssertEqual(finishedFlow.request.url.host, "dns-spoof.test")
            XCTAssertEqual(finishedFlow.connection?.upstreamHost, "dns-spoof.test")
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.ruleName), ["Local API destination"])
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.phase), [.connection])
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.outcome), [.applied])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPSDNSSpoofPreservesLogicalSNIAndCertificateValidation() async throws {
        let logicalHost = "secure-dns-spoof.test"
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.dns-spoof-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: logicalHost)
        let upstream = try await TestHTTPServer.startHTTPS(
            responseBody: "secure spoofed upstream",
            identity: upstreamIdentity
        )
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Secure local API destination",
                    priority: 10,
                    phase: .connection,
                    matcher: .host(.exact(logicalHost)),
                    action: .dnsSpoof(try DNSSpoofSpec(address: "127.0.0.1"))
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            certificateProvider: certificateProvider,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            ),
            ruleSnapshot: snapshot
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                try await certificateProvider.removeCertificateAuthority()
                return
            }

            let response = try await HTTPSTestClient.get(
                url: "https://\(logicalHost):\(upstream.endpoint.port)/secure",
                through: proxyEndpoint,
                trustedRootCertificate: rootCertificate
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("secure spoofed upstream".utf8))
            XCTAssertEqual(
                upstream.requestHeader("Host"),
                "\(logicalHost):\(upstream.endpoint.port)"
            )
            await eventSink.waitForFinished()
            let events = await eventSink.snapshot()
            let flow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    guard case .finished(let flow) = event else {
                        return nil
                    }
                    return flow
                }.first
            )
            XCTAssertEqual(flow.request.url.host, logicalHost)
            XCTAssertEqual(flow.connection?.upstreamHost, logicalHost)
            XCTAssertEqual(flow.connection?.tlsIntercepted, true)
            XCTAssertEqual(flow.ruleTraces.map(\.phase), [.connection])
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testWebSocketDNSSpoofRoutesUpgradeWithoutChangingLogicalHost() async throws {
        let logicalHost = "socket-dns-spoof.test"
        let upstream = try await TestWebSocketServer.start()
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Local WebSocket destination",
                    priority: 10,
                    phase: .connection,
                    matcher: .host(.exact(logicalHost)),
                    action: .dnsSpoof(try DNSSpoofSpec(address: "127.0.0.1"))
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await WebSocketTestClient.exchange(
                url: "ws://\(logicalHost):\(upstream.endpoint.port)/echo",
                through: proxyEndpoint,
                message: "spoofed hello"
            )

            XCTAssertEqual(response, "echo:spoofed hello")
            XCTAssertEqual(
                upstream.requestHeader("Host"),
                "\(logicalHost):\(upstream.endpoint.port)"
            )
            try await eventually("a finished DNS-spoofed WebSocket flow") {
                await eventSink.snapshot().contains { event in
                    if case .finished = event {
                        return true
                    }
                    return false
                }
            }
            let events = await eventSink.snapshot()
            let flow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    guard case .finished(let flow) = event else {
                        return nil
                    }
                    return flow
                }.first
            )
            XCTAssertEqual(flow.request.url.host, logicalHost)
            XCTAssertEqual(flow.connection?.upstreamHost, logicalHost)
            XCTAssertEqual(flow.connection?.protocolKind, .webSocket)
            XCTAssertEqual(flow.ruleTraces.map(\.ruleName), ["Local WebSocket destination"])
            XCTAssertEqual(flow.ruleTraces.map(\.phase), [.connection])
            XCTAssertEqual(flow.ruleTraces.map(\.outcome), [.applied])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testSOCKS5ListenerCapturesPlainHTTPWithDestinationIdentity() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "SOCKS response")
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(eventSink: eventSink)
        let socks = try SOCKS5ListenerConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
            isEnabled: true
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false,
                    socks5Listener: socks
                ),
                sessionID: SessionID()
            )
            let boundSOCKSEndpoint = await engine.socks5Endpoint()
            let socksEndpoint = try XCTUnwrap(boundSOCKSEndpoint)
            let response = try await SOCKS5TestClient.get(
                path: "/through-socks?value=1",
                destination: upstream.endpoint,
                through: socksEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("SOCKS response".utf8))
            XCTAssertEqual(upstream.requestURI, "/through-socks?value=1")
            await eventSink.waitForFinished()
            let events = await eventSink.snapshot()
            let flow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    guard case .finished(let flow) = event else { return nil }
                    return flow
                }.first
            )
            XCTAssertEqual(flow.source.kind, .socks5Proxy)
            XCTAssertEqual(flow.source.label, "SOCKS5 Proxy")
            XCTAssertEqual(flow.request.url.host, upstream.endpoint.host)
            XCTAssertEqual(flow.request.url.port, Int(upstream.endpoint.port))
            XCTAssertEqual(flow.connection?.protocolKind, .http)
            XCTAssertEqual(flow.connection?.tlsIntercepted, false)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testSOCKS5ListenerInterceptsHTTPSWithDestinationIdentity() async throws {
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.socks-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTPS(
            responseBody: "secure SOCKS response",
            identity: upstreamIdentity
        )
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            certificateProvider: certificateProvider,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            )
        )
        let socks = try SOCKS5ListenerConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
            isEnabled: true
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true,
                    socks5Listener: socks
                ),
                sessionID: SessionID()
            )
            let boundSOCKSEndpoint = await engine.socks5Endpoint()
            let socksEndpoint = try XCTUnwrap(boundSOCKSEndpoint)
            let response = try await SOCKS5TestClient.getHTTPS(
                path: "/secure-socks",
                destinationHost: "localhost",
                destinationPort: upstream.endpoint.port,
                through: socksEndpoint,
                trustedRootCertificate: rootCertificate
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("secure SOCKS response".utf8))
            await eventSink.waitForFinished()
            let events = await eventSink.snapshot()
            let flow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    guard case .finished(let flow) = event else { return nil }
                    return flow
                }.first
            )
            XCTAssertEqual(flow.source.kind, .socks5Proxy)
            XCTAssertEqual(flow.request.url.scheme, "https")
            XCTAssertEqual(flow.request.url.host, "localhost")
            XCTAssertEqual(flow.connection?.upstreamHost, "localhost")
            XCTAssertEqual(flow.connection?.tlsIntercepted, true)
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testSOCKS5PassthroughForExcludedHostDeliversOriginCertificate() async throws {
        let originProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.ssl-list-socks.\(UUID().uuidString)"
            )
        )
        let originRoot = try await originProvider.rootCertificate()
        let originIdentity = try await originProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTPS(
            responseBody: "socks origin",
            identity: originIdentity
        )
        let engineProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.ssl-list-socks-ca.\(UUID().uuidString)"
            )
        )
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            certificateProvider: engineProvider,
            tlsInterceptionPolicy: MutableTLSInterceptionPolicy(
                policy: try TLSInterceptionPolicy(mode: .interceptAllExcept, entries: ["localhost"])
            )
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true,
                    socks5Listener: SOCKS5ListenerConfiguration(
                        listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                        isEnabled: true
                    )
                ),
                sessionID: SessionID()
            )
            guard case .running = await engine.state(),
                let socksEndpoint = await engine.socks5Endpoint()
            else {
                XCTFail("Expected the SOCKS5 listener to be running")
                await upstream.stop()
                return
            }

            // Trusts ONLY the origin root: succeeds only if the proxy did not re-terminate
            // TLS on the SOCKS path either.
            let response = try await SOCKS5TestClient.getHTTPS(
                path: "/pinned",
                destinationHost: "localhost",
                destinationPort: upstream.endpoint.port,
                through: socksEndpoint,
                trustedRootCertificate: originRoot
            )
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("socks origin".utf8))

            await eventSink.waitForFinished()
            let tunnelFlow = await eventSink.lastFlow { $0.state == .completed }
            let tunnel = try XCTUnwrap(tunnelFlow)
            XCTAssertEqual(tunnel.request.method, .connect)
            XCTAssertEqual(tunnel.connection?.tlsIntercepted, false)
            XCTAssertEqual(tunnel.connection?.protocolKind, .https)
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await engineProvider.removeCertificateAuthority()
            try? await originProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await engineProvider.removeCertificateAuthority()
        try await originProvider.removeCertificateAuthority()
    }

    func testSOCKS5PassthroughUpstreamFailureFailsTheTunnelFlow() async throws {
        let eventSink = RecordingFlowEventSink()
        let policy = MutableTLSInterceptionPolicy(
            policy: try TLSInterceptionPolicy(mode: .interceptAllExcept, entries: ["127.0.0.1"])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, tlsInterceptionPolicy: policy)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false,
                    socks5Listener: SOCKS5ListenerConfiguration(
                        listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                        isEnabled: true
                    )
                ),
                sessionID: SessionID()
            )
            guard case .running = await engine.state(),
                let socksEndpoint = await engine.socks5Endpoint()
            else {
                XCTFail("Expected the SOCKS5 listener to be running")
                return
            }

            // Port 1 on loopback: nothing listens there, the raw dial must fail. The SOCKS
            // success reply is already sent by the time the dial is attempted, so the client
            // only observes the raw connection closing once it looks enough like TLS for the
            // server to classify and act on it.
            try await SOCKS5TestClient.expectConnectionClosedAfterTLSPrefix(
                destinationHost: "127.0.0.1",
                destinationPort: 1,
                through: socksEndpoint
            )

            await eventSink.waitForFinished()
            let failedFlow = await eventSink.lastFlow {
                if case .failed = $0.state { return true }
                return false
            }
            let failed = try XCTUnwrap(failedFlow)
            XCTAssertEqual(failed.request.method, .connect)
            XCTAssertEqual(failed.state, .failed(.upstreamUnavailable))
        } catch {
            await engine.stop()
            throw error
        }

        await engine.stop()
    }

    func testSOCKS5ListenerStartupRollsBackAtomically() async throws {
        let occupiedListener = try await TestHTTPServer.start(responseBody: "occupied")
        let socks = try SOCKS5ListenerConfiguration(
            listenEndpoint: occupiedListener.endpoint,
            isEnabled: true
        )
        let configuration = ProxyConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
            interceptHTTPS: false,
            socks5Listener: socks
        )
        let engine = NIOProxyEngine()

        do {
            do {
                try await engine.start(configuration: configuration, sessionID: SessionID())
                XCTFail("Expected the occupied SOCKS5 listener to fail startup")
            } catch {
                guard case .failed = await engine.state() else {
                    return XCTFail("Expected a failed engine state after listener rollback")
                }
            }

            await occupiedListener.stop()
            try await engine.start(configuration: configuration, sessionID: SessionID())
            let boundSOCKSEndpoint = await engine.socks5Endpoint()
            XCTAssertNotNil(boundSOCKSEndpoint)
        } catch {
            await engine.stop()
            await occupiedListener.stop()
            throw error
        }

        await engine.stop()
    }

    func testReverseProxyRoutesOriginFormAndIgnoresClientHostForUpstreamRouting() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "reverse response")
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(eventSink: eventSink)
        let route = try ReverseProxyRoute(
            name: "Local API",
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
            upstreamURL: try XCTUnwrap(
                URL(string: "http://127.0.0.1:\(upstream.endpoint.port)/v1")
            )
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false,
                    reverseProxyRoutes: [route]
                ),
                sessionID: SessionID()
            )
            let reverseEndpoints = await engine.reverseProxyEndpoints()
            let reverseEndpoint = try XCTUnwrap(reverseEndpoints[route.id])

            let response = try await HTTPTestClient.get(
                url: "/users%20active?id=7",
                through: reverseEndpoint,
                extraHeaders: [("Host", "attacker.invalid")]
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("reverse response".utf8))
            XCTAssertEqual(upstream.requestURI, "/v1/users%20active?id=7")
            XCTAssertEqual(
                upstream.requestHeader("Host"),
                "127.0.0.1:\(upstream.endpoint.port)"
            )

            await eventSink.waitForFinished()
            let events = await eventSink.snapshot()
            let flow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    guard case .finished(let flow) = event else { return nil }
                    return flow
                }.first
            )
            XCTAssertEqual(flow.source.kind, .reverseProxy)
            XCTAssertEqual(flow.source.label, "Reverse Proxy: Local API")
            XCTAssertEqual(flow.request.url.path, "/v1/users active")
            XCTAssertEqual(flow.request.rawTarget, "/users%20active?id=7")
            XCTAssertEqual(flow.connection?.tlsIntercepted, false)

            let connectResponse = try await HTTPTestClient.connect(
                authority: "example.com:443",
                through: reverseEndpoint
            )
            XCTAssertEqual(connectResponse.statusCode, 405)
            XCTAssertEqual(upstream.requestCount, 1)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testReverseProxyUsesLogicalHTTPSIdentityWithDNSSpoofing() async throws {
        let logicalHost = "reverse-secure.test"
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.reverse-proxy-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: logicalHost)
        let upstream = try await TestHTTPServer.startHTTP2(
            responseBody: "secure reverse response",
            identity: upstreamIdentity
        )
        let eventSink = RecordingFlowEventSink()
        let rules = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Resolve secure reverse target",
                    priority: 10,
                    phase: .connection,
                    matcher: .host(.exact(logicalHost)),
                    action: .dnsSpoof(try DNSSpoofSpec(address: "127.0.0.1"))
                )
            ])
        )
        let route = try ReverseProxyRoute(
            name: "Secure API",
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
            upstreamURL: try XCTUnwrap(
                URL(string: "https://\(logicalHost):\(upstream.endpoint.port)/api")
            )
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            ),
            ruleSnapshot: rules
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false,
                    reverseProxyRoutes: [route]
                ),
                sessionID: SessionID()
            )
            let reverseEndpoints = await engine.reverseProxyEndpoints()
            let reverseEndpoint = try XCTUnwrap(reverseEndpoints[route.id])
            let response = try await HTTPTestClient.get(
                url: "/health",
                through: reverseEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("secure reverse response".utf8))
            XCTAssertEqual(upstream.requestURI, "/api/health")
            XCTAssertEqual(
                upstream.requestHeader("Host"),
                "\(logicalHost):\(upstream.endpoint.port)"
            )

            await eventSink.waitForFinished()
            let events = await eventSink.snapshot()
            let flow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    guard case .finished(let flow) = event else { return nil }
                    return flow
                }.first
            )
            XCTAssertEqual(flow.request.url.host, logicalHost)
            XCTAssertEqual(flow.connection?.upstreamHost, logicalHost)
            XCTAssertEqual(flow.connection?.protocolKind, .https)
            XCTAssertEqual(flow.connection?.tlsIntercepted, false)
            XCTAssertEqual(flow.connection?.upstreamHTTPVersion, .http2)
            XCTAssertEqual(flow.ruleTraces.map(\.ruleName), ["Resolve secure reverse target"])
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testReverseProxyRoutesWebSocketUpgradeThroughSharedCapturePipeline() async throws {
        let upstream = try await TestWebSocketServer.start()
        let eventSink = RecordingFlowEventSink()
        let route = try ReverseProxyRoute(
            name: "Socket API",
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
            upstreamURL: try XCTUnwrap(
                URL(string: "http://127.0.0.1:\(upstream.endpoint.port)")
            )
        )
        let engine = NIOProxyEngine(eventSink: eventSink)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false,
                    reverseProxyRoutes: [route]
                ),
                sessionID: SessionID()
            )
            let reverseEndpoints = await engine.reverseProxyEndpoints()
            let reverseEndpoint = try XCTUnwrap(reverseEndpoints[route.id])
            let response = try await WebSocketTestClient.exchange(
                url: "ws://127.0.0.1:\(upstream.endpoint.port)/echo",
                through: reverseEndpoint,
                message: "reverse hello",
                requestURI: "/echo",
                hostHeader: "attacker.invalid"
            )

            XCTAssertEqual(response, "echo:reverse hello")
            XCTAssertEqual(upstream.requestURI, "/echo")
            XCTAssertEqual(
                upstream.requestHeader("Host"),
                "127.0.0.1:\(upstream.endpoint.port)"
            )
            try await eventually("a finished reverse WebSocket flow") {
                await eventSink.snapshot().contains { event in
                    if case .finished = event { return true }
                    return false
                }
            }
            let events = await eventSink.snapshot()
            let flow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    guard case .finished(let flow) = event else { return nil }
                    return flow
                }.first
            )
            XCTAssertEqual(flow.source.kind, .reverseProxy)
            XCTAssertEqual(flow.connection?.protocolKind, .webSocket)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testReverseProxyListenerStartupRollsBackAtomically() async throws {
        let occupiedListener = try await TestHTTPServer.start(responseBody: "occupied")
        let upstream = try await TestHTTPServer.start(responseBody: "available")
        let route = try ReverseProxyRoute(
            name: "Fixed listener",
            listenEndpoint: occupiedListener.endpoint,
            upstreamURL: try XCTUnwrap(
                URL(string: "http://127.0.0.1:\(upstream.endpoint.port)")
            )
        )
        let configuration = ProxyConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
            interceptHTTPS: false,
            reverseProxyRoutes: [route]
        )
        let engine = NIOProxyEngine()

        do {
            do {
                try await engine.start(configuration: configuration, sessionID: SessionID())
                XCTFail("Expected the occupied reverse listener to fail startup")
            } catch {
                guard case .failed = await engine.state() else {
                    XCTFail("Expected a failed engine state after listener rollback")
                    await occupiedListener.stop()
                    await upstream.stop()
                    return
                }
            }

            await occupiedListener.stop()
            try await engine.start(configuration: configuration, sessionID: SessionID())
            let reverseEndpoints = await engine.reverseProxyEndpoints()
            XCTAssertNotNil(reverseEndpoints[route.id])
        } catch {
            await engine.stop()
            await occupiedListener.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPForwardingAttachesTheResolvedApplicationSource() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "attributed response")
        let eventSink = RecordingFlowEventSink()
        let expectedSource = FlowSource(
            kind: .desktopProxy,
            label: "Safari",
            clientAddress: "127.0.0.1:54321",
            application: FlowApplication(
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                processIdentifier: 101
            )
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            flowSourceResolver: FixedFlowSourceResolver(source: expectedSource)
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            _ = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/attributed",
                through: proxyEndpoint
            )
            await eventSink.waitForFinished()

            let events = await eventSink.snapshot()
            let finishedFlow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            XCTAssertEqual(finishedFlow.source, expectedSource)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPBlockRuleReturnsForbiddenWithoutConnectingUpstream() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "should not be reached")
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Block fixture",
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .block(reason: "blocked fixture")
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)
        let sessionID = SessionID()

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: sessionID
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/blocked",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 403)
            XCTAssertEqual(String(data: response.body, encoding: .utf8), "blocked fixture\n")
            XCTAssertEqual(upstream.requestCount, 0)

            await eventSink.waitForFinished()
            let blockedEvents = await eventSink.snapshot()
            let finishedFlow = try XCTUnwrap(
                blockedEvents.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            XCTAssertEqual(finishedFlow.state, .completed)
            XCTAssertEqual(finishedFlow.response?.statusCode, 403)
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.ruleName), ["Block fixture"])
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.outcome), [.applied])
            XCTAssertNil(finishedFlow.timing.upstreamConnectedAt)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPMapLocalRuleReturnsFileWithoutConnectingUpstream() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "should not be reached")
        let eventSink = RecordingFlowEventSink()
        let body = Data(#"{"mapped":true}"#.utf8)
        let spec = MapLocalSpec(
            resourceID: "users.json",
            filePath: "/tmp/users.json",
            statusCode: 201,
            reasonPhrase: "Created",
            body: BodyReference(
                inline: body,
                metadata: BodyMetadata(contentType: "application/json")
            )
        )
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map local users",
                    priority: 15,
                    phase: .requestHeaders,
                    matcher: .allOf([
                        .host(.exact("127.0.0.1")),
                        .path(.exact("/users"))
                    ]),
                    action: .mapLocal(resourceID: spec.resourceID)
                )
            ]),
            mappedLocals: [spec]
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)
        let sessionID = SessionID()

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: sessionID
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/users",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 201)
            XCTAssertEqual(response.body, body)
            XCTAssertEqual(response.header("Content-Type"), "application/json")
            XCTAssertEqual(upstream.requestCount, 0)

            await eventSink.waitForFinished()
            let mappedEvents = await eventSink.snapshot()
            let finishedFlow = try XCTUnwrap(
                mappedEvents.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            XCTAssertEqual(finishedFlow.state, .completed)
            XCTAssertEqual(finishedFlow.response?.statusCode, 201)
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.ruleName), ["Map local users"])
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.outcome), [.applied])
            XCTAssertNil(finishedFlow.timing.upstreamConnectedAt)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPMapLocalRuleAppliesNoCacheToTheMappedResponse() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "should not be reached")
        let eventSink = RecordingFlowEventSink()
        let spec = MapLocalSpec(
            resourceID: "asset.js",
            statusCode: 200,
            headers: HTTPHeaders([
                try HTTPHeader(name: "Cache-Control", value: "public, max-age=3600"),
                try HTTPHeader(name: "ETag", value: "\"abc\"")
            ]),
            body: BodyReference(
                inline: Data("mapped asset".utf8),
                metadata: BodyMetadata(contentType: "text/javascript")
            )
        )
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Allow fixture",
                    priority: 0,
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .allow
                ),
                Rule(
                    name: "Map local asset",
                    priority: 15,
                    phase: .requestHeaders,
                    matcher: .path(.exact("/asset.js")),
                    action: .mapLocal(resourceID: spec.resourceID)
                ),
                Rule(
                    name: "No cache request",
                    priority: 20,
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .noCache
                )
            ]),
            mappedLocals: [spec]
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/asset.js",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("mapped asset".utf8))
            XCTAssertEqual(
                response.header("Cache-Control"),
                "no-store, no-cache, must-revalidate, max-age=0"
            )
            XCTAssertEqual(response.header("Pragma"), "no-cache")
            XCTAssertNil(response.header("ETag"))
            XCTAssertEqual(upstream.requestCount, 0)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPMapRemoteRuleForwardsToAnotherHostWithoutCallingTheOriginal() async throws {
        let original = try await TestHTTPServer.start(responseBody: "original upstream")
        let mapped = try await TestHTTPServer.start(responseBody: "mapped upstream")
        let eventSink = RecordingFlowEventSink()
        let destination = URL(string: "http://127.0.0.1:\(mapped.endpoint.port)")!
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map remote users",
                    priority: 15,
                    phase: .requestHeaders,
                    matcher: .allOf([
                        .host(.exact("127.0.0.1")),
                        .path(.exact("/users"))
                    ]),
                    action: .mapRemote(url: destination)
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await original.stop()
                await mapped.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(original.endpoint.port)/users?id=1",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("mapped upstream".utf8))
            XCTAssertEqual(original.requestCount, 0)
            XCTAssertEqual(mapped.requestCount, 1)
            XCTAssertEqual(mapped.requestURI, "/users?id=1")
            XCTAssertEqual(
                mapped.requestHeader("Host"),
                "127.0.0.1:\(mapped.endpoint.port)"
            )

            await eventSink.waitForFinished()
            let mappedEvents = await eventSink.snapshot()
            let finishedFlow = try XCTUnwrap(
                mappedEvents.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            XCTAssertEqual(finishedFlow.state, .completed)
            XCTAssertEqual(finishedFlow.request.url.path, "/users")
            XCTAssertEqual(finishedFlow.connection?.upstreamPort, mapped.endpoint.port)
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.ruleName), ["Map remote users"])
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.outcome), [.applied])
            XCTAssertNotNil(finishedFlow.timing.upstreamConnectedAt)
        } catch {
            await engine.stop()
            await original.stop()
            await mapped.stop()
            throw error
        }

        await engine.stop()
        await original.stop()
        await mapped.stop()
    }

    func testHTTPRedirectRuleReturnsTemporaryRedirectWithoutCallingUpstream() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "must not be called")
        let eventSink = RecordingFlowEventSink()
        let destination = URL(string: "https://login.example.com/continue?from=proxy")!
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Redirect login",
                    priority: 14,
                    phase: .requestHeaders,
                    matcher: .allOf([
                        .host(.exact("127.0.0.1")),
                        .path(.exact("/login"))
                    ]),
                    action: .redirect(url: destination)
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/login?source=client",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 307)
            XCTAssertEqual(response.header("Location"), destination.absoluteString)
            XCTAssertEqual(response.body, Data())
            XCTAssertEqual(upstream.requestCount, 0)

            await eventSink.waitForFinished()
            let completed = await eventSink.lastFlow { $0.state == .completed }
            let finished = try XCTUnwrap(completed)
            XCTAssertEqual(finished.response?.statusCode, 307)
            XCTAssertEqual(finished.ruleTraces.map(\.ruleName), ["Redirect login"])
            XCTAssertEqual(finished.ruleTraces.map(\.outcome), [.applied])
            XCTAssertNil(finished.timing.upstreamConnectedAt)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPThrottleRuleDelaysUpstreamConnectionWithoutBlockingCapture() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "delayed upstream")
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Throttle local fixture",
                    priority: 17,
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .throttle(ThrottleProfile(latency: 0.2))
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let startedAt = ContinuousClock.now
            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/slow",
                through: proxyEndpoint
            )
            let elapsed = startedAt.duration(to: .now)

            XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(150))
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("delayed upstream".utf8))
            XCTAssertEqual(upstream.requestCount, 1)

            await eventSink.waitForFinished()
            let completed = await eventSink.lastFlow { $0.state == .completed }
            let finished = try XCTUnwrap(completed)
            XCTAssertEqual(finished.ruleTraces.map(\.ruleName), ["Throttle local fixture"])
            XCTAssertEqual(finished.ruleTraces.map(\.outcome), [.applied])
            XCTAssertNotNil(finished.timing.upstreamConnectedAt)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPThrottleRuleCanSimulateLostConnectionWithoutCallingUpstream() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "should not arrive")
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Lost connection",
                    priority: 17,
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .throttle(ThrottleProfile(packetLossPercentage: 100))
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            do {
                _ = try await HTTPTestClient.get(
                    url: "http://127.0.0.1:\(upstream.endpoint.port)/lost",
                    through: proxyEndpoint
                )
                XCTFail("Expected the simulated lost connection to close without a response")
            } catch {
                // Expected: packet loss closes the client connection before an HTTP response.
            }

            XCTAssertEqual(upstream.requestCount, 0)
            await eventSink.waitForFinished()
            let failed = await eventSink.lastFlow {
                $0.state == .failed(.simulatedNetworkFailure)
            }
            let finished = try XCTUnwrap(failed)
            XCTAssertEqual(finished.ruleTraces.map(\.ruleName), ["Lost connection"])
            XCTAssertEqual(finished.ruleTraces.map(\.outcome), [.applied])
            XCTAssertNil(finished.timing.upstreamConnectedAt)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPThrottleRuleShapesUploadBandwidth() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "uploaded")
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Slow upload",
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .throttle(
                        ThrottleProfile(uploadBytesPerSecond: 16_384)
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let body = Data(repeating: 0x61, count: 8_192)
            let startedAt = ContinuousClock.now
            let response = try await HTTPTestClient.post(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/upload",
                body: body,
                through: proxyEndpoint
            )
            let elapsed = startedAt.duration(to: .now)

            XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(400))
            XCTAssertEqual(response.body, Data("uploaded:".utf8) + body)
            XCTAssertEqual(upstream.requestCount, 1)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPThrottleRuleShapesDownloadBandwidth() async throws {
        let responseText = String(repeating: "d", count: 8_192)
        let upstream = try await TestHTTPServer.start(responseBody: responseText)
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Slow download",
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .throttle(
                        ThrottleProfile(downloadBytesPerSecond: 16_384)
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let startedAt = ContinuousClock.now
            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/download",
                through: proxyEndpoint
            )
            let elapsed = startedAt.duration(to: .now)

            XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(400))
            XCTAssertEqual(response.body, Data(responseText.utf8))
            XCTAssertEqual(upstream.requestCount, 1)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPMapRemoteRuleReplacesPathAndAppliesNoCache() async throws {
        let original = try await TestHTTPServer.start(responseBody: "original upstream")
        let mapped = try await TestHTTPServer.start(responseBody: "mapped mock")
        let eventSink = RecordingFlowEventSink()
        let destination = URL(
            string: "http://127.0.0.1:\(mapped.endpoint.port)/mock/users"
        )!
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Allow fixture",
                    priority: 0,
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .allow
                ),
                Rule(
                    name: "Map remote users",
                    priority: 15,
                    phase: .requestHeaders,
                    matcher: .path(.exact("/users")),
                    action: .mapRemote(url: destination)
                ),
                Rule(
                    name: "No cache request",
                    priority: 20,
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .noCache
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await original.stop()
                await mapped.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(original.endpoint.port)/users?id=1",
                through: proxyEndpoint,
                extraHeaders: [("If-None-Match", "\"abc\"")]
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("mapped mock".utf8))
            XCTAssertEqual(original.requestCount, 0)
            XCTAssertEqual(mapped.requestCount, 1)
            XCTAssertEqual(mapped.requestURI, "/mock/users")
            XCTAssertEqual(mapped.requestHeader("Cache-Control"), "no-cache")
            XCTAssertEqual(mapped.requestHeader("Pragma"), "no-cache")
            XCTAssertNil(mapped.requestHeader("If-None-Match"))
        } catch {
            await engine.stop()
            await original.stop()
            await mapped.stop()
            throw error
        }

        await engine.stop()
        await original.stop()
        await mapped.stop()
    }

    func testHTTPAllowRuleOverridesLaterCatchAllBlock() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "allowed upstream")
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Allow fixture",
                    priority: 0,
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .allow
                ),
                Rule(
                    name: "Block all",
                    priority: 10,
                    phase: .requestHeaders,
                    action: .block(reason: "blocked by default")
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/allowed",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("allowed upstream".utf8))
            XCTAssertEqual(upstream.requestCount, 1)

            await eventSink.waitForFinished()
            let allowedEvents = await eventSink.snapshot()
            let finishedFlow = try XCTUnwrap(
                allowedEvents.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.ruleName), ["Allow fixture", "Block all"])
            XCTAssertEqual(
                finishedFlow.ruleTraces.map(\.outcome),
                [
                    .applied,
                    .skipped(reason: RulePlanner.Decision.alreadyDecidedReason)
                ]
            )
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPNoCacheRuleRewritesRequestAndResponseHeaders() async throws {
        let upstream = try await TestHTTPServer.start(
            responseBody: "cached asset",
            extraResponseHeaders: [
                ("Cache-Control", "public, max-age=3600"),
                ("ETag", "\"abc\""),
                ("Age", "12")
            ]
        )
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "No cache request",
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .noCache
                ),
                Rule(
                    name: "No cache response",
                    phase: .responseHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .noCache
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/asset.js",
                through: proxyEndpoint,
                extraHeaders: [("If-None-Match", "\"abc\"")]
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(upstream.requestHeader("Cache-Control"), "no-cache")
            XCTAssertEqual(upstream.requestHeader("Pragma"), "no-cache")
            XCTAssertNil(upstream.requestHeader("If-None-Match"))
            XCTAssertEqual(
                response.header("Cache-Control"),
                "no-store, no-cache, must-revalidate, max-age=0"
            )
            XCTAssertEqual(response.header("Pragma"), "no-cache")
            XCTAssertEqual(response.header("Expires"), "0")
            XCTAssertNil(response.header("ETag"))
            XCTAssertNil(response.header("Age"))

            await eventSink.waitForFinished()
            let noCacheEvents = await eventSink.snapshot()
            let finishedFlow = try XCTUnwrap(
                noCacheEvents.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            XCTAssertEqual(
                finishedFlow.request.headers.firstValue(for: "Cache-Control"),
                "no-cache"
            )
            XCTAssertEqual(
                finishedFlow.response?.headers.firstValue(for: "Cache-Control"),
                "no-store, no-cache, must-revalidate, max-age=0"
            )
            XCTAssertEqual(
                finishedFlow.ruleTraces.map(\.ruleName),
                ["No cache request", "No cache response"]
            )
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPRequestBreakpointHoldsUpstreamUntilContinue() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream response")
        let eventSink = RecordingFlowEventSink()
        let coordinator = BreakpointCoordinator()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Breakpoint fixture",
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .breakpoint
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            breakpointGate: coordinator
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let upstreamPort = upstream.endpoint.port
            async let clientResponse = HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstreamPort)/paused",
                through: proxyEndpoint
            )
            await eventSink.waitForFlow { $0.state == .paused(.request) }
            XCTAssertEqual(upstream.requestCount, 0)

            let paused = await eventSink.lastFlow { $0.state == .paused(.request) }
            let pausedFlow = try XCTUnwrap(paused)
            let pendingHit = await coordinator.hit(for: pausedFlow.id)
            let hit = try XCTUnwrap(pendingHit)
            await coordinator.resume(flowID: hit.flowID, decision: .continue(hit))

            let response = try await clientResponse
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("upstream response".utf8))
            XCTAssertEqual(upstream.requestCount, 1)

            await eventSink.waitForFinished()
            let finished = await eventSink.lastFlow { $0.state == .completed }
            let finishedFlow = try XCTUnwrap(finished)
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.ruleName), ["Breakpoint fixture"])
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.outcome), [.applied])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testGraphQLOperationBreakpointDiscoversBodyBeforeConnectingUpstream() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream response")
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensGraphQLBreakpointTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let eventSink = RecordingFlowEventSink()
        let coordinator = BreakpointCoordinator()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Breakpoint GraphQL mutation SaveProfile",
                    phase: .requestBody,
                    matcher: .graphqlOperation(
                        name: .exact("SaveProfile"),
                        kind: .mutation
                    ),
                    action: .breakpoint
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            bodyStore: FileBodyStore(database: database),
            ruleSnapshot: snapshot,
            breakpointGate: coordinator
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let body = Data(
                #"{"query":"mutation SaveProfile { saveProfile { id } }"}"#.utf8
            )
            let upstreamPort = upstream.endpoint.port
            async let clientResponse = HTTPTestClient.post(
                url: "http://127.0.0.1:\(upstreamPort)/graphql",
                body: body,
                through: proxyEndpoint,
                extraHeaders: [("Content-Type", "application/json")]
            )
            await eventSink.waitForFlow { $0.state == .paused(.request) }
            XCTAssertEqual(upstream.requestCount, 0)

            let paused = await eventSink.lastFlow { $0.state == .paused(.request) }
            let pausedFlow = try XCTUnwrap(paused)
            XCTAssertEqual(
                pausedFlow.request.graphqlOperation,
                GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
            )
            let pendingHit = await coordinator.hit(for: pausedFlow.id)
            let hit = try XCTUnwrap(pendingHit)
            await coordinator.resume(flowID: hit.flowID, decision: .continue(hit))

            let response = try await clientResponse
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(upstream.requestCount, 1)
            await eventSink.waitForFinished()
            let completed = await eventSink.lastFlow { $0.state == .completed }
            let finished = try XCTUnwrap(completed)
            XCTAssertEqual(
                finished.ruleTraces.map(\.ruleName),
                ["Breakpoint GraphQL mutation SaveProfile"]
            )
            XCTAssertEqual(finished.ruleTraces.map(\.phase), [.requestBody])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testGraphQLOperationBlockReturnsForbiddenBeforeConnectingUpstream() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "should not be reached")
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensGraphQLBlockTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Block GraphQL mutation SaveProfile",
                    phase: .requestBody,
                    matcher: .graphqlOperation(
                        name: .exact("SaveProfile"),
                        kind: .mutation
                    ),
                    action: .block(reason: "Blocked GraphQL operation")
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            bodyStore: FileBodyStore(database: database),
            ruleSnapshot: snapshot
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.post(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/graphql",
                body: Data(
                    #"{"query":"mutation SaveProfile { saveProfile { id } }"}"#.utf8
                ),
                through: proxyEndpoint,
                extraHeaders: [("Content-Type", "application/json")]
            )

            XCTAssertEqual(response.statusCode, 403)
            XCTAssertEqual(upstream.requestCount, 0)
            await eventSink.waitForFinished()
            let completed = await eventSink.lastFlow { $0.state == .completed }
            let finished = try XCTUnwrap(completed)
            XCTAssertEqual(
                finished.request.graphqlOperation,
                GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
            )
            XCTAssertEqual(
                finished.ruleTraces.map(\.ruleName),
                [
                    "Block GraphQL mutation SaveProfile"
                ])
            XCTAssertEqual(finished.ruleTraces.map(\.phase), [.requestBody])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testGraphQLOperationMapLocalReturnsFixtureBeforeConnectingUpstream() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "should not be reached")
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensGraphQLMapLocalTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let eventSink = RecordingFlowEventSink()
        let mappedBody = Data(#"{"data":{"catalog":[]}}"#.utf8)
        let spec = MapLocalSpec(
            resourceID: "catalog.json",
            statusCode: 201,
            reasonPhrase: "Created",
            body: BodyReference(
                inline: mappedBody,
                metadata: BodyMetadata(contentType: "application/json")
            )
        )
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map local GraphQL query Catalog",
                    phase: .requestBody,
                    matcher: .graphqlOperation(name: .exact("Catalog"), kind: .query),
                    action: .mapLocal(resourceID: spec.resourceID)
                )
            ]),
            mappedLocals: [spec]
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            bodyStore: FileBodyStore(database: database),
            ruleSnapshot: snapshot
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.post(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/graphql",
                body: Data(#"{"query":"query Catalog { catalog { id } }"}"#.utf8),
                through: proxyEndpoint,
                extraHeaders: [("Content-Type", "application/json")]
            )

            XCTAssertEqual(response.statusCode, 201)
            XCTAssertEqual(response.body, mappedBody)
            XCTAssertEqual(response.header("Content-Type"), "application/json")
            XCTAssertEqual(upstream.requestCount, 0)
            await eventSink.waitForFinished()
            let completed = await eventSink.lastFlow { $0.state == .completed }
            let finished = try XCTUnwrap(completed)
            XCTAssertEqual(
                finished.request.graphqlOperation,
                GraphQLOperationMetadata(kind: .query, name: "Catalog")
            )
            XCTAssertEqual(
                finished.ruleTraces.map(\.ruleName),
                [
                    "Map local GraphQL query Catalog"
                ])
            XCTAssertNil(finished.timing.upstreamConnectedAt)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testGraphQLOperationMapRemoteConnectsToMappedUpstream() async throws {
        let original = try await TestHTTPServer.start(responseBody: "original upstream")
        let mapped = try await TestHTTPServer.start(responseBody: "mapped upstream")
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensGraphQLMapRemoteTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let eventSink = RecordingFlowEventSink()
        let destination = URL(string: "http://127.0.0.1:\(mapped.endpoint.port)")!
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Map remote GraphQL mutation SaveProfile",
                    phase: .requestBody,
                    matcher: .graphqlOperation(
                        name: .exact("SaveProfile"),
                        kind: .mutation
                    ),
                    action: .mapRemote(url: destination)
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            bodyStore: FileBodyStore(database: database),
            ruleSnapshot: snapshot
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await original.stop()
                await mapped.stop()
                return
            }

            let requestBody = Data(
                #"{"query":"mutation SaveProfile { saveProfile { id } }"}"#.utf8
            )
            let response = try await HTTPTestClient.post(
                url: "http://127.0.0.1:\(original.endpoint.port)/graphql?source=client",
                body: requestBody,
                through: proxyEndpoint,
                extraHeaders: [("Content-Type", "application/json")]
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(
                response.body,
                Data("mapped upstream:\(String(decoding: requestBody, as: UTF8.self))".utf8)
            )
            XCTAssertEqual(original.requestCount, 0)
            XCTAssertEqual(mapped.requestCount, 1)
            XCTAssertEqual(mapped.requestURI, "/graphql?source=client")
            XCTAssertEqual(mapped.requestHeader("Host"), "127.0.0.1:\(mapped.endpoint.port)")
            await eventSink.waitForFinished()
            let completed = await eventSink.lastFlow { $0.state == .completed }
            let finished = try XCTUnwrap(completed)
            XCTAssertEqual(finished.request.url.port, Int(original.endpoint.port))
            XCTAssertEqual(
                finished.request.graphqlOperation,
                GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
            )
            XCTAssertEqual(finished.connection?.upstreamHost, "127.0.0.1")
            XCTAssertEqual(finished.connection?.upstreamPort, mapped.endpoint.port)
            XCTAssertEqual(
                finished.ruleTraces.map(\.ruleName),
                ["Map remote GraphQL mutation SaveProfile"]
            )
            XCTAssertEqual(finished.ruleTraces.map(\.phase), [.requestBody])
        } catch {
            await engine.stop()
            await original.stop()
            await mapped.stop()
            throw error
        }

        await engine.stop()
        await original.stop()
        await mapped.stop()
    }

    func testGraphQLOperationBodyReplacementForwardsEditedBytesAndPreservesCapture()
        async throws
    {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream")
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensGraphQLReplaceBodyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let eventSink = RecordingFlowEventSink()
        let originalBody = Data(
            #"{"query":"mutation SaveProfile { saveProfile { id } }"}"#.utf8
        )
        let replacementBody = Data(#"{"name":"Ada"}"#.utf8)
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Replace body GraphQL mutation SaveProfile",
                    phase: .requestBody,
                    matcher: .graphqlOperation(
                        name: .exact("SaveProfile"),
                        kind: .mutation
                    ),
                    action: .replaceBody(
                        body: BodyReference(
                            inline: replacementBody,
                            metadata: BodyMetadata(contentType: "application/json")
                        )
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            bodyStore: bodyStore,
            ruleSnapshot: snapshot
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.post(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/graphql",
                body: originalBody,
                through: proxyEndpoint,
                extraHeaders: [("Content-Type", "application/json")]
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(
                response.body,
                Data("upstream:\(String(decoding: replacementBody, as: UTF8.self))".utf8)
            )
            XCTAssertEqual(upstream.requestCount, 1)
            XCTAssertEqual(upstream.requestHeader("Content-Length"), "\(replacementBody.count)")
            XCTAssertEqual(upstream.requestHeader("Content-Type"), "application/json")
            await eventSink.waitForFinished()
            let completed = await eventSink.lastFlow { $0.state == .completed }
            let finished = try XCTUnwrap(completed)
            let capturedBody = try XCTUnwrap(finished.request.body)
            let capturedBytes = try await bodyStore.read(capturedBody)
            XCTAssertEqual(capturedBytes, originalBody)
            XCTAssertEqual(
                finished.request.graphqlOperation,
                GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
            )
            XCTAssertEqual(
                finished.ruleTraces.map(\.ruleName),
                ["Replace body GraphQL mutation SaveProfile"]
            )
            XCTAssertEqual(finished.ruleTraces.map(\.phase), [.requestBody])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHostPathBodyReplacementForwardsWithoutGraphQLMetadata() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream")
        let eventSink = RecordingFlowEventSink()
        let replacementBody = Data("replacement".utf8)
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Replace body local fixture",
                    phase: .requestBody,
                    matcher: .allOf([
                        .host(.exact("127.0.0.1")),
                        .path(.exact("/replace"))
                    ]),
                    action: .replaceBody(
                        body: BodyReference(
                            inline: replacementBody,
                            metadata: BodyMetadata(contentType: "text/plain; charset=utf-8")
                        )
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.post(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/replace?source=client",
                body: Data("original".utf8),
                through: proxyEndpoint,
                extraHeaders: [("Content-Type", "application/octet-stream")]
            )

            XCTAssertEqual(response.body, Data("upstream:replacement".utf8))
            XCTAssertEqual(upstream.requestHeader("Content-Length"), "\(replacementBody.count)")
            XCTAssertEqual(upstream.requestHeader("Content-Type"), "text/plain; charset=utf-8")
            await eventSink.waitForFinished()
            let completed = await eventSink.lastFlow { $0.state == .completed }
            let finished = try XCTUnwrap(completed)
            XCTAssertNil(finished.request.graphqlOperation)
            XCTAssertEqual(finished.ruleTraces.map(\.ruleName), ["Replace body local fixture"])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHostPathResponseBodyReplacementPreservesUpstreamCapture() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "original upstream")
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensResponseReplaceBodyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let eventSink = RecordingFlowEventSink()
        let replacementBody = Data(#"{"mocked":true}"#.utf8)
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Replace response body local fixture",
                    phase: .responseBody,
                    matcher: .allOf([
                        .host(.exact("127.0.0.1")),
                        .path(.exact("/replace-response")),
                        .status(200)
                    ]),
                    action: .replaceBody(
                        body: BodyReference(
                            inline: replacementBody,
                            metadata: BodyMetadata(contentType: "application/json")
                        )
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            bodyStore: bodyStore,
            ruleSnapshot: snapshot
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/replace-response",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, replacementBody)
            XCTAssertEqual(response.header("Content-Length"), "\(replacementBody.count)")
            XCTAssertEqual(response.header("Content-Type"), "application/json")
            await eventSink.waitForFinished()
            let completed = await eventSink.lastFlow { $0.state == .completed }
            let finished = try XCTUnwrap(completed)
            let capturedBody = try XCTUnwrap(finished.response?.body)
            let capturedBytes = try await bodyStore.read(capturedBody)
            XCTAssertEqual(capturedBytes, Data("original upstream".utf8))
            XCTAssertEqual(
                finished.ruleTraces.map(\.ruleName),
                ["Replace response body local fixture"]
            )
            XCTAssertEqual(finished.ruleTraces.map(\.phase), [.responseBody])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testRequestBodyScriptMutatesForwardedTextMessage() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream")
        let eventSink = RecordingFlowEventSink()
        let scriptExecutor = StubScriptExecutor { request in
            XCTAssertEqual(request.hook, .request)
            XCTAssertEqual(request.message.body, "original")
            return try ScriptExecutionResult(
                hook: .request,
                message: ScriptHTTPMessage(
                    method: request.message.method,
                    url: request.message.url,
                    headers: request.message.headers + [
                        try HTTPHeader(name: "X-ProxyLens-Script", value: "request")
                    ],
                    body: "scripted"
                ),
                logs: ["request changed"]
            )
        }
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Rewrite request text",
                    phase: .requestBody,
                    matcher: .path(.exact("/script-request")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onRequest(context) {}")
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            scriptExecutor: scriptExecutor
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let response = try await HTTPTestClient.post(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/script-request",
                body: Data("original".utf8),
                through: proxyEndpoint,
                extraHeaders: [("Content-Type", "text/plain; charset=utf-8")]
            )

            XCTAssertEqual(response.body, Data("upstream:scripted".utf8))
            XCTAssertEqual(upstream.requestHeader("X-ProxyLens-Script"), "request")
            XCTAssertEqual(upstream.requestHeader("Content-Length"), "8")
            await eventSink.waitForFinished()
            let completedFlow = await eventSink.lastFlow { $0.state == .completed }
            let flow = try XCTUnwrap(completedFlow)
            XCTAssertEqual(flow.ruleTraces.map(\.ruleName), ["Rewrite request text"])
            XCTAssertEqual(flow.ruleTraces.map(\.outcome), [.applied])
            XCTAssertEqual(flow.ruleTraces.map(\.logs), [["request changed"]])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testRequestHeaderScriptMutatesForwardedHeadersAndKeepsCaptureAuthoritative() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream")
        let eventSink = RecordingFlowEventSink()
        let scriptExecutor = StubScriptExecutor { request in
            XCTAssertEqual(request.hook, .request)
            XCTAssertNil(request.message.body)
            return try ScriptExecutionResult(
                hook: .request,
                message: ScriptHTTPMessage(
                    method: request.message.method,
                    url: request.message.url,
                    headers: request.message.headers.filter {
                        $0.name.caseInsensitiveCompare("Content-Length") != .orderedSame
                    } + [
                        try HTTPHeader(name: "X-ProxyLens-Header-Script", value: "request"),
                        try HTTPHeader(name: "Content-Length", value: "999")
                    ]
                ),
                logs: ["request headers changed"]
            )
        }
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Rewrite request headers",
                    phase: .requestHeaders,
                    matcher: .path(.exact("/script-request-headers")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onRequest(context) {}")
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            scriptExecutor: scriptExecutor
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let response = try await HTTPTestClient.post(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/script-request-headers",
                body: Data("original".utf8),
                through: proxyEndpoint
            )

            XCTAssertEqual(response.body, Data("upstream:original".utf8))
            XCTAssertEqual(upstream.requestHeader("X-ProxyLens-Header-Script"), "request")
            XCTAssertEqual(upstream.requestHeader("Content-Length"), "8")
            await eventSink.waitForFinished()
            let completedFlow = await eventSink.lastFlow { $0.state == .completed }
            let flow = try XCTUnwrap(completedFlow)
            XCTAssertNil(flow.request.headers.firstValue(for: "X-ProxyLens-Header-Script"))
            XCTAssertEqual(flow.ruleTraces.map(\.phase), [.requestHeaders])
            XCTAssertEqual(flow.ruleTraces.map(\.outcome), [.applied])
            XCTAssertEqual(flow.ruleTraces.map(\.logs), [["request headers changed"]])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testRequestHeaderScriptRejectsBodyMutationAndFailsOpen() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream")
        let eventSink = RecordingFlowEventSink()
        let scriptExecutor = StubScriptExecutor { request in
            try ScriptExecutionResult(
                hook: .request,
                message: ScriptHTTPMessage(
                    method: request.message.method,
                    url: request.message.url,
                    headers: request.message.headers + [
                        try HTTPHeader(name: "X-Must-Not-Apply", value: "true")
                    ],
                    body: "forbidden"
                )
            )
        }
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Invalid header script",
                    phase: .requestHeaders,
                    action: .script(
                        try ScriptRuleSpec(source: "function onRequest(context) {}")
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            scriptExecutor: scriptExecutor
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/script-invalid-headers",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertNil(upstream.requestHeader("X-Must-Not-Apply"))
            await eventSink.waitForFinished()
            let completedFlow = await eventSink.lastFlow { $0.state == .completed }
            let flow = try XCTUnwrap(completedFlow)
            XCTAssertEqual(flow.ruleTraces.map(\.phase), [.requestHeaders])
            guard case .failed(let message) = try XCTUnwrap(flow.ruleTraces.first?.outcome) else {
                return XCTFail("Expected the invalid header script to fail open")
            }
            XCTAssertTrue(message.contains("body"))
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testBodyScriptRunnerKeepsLogsWithOwningRulesInOrder() async throws {
        let scripts = [
            PlannedScript(
                ruleID: RuleID(),
                ruleName: "First script",
                spec: try ScriptRuleSpec(source: "first")
            ),
            PlannedScript(
                ruleID: RuleID(),
                ruleName: "Second script",
                spec: try ScriptRuleSpec(source: "second")
            )
        ]
        let executor = StubScriptExecutor { request in
            let name = request.source == "first" ? "first" : "second"
            return try ScriptExecutionResult(
                hook: request.hook,
                message: ScriptHTTPMessage(
                    statusCode: request.message.statusCode,
                    headers: request.message.headers,
                    body: (request.message.body ?? "") + name
                ),
                logs: ["\(name) started", "\(name) finished"]
            )
        }

        let result = await BodyScriptRunner.run(
            scripts: scripts,
            hook: .response,
            initialMessage: ScriptHTTPMessage(statusCode: 200, body: ""),
            executor: executor
        )

        XCTAssertEqual(result.message.body, "firstsecond")
        XCTAssertEqual(result.traces.map(\.ruleName), ["First script", "Second script"])
        XCTAssertEqual(
            result.traces.map(\.logs),
            [
                ["first started", "first finished"],
                ["second started", "second finished"]
            ]
        )
    }

    func testHeaderScriptRequestConversionRejectsInvalidProxyTarget() throws {
        let original = HTTPRequest(
            method: .get,
            url: try XCTUnwrap(URL(string: "https://example.com/original"))
        )
        let edited = ScriptHTTPMessage(
            method: "GET",
            url: "https://example.com/edited#fragment"
        )

        XCTAssertThrowsError(
            try HeaderScriptRunner.request(from: edited, preserving: original)
        ) { error in
            XCTAssertEqual(
                error as? ProxyTargetError,
                .invalidURI("https://example.com/edited#fragment")
            )
        }
    }

    func testWebSocketHeaderScriptRunnerKeepsLastValidMutationInOrder() async throws {
        let scripts = [
            PlannedScript(
                ruleID: RuleID(),
                ruleName: "Safe handshake script",
                spec: try ScriptRuleSpec(source: "safe")
            ),
            PlannedScript(
                ruleID: RuleID(),
                ruleName: "Invalid handshake script",
                spec: try ScriptRuleSpec(source: "invalid")
            )
        ]
        let initialMessage = ScriptHTTPMessage(
            method: "GET",
            url: "ws://example.test/echo",
            headers: [
                try HTTPHeader(name: "Host", value: "example.test"),
                try HTTPHeader(name: "Connection", value: "Upgrade"),
                try HTTPHeader(name: "Upgrade", value: "websocket"),
                try HTTPHeader(name: "Sec-WebSocket-Key", value: "fixture-key"),
                try HTTPHeader(name: "Sec-WebSocket-Version", value: "13")
            ]
        )
        let executor = StubScriptExecutor { request in
            let isSafe = request.source == "safe"
            return try ScriptExecutionResult(
                hook: .request,
                message: ScriptHTTPMessage(
                    method: isSafe ? request.message.method : "POST",
                    url: request.message.url,
                    headers: request.message.headers + [
                        try HTTPHeader(
                            name: isSafe ? "X-Safe" : "X-Must-Not-Apply",
                            value: "true"
                        )
                    ]
                )
            )
        }

        let result = await HeaderScriptRunner.run(
            scripts: scripts,
            hook: .request,
            phase: .requestHeaders,
            initialMessage: initialMessage,
            executor: executor,
            policy: .webSocketHandshake
        )

        XCTAssertEqual(result.message.method, "GET")
        XCTAssertEqual(
            result.message.headers.first { $0.name == "X-Safe" }?.value,
            "true"
        )
        XCTAssertNil(result.message.headers.first { $0.name == "X-Must-Not-Apply" })
        XCTAssertEqual(result.traces.first?.outcome, .applied)
        guard case .failed(let message) = try XCTUnwrap(result.traces.last?.outcome) else {
            return XCTFail("Expected the invalid later script to fail open")
        }
        XCTAssertTrue(message.contains("WebSocket handshake"))
    }

    func testResponseBodyScriptMutatesForwardedTextMessage() async throws {
        let upstream = try await TestHTTPServer.start(
            responseBody: "original response",
            extraResponseHeaders: [("Content-Type", "application/json")]
        )
        let eventSink = RecordingFlowEventSink()
        let scriptExecutor = StubScriptExecutor { request in
            XCTAssertEqual(request.hook, .response)
            XCTAssertEqual(request.message.body, "original response")
            return try ScriptExecutionResult(
                hook: .response,
                message: ScriptHTTPMessage(
                    statusCode: 201,
                    headers: request.message.headers + [
                        try HTTPHeader(name: "X-ProxyLens-Script", value: "response")
                    ],
                    body: #"{"scripted":true}"#
                )
            )
        }
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Rewrite response JSON",
                    phase: .responseBody,
                    matcher: .path(.exact("/script-response")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onResponse(context) {}")
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            scriptExecutor: scriptExecutor
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/script-response",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 201)
            XCTAssertEqual(response.body, Data(#"{"scripted":true}"#.utf8))
            XCTAssertEqual(response.header("X-ProxyLens-Script"), "response")
            XCTAssertEqual(response.header("Content-Length"), "17")
            await eventSink.waitForFinished()
            let completedFlow = await eventSink.lastFlow { $0.state == .completed }
            let flow = try XCTUnwrap(completedFlow)
            XCTAssertEqual(flow.response?.statusCode, 200)
            XCTAssertEqual(flow.ruleTraces.map(\.ruleName), ["Rewrite response JSON"])
            XCTAssertEqual(flow.ruleTraces.map(\.outcome), [.applied])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testResponseHeaderScriptMutatesForwardedHeadAndKeepsCaptureAuthoritative() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "original response")
        let eventSink = RecordingFlowEventSink()
        let scriptExecutor = StubScriptExecutor { request in
            XCTAssertEqual(request.hook, .response)
            XCTAssertNil(request.message.body)
            try await Task.sleep(for: .milliseconds(50))
            return try ScriptExecutionResult(
                hook: .response,
                message: ScriptHTTPMessage(
                    statusCode: 202,
                    headers: request.message.headers.filter {
                        $0.name.caseInsensitiveCompare("Content-Length") != .orderedSame
                    } + [
                        try HTTPHeader(name: "X-ProxyLens-Header-Script", value: "response"),
                        try HTTPHeader(name: "Content-Length", value: "999")
                    ]
                ),
                logs: ["response headers changed"]
            )
        }
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Rewrite response headers",
                    phase: .responseHeaders,
                    matcher: .path(.exact("/script-response-headers")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onResponse(context) {}")
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            scriptExecutor: scriptExecutor
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/script-response-headers",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 202)
            XCTAssertEqual(response.body, Data("original response".utf8))
            XCTAssertEqual(response.header("X-ProxyLens-Header-Script"), "response")
            XCTAssertEqual(response.header("Content-Length"), "17")
            await eventSink.waitForFinished()
            let completedFlow = await eventSink.lastFlow { $0.state == .completed }
            let flow = try XCTUnwrap(completedFlow)
            XCTAssertEqual(flow.response?.statusCode, 200)
            XCTAssertNil(flow.response?.headers.firstValue(for: "X-ProxyLens-Header-Script"))
            XCTAssertEqual(flow.ruleTraces.map(\.phase), [.responseHeaders])
            XCTAssertEqual(flow.ruleTraces.map(\.outcome), [.applied])
            XCTAssertEqual(flow.ruleTraces.map(\.logs), [["response headers changed"]])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testFailingResponseBodyScriptForwardsOriginalAndRecordsFailure() async throws {
        let upstream = try await TestHTTPServer.start(
            responseBody: "original response",
            extraResponseHeaders: [("Content-Type", "text/plain")]
        )
        let eventSink = RecordingFlowEventSink()
        let scriptExecutor = StubScriptExecutor { _ in
            throw ScriptExecutionError.javaScriptException("fixture failed")
        }
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Failing response script",
                    phase: .responseBody,
                    action: .script(
                        try ScriptRuleSpec(source: "function onResponse(context) {}")
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            scriptExecutor: scriptExecutor
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/script-failure",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("original response".utf8))
            await eventSink.waitForFinished()
            let completedFlow = await eventSink.lastFlow { $0.state == .completed }
            let flow = try XCTUnwrap(completedFlow)
            XCTAssertEqual(flow.ruleTraces.map(\.ruleName), ["Failing response script"])
            XCTAssertEqual(
                flow.ruleTraces.map(\.outcome),
                [.failed(message: "JavaScript failed: fixture failed")]
            )
            XCTAssertEqual(flow.ruleTraces.map(\.logs), [[]])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testFailingRequestBodyScriptForwardsOriginalAndRecordsFailure() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream")
        let eventSink = RecordingFlowEventSink()
        let scriptExecutor = StubScriptExecutor { _ in
            throw ScriptExecutionError.javaScriptException("fixture failed")
        }
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Failing request script",
                    phase: .requestBody,
                    action: .script(
                        try ScriptRuleSpec(source: "function onRequest(context) {}")
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            scriptExecutor: scriptExecutor
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let response = try await HTTPTestClient.post(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/script-failure",
                body: Data("original".utf8),
                through: proxyEndpoint,
                extraHeaders: [("Content-Type", "text/plain")]
            )

            XCTAssertEqual(response.body, Data("upstream:original".utf8))
            await eventSink.waitForFinished()
            let completedFlow = await eventSink.lastFlow { $0.state == .completed }
            let flow = try XCTUnwrap(completedFlow)
            XCTAssertEqual(flow.ruleTraces.map(\.ruleName), ["Failing request script"])
            XCTAssertEqual(
                flow.ruleTraces.map(\.outcome),
                [.failed(message: "JavaScript failed: fixture failed")]
            )
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPRequestBreakpointAbortDoesNotCallUpstream() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "should not be reached")
        let eventSink = RecordingFlowEventSink()
        let coordinator = BreakpointCoordinator()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Breakpoint fixture",
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .breakpoint
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            breakpointGate: coordinator
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let upstreamPort = upstream.endpoint.port
            async let clientResponse = HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstreamPort)/aborted",
                through: proxyEndpoint
            )
            await eventSink.waitForFlow { $0.state == .paused(.request) }
            let paused = await eventSink.lastFlow { $0.state == .paused(.request) }
            let pausedFlow = try XCTUnwrap(paused)
            await coordinator.abort(flowID: pausedFlow.id)

            let response = try await clientResponse
            XCTAssertEqual(response.statusCode, 403)
            XCTAssertEqual(
                String(data: response.body, encoding: .utf8), "Aborted at breakpoint\r\n")
            XCTAssertEqual(upstream.requestCount, 0)

            await eventSink.waitForFinished()
            let finished = await eventSink.lastFlow { $0.state.isTerminal }
            let finishedFlow = try XCTUnwrap(finished)
            XCTAssertEqual(finishedFlow.state, .cancelled)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPRequestBreakpointAppliesEditedPathAndBody() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream")
        let eventSink = RecordingFlowEventSink()
        let coordinator = BreakpointCoordinator()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Breakpoint fixture",
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .breakpoint
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            breakpointGate: coordinator
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let upstreamPort = upstream.endpoint.port
            async let clientResponse = HTTPTestClient.post(
                url: "http://127.0.0.1:\(upstreamPort)/original",
                body: Data("before".utf8),
                through: proxyEndpoint
            )
            await eventSink.waitForFlow { $0.state == .paused(.request) }
            let paused = await eventSink.lastFlow { $0.state == .paused(.request) }
            let pausedFlow = try XCTUnwrap(paused)
            let pendingHit = await coordinator.hit(for: pausedFlow.id)
            let hit = try XCTUnwrap(pendingHit)
            let host = try XCTUnwrap(hit.request.headers.firstValue(for: "Host"))
            let edited = try HTTPMessageText.parseRequest(
                headersText: """
                    POST /edited HTTP/1.1
                    Host: \(host)
                    Content-Type: text/plain
                    """,
                body: Data("after".utf8),
                original: hit.request
            )
            await coordinator.resume(
                flowID: hit.flowID,
                decision: .continue(
                    BreakpointHit(
                        flowID: hit.flowID,
                        phase: .request,
                        request: edited
                    )
                )
            )

            let response = try await clientResponse
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("upstream:after".utf8))
            XCTAssertEqual(upstream.requestURI, "/edited")
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPResponseBreakpointHoldsClientUntilContinueAndAppliesEdits() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream response")
        let eventSink = RecordingFlowEventSink()
        let coordinator = BreakpointCoordinator()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Breakpoint response",
                    phase: .responseHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .breakpoint
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            breakpointGate: coordinator
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let upstreamPort = upstream.endpoint.port
            async let clientResponse = HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstreamPort)/response-pause",
                through: proxyEndpoint
            )
            await eventSink.waitForFlow { $0.state == .paused(.response) }
            XCTAssertEqual(upstream.requestCount, 1)

            let paused = await eventSink.lastFlow { $0.state == .paused(.response) }
            let pausedFlow = try XCTUnwrap(paused)
            let pendingHit = await coordinator.hit(for: pausedFlow.id)
            let hit = try XCTUnwrap(pendingHit)
            let originalResponse = try XCTUnwrap(hit.response)
            let edited = try HTTPMessageText.parseResponse(
                headersText: """
                    HTTP/1.1 201 Created
                    Content-Type: text/plain; charset=utf-8
                    """,
                body: Data("patched".utf8),
                original: originalResponse
            )
            await coordinator.resume(
                flowID: hit.flowID,
                decision: .continue(
                    BreakpointHit(
                        flowID: hit.flowID,
                        phase: .response,
                        request: hit.request,
                        response: edited
                    )
                )
            )

            let response = try await clientResponse
            XCTAssertEqual(response.statusCode, 201)
            XCTAssertEqual(response.body, Data("patched".utf8))

            await eventSink.waitForFinished()
            let finished = await eventSink.lastFlow { $0.state == .completed }
            let finishedFlow = try XCTUnwrap(finished)
            XCTAssertEqual(finishedFlow.response?.statusCode, 201)
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.ruleName), ["Breakpoint response"])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPResponseBodyReplacementSurvivesAnUneditedBreakpointContinue() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "original upstream")
        let eventSink = RecordingFlowEventSink()
        let coordinator = BreakpointCoordinator()
        let replacementBody = Data("replacement response".utf8)
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Breakpoint response",
                    phase: .responseHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .breakpoint
                ),
                Rule(
                    name: "Replace response body",
                    phase: .responseBody,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .replaceBody(
                        body: BodyReference(
                            inline: replacementBody,
                            metadata: BodyMetadata(contentType: "text/plain; charset=utf-8")
                        )
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            breakpointGate: coordinator
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let upstreamPort = upstream.endpoint.port
            async let clientResponse = HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstreamPort)/response-replace-pause",
                through: proxyEndpoint
            )
            await eventSink.waitForFlow { $0.state == .paused(.response) }
            let paused = await eventSink.lastFlow { $0.state == .paused(.response) }
            let pausedFlow = try XCTUnwrap(paused)
            let pendingHit = await coordinator.hit(for: pausedFlow.id)
            let hit = try XCTUnwrap(pendingHit)
            await coordinator.resume(flowID: hit.flowID, decision: .continue(hit))

            let response = try await clientResponse
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, replacementBody)
            XCTAssertEqual(response.header("Content-Length"), "\(replacementBody.count)")
            await eventSink.waitForFinished()
            let completed = await eventSink.lastFlow { $0.state == .completed }
            let finished = try XCTUnwrap(completed)
            XCTAssertEqual(
                finished.ruleTraces.map(\.ruleName),
                ["Breakpoint response", "Replace response body"]
            )
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPResponseBreakpointFailsWhenUpstreamDropsIncompleteResponse() async throws {
        let upstream = try await TestHTTPServer.startDroppingAfterPartialResponse()
        let eventSink = RecordingFlowEventSink()
        let coordinator = BreakpointCoordinator()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Breakpoint response",
                    phase: .responseHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .breakpoint
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            breakpointGate: coordinator
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/drop",
                through: proxyEndpoint
            )
            XCTAssertEqual(response.statusCode, 502)

            await eventSink.waitForFinished()
            let finished = await eventSink.lastFlow { flow in
                if case .failed = flow.state {
                    return true
                }
                return false
            }
            let finishedFlow = try XCTUnwrap(finished)
            let pendingHit = await coordinator.hit(for: finishedFlow.id)
            XCTAssertNil(pendingHit)
            guard case .failed(let failure) = finishedFlow.state else {
                return XCTFail("Expected the incomplete breakpoint response to fail the flow")
            }
            switch failure {
            case .protocolError:
                break
            default:
                XCTFail("Expected a protocol error, got \(failure)")
            }
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPBreakpointRuleContinuesImmediatelyWithoutACoordinator() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream response")
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Breakpoint fixture",
                    phase: .requestHeaders,
                    matcher: .host(.exact("127.0.0.1")),
                    action: .breakpoint
                )
            ])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, ruleSnapshot: snapshot)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/auto-continue",
                through: proxyEndpoint
            )
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("upstream response".utf8))

            await eventSink.waitForFinished()
            let finished = await eventSink.lastFlow { $0.state == .completed }
            let finishedFlow = try XCTUnwrap(finished)
            XCTAssertEqual(finishedFlow.ruleTraces.map(\.outcome), [.applied])
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPForwardingStreamsAndPersistsRawBodies() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream response")
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensCaptureTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies"),
                inlineBodyThreshold: 4,
                maximumCapturedBodyBytes: 1_024
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let eventRecorder = RecordingFlowEventSink()
        let persistenceSink = PersistingFlowEventSink(
            flowStore: sessionStore,
            downstream: eventRecorder
        )
        let engine = NIOProxyEngine(
            eventSink: persistenceSink,
            bodyStore: bodyStore,
            maximumCapturedBodyBytes: 1_024
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ), sessionID: SessionID())

            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let requestBytes = Data("request body".utf8)
            let expectedResponseBytes = Data("upstream response:request body".utf8)
            let response = try await HTTPTestClient.post(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/echo",
                body: requestBytes,
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, expectedResponseBytes)

            await eventRecorder.waitForFinished()
            let events = await eventRecorder.snapshot()
            let finishedFlow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            let loadedFlow = try await sessionStore.load(flowID: finishedFlow.id)
            let persistedFlow = try XCTUnwrap(loadedFlow)
            let requestBody = try XCTUnwrap(persistedFlow.request.body)
            let responseBody = try XCTUnwrap(persistedFlow.response?.body)
            let persistedRequestBytes = try await bodyStore.read(requestBody)
            let persistedResponseBytes = try await bodyStore.read(responseBody)

            XCTAssertEqual(persistedFlow.state, .completed)
            XCTAssertEqual(persistedRequestBytes, requestBytes)
            XCTAssertEqual(persistedResponseBytes, expectedResponseBytes)
            XCTAssertFalse(requestBody.isTruncated)
            XCTAssertFalse(responseBody.isTruncated)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testClientDisconnectAfterRequestEndPreservesIncompleteFlow() async throws {
        let upstream = try await TestHTTPServer.startHanging()
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(eventSink: eventSink)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ), sessionID: SessionID())
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            try await HTTPTestClient.postThenDisconnect(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/hang",
                body: Data("complete request".utf8),
                through: proxyEndpoint
            )
            await eventSink.waitForFinished()
            let events = await eventSink.snapshot()
            let finishedFlow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            XCTAssertEqual(finishedFlow.state, .failed(.clientDisconnected))
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testHTTPSConnectInterceptionPersistsCompletedFlowAcrossReopen() async throws {
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.capture-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTPS(
            responseBody: "secure upstream response",
            identity: upstreamIdentity
        )
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensHTTPSCaptureTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let persistenceConfiguration = DatabaseConfiguration(
            databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
            bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies"),
            inlineBodyThreshold: 4
        )
        let database = try DatabaseController(configuration: persistenceConfiguration)
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let eventRecorder = RecordingFlowEventSink()
        let persistenceSink = PersistingFlowEventSink(
            flowStore: sessionStore,
            downstream: eventRecorder
        )
        let engine = NIOProxyEngine(
            eventSink: persistenceSink,
            bodyStore: bodyStore,
            certificateProvider: certificateProvider,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            )
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ), sessionID: SessionID())

            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                try await certificateProvider.removeCertificateAuthority()
                return
            }

            let expectedResponseBytes = Data("secure upstream response".utf8)
            let response = try await HTTPSTestClient.get(
                url: "https://localhost:\(upstream.endpoint.port)/secure?from=proxy",
                through: proxyEndpoint,
                trustedRootCertificate: rootCertificate
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, expectedResponseBytes)

            await eventRecorder.waitForFinished()
            let events = await eventRecorder.snapshot()
            let finishedFlow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first
            )
            let reopenedDatabase = try DatabaseController(
                configuration: persistenceConfiguration
            )
            let reopenedBodyStore = FileBodyStore(database: reopenedDatabase)
            let reopenedSessionStore = GRDBSessionStore(
                database: reopenedDatabase,
                bodyStore: reopenedBodyStore
            )
            let loadedFlow = try await reopenedSessionStore.load(flowID: finishedFlow.id)
            let persistedFlow = try XCTUnwrap(loadedFlow)
            let responseBody = try XCTUnwrap(persistedFlow.response?.body)
            let persistedResponseBytes = try await reopenedBodyStore.read(responseBody)

            XCTAssertEqual(persistedFlow.state, .completed)
            XCTAssertEqual(persistedFlow.request.url.scheme, "https")
            XCTAssertEqual(persistedFlow.request.url.host, "localhost")
            XCTAssertEqual(persistedFlow.response?.statusCode, 200)
            XCTAssertEqual(persistedFlow.connection?.protocolKind, .https)
            XCTAssertEqual(persistedFlow.connection?.tlsIntercepted, true)
            XCTAssertEqual(persistedResponseBytes, expectedResponseBytes)
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testHTTPSConnectInterceptionCapturesConcurrentHTTP2Streams() async throws {
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.capture-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTPS(
            responseBody: "secure HTTP/2 upstream response",
            identity: upstreamIdentity
        )
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensHTTP2CaptureTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies"),
                inlineBodyThreshold: 4
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            bodyStore: bodyStore,
            certificateProvider: certificateProvider,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            )
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                try await certificateProvider.removeCertificateAuthority()
                return
            }

            let baseURL = "https://localhost:\(upstream.endpoint.port)"
            let requestBody = Data("HTTP/2 request body".utf8)
            let responses = try await HTTP2TestClient.send(
                urls: [
                    "\(baseURL)/first?transport=h2",
                    "\(baseURL)/second?transport=h2"
                ],
                bodies: [nil, requestBody],
                through: proxyEndpoint,
                trustedRootCertificate: rootCertificate
            )

            XCTAssertEqual(responses.map(\.statusCode), [200, 200])
            XCTAssertEqual(
                responses.map(\.body),
                [
                    Data("secure HTTP/2 upstream response".utf8),
                    Data("secure HTTP/2 upstream response:HTTP/2 request body".utf8)
                ]
            )
            try await eventually("two completed HTTP/2 flows") {
                let events = await eventSink.snapshot()
                return events.filter { event in
                    if case .finished = event {
                        return true
                    }
                    return false
                }.count == 2
            }
            let flows = await eventSink.snapshot().compactMap { event -> Flow? in
                if case .finished(let flow) = event {
                    return flow
                }
                return nil
            }
            XCTAssertEqual(flows.count, 2)
            XCTAssertTrue(flows.allSatisfy { $0.state == .completed })
            XCTAssertTrue(flows.allSatisfy { $0.request.version == .http2 })
            XCTAssertTrue(flows.allSatisfy { $0.response?.version == .http2 })
            XCTAssertTrue(flows.allSatisfy { $0.connection?.protocolKind == .https })
            XCTAssertTrue(flows.allSatisfy { $0.connection?.tlsIntercepted == true })
            for flow in flows {
                let responseBody = try XCTUnwrap(flow.response?.body)
                let capturedResponseBody = try await bodyStore.read(responseBody)
                let expectedResponseBody =
                    flow.request.url.path == "/second"
                    ? Data("secure HTTP/2 upstream response:HTTP/2 request body".utf8)
                    : Data("secure HTTP/2 upstream response".utf8)
                XCTAssertEqual(capturedResponseBody, expectedResponseBody)
            }
            let postedFlow = try XCTUnwrap(
                flows.first { $0.request.url.path == "/second" }
            )
            let postedRequestBody = try XCTUnwrap(postedFlow.request.body)
            let capturedRequestBody = try await bodyStore.read(postedRequestBody)
            XCTAssertEqual(capturedRequestBody, requestBody)
            XCTAssertEqual(upstream.requestCount, 2)
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testHTTPSConnectInterceptionPoolsConcurrentUpstreamHTTP2Streams() async throws {
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.capture-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTP2(
            responseBody: "pooled HTTP/2 response",
            identity: upstreamIdentity
        )
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            certificateProvider: certificateProvider,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            )
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                try await certificateProvider.removeCertificateAuthority()
                return
            }

            let baseURL = "https://localhost:\(upstream.endpoint.port)"
            let responses = try await HTTP2TestClient.send(
                urls: [
                    "\(baseURL)/pooled/first",
                    "\(baseURL)/pooled/second"
                ],
                through: proxyEndpoint,
                trustedRootCertificate: rootCertificate
            )

            XCTAssertEqual(responses.map(\.statusCode), [200, 200])
            XCTAssertEqual(
                responses.map(\.body),
                Array(repeating: Data("pooled HTTP/2 response".utf8), count: 2)
            )
            try await eventually("two pooled HTTP/2 flows") {
                await eventSink.snapshot().filter { event in
                    if case .finished = event {
                        return true
                    }
                    return false
                }.count == 2
            }
            XCTAssertEqual(upstream.requestCount, 2)
            XCTAssertEqual(upstream.connectionCount, 1)
            let flows = await eventSink.snapshot().compactMap { event -> Flow? in
                if case .finished(let flow) = event {
                    return flow
                }
                return nil
            }
            XCTAssertTrue(flows.allSatisfy { $0.connection?.upstreamHTTPVersion == .http2 })
            XCTAssertEqual(
                flows.filter { $0.connection?.isUpstreamConnectionReused == false }.count,
                1
            )
            XCTAssertEqual(
                flows.filter { $0.connection?.isUpstreamConnectionReused == true }.count,
                1
            )
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testHTTPSConnectInterceptionUsesPooledUpstreamHTTP2ForHTTP1Client() async throws {
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.capture-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTP2(
            responseBody: "HTTP/1 client over pooled HTTP/2",
            identity: upstreamIdentity
        )
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            certificateProvider: certificateProvider,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            )
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                try await certificateProvider.removeCertificateAuthority()
                return
            }

            let baseURL = "https://localhost:\(upstream.endpoint.port)"
            let firstResponse = try await HTTPSTestClient.get(
                url: "\(baseURL)/pooled/http1/first",
                through: proxyEndpoint,
                trustedRootCertificate: rootCertificate
            )
            let secondResponse = try await HTTPSTestClient.get(
                url: "\(baseURL)/pooled/http1/second",
                through: proxyEndpoint,
                trustedRootCertificate: rootCertificate
            )

            XCTAssertEqual(firstResponse.statusCode, 200)
            XCTAssertEqual(secondResponse.statusCode, 200)
            XCTAssertEqual(firstResponse.version, .http1_1)
            XCTAssertEqual(secondResponse.version, .http1_1)
            XCTAssertEqual(upstream.requestCount, 2)
            XCTAssertEqual(upstream.connectionCount, 1)
            try await eventually("two HTTP/1 client flows completed over pooled HTTP/2") {
                await eventSink.snapshot().filter { event in
                    if case .finished = event {
                        return true
                    }
                    return false
                }.count == 2
            }
            let flows = await eventSink.snapshot().compactMap { event -> Flow? in
                if case .finished(let flow) = event {
                    return flow
                }
                return nil
            }
            XCTAssertTrue(flows.allSatisfy { $0.request.version == .http11 })
            XCTAssertTrue(flows.allSatisfy { $0.response?.version == .http11 })
            let firstFlow = try XCTUnwrap(
                flows.first { $0.request.url.path == "/pooled/http1/first" }
            )
            let secondFlow = try XCTUnwrap(
                flows.first { $0.request.url.path == "/pooled/http1/second" }
            )
            XCTAssertEqual(firstFlow.connection?.upstreamHTTPVersion, .http2)
            XCTAssertEqual(firstFlow.connection?.isUpstreamConnectionReused, false)
            XCTAssertEqual(secondFlow.connection?.upstreamHTTPVersion, .http2)
            XCTAssertEqual(secondFlow.connection?.isUpstreamConnectionReused, true)
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testHTTPSConnectInterceptionClosesUpstreamHTTP2PoolOnStop() async throws {
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.capture-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTP2(
            responseBody: "pool lifecycle response",
            identity: upstreamIdentity
        )
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            certificateProvider: certificateProvider,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            )
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let firstProxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                try await certificateProvider.removeCertificateAuthority()
                return
            }

            let url = "https://localhost:\(upstream.endpoint.port)/pool/lifecycle/first"
            let firstResponse = try await HTTPSTestClient.get(
                url: url,
                through: firstProxyEndpoint,
                trustedRootCertificate: rootCertificate
            )
            XCTAssertEqual(firstResponse.statusCode, 200)
            try await eventually("one active pooled upstream connection") {
                upstream.activeConnectionCount == 1
            }

            await engine.stop()
            try await eventually("the pooled upstream connection to close") {
                upstream.activeConnectionCount == 0
            }

            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let secondProxyEndpoint) = await engine.state() else {
                XCTFail("Expected the restarted proxy engine to be running")
                await upstream.stop()
                try await certificateProvider.removeCertificateAuthority()
                return
            }
            let secondResponse = try await HTTPSTestClient.get(
                url: "https://localhost:\(upstream.endpoint.port)/pool/lifecycle/second",
                through: secondProxyEndpoint,
                trustedRootCertificate: rootCertificate
            )
            XCTAssertEqual(secondResponse.statusCode, 200)
            XCTAssertEqual(upstream.connectionCount, 2)
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testHTTPSConnectInterceptionCachesUpstreamHTTP1Fallback() async throws {
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.capture-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTPS(
            responseBody: "HTTP/1.1 fallback response",
            identity: upstreamIdentity
        )
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            certificateProvider: certificateProvider,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            )
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                try await certificateProvider.removeCertificateAuthority()
                return
            }

            let baseURL = "https://localhost:\(upstream.endpoint.port)"
            let responses = try await HTTP2TestClient.send(
                urls: [
                    "\(baseURL)/fallback/first",
                    "\(baseURL)/fallback/second"
                ],
                through: proxyEndpoint,
                trustedRootCertificate: rootCertificate
            )

            XCTAssertEqual(responses.map(\.statusCode), [200, 200])
            XCTAssertEqual(
                responses.map(\.body),
                Array(repeating: Data("HTTP/1.1 fallback response".utf8), count: 2)
            )
            XCTAssertEqual(upstream.requestCount, 2)
            XCTAssertEqual(upstream.connectionCount, 3)
            try await eventually("two HTTP/1 fallback flows completed") {
                await eventSink.snapshot().filter { event in
                    if case .finished = event {
                        return true
                    }
                    return false
                }.count == 2
            }
            let flows = await eventSink.snapshot().compactMap { event -> Flow? in
                if case .finished(let flow) = event {
                    return flow
                }
                return nil
            }
            XCTAssertTrue(flows.allSatisfy { $0.connection?.upstreamHTTPVersion == .http11 })
            XCTAssertTrue(
                flows.allSatisfy { $0.connection?.isUpstreamConnectionReused == false }
            )
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testHTTPSConnectInterceptionAppliesBlockRuleToHTTP2Stream() async throws {
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.capture-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let eventSink = RecordingFlowEventSink()
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Block HTTP/2 fixture",
                    phase: .requestHeaders,
                    matcher: .host(.exact("blocked.test")),
                    action: .block(reason: "blocked over HTTP/2")
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            certificateProvider: certificateProvider,
            ruleSnapshot: snapshot
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                try await certificateProvider.removeCertificateAuthority()
                return
            }

            let responses = try await HTTP2TestClient.send(
                urls: ["https://blocked.test:443/blocked"],
                through: proxyEndpoint,
                trustedRootCertificate: rootCertificate
            )

            XCTAssertEqual(responses.first?.statusCode, 403)
            XCTAssertEqual(
                responses.first?.body,
                Data("blocked over HTTP/2\n".utf8)
            )
            await eventSink.waitForFinished()
            let events = await eventSink.snapshot()
            let flow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    if case .finished(let flow) = event {
                        return flow
                    }
                    return nil
                }.first)
            XCTAssertEqual(flow.state, .completed)
            XCTAssertEqual(flow.request.version, .http2)
            XCTAssertEqual(flow.response?.version, .http2)
            XCTAssertEqual(flow.response?.statusCode, 403)
            XCTAssertNil(flow.timing.upstreamConnectedAt)
            XCTAssertEqual(flow.ruleTraces.map(\.ruleName), ["Block HTTP/2 fixture"])
            XCTAssertEqual(flow.ruleTraces.map(\.outcome), [.applied])
        } catch {
            await engine.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testExternalHTTPProxyUsesAbsoluteFormAndKeepsAuthorizationOutOfCapture() async throws {
        let upstreamProxy = try await TestHTTPServer.start(responseBody: "external proxy response")
        let eventSink = RecordingFlowEventSink()
        let credentialStore = TestExternalHTTPProxyCredentialStore(
            credentials: try ExternalHTTPProxyCredentials(
                username: "proxy-user",
                password: "proxy-password"
            )
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            externalHTTPProxyCredentialStore: credentialStore
        )
        let externalProxy = try ExternalHTTPProxyConfiguration(
            endpoint: upstreamProxy.endpoint,
            username: "proxy-user",
            isEnabled: true
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false,
                    externalHTTPProxy: externalProxy
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstreamProxy.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://origin.invalid:8081/resource?q=external",
                through: proxyEndpoint
            )
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("external proxy response".utf8))
            XCTAssertEqual(
                upstreamProxy.requestURI,
                "http://origin.invalid:8081/resource?q=external"
            )
            XCTAssertEqual(upstreamProxy.requestHeader("Host"), "origin.invalid:8081")
            XCTAssertEqual(
                upstreamProxy.requestHeader("Proxy-Authorization"),
                "Basic cHJveHktdXNlcjpwcm94eS1wYXNzd29yZA=="
            )

            await eventSink.waitForFinished()
            let events = await eventSink.snapshot()
            let flow = try XCTUnwrap(
                events.compactMap { event -> Flow? in
                    if case .finished(let flow) = event { return flow }
                    return nil
                }.first
            )
            XCTAssertEqual(flow.request.url.host, "origin.invalid")
            XCTAssertNil(flow.request.headers.firstValue(for: "Proxy-Authorization"))
        } catch {
            await engine.stop()
            await upstreamProxy.stop()
            throw error
        }

        await engine.stop()
        await upstreamProxy.stop()
    }

    func testExternalHTTPProxyBypassKeepsDirectRouting() async throws {
        let upstreamProxy = try await TestHTTPServer.start(responseBody: "wrong route")
        let upstream = try await TestHTTPServer.start(responseBody: "direct response")
        let engine = NIOProxyEngine()
        let externalProxy = try ExternalHTTPProxyConfiguration(
            endpoint: upstreamProxy.endpoint,
            bypassHosts: ["127.0.0.1"],
            isEnabled: true
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false,
                    externalHTTPProxy: externalProxy
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                await upstreamProxy.stop()
                return
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/bypassed",
                through: proxyEndpoint
            )
            XCTAssertEqual(response.body, Data("direct response".utf8))
            XCTAssertEqual(upstream.requestCount, 1)
            XCTAssertEqual(upstreamProxy.requestCount, 0)
        } catch {
            await engine.stop()
            await upstream.stop()
            await upstreamProxy.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        await upstreamProxy.stop()
    }

    func testCoordinatorCapturePersistsAndStreamsFlowUnderCreatedSession() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "coordinated response")
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensCoordinatorTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies")
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let flowEvents = FlowEventBus()
        let persistenceSink = PersistingFlowEventSink(
            flowStore: sessionStore,
            downstream: flowEvents
        )
        let engine = NIOProxyEngine(
            eventSink: persistenceSink,
            bodyStore: bodyStore
        )
        let coordinator = CaptureCoordinator(
            proxyEngine: engine,
            sessionStore: sessionStore,
            systemProxyController: TestSystemProxyController()
        )
        let eventStream = await flowEvents.events(bufferingPolicy: .unbounded)
        let finishedFlowTask = Task<Flow?, Never> {
            for await event in eventStream {
                if case .finished(let flow) = event {
                    return flow
                }
            }
            return nil
        }

        do {
            let context = try await coordinator.start(
                configuration: CaptureConfiguration(
                    proxy: ProxyConfiguration(
                        listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                        interceptHTTPS: false
                    ),
                    configuresSystemProxy: false
                )
            )
            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(upstream.endpoint.port)/coordinated",
                through: context.endpoint
            )
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("coordinated response".utf8))

            let streamedFlow = await finishedFlowTask.value
            let finishedFlow = try XCTUnwrap(streamedFlow)
            XCTAssertEqual(finishedFlow.sessionID, context.sessionID)
            let loadedFlow = try await sessionStore.load(flowID: finishedFlow.id)
            XCTAssertEqual(loadedFlow, finishedFlow)
            let recordingSession = try await sessionStore.loadSession(
                sessionID: context.sessionID
            )
            XCTAssertEqual(recordingSession?.state, .recording)

            try await coordinator.stop()

            let stoppedSession = try await sessionStore.loadSession(
                sessionID: context.sessionID
            )
            XCTAssertEqual(stoppedSession?.state, .stopped)
        } catch {
            try? await coordinator.stop()
            await upstream.stop()
            throw error
        }

        await upstream.stop()
    }

    func testRequestHeaderScriptRetargetsUpstreamMethodAndURLAcrossHosts() async throws {
        let originalUpstream = try await TestHTTPServer.start(responseBody: "original-upstream")
        let scriptedUpstream = try await TestHTTPServer.start(responseBody: "scripted-upstream")
        let scriptedPort = scriptedUpstream.endpoint.port
        let eventSink = RecordingFlowEventSink()
        let scriptExecutor = StubScriptExecutor { request in
            XCTAssertEqual(request.hook, .request)
            XCTAssertEqual(request.message.method, "GET")
            XCTAssertNil(request.message.body)
            XCTAssertTrue(request.message.url?.hasSuffix("/original") == true)
            return try ScriptExecutionResult(
                hook: .request,
                message: ScriptHTTPMessage(
                    method: "PUT",
                    url: "http://127.0.0.1:\(scriptedPort)/rewritten",
                    headers: request.message.headers
                ),
                logs: ["request retargeted"]
            )
        }
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Retarget request",
                    phase: .requestHeaders,
                    matcher: .path(.exact("/original")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onRequest(context) {}")
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            ruleSnapshot: snapshot,
            scriptExecutor: scriptExecutor
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                return XCTFail("Expected the proxy engine to be running")
            }

            let response = try await HTTPTestClient.get(
                url: "http://127.0.0.1:\(originalUpstream.endpoint.port)/original",
                through: proxyEndpoint
            )

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("scripted-upstream".utf8))
            XCTAssertEqual(scriptedUpstream.requestMethod, "PUT")
            XCTAssertEqual(scriptedUpstream.requestURI, "/rewritten")
            XCTAssertEqual(scriptedUpstream.requestHeader("Host"), "127.0.0.1:\(scriptedPort)")
            XCTAssertEqual(originalUpstream.requestCount, 0)
            await eventSink.waitForFinished()
            let completedFlow = await eventSink.lastFlow { $0.state == .completed }
            let flow = try XCTUnwrap(completedFlow)
            XCTAssertEqual(flow.request.method, .get)
            XCTAssertEqual(flow.request.url.path, "/original")
            XCTAssertEqual(flow.request.url.port, Int(originalUpstream.endpoint.port))
            XCTAssertEqual(flow.connection?.upstreamPort, scriptedPort)
            XCTAssertEqual(flow.ruleTraces.map(\.phase), [.requestHeaders])
            XCTAssertEqual(flow.ruleTraces.map(\.outcome), [.applied])
            XCTAssertEqual(flow.ruleTraces.map(\.logs), [["request retargeted"]])
        } catch {
            await engine.stop()
            await scriptedUpstream.stop()
            await originalUpstream.stop()
            throw error
        }

        await engine.stop()
        await scriptedUpstream.stop()
        await originalUpstream.stop()
    }

    func testInterceptedSecureWebSocketHandshakeScriptsRewriteSafeRequestAndResponseFields()
        async throws
    {
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.secure-ws-script-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: "localhost")
        let upstream = try await TestWebSocketServer.startTLS(identity: upstreamIdentity)
        let flowEvents = RecordingFlowEventSink()
        let scriptExecutor = StubScriptExecutor { request in
            switch request.hook {
            case .request:
                XCTAssertTrue(request.message.url?.hasPrefix("wss://") == true)
                let url = try XCTUnwrap(URL(string: try XCTUnwrap(request.message.url)))
                var components = try XCTUnwrap(
                    URLComponents(url: url, resolvingAgainstBaseURL: false))
                components.path = "/scripted"
                return try ScriptExecutionResult(
                    hook: .request,
                    message: ScriptHTTPMessage(
                        method: request.message.method,
                        url: try XCTUnwrap(components.url).absoluteString,
                        headers: request.message.headers + [
                            try HTTPHeader(name: "X-ProxyLens-Secure-WebSocket", value: "request")
                        ]
                    ),
                    logs: ["secure WebSocket request handshake updated"]
                )
            case .response:
                return try ScriptExecutionResult(
                    hook: .response,
                    message: ScriptHTTPMessage(
                        statusCode: request.message.statusCode,
                        headers: request.message.headers + [
                            try HTTPHeader(name: "X-ProxyLens-Secure-WebSocket", value: "response")
                        ]
                    ),
                    logs: ["secure WebSocket response handshake updated"]
                )
            }
        }
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Rewrite secure WebSocket request handshake",
                    priority: 10,
                    phase: .requestHeaders,
                    matcher: .header(name: "Upgrade", value: .exact("websocket")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onRequest(context) {}")
                    )
                ),
                Rule(
                    name: "Rewrite secure WebSocket response handshake",
                    priority: 10,
                    phase: .responseHeaders,
                    matcher: .header(name: "Upgrade", value: .exact("websocket")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onResponse(context) {}")
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: flowEvents,
            certificateProvider: certificateProvider,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            ),
            ruleSnapshot: snapshot,
            scriptExecutor: scriptExecutor
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                try await certificateProvider.removeCertificateAuthority()
                return
            }

            let result = try await SecureWebSocketTestClient.exchangeDetails(
                url: "wss://localhost:\(upstream.endpoint.port)/echo",
                through: proxyEndpoint,
                trustedRootCertificate: rootCertificate,
                initialMessage: "hello",
                expectedResponseCount: 1
            )

            XCTAssertEqual(result.responses, ["echo:hello"])
            XCTAssertEqual(upstream.requestURI, "/scripted")
            XCTAssertEqual(upstream.requestHeader("X-ProxyLens-Secure-WebSocket"), "request")
            XCTAssertEqual(upstream.requestHeader("Upgrade"), "websocket")
            XCTAssertEqual(upstream.requestHeader("Sec-WebSocket-Key"), "AQIDBAUGBwgJCgsMDQ4PEC==")
            XCTAssertEqual(upstream.requestHeader("Host"), "localhost:\(upstream.endpoint.port)")
            XCTAssertEqual(result.header("X-ProxyLens-Secure-WebSocket"), "response")
            XCTAssertEqual(result.header("Upgrade"), "websocket")
            await flowEvents.waitForFinished()
            let completedFlow = await flowEvents.lastFlow { $0.state == .completed }
            let flow = try XCTUnwrap(completedFlow)
            XCTAssertEqual(flow.request.url.scheme, "https")
            XCTAssertEqual(flow.request.url.path, "/echo")
            XCTAssertEqual(flow.connection?.protocolKind, .secureWebSocket)
            XCTAssertEqual(flow.connection?.tlsIntercepted, true)
            XCTAssertNil(flow.request.headers.firstValue(for: "X-ProxyLens-Secure-WebSocket"))
            XCTAssertNil(flow.response?.headers.firstValue(for: "X-ProxyLens-Secure-WebSocket"))
            XCTAssertEqual(flow.ruleTraces.map(\.outcome), [.applied, .applied])
            XCTAssertEqual(
                flow.ruleTraces.map(\.logs),
                [
                    ["secure WebSocket request handshake updated"],
                    ["secure WebSocket response handshake updated"]
                ]
            )
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testInterceptedSecureWebSocketHandshakeScriptsFailOpenForCriticalFieldMutations()
        async throws
    {
        let certificateProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.secure-ws-script-tests.\(UUID().uuidString)"
            )
        )
        let rootCertificate = try await certificateProvider.rootCertificate()
        let upstreamIdentity = try await certificateProvider.leafCertificate(for: "localhost")
        let upstream = try await TestWebSocketServer.startTLS(identity: upstreamIdentity)
        let flowEvents = RecordingFlowEventSink()
        let scriptExecutor = StubScriptExecutor { request in
            switch request.hook {
            case .request:
                XCTAssertTrue(request.message.url?.hasPrefix("wss://") == true)
                return try ScriptExecutionResult(
                    hook: .request,
                    message: ScriptHTTPMessage(
                        method: "POST",
                        url: request.message.url,
                        headers: request.message.headers.filter {
                            $0.name.caseInsensitiveCompare("Sec-WebSocket-Key") != .orderedSame
                        } + [
                            try HTTPHeader(name: "Sec-WebSocket-Key", value: "invalid"),
                            try HTTPHeader(name: "X-Must-Not-Apply", value: "request")
                        ]
                    )
                )
            case .response:
                return try ScriptExecutionResult(
                    hook: .response,
                    message: ScriptHTTPMessage(
                        statusCode: 200,
                        headers: request.message.headers + [
                            try HTTPHeader(name: "X-Must-Not-Apply", value: "response")
                        ]
                    )
                )
            }
        }
        let snapshot = MutableRuleSnapshot(
            rules: RuleSet(rules: [
                Rule(
                    name: "Invalid secure WebSocket request handshake",
                    priority: 10,
                    phase: .requestHeaders,
                    matcher: .header(name: "Upgrade", value: .exact("websocket")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onRequest(context) {}")
                    )
                ),
                Rule(
                    name: "Invalid secure WebSocket response handshake",
                    priority: 10,
                    phase: .responseHeaders,
                    matcher: .header(name: "Upgrade", value: .exact("websocket")),
                    action: .script(
                        try ScriptRuleSpec(source: "function onResponse(context) {}")
                    )
                )
            ])
        )
        let engine = NIOProxyEngine(
            eventSink: flowEvents,
            certificateProvider: certificateProvider,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [rootCertificate]
            ),
            ruleSnapshot: snapshot,
            scriptExecutor: scriptExecutor
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                try await certificateProvider.removeCertificateAuthority()
                return
            }

            let result = try await SecureWebSocketTestClient.exchangeDetails(
                url: "wss://localhost:\(upstream.endpoint.port)/echo",
                through: proxyEndpoint,
                trustedRootCertificate: rootCertificate,
                initialMessage: "hello",
                expectedResponseCount: 1
            )

            XCTAssertEqual(result.responses, ["echo:hello"])
            XCTAssertEqual(upstream.requestURI, "/echo")
            XCTAssertNil(upstream.requestHeader("X-Must-Not-Apply"))
            XCTAssertEqual(upstream.requestHeader("Sec-WebSocket-Key"), "AQIDBAUGBwgJCgsMDQ4PEC==")
            XCTAssertNil(result.header("X-Must-Not-Apply"))
            await flowEvents.waitForFinished()
            let completedFlow = await flowEvents.lastFlow { $0.state == .completed }
            let flow = try XCTUnwrap(completedFlow)
            XCTAssertEqual(flow.ruleTraces.count, 2)
            for trace in flow.ruleTraces {
                guard case .failed(let message) = trace.outcome else {
                    return XCTFail("Expected protected WebSocket mutation to fail open")
                }
                XCTAssertTrue(message.contains("WebSocket handshake"))
            }
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await certificateProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await certificateProvider.removeCertificateAuthority()
    }

    func testTunnelRelayBuffersReadsUntilPeerIsConnected() throws {
        let clientSide = EmbeddedChannel(handler: TunnelRelayHandler())
        let upstreamSide = EmbeddedChannel()

        var early = clientSide.allocator.buffer(capacity: 5)
        early.writeString("hello")
        try clientSide.writeInbound(early)
        XCTAssertNil(try upstreamSide.readOutbound(as: ByteBuffer.self))

        let relay = try clientSide.pipeline.syncOperations.handler(type: TunnelRelayHandler.self)
        relay.connectPeer(upstreamSide)
        upstreamSide.embeddedEventLoop.run()
        var relayed = try XCTUnwrap(upstreamSide.readOutbound(as: ByteBuffer.self))
        XCTAssertEqual(relayed.readString(length: relayed.readableBytes), "hello")
    }

    func testTunnelRelayForwardsBytesBothWaysAfterSplice() throws {
        let clientSide = EmbeddedChannel(handler: TunnelRelayHandler())
        let upstreamSide = EmbeddedChannel(handler: TunnelRelayHandler())
        let clientRelay = try clientSide.pipeline.syncOperations.handler(
            type: TunnelRelayHandler.self
        )
        let upstreamRelay = try upstreamSide.pipeline.syncOperations.handler(
            type: TunnelRelayHandler.self
        )
        clientRelay.connectPeer(upstreamSide)
        upstreamRelay.connectPeer(clientSide)

        var clientHello = clientSide.allocator.buffer(capacity: 3)
        clientHello.writeString("abc")
        try clientSide.writeInbound(clientHello)
        upstreamSide.embeddedEventLoop.run()
        var toUpstream = try XCTUnwrap(upstreamSide.readOutbound(as: ByteBuffer.self))
        XCTAssertEqual(toUpstream.readString(length: toUpstream.readableBytes), "abc")

        var serverBytes = upstreamSide.allocator.buffer(capacity: 3)
        serverBytes.writeString("xyz")
        try upstreamSide.writeInbound(serverBytes)
        clientSide.embeddedEventLoop.run()
        var toClient = try XCTUnwrap(clientSide.readOutbound(as: ByteBuffer.self))
        XCTAssertEqual(toClient.readString(length: toClient.readableBytes), "xyz")
    }

    func testTunnelRelayClosesPeerAndReportsCloseWhenEitherSideCloses() throws {
        let closed = expectation(description: "onClose fired")
        let clientSide = EmbeddedChannel(handler: TunnelRelayHandler(onClose: { closed.fulfill() }))
        let upstreamSide = EmbeddedChannel(handler: TunnelRelayHandler())
        let clientRelay = try clientSide.pipeline.syncOperations.handler(
            type: TunnelRelayHandler.self
        )
        let upstreamRelay = try upstreamSide.pipeline.syncOperations.handler(
            type: TunnelRelayHandler.self
        )
        clientRelay.connectPeer(upstreamSide)
        upstreamRelay.connectPeer(clientSide)

        clientSide.pipeline.fireChannelInactive()
        upstreamSide.embeddedEventLoop.run()
        wait(for: [closed], timeout: 1)
        XCTAssertFalse(upstreamSide.isActive)
    }

    func testTunnelRelayPausesPeerReadsWhenUnwritableAndResumesWhenWritable() throws {
        let clientSide = EmbeddedChannel(handler: TunnelRelayHandler())
        let upstreamSide = EmbeddedChannel()
        let relay = try clientSide.pipeline.syncOperations.handler(type: TunnelRelayHandler.self)
        relay.connectPeer(upstreamSide)

        // EmbeddedChannel does not wire `isWritable` to buffered outbound bytes or a
        // write-buffer water mark the way a socket channel would, so there is no way to
        // cross a high watermark and have writability flip on its own. NIO's own
        // EmbeddedChannel tests (testEmbeddedChannelWritabilityIsWritable) drive it the
        // same way: assign `isWritable` directly, then fire the pipeline event that a
        // real channel would fire when its writability actually changes.
        clientSide.isWritable = false
        clientSide.pipeline.fireChannelWritabilityChanged()
        upstreamSide.embeddedEventLoop.run()

        let autoReadWhileUnwritable = try XCTUnwrap(
            upstreamSide.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?
                .value as? Bool
        )
        XCTAssertFalse(autoReadWhileUnwritable)

        clientSide.isWritable = true
        clientSide.pipeline.fireChannelWritabilityChanged()
        upstreamSide.embeddedEventLoop.run()

        let autoReadOnceWritable = try XCTUnwrap(
            upstreamSide.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?
                .value as? Bool
        )
        XCTAssertTrue(autoReadOnceWritable)
    }

    func testTunnelRelayClosesPeerAndReportsCloseWhenErrorIsCaught() throws {
        let closed = expectation(description: "onClose fired")
        let clientSide = EmbeddedChannel(handler: TunnelRelayHandler(onClose: { closed.fulfill() }))
        let upstreamSide = EmbeddedChannel(handler: TunnelRelayHandler())
        let clientRelay = try clientSide.pipeline.syncOperations.handler(
            type: TunnelRelayHandler.self
        )
        let upstreamRelay = try upstreamSide.pipeline.syncOperations.handler(
            type: TunnelRelayHandler.self
        )
        clientRelay.connectPeer(upstreamSide)
        upstreamRelay.connectPeer(clientSide)

        clientSide.pipeline.fireErrorCaught(ProxyLensError.unsupportedOperation("boom"))
        upstreamSide.embeddedEventLoop.run()
        wait(for: [closed], timeout: 1)
        XCTAssertFalse(upstreamSide.isActive)
    }

    // MARK: - CONNECT passthrough

    func testCONNECTPassthroughForExcludedHostDeliversOriginCertificate() async throws {
        let engineProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.ssl-list-tests.\(UUID().uuidString)"
            )
        )
        let originProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.ssl-list-origin.\(UUID().uuidString)"
            )
        )
        let originRoot = try await originProvider.rootCertificate()
        let originIdentity = try await originProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTPS(
            responseBody: "origin body",
            identity: originIdentity
        )
        let eventSink = RecordingFlowEventSink()
        let policy = MutableTLSInterceptionPolicy(
            policy: try TLSInterceptionPolicy(mode: .interceptAllExcept, entries: ["localhost"])
        )
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            certificateProvider: engineProvider,
            tlsInterceptionPolicy: policy
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            // Trusts ONLY the origin root: succeeds only if the proxy did not re-terminate TLS.
            let response = try await HTTPSTestClient.get(
                url: "https://localhost:\(upstream.endpoint.port)/pinned",
                through: proxyEndpoint,
                trustedRootCertificate: originRoot
            )
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("origin body".utf8))
            XCTAssertEqual(upstream.requestCount, 1)

            await eventSink.waitForFinished()
            let tunnelFlow = await eventSink.lastFlow { $0.state == .completed }
            let tunnel = try XCTUnwrap(tunnelFlow)
            XCTAssertEqual(tunnel.request.method, .connect)
            XCTAssertEqual(tunnel.request.url.host, "localhost")
            XCTAssertEqual(tunnel.connection?.tlsIntercepted, false)
            XCTAssertEqual(tunnel.connection?.protocolKind, .https)
            XCTAssertNotNil(tunnel.timing.upstreamConnectedAt)
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await engineProvider.removeCertificateAuthority()
            try? await originProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await engineProvider.removeCertificateAuthority()
        try await originProvider.removeCertificateAuthority()
    }

    func testDisabledHTTPSInterceptionTunnelsInsteadOfRefusingCONNECT() async throws {
        let originProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.ssl-list-501.\(UUID().uuidString)"
            )
        )
        let originRoot = try await originProvider.rootCertificate()
        let originIdentity = try await originProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTPS(
            responseBody: "tunneled",
            identity: originIdentity
        )
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(eventSink: eventSink)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            let response = try await HTTPSTestClient.get(
                url: "https://localhost:\(upstream.endpoint.port)/tunnel",
                through: proxyEndpoint,
                trustedRootCertificate: originRoot
            )
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("tunneled".utf8))
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await originProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await originProvider.removeCertificateAuthority()
    }

    func testLivePolicyReplacementAffectsTheNextCONNECT() async throws {
        let engineProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.ssl-list-live.\(UUID().uuidString)"
            )
        )
        let engineRoot = try await engineProvider.rootCertificate()
        let originProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.ssl-list-live-origin.\(UUID().uuidString)"
            )
        )
        let originRoot = try await originProvider.rootCertificate()
        let originIdentity = try await originProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTPS(
            responseBody: "either way",
            identity: originIdentity
        )
        let eventSink = RecordingFlowEventSink()
        let policy = MutableTLSInterceptionPolicy()
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            certificateProvider: engineProvider,
            upstreamTLSConfiguration: UpstreamTLSConfiguration(
                additionalTrustRootCertificates: [originRoot]
            ),
            tlsInterceptionPolicy: policy
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            // Empty policy: MITM as today — client trusts the ENGINE root.
            let intercepted = try await HTTPSTestClient.get(
                url: "https://localhost:\(upstream.endpoint.port)/first",
                through: proxyEndpoint,
                trustedRootCertificate: engineRoot
            )
            XCTAssertEqual(intercepted.statusCode, 200)

            policy.replace(
                try TLSInterceptionPolicy(mode: .interceptAllExcept, entries: ["localhost"])
            )

            // Next CONNECT passes through — client now succeeds trusting only the ORIGIN root.
            let passthrough = try await HTTPSTestClient.get(
                url: "https://localhost:\(upstream.endpoint.port)/second",
                through: proxyEndpoint,
                trustedRootCertificate: originRoot
            )
            XCTAssertEqual(passthrough.statusCode, 200)
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await engineProvider.removeCertificateAuthority()
            try? await originProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await engineProvider.removeCertificateAuthority()
        try await originProvider.removeCertificateAuthority()
    }

    func testInterceptOnlyModePassesUnlistedHostsThrough() async throws {
        let engineProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.ssl-list-only.\(UUID().uuidString)"
            )
        )
        let originProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.ssl-list-only-origin.\(UUID().uuidString)"
            )
        )
        let originRoot = try await originProvider.rootCertificate()
        let originIdentity = try await originProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTPS(
            responseBody: "unlisted",
            identity: originIdentity
        )
        let engine = NIOProxyEngine(
            eventSink: RecordingFlowEventSink(),
            certificateProvider: engineProvider,
            tlsInterceptionPolicy: MutableTLSInterceptionPolicy(
                policy: try TLSInterceptionPolicy(
                    mode: .interceptOnly,
                    entries: ["listed.example.com"]
                )
            )
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: true
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                await upstream.stop()
                return
            }

            // "localhost" is not listed, so intercept-only mode must tunnel it: the client
            // trusting only the origin root proves the proxy never re-terminated TLS.
            let response = try await HTTPSTestClient.get(
                url: "https://localhost:\(upstream.endpoint.port)/unlisted",
                through: proxyEndpoint,
                trustedRootCertificate: originRoot
            )
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("unlisted".utf8))
        } catch {
            await engine.stop()
            await upstream.stop()
            try? await engineProvider.removeCertificateAuthority()
            try? await originProvider.removeCertificateAuthority()
            throw error
        }

        await engine.stop()
        await upstream.stop()
        try await engineProvider.removeCertificateAuthority()
        try await originProvider.removeCertificateAuthority()
    }

    func testCONNECTPassthroughUpstreamFailureFailsTheTunnelFlow() async throws {
        let eventSink = RecordingFlowEventSink()
        let policy = MutableTLSInterceptionPolicy(
            policy: try TLSInterceptionPolicy(mode: .interceptAllExcept, entries: ["127.0.0.1"])
        )
        let engine = NIOProxyEngine(eventSink: eventSink, tlsInterceptionPolicy: policy)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let proxyEndpoint) = await engine.state() else {
                XCTFail("Expected the proxy engine to be running")
                return
            }

            // Port 1 on loopback: nothing listens there, the raw dial must fail. The
            // helper's TLS material is never reached because no 200 is written when the
            // upstream connect fails, so an empty trusted root is fine here.
            await assertThrowsErrorAsync(
                try await HTTPSTestClient.get(
                    url: "https://127.0.0.1:1/unreachable",
                    through: proxyEndpoint,
                    trustedRootCertificate: Data()
                )
            )

            await eventSink.waitForFinished()
            let failedFlow = await eventSink.lastFlow {
                if case .failed = $0.state { return true }
                return false
            }
            let failed = try XCTUnwrap(failedFlow)
            XCTAssertEqual(failed.request.method, .connect)
            XCTAssertEqual(failed.state, .failed(.upstreamUnavailable))
        } catch {
            await engine.stop()
            throw error
        }

        await engine.stop()
    }

    func testCONNECTPassthroughChainsThroughTheExternalHTTPProxy() async throws {
        // Engine B (interceptHTTPS: false → passthrough-everything) plays the external
        // CONNECT proxy for engine A, so no new relaying fixture is needed.
        let originProvider = KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.ssl-list-chain.\(UUID().uuidString)"
            )
        )
        let originRoot = try await originProvider.rootCertificate()
        let originIdentity = try await originProvider.leafCertificate(for: "localhost")
        let upstream = try await TestHTTPServer.startHTTPS(
            responseBody: "chained",
            identity: originIdentity
        )
        let outerSink = RecordingFlowEventSink()
        let innerSink = RecordingFlowEventSink()
        let engineB = NIOProxyEngine(eventSink: innerSink)
        let engineA = NIOProxyEngine(
            eventSink: outerSink,
            tlsInterceptionPolicy: MutableTLSInterceptionPolicy(
                policy: try TLSInterceptionPolicy(mode: .interceptAllExcept, entries: ["localhost"])
            )
        )

        do {
            try await engineB.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                ),
                sessionID: SessionID()
            )
            guard case .running(let innerEndpoint) = await engineB.state() else {
                XCTFail("Expected the inner proxy engine to be running")
                return
            }
            try await engineA.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false,
                    externalHTTPProxy: try ExternalHTTPProxyConfiguration(
                        endpoint: innerEndpoint,
                        isEnabled: true
                    )
                ),
                sessionID: SessionID()
            )
            guard case .running(let outerEndpoint) = await engineA.state() else {
                XCTFail("Expected the outer proxy engine to be running")
                return
            }

            let response = try await HTTPSTestClient.get(
                url: "https://localhost:\(upstream.endpoint.port)/via-chain",
                through: outerEndpoint,
                trustedRootCertificate: originRoot
            )
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("chained".utf8))
        } catch {
            await engineA.stop()
            await engineB.stop()
            await upstream.stop()
            try? await originProvider.removeCertificateAuthority()
            throw error
        }

        await engineA.stop()
        await engineB.stop()
        await upstream.stop()
        try await originProvider.removeCertificateAuthority()
    }
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected the expression to throw", file: file, line: line)
    } catch {}
}

private actor TestExternalHTTPProxyCredentialStore: ExternalHTTPProxyCredentialStoring {
    private var value: ExternalHTTPProxyCredentials?

    init(credentials: ExternalHTTPProxyCredentials? = nil) {
        value = credentials
    }

    func credentials(
        for _: NetworkEndpoint,
        username _: String
    ) -> ExternalHTTPProxyCredentials? {
        value
    }

    func save(
        _ credentials: ExternalHTTPProxyCredentials,
        for _: NetworkEndpoint
    ) {
        value = credentials
    }

    func removeCredentials(for _: NetworkEndpoint) {
        value = nil
    }
}

private actor TestSystemProxyController: SystemProxyController {
    func recoverInterruptedConfiguration() {}
    func prepareForProxyActivation() {}
    func apply(_: SystemProxyConfiguration) {}
    func restorePreviousConfiguration() {}
}

private struct FixedFlowSourceResolver: FlowSourceResolver {
    let source: FlowSource

    func resolveSource(
        clientEndpoint _: NetworkEndpoint,
        proxyEndpoint _: NetworkEndpoint
    ) async -> FlowSource {
        source
    }
}

private actor RecordingFlowEventSink: FlowEventSink {
    private var events: [FlowEvent] = []
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var flowWaiters: [FlowWaiter] = []

    func publish(_ event: FlowEvent) async {
        events.append(event)
        if case .finished = event {
            let waiters = finishedWaiters
            finishedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        let remaining = flowWaiters.filter { waiter in
            if waiter.predicate(event.flow) {
                waiter.continuation.resume()
                return false
            }
            return true
        }
        flowWaiters = remaining
    }

    func waitForFinished() async {
        if events.contains(where: { event in
            if case .finished = event {
                return true
            }
            return false
        }) {
            return
        }

        await withCheckedContinuation { continuation in
            finishedWaiters.append(continuation)
        }
    }

    func waitForFlow(
        where predicate: @escaping @Sendable (Flow) -> Bool
    ) async {
        if events.contains(where: { predicate($0.flow) }) {
            return
        }

        await withCheckedContinuation { continuation in
            flowWaiters.append(FlowWaiter(predicate: predicate, continuation: continuation))
        }
    }

    func snapshot() -> [FlowEvent] {
        events
    }

    func lastFlow(where predicate: @Sendable (Flow) -> Bool) -> Flow? {
        events.map(\.flow).last(where: predicate)
    }

    private struct FlowWaiter {
        let predicate: @Sendable (Flow) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }
}

private actor RecordingWebSocketFrameSink: WebSocketFrameEventSink {
    private var recordedFrames: [CapturedWebSocketFrame] = []

    func publish(_ frame: CapturedWebSocketFrame) {
        recordedFrames.append(frame)
    }

    func frames() -> [CapturedWebSocketFrame] {
        recordedFrames
    }

}

private actor RecordingServerSentEventSink: ServerSentEventEventSink {
    private var recordedEvents: [CapturedServerSentEvent] = []

    func publish(_ event: CapturedServerSentEvent) {
        recordedEvents.append(event)
    }

    func events() -> [CapturedServerSentEvent] {
        recordedEvents
    }
}

private final class TestWebSocketServer {
    let endpoint: NetworkEndpoint

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let connections: TestWebSocketServerConnections

    private init(
        group: MultiThreadedEventLoopGroup,
        channel: Channel,
        connections: TestWebSocketServerConnections
    ) throws {
        guard let address = channel.localAddress,
            let port = address.port,
            let boundPort = UInt16(exactly: port)
        else {
            throw ProxyLensError.unsupportedOperation("Test WebSocket server has no local address")
        }
        self.group = group
        self.channel = channel
        self.connections = connections
        endpoint = NetworkEndpoint(host: address.ipAddress ?? "127.0.0.1", port: boundPort)
    }

    var requestURI: String? {
        connections.requestURI
    }

    func requestHeader(_ name: String) -> String? {
        connections.requestHeader(name)
    }

    static func start() async throws -> TestWebSocketServer {
        try await start(tlsContext: nil)
    }

    static func startTLS(identity: CertificateIdentity) async throws -> TestWebSocketServer {
        try await start(tlsContext: TLSContextFactory.serverContext(identity: identity))
    }

    private static func start(tlsContext: NIOSSLContext?) async throws -> TestWebSocketServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connections = TestWebSocketServerConnections()
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    connections.register(channel)
                    let rejectionHandler = WebSocketUpgradeRejectionServerHandler()
                    let upgrader = NIOWebSocketServerUpgrader(
                        shouldUpgrade: { channel, request in
                            connections.recordUpgradeRequest(request)
                            let acceptedPaths = ["/close", "/echo", "/ping", "/scripted"]
                            return channel.eventLoop.makeSucceededFuture(
                                acceptedPaths.contains(request.uri)
                                    ? NIOHTTP1.HTTPHeaders()
                                    : nil
                            )
                        },
                        upgradePipelineHandler: { channel, request in
                            if request.uri == "/ping" {
                                return channel.pipeline.addHandler(WebSocketPingHandler())
                            }
                            if request.uri == "/close" {
                                return channel.pipeline.addHandler(WebSocketPeerCloseHandler())
                            }
                            return channel.pipeline.addHandler(WebSocketEchoHandler())
                        }
                    )
                    let configuration: NIOHTTPServerUpgradeSendableConfiguration = (
                        upgraders: [upgrader],
                        completionHandler: { context in
                            context.pipeline.removeHandler(rejectionHandler, promise: nil)
                        }
                    )
                    do {
                        if let tlsContext {
                            try channel.pipeline.syncOperations.addHandler(
                                NIOSSLServerHandler(context: tlsContext)
                            )
                        }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                    return channel.pipeline.configureHTTPServerPipeline(
                        withPipeliningAssistance: false,
                        withServerUpgrade: configuration
                    ).flatMap {
                        channel.pipeline.addHandler(rejectionHandler)
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            return try TestWebSocketServer(
                group: group,
                channel: channel,
                connections: connections
            )
        } catch {
            await shutdown(group)
            throw error
        }
    }

    func stop() async {
        _ = try? await channel.close().get()
        await connections.closeAll()
        await shutdown(group)
    }
}

private final class TestWebSocketServerConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var latestRequestURI: String?
    private var latestRequestHeaders: [(String, String)] = []

    var requestURI: String? {
        lock.lock()
        defer { lock.unlock() }
        return latestRequestURI
    }

    func requestHeader(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return latestRequestHeaders.first {
            $0.0.caseInsensitiveCompare(name) == .orderedSame
        }?.1
    }

    func recordUpgradeRequest(_ request: HTTPRequestHead) {
        lock.lock()
        latestRequestURI = request.uri
        latestRequestHeaders = request.headers.map { ($0.name, $0.value) }
        lock.unlock()
    }

    func register(_ channel: Channel) {
        let identifier = ObjectIdentifier(channel)
        lock.lock()
        channels[identifier] = channel
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.unregister(identifier)
        }
    }

    func closeAll() async {
        let openChannels = snapshot()
        for channel in openChannels {
            _ = try? await channel.close().get()
        }
    }

    private func snapshot() -> [Channel] {
        lock.lock()
        let openChannels = Array(channels.values)
        lock.unlock()
        return openChannels
    }

    private func unregister(_ identifier: ObjectIdentifier) {
        lock.lock()
        channels.removeValue(forKey: identifier)
        lock.unlock()
    }
}

private final class WebSocketUpgradeRejectionServerHandler:
    ChannelInboundHandler,
    RemovableChannelHandler,
    Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = Self.unwrapInboundIn(data)
        guard case .head = part else {
            return
        }
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        context.write(
            Self.wrapOutboundOut(
                .head(
                    HTTPResponseHead(
                        version: .http1_1,
                        status: .notFound,
                        headers: headers
                    )
                )
            ),
            promise: nil
        )
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            boundContext.value.close(promise: nil)
        }
    }
}

private final class WebSocketEchoHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            let request = String(decoding: frame.unmaskedData.readableBytesView, as: UTF8.self)
            var payload = context.channel.allocator.buffer(capacity: request.utf8.count + 5)
            payload.writeString("echo:\(request)")
            context.writeAndFlush(
                Self.wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: payload)),
                promise: nil
            )
        case .connectionClose:
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(
                Self.wrapOutboundOut(
                    WebSocketFrame(
                        fin: true,
                        opcode: .connectionClose,
                        data: frame.unmaskedData
                    )
                )
            ).whenComplete { _ in
                boundContext.value.close(promise: nil)
            }
        default:
            break
        }
    }
}

private final class WebSocketPingHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var payload = context.channel.allocator.buffer(capacity: 6)
            payload.writeString("health")
            context.writeAndFlush(
                Self.wrapOutboundOut(WebSocketFrame(fin: true, opcode: .ping, data: payload)),
                promise: nil
            )
        case .pong:
            guard String(decoding: frame.unmaskedData.readableBytesView, as: UTF8.self) == "health"
            else {
                context.close(promise: nil)
                return
            }
            var payload = context.channel.allocator.buffer(capacity: 13)
            payload.writeString("pong-received")
            context.writeAndFlush(
                Self.wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: payload)),
                promise: nil
            )
        case .connectionClose:
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(
                Self.wrapOutboundOut(
                    WebSocketFrame(
                        fin: true,
                        opcode: .connectionClose,
                        data: frame.unmaskedData
                    )
                )
            ).whenComplete { _ in
                boundContext.value.close(promise: nil)
            }
        default:
            break
        }
    }
}

private final class WebSocketPeerCloseHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            context.writeAndFlush(
                Self.wrapOutboundOut(
                    WebSocketFrame(
                        fin: true,
                        opcode: .connectionClose,
                        data: context.channel.allocator.buffer(capacity: 0)
                    )
                ),
                promise: nil
            )
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }
}

private enum WebSocketTestClient {
    static func exchange(
        url: String,
        through proxy: NetworkEndpoint,
        message: String,
        requestURI: String? = nil,
        hostHeader: String? = nil
    ) async throws -> String {
        let responses = try await exchangeMessages(
            url: url,
            through: proxy,
            initialMessage: message,
            expectedResponseCount: 1,
            requestURI: requestURI,
            hostHeader: hostHeader
        )
        guard let response = responses.first else {
            throw ProxyLensError.unsupportedOperation(
                "The WebSocket test client received no response"
            )
        }
        return response
    }

    static func exchangeMessages(
        url: String,
        through proxy: NetworkEndpoint,
        initialMessage: String,
        expectedResponseCount: Int,
        requestURI: String? = nil,
        hostHeader: String? = nil
    ) async throws -> [String] {
        try await exchangeDetails(
            url: url,
            through: proxy,
            initialMessage: initialMessage,
            expectedResponseCount: expectedResponseCount,
            requestURI: requestURI,
            hostHeader: hostHeader
        ).responses
    }

    static func exchangeDetails(
        url: String,
        through proxy: NetworkEndpoint,
        initialMessage: String,
        expectedResponseCount: Int,
        requestURI: String? = nil,
        hostHeader: String? = nil
    ) async throws -> WebSocketTestExchange {
        guard let target = URL(string: url), let host = target.host, let port = target.port else {
            throw ProxyLensError.invalidURL(url)
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let responsePromise = group.next().makePromise(of: WebSocketTestExchange.self)
        let requestHandler = WebSocketUpgradeRequestHandler(
            url: requestURI ?? url,
            hostHeader: hostHeader ?? "\(host):\(port)",
            responsePromise: responsePromise
        )
        let upgrader = NIOWebSocketClientUpgrader(
            requestKey: "AQIDBAUGBwgJCgsMDQ4PEC==",
            upgradePipelineHandler: { channel, responseHead in
                channel.pipeline.addHandler(
                    WebSocketTestResponseHandler(
                        promise: responsePromise,
                        expectedResponseCount: expectedResponseCount,
                        responseHeaders: responseHead.headers.map { ($0.name, $0.value) }
                    )
                ).flatMap {
                    var payload = channel.allocator.buffer(capacity: initialMessage.utf8.count)
                    payload.writeString(initialMessage)
                    return channel.writeAndFlush(
                        WebSocketFrame(
                            fin: true,
                            opcode: .text,
                            maskKey: [1, 2, 3, 4],
                            data: payload
                        )
                    )
                }
            }
        )
        let configuration: NIOHTTPClientUpgradeSendableConfiguration = (
            upgraders: [upgrader],
            completionHandler: { context in
                context.pipeline.removeHandler(requestHandler, promise: nil)
            }
        )

        do {
            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHTTPClientHandlers(withClientUpgrade: configuration)
                        .flatMap {
                            channel.pipeline.addHandler(requestHandler)
                        }
                }
                .connect(host: proxy.host, port: Int(proxy.port))
                .get()
            let timeout = channel.eventLoop.scheduleTask(in: .seconds(3)) {
                responsePromise.fail(
                    ProxyLensError.unsupportedOperation(
                        "Timed out waiting for the WebSocket echo response"
                    )
                )
            }
            responsePromise.futureResult.whenComplete { _ in
                timeout.cancel()
            }
            let result = try await responsePromise.futureResult.get()
            _ = try? await channel.close().get()
            await shutdown(group)
            return result
        } catch {
            await shutdown(group)
            throw error
        }
    }
}

private final class WebSocketUpgradeRequestHandler:
    ChannelInboundHandler,
    RemovableChannelHandler,
    Sendable
{
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let url: String
    private let hostHeader: String
    private let responsePromise: EventLoopPromise<WebSocketTestExchange>

    init(
        url: String,
        hostHeader: String,
        responsePromise: EventLoopPromise<WebSocketTestExchange>
    ) {
        self.url = url
        self.hostHeader = hostHeader
        self.responsePromise = responsePromise
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Host", value: hostHeader)
        headers.add(name: "Content-Length", value: "0")
        context.write(
            Self.wrapOutboundOut(
                .head(
                    HTTPRequestHead(
                        version: .http1_1,
                        method: .GET,
                        uri: url,
                        headers: headers
                    )
                )
            ),
            promise: nil
        )
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = Self.unwrapInboundIn(data)
        if case .head(let head) = response {
            responsePromise.fail(
                ProxyLensError.unsupportedOperation(
                    "WebSocket upgrade returned HTTP \(head.status.code)"
                )
            )
        }
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        responsePromise.fail(error)
        context.close(promise: nil)
    }
}

private final class WebSocketTestResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let promise: EventLoopPromise<WebSocketTestExchange>
    private let expectedResponseCount: Int
    private let responseHeaders: [(String, String)]
    private var responses: [String] = []
    private var completed = false

    init(
        promise: EventLoopPromise<WebSocketTestExchange>,
        expectedResponseCount: Int,
        responseHeaders: [(String, String)]
    ) {
        self.promise = promise
        self.expectedResponseCount = max(1, expectedResponseCount)
        self.responseHeaders = responseHeaders
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        if frame.opcode == .ping {
            context.writeAndFlush(
                Self.wrapOutboundOut(
                    WebSocketFrame(
                        fin: true,
                        opcode: .pong,
                        maskKey: [1, 2, 3, 4],
                        data: frame.unmaskedData
                    )
                ),
                promise: nil
            )
            return
        }
        guard frame.opcode == .text else {
            return
        }
        responses.append(String(decoding: frame.unmaskedData.readableBytesView, as: UTF8.self))
        if responses.count >= expectedResponseCount {
            completed = true
            promise.succeed(
                WebSocketTestExchange(
                    responses: responses,
                    responseHeaders: responseHeaders
                )
            )
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completed = true
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            completed = true
            promise.fail(ChannelError.eof)
        }
        context.fireChannelInactive()
    }
}

private struct WebSocketTestExchange: Sendable {
    let responses: [String]
    let responseHeaders: [(String, String)]

    func header(_ name: String) -> String? {
        responseHeaders.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}

private func eventually(
    _ expectation: String,
    attempts: Int = 100,
    condition: () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw ProxyLensError.unsupportedOperation("Timed out waiting for \(expectation)")
}

private struct HTTPTestResponse: Sendable {
    let statusCode: UInt
    let version: NIOHTTP1.HTTPVersion
    let headers: [(String, String)]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }
}

private enum SOCKS5TestClient {
    private static func requestHead(
        path: String,
        host: String,
        port: UInt16
    ) -> HTTPRequestHead {
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Host", value: "\(host):\(port)")
        headers.add(name: "Connection", value: "close")
        return HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: path,
            headers: headers
        )
    }

    static func get(
        path: String,
        destination: NetworkEndpoint,
        through proxy: NetworkEndpoint
    ) async throws -> HTTPTestResponse {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let handshakePromise = group.next().makePromise(of: Void.self)
            let handshakeHandler = SOCKS5ClientHandshakeHandler(
                destinationHost: destination.host,
                destinationPort: destination.port,
                promise: handshakePromise
            )
            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(handshakeHandler)
                }
                .connect(host: proxy.host, port: Int(proxy.port))
                .get()
            try await handshakePromise.futureResult.get()
            try await channel.setOption(ChannelOptions.autoRead, value: false).get()

            let responsePromise = channel.eventLoop.makePromise(of: HTTPTestResponse.self)
            try await channel.pipeline.removeHandler(handshakeHandler).flatMap {
                channel.pipeline.addHTTPClientHandlers()
            }.flatMap {
                channel.pipeline.addHandler(HTTPTestResponseHandler(promise: responsePromise))
            }.get()
            try await channel.setOption(ChannelOptions.autoRead, value: true).get()

            channel.write(
                HTTPClientRequestPart.head(
                    requestHead(
                        path: path,
                        host: destination.host,
                        port: destination.port
                    )
                ),
                promise: nil
            )
            channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
            let response = try await responsePromise.futureResult.get()
            await shutdown(group)
            return response
        } catch {
            await shutdown(group)
            throw error
        }
    }

    static func getHTTPS(
        path: String,
        destinationHost: String,
        destinationPort: UInt16,
        through proxy: NetworkEndpoint,
        trustedRootCertificate: Data
    ) async throws -> HTTPTestResponse {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let handshakePromise = group.next().makePromise(of: Void.self)
            let handshakeHandler = SOCKS5ClientHandshakeHandler(
                destinationHost: destinationHost,
                destinationPort: destinationPort,
                promise: handshakePromise
            )
            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(handshakeHandler)
                }
                .connect(host: proxy.host, port: Int(proxy.port))
                .get()
            try await handshakePromise.futureResult.get()
            try await channel.setOption(ChannelOptions.autoRead, value: false).get()

            let trustedRoots = try NIOSSLCertificate.fromPEMBytes(
                Array(trustedRootCertificate)
            )
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.minimumTLSVersion = .tlsv12
            tlsConfiguration.additionalTrustRoots = [.certificates(trustedRoots)]
            let tlsContext = try NIOSSLContext(configuration: tlsConfiguration)
            let tlsHandshakePromise = channel.eventLoop.makePromise(of: Void.self)
            let responsePromise = channel.eventLoop.makePromise(of: HTTPTestResponse.self)

            try await channel.pipeline.removeHandler(handshakeHandler).flatMapThrowing {
                let operations = channel.pipeline.syncOperations
                try operations.addHandler(
                    NIOSSLClientHandler(
                        context: tlsContext,
                        serverHostname: destinationHost
                    )
                )
                try operations.addHandler(TLSHandshakeHandler(promise: tlsHandshakePromise))
                try operations.addHTTPClientHandlers()
                try operations.addHandler(HTTPTestResponseHandler(promise: responsePromise))
            }.get()
            try await channel.setOption(ChannelOptions.autoRead, value: true).get()
            try await tlsHandshakePromise.futureResult.get()

            channel.write(
                HTTPClientRequestPart.head(
                    requestHead(
                        path: path,
                        host: destinationHost,
                        port: destinationPort
                    )
                ),
                promise: nil
            )
            channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
            let response = try await responsePromise.futureResult.get()
            await shutdown(group)
            return response
        } catch {
            await shutdown(group)
            throw error
        }
    }

    /// Completes the SOCKS5 handshake, then writes just enough bytes to look like the start
    /// of a TLS ClientHello (`SOCKS5ServerHandler`'s protocol sniff only needs the first
    /// three bytes to classify `.tls`) and waits for the raw connection to close. Used to
    /// observe passthrough-dial-failure behavior without driving a real `NIOSSLClientHandler`
    /// handshake against a connection the server is about to abruptly close.
    static func expectConnectionClosedAfterTLSPrefix(
        destinationHost: String,
        destinationPort: UInt16,
        through proxy: NetworkEndpoint
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let handshakePromise = group.next().makePromise(of: Void.self)
            let handshakeHandler = SOCKS5ClientHandshakeHandler(
                destinationHost: destinationHost,
                destinationPort: destinationPort,
                promise: handshakePromise
            )
            let closePromise = group.next().makePromise(of: Void.self)
            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(handshakeHandler)
                }
                .connect(host: proxy.host, port: Int(proxy.port))
                .get()
            try await handshakePromise.futureResult.get()

            try await channel.pipeline.removeHandler(handshakeHandler).flatMapThrowing {
                try channel.pipeline.syncOperations.addHandler(
                    ConnectionCloseObserver(promise: closePromise)
                )
            }.get()

            var tlsPrefix = channel.allocator.buffer(capacity: 3)
            tlsPrefix.writeBytes([0x16, 0x03, 0x01])
            try await channel.writeAndFlush(tlsPrefix).get()

            try await closePromise.futureResult.get()
            await shutdown(group)
        } catch {
            await shutdown(group)
            throw error
        }
    }
}

/// Resolves its promise the moment the channel closes, regardless of whether that closure
/// carries an error — used by tests that only care whether (and roughly when) a connection
/// was torn down.
private final class ConnectionCloseObserver: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<Void>
    private var didComplete = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete()
        context.fireErrorCaught(error)
    }

    private func complete() {
        guard !didComplete else { return }
        didComplete = true
        promise.succeed(())
    }
}

private final class SOCKS5ClientHandshakeHandler:
    ChannelDuplexHandler,
    RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State {
        case greeting
        case request
        case complete
    }

    private let destinationHost: String
    private let destinationPort: UInt16
    private let promise: EventLoopPromise<Void>
    private var state = State.greeting
    private var buffer: [UInt8] = []

    init(
        destinationHost: String,
        destinationPort: UInt16,
        promise: EventLoopPromise<Void>
    ) {
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        write([0x05, 0x01, 0x00], context: context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inbound = Self.unwrapInboundIn(data)
        buffer.append(contentsOf: inbound.readableBytesView)

        switch state {
        case .greeting:
            guard buffer.count >= 2 else { return }
            guard Array(buffer.prefix(2)) == [0x05, 0x00] else {
                fail("SOCKS5 authentication negotiation failed", context: context)
                return
            }
            buffer.removeFirst(2)
            let hostBytes = Array(destinationHost.utf8)
            guard !hostBytes.isEmpty, hostBytes.count <= 255 else {
                fail("SOCKS5 destination host is invalid", context: context)
                return
            }
            let portBytes = [UInt8(destinationPort >> 8), UInt8(destinationPort & 0xff)]
            write(
                [0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)] + hostBytes + portBytes,
                context: context
            )
            state = .request
            if !buffer.isEmpty {
                parseRequestReply(context: context)
            }
        case .request:
            parseRequestReply(context: context)
        case .complete:
            context.fireChannelRead(data)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }

    private func parseRequestReply(context: ChannelHandlerContext) {
        guard buffer.count >= 10 else { return }
        guard buffer[0] == 0x05, buffer[1] == 0x00 else {
            fail("SOCKS5 CONNECT failed with code \(buffer[1])", context: context)
            return
        }
        buffer.removeFirst(10)
        state = .complete
        promise.succeed(())
    }

    private func write(_ bytes: [UInt8], context: ChannelHandlerContext) {
        var outbound = context.channel.allocator.buffer(capacity: bytes.count)
        outbound.writeBytes(bytes)
        context.writeAndFlush(Self.wrapOutboundOut(outbound), promise: nil)
    }

    private func fail(_ message: String, context: ChannelHandlerContext) {
        promise.fail(ProxyLensError.unsupportedOperation(message))
        context.close(promise: nil)
    }
}

private enum HTTPSTestClient {
    static func get(
        url: String,
        through proxy: NetworkEndpoint,
        trustedRootCertificate: Data
    ) async throws -> HTTPTestResponse {
        guard let targetURL = URL(string: url),
            let host = targetURL.host,
            let port = targetURL.port
        else {
            throw ProxyLensError.invalidURL(url)
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ClientBootstrap(group: group)
                .connect(host: proxy.host, port: Int(proxy.port))
                .get()

            let connectPromise = channel.eventLoop.makePromise(of: UInt.self)
            try await HTTPSTestPipeline.installConnectHandlers(
                on: channel,
                promise: connectPromise
            ).get()

            var connectHeaders = NIOHTTP1.HTTPHeaders()
            connectHeaders.add(name: "Host", value: "\(host):\(port)")
            let connectRequest = HTTPRequestHead(
                version: .http1_1,
                method: .CONNECT,
                uri: "\(host):\(port)",
                headers: connectHeaders
            )
            channel.write(HTTPClientRequestPart.head(connectRequest), promise: nil)
            channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)

            let connectStatus = try await connectPromise.futureResult.get()
            guard connectStatus == 200 else {
                throw ProxyLensError.unsupportedOperation(
                    "The proxy rejected CONNECT with status \(connectStatus)"
                )
            }

            try await channel.setOption(ChannelOptions.autoRead, value: false).get()

            let trustedRoots = try NIOSSLCertificate.fromPEMBytes(
                Array(trustedRootCertificate)
            )
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.minimumTLSVersion = .tlsv12
            tlsConfiguration.additionalTrustRoots = [.certificates(trustedRoots)]
            let tlsContext = try NIOSSLContext(configuration: tlsConfiguration)
            let handshakePromise = channel.eventLoop.makePromise(of: Void.self)
            let responsePromise = channel.eventLoop.makePromise(of: HTTPTestResponse.self)

            try await HTTPSTestPipeline.replaceConnectHandlersWithTLS(
                on: channel,
                tlsContext: tlsContext,
                serverHostname: host,
                handshakePromise: handshakePromise,
                responsePromise: responsePromise
            ).get()
            try await channel.setOption(ChannelOptions.autoRead, value: true).get()
            try await handshakePromise.futureResult.get()

            var headers = NIOHTTP1.HTTPHeaders()
            headers.add(name: "Host", value: "\(host):\(port)")
            headers.add(name: "Connection", value: "close")
            let urlComponents = URLComponents(url: targetURL, resolvingAgainstBaseURL: false)
            let path =
                urlComponents?.percentEncodedPath.isEmpty == false
                ? urlComponents?.percentEncodedPath ?? "/"
                : "/"
            let query = urlComponents?.percentEncodedQuery.map { "?\($0)" } ?? ""
            let request = HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: path + query,
                headers: headers
            )
            channel.write(HTTPClientRequestPart.head(request), promise: nil)
            channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)

            let response = try await responsePromise.futureResult.get()
            await shutdown(group)
            return response
        } catch {
            await shutdown(group)
            throw error
        }
    }
}

private enum HTTP2TestClient {
    static func send(
        urls: [String],
        bodies: [Data?]? = nil,
        through proxy: NetworkEndpoint,
        trustedRootCertificate: Data
    ) async throws -> [HTTPTestResponse] {
        let requestBodies = bodies ?? Array(repeating: nil, count: urls.count)
        guard let firstURL = urls.first,
            let targetURL = URL(string: firstURL),
            let host = targetURL.host,
            let port = targetURL.port,
            requestBodies.count == urls.count,
            urls.allSatisfy({ url in
                guard let candidate = URL(string: url) else {
                    return false
                }
                return candidate.scheme == "https"
                    && candidate.host == host
                    && candidate.port == port
            })
        else {
            throw ProxyLensError.unsupportedOperation(
                "HTTP/2 test requests must use one absolute HTTPS origin"
            )
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ClientBootstrap(group: group)
                .connect(host: proxy.host, port: Int(proxy.port))
                .get()

            let connectPromise = channel.eventLoop.makePromise(of: UInt.self)
            try await HTTPSTestPipeline.installConnectHandlers(
                on: channel,
                promise: connectPromise
            ).get()

            var connectHeaders = NIOHTTP1.HTTPHeaders()
            connectHeaders.add(name: "Host", value: "\(host):\(port)")
            channel.write(
                HTTPClientRequestPart.head(
                    HTTPRequestHead(
                        version: .http1_1,
                        method: .CONNECT,
                        uri: "\(host):\(port)",
                        headers: connectHeaders
                    )
                ),
                promise: nil
            )
            channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)

            let connectStatus = try await connectPromise.futureResult.get()
            guard connectStatus == 200 else {
                throw ProxyLensError.unsupportedOperation(
                    "The proxy rejected CONNECT with status \(connectStatus)"
                )
            }

            try await channel.setOption(ChannelOptions.autoRead, value: false).get()
            let trustedRoots = try NIOSSLCertificate.fromPEMBytes(
                Array(trustedRootCertificate)
            )
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.minimumTLSVersion = .tlsv12
            tlsConfiguration.additionalTrustRoots = [.certificates(trustedRoots)]
            tlsConfiguration.applicationProtocols = ["h2"]
            let tlsContext = try NIOSSLContext(configuration: tlsConfiguration)
            let handshakePromise = channel.eventLoop.makePromise(of: Void.self)
            let multiplexerPromise = channel.eventLoop.makePromise(
                of: NIOHTTP2Handler.StreamMultiplexer.self
            )

            try await HTTPSTestPipeline.replaceConnectHandlersWithHTTP2(
                on: channel,
                tlsContext: tlsContext,
                serverHostname: host,
                handshakePromise: handshakePromise,
                multiplexerPromise: multiplexerPromise
            ).get()
            try await channel.setOption(ChannelOptions.autoRead, value: true).get()
            try await handshakePromise.futureResult.get()
            let multiplexer = try await multiplexerPromise.futureResult.get()

            var responseFutures: [EventLoopFuture<HTTPTestResponse>] = []
            for (index, url) in urls.enumerated() {
                let parsedURL = try XCTUnwrap(URL(string: url))
                let requestBody = requestBodies[index]
                let responsePromise = channel.eventLoop.makePromise(of: HTTPTestResponse.self)
                let streamChannel = try await multiplexer.createStreamChannel { streamChannel in
                    streamChannel.eventLoop.makeCompletedFuture {
                        let operations = streamChannel.pipeline.syncOperations
                        try operations.addHandler(
                            HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
                        )
                        try operations.addHandler(
                            HTTPTestResponseHandler(promise: responsePromise)
                        )
                    }
                }.get()
                var headers = NIOHTTP1.HTTPHeaders()
                headers.add(name: "Host", value: "\(host):\(port)")
                if let requestBody {
                    headers.add(name: "Content-Type", value: "text/plain")
                    headers.add(name: "Content-Length", value: "\(requestBody.count)")
                }
                let components = URLComponents(
                    url: parsedURL,
                    resolvingAgainstBaseURL: false
                )
                let path =
                    components?.percentEncodedPath.isEmpty == false
                    ? components?.percentEncodedPath ?? "/"
                    : "/"
                let query = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
                streamChannel.write(
                    HTTPClientRequestPart.head(
                        HTTPRequestHead(
                            version: NIOHTTP1.HTTPVersion(major: 2, minor: 0),
                            method: requestBody == nil ? .GET : .POST,
                            uri: path + query,
                            headers: headers
                        )
                    ),
                    promise: nil
                )
                if let requestBody {
                    var buffer = streamChannel.allocator.buffer(capacity: requestBody.count)
                    buffer.writeBytes(requestBody)
                    streamChannel.write(
                        HTTPClientRequestPart.body(.byteBuffer(buffer)),
                        promise: nil
                    )
                }
                streamChannel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                responseFutures.append(responsePromise.futureResult)
            }

            var responses: [HTTPTestResponse] = []
            for responseFuture in responseFutures {
                responses.append(try await responseFuture.get())
            }
            try await channel.close().get()
            await shutdown(group)
            return responses
        } catch {
            await shutdown(group)
            throw error
        }
    }
}

private enum HTTPSTestPipeline {
    private static let requestEncoderName = "proxylens.tests.connect.request-encoder"
    private static let responseDecoderName = "proxylens.tests.connect.response-decoder"
    private static let responseHandlerName = "proxylens.tests.connect.response-handler"

    static func installConnectHandlers(
        on channel: Channel,
        promise: EventLoopPromise<UInt>
    ) -> EventLoopFuture<Void> {
        channel.eventLoop.submit {
            let operations = channel.pipeline.syncOperations
            try operations.addHandler(HTTPRequestEncoder(), name: requestEncoderName)
            try operations.addHandler(
                ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)),
                name: responseDecoderName
            )
            try operations.addHandler(
                ConnectResponseHandler(promise: promise),
                name: responseHandlerName
            )
        }
    }

    static func replaceConnectHandlersWithTLS(
        on channel: Channel,
        tlsContext: NIOSSLContext,
        serverHostname: String,
        handshakePromise: EventLoopPromise<Void>,
        responsePromise: EventLoopPromise<HTTPTestResponse>
    ) -> EventLoopFuture<Void> {
        return channel.eventLoop.submit {
            let operations = channel.pipeline.syncOperations
            let responseHandler = try operations.context(name: responseHandlerName)
            let responseDecoder = try operations.context(name: responseDecoderName)
            let requestEncoder = try operations.context(name: requestEncoderName)
            let loopBoundOperations = NIOLoopBound(operations, eventLoop: channel.eventLoop)
            let loopBoundResponseDecoder = NIOLoopBound(
                responseDecoder,
                eventLoop: channel.eventLoop
            )
            let loopBoundRequestEncoder = NIOLoopBound(
                requestEncoder,
                eventLoop: channel.eventLoop
            )

            return operations.removeHandler(context: responseHandler)
                .flatMap {
                    loopBoundOperations.value.removeHandler(
                        context: loopBoundResponseDecoder.value
                    )
                }
                .flatMap {
                    loopBoundOperations.value.removeHandler(
                        context: loopBoundRequestEncoder.value
                    )
                }
                .flatMapThrowing {
                    try loopBoundOperations.value.addHandler(
                        NIOSSLClientHandler(
                            context: tlsContext,
                            serverHostname: serverHostname
                        )
                    )
                    try loopBoundOperations.value.addHandler(
                        TLSHandshakeHandler(promise: handshakePromise)
                    )
                    try loopBoundOperations.value.addHTTPClientHandlers()
                    try loopBoundOperations.value.addHandler(
                        HTTPTestResponseHandler(promise: responsePromise)
                    )
                }
        }.flatMap { $0 }
    }

    static func replaceConnectHandlersWithTLSOnly(
        on channel: Channel,
        tlsContext: NIOSSLContext,
        serverHostname: String,
        handshakePromise: EventLoopPromise<Void>
    ) -> EventLoopFuture<Void> {
        channel.eventLoop.submit {
            let operations = channel.pipeline.syncOperations
            let responseHandler = try operations.context(name: responseHandlerName)
            let responseDecoder = try operations.context(name: responseDecoderName)
            let requestEncoder = try operations.context(name: requestEncoderName)
            let loopBoundOperations = NIOLoopBound(operations, eventLoop: channel.eventLoop)
            let loopBoundResponseDecoder = NIOLoopBound(
                responseDecoder,
                eventLoop: channel.eventLoop
            )
            let loopBoundRequestEncoder = NIOLoopBound(
                requestEncoder,
                eventLoop: channel.eventLoop
            )

            return operations.removeHandler(context: responseHandler)
                .flatMap {
                    loopBoundOperations.value.removeHandler(
                        context: loopBoundResponseDecoder.value
                    )
                }
                .flatMap {
                    loopBoundOperations.value.removeHandler(
                        context: loopBoundRequestEncoder.value
                    )
                }
                .flatMapThrowing {
                    try loopBoundOperations.value.addHandler(
                        NIOSSLClientHandler(
                            context: tlsContext,
                            serverHostname: serverHostname
                        )
                    )
                    try loopBoundOperations.value.addHandler(
                        TLSHandshakeHandler(promise: handshakePromise)
                    )
                }
        }.flatMap { $0 }
    }

    static func replaceConnectHandlersWithHTTP2(
        on channel: Channel,
        tlsContext: NIOSSLContext,
        serverHostname: String,
        handshakePromise: EventLoopPromise<Void>,
        multiplexerPromise: EventLoopPromise<NIOHTTP2Handler.StreamMultiplexer>
    ) -> EventLoopFuture<Void> {
        channel.eventLoop.submit {
            let operations = channel.pipeline.syncOperations
            let responseHandler = try operations.context(name: responseHandlerName)
            let responseDecoder = try operations.context(name: responseDecoderName)
            let requestEncoder = try operations.context(name: requestEncoderName)
            let loopBoundOperations = NIOLoopBound(operations, eventLoop: channel.eventLoop)
            let loopBoundResponseDecoder = NIOLoopBound(
                responseDecoder,
                eventLoop: channel.eventLoop
            )
            let loopBoundRequestEncoder = NIOLoopBound(
                requestEncoder,
                eventLoop: channel.eventLoop
            )

            return operations.removeHandler(context: responseHandler)
                .flatMap {
                    loopBoundOperations.value.removeHandler(
                        context: loopBoundResponseDecoder.value
                    )
                }
                .flatMap {
                    loopBoundOperations.value.removeHandler(
                        context: loopBoundRequestEncoder.value
                    )
                }
                .flatMapThrowing {
                    try loopBoundOperations.value.addHandler(
                        NIOSSLClientHandler(
                            context: tlsContext,
                            serverHostname: serverHostname
                        )
                    )
                    try loopBoundOperations.value.addHandler(
                        TLSHandshakeHandler(promise: handshakePromise)
                    )
                }
                .flatMap {
                    channel.configureHTTP2SecureUpgrade(
                        h2ChannelConfigurator: { channel in
                            channel.configureHTTP2Pipeline(
                                mode: .client,
                                connectionConfiguration:
                                    NIOHTTP2Handler
                                    .ConnectionConfiguration(),
                                streamConfiguration:
                                    NIOHTTP2Handler
                                    .StreamConfiguration()
                            ) { streamChannel in
                                streamChannel.eventLoop.makeSucceededVoidFuture()
                            }.map { multiplexer in
                                multiplexerPromise.succeed(multiplexer)
                            }
                        },
                        http1ChannelConfigurator: { channel in
                            let error = ProxyLensError.unsupportedOperation(
                                "Expected HTTP/2 ALPN negotiation"
                            )
                            multiplexerPromise.fail(error)
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    )
                }
        }.flatMap { $0 }
    }
}

private final class ConnectResponseHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<UInt>
    private var statusCode: UInt?

    init(promise: EventLoopPromise<UInt>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            statusCode = head.status.code
        case .body:
            break
        case .end:
            promise.succeed(statusCode ?? 0)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

private final class TLSHandshakeHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let promise: EventLoopPromise<Void>
    private var didComplete = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent {
            complete { $0.succeed(()) }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete { $0.fail(error) }
        context.fireErrorCaught(error)
    }

    // A peer that closes the raw connection before ever completing (or failing) the TLS
    // handshake at the record layer — e.g. a bare TCP close with no alert — would otherwise
    // leave `promise` unresolved forever and hang any test `await`ing it.
    func channelInactive(context: ChannelHandlerContext) {
        complete { $0.fail(ChannelError.eof) }
        context.fireChannelInactive()
    }

    private func complete(_ action: (EventLoopPromise<Void>) -> Void) {
        guard !didComplete else { return }
        didComplete = true
        action(promise)
    }
}

private enum HTTPTestClient {
    static func get(
        url: String,
        through proxy: NetworkEndpoint,
        extraHeaders: [(String, String)] = []
    ) async throws -> HTTPTestResponse {
        try await request(
            method: .GET,
            url: url,
            body: nil,
            through: proxy,
            extraHeaders: extraHeaders
        )
    }

    static func post(
        url: String,
        body: Data,
        through proxy: NetworkEndpoint,
        extraHeaders: [(String, String)] = []
    ) async throws -> HTTPTestResponse {
        try await request(
            method: .POST,
            url: url,
            body: body,
            through: proxy,
            extraHeaders: extraHeaders
        )
    }

    static func connect(
        authority: String,
        through proxy: NetworkEndpoint
    ) async throws -> HTTPTestResponse {
        try await request(
            method: .CONNECT,
            url: authority,
            body: nil,
            through: proxy,
            extraHeaders: [("Host", authority)]
        )
    }

    static func postThenDisconnect(
        url: String,
        body: Data,
        through proxy: NetworkEndpoint
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHTTPClientHandlers()
                }
                .connect(host: proxy.host, port: Int(proxy.port))
                .get()

            var headers = NIOHTTP1.HTTPHeaders()
            if let targetURL = URL(string: url), let host = targetURL.host {
                let port = targetURL.port.map { ":\($0)" } ?? ""
                headers.add(name: "Host", value: "\(host)\(port)")
            }
            headers.add(name: "Content-Length", value: "\(body.count)")
            headers.add(name: "Content-Type", value: "text/plain")

            channel.write(
                HTTPClientRequestPart.head(
                    HTTPRequestHead(
                        version: .http1_1,
                        method: .POST,
                        uri: url,
                        headers: headers
                    )
                ),
                promise: nil
            )
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
            try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
            try await channel.close().get()
            await shutdown(group)
        } catch {
            await shutdown(group)
            throw error
        }
    }

    private static func request(
        method: NIOHTTP1.HTTPMethod,
        url: String,
        body: Data?,
        through proxy: NetworkEndpoint,
        extraHeaders: [(String, String)] = []
    ) async throws -> HTTPTestResponse {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let promise = group.next().makePromise(of: HTTPTestResponse.self)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().flatMapThrowing {
                    try channel.pipeline.syncOperations.addHandler(
                        HTTPTestResponseHandler(promise: promise)
                    )
                }
            }

        do {
            let channel = try await bootstrap.connect(host: proxy.host, port: Int(proxy.port)).get()
            var headers = NIOHTTP1.HTTPHeaders()
            if let targetURL = URL(string: url), let host = targetURL.host {
                let port = targetURL.port.map { ":\($0)" } ?? ""
                headers.add(name: "Host", value: "\(host)\(port)")
            }
            headers.add(name: "Connection", value: "close")
            for (name, value) in extraHeaders {
                headers.add(name: name, value: value)
            }
            if let body {
                headers.add(name: "Content-Length", value: "\(body.count)")
                if !headers.contains(name: "Content-Type") {
                    headers.add(name: "Content-Type", value: "text/plain")
                }
            }

            let request = HTTPRequestHead(
                version: .http1_1,
                method: method,
                uri: url,
                headers: headers
            )
            channel.write(HTTPClientRequestPart.head(request), promise: nil)
            if let body {
                var buffer = channel.allocator.buffer(capacity: body.count)
                buffer.writeBytes(body)
                channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
            }
            channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)

            let response = try await promise.futureResult.get()
            await shutdown(group)
            return response
        } catch {
            await shutdown(group)
            throw error
        }
    }
}

private final class HTTPTestResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let promise: EventLoopPromise<HTTPTestResponse>
    private var statusCode: UInt = 0
    private var version = NIOHTTP1.HTTPVersion.http1_1
    private var headers: [(String, String)] = []
    private var body = Data()
    private var isFinished = false

    init(promise: EventLoopPromise<HTTPTestResponse>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            statusCode = head.status.code
            version = head.version
            headers = head.headers.map { ($0.0, $0.1) }
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            isFinished = true
            promise.succeed(
                HTTPTestResponse(
                    statusCode: statusCode,
                    version: version,
                    headers: headers,
                    body: body
                )
            )
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        isFinished = true
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !isFinished {
            isFinished = true
            promise.fail(ChannelError.eof)
        }
        context.fireChannelInactive()
    }
}

private final class TestHTTPServer {
    let endpoint: NetworkEndpoint

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let state: TestHTTPServerState

    var requestCount: Int {
        state.requestCount
    }

    var connectionCount: Int {
        state.connectionCount
    }

    var activeConnectionCount: Int {
        state.activeConnectionCount
    }

    var requestURI: String? {
        state.requestURI
    }

    var requestMethod: String? {
        state.requestMethod
    }

    func requestHeader(_ name: String) -> String? {
        state.headerValue(name)
    }

    private init(
        group: MultiThreadedEventLoopGroup,
        channel: Channel,
        state: TestHTTPServerState
    ) throws {
        guard let address = channel.localAddress,
            let port = address.port,
            let boundPort = UInt16(exactly: port)
        else {
            throw ProxyLensError.unsupportedOperation("Test server has no local address")
        }

        self.group = group
        self.channel = channel
        self.state = state
        self.endpoint = NetworkEndpoint(
            host: address.ipAddress ?? "127.0.0.1",
            port: boundPort
        )
    }

    static func start(
        responseBody: String,
        extraResponseHeaders: [(String, String)] = []
    ) async throws -> TestHTTPServer {
        try await start(
            responseData: Data(responseBody.utf8),
            tlsContext: nil,
            extraResponseHeaders: extraResponseHeaders
        )
    }

    static func start(
        responseData: Data,
        extraResponseHeaders: [(String, String)] = []
    ) async throws -> TestHTTPServer {
        try await start(
            responseData: responseData,
            tlsContext: nil,
            extraResponseHeaders: extraResponseHeaders
        )
    }

    static func startHanging() async throws -> TestHTTPServer {
        try await start(responseData: Data(), tlsContext: nil, responds: false)
    }

    static func startDroppingAfterPartialResponse() async throws -> TestHTTPServer {
        try await start(
            responseData: Data("partial".utf8),
            tlsContext: nil,
            closeAfterPartialResponse: true
        )
    }

    static func startHTTPS(
        responseBody: String,
        identity: CertificateIdentity
    ) async throws -> TestHTTPServer {
        try await start(
            responseData: Data(responseBody.utf8),
            tlsContext: testTLSServerContext(
                identity: identity,
                applicationProtocols: ["http/1.1"]
            )
        )
    }

    static func startHTTP2(
        responseBody: String,
        identity: CertificateIdentity
    ) async throws -> TestHTTPServer {
        try await start(
            responseData: Data(responseBody.utf8),
            tlsContext: testTLSServerContext(
                identity: identity,
                applicationProtocols: ["h2"]
            ),
            usesHTTP2: true
        )
    }

    private static func start(
        responseData: Data,
        tlsContext: NIOSSLContext?,
        responds: Bool = true,
        extraResponseHeaders: [(String, String)] = [],
        closeAfterPartialResponse: Bool = false,
        usesHTTP2: Bool = false
    ) async throws -> TestHTTPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let state = TestHTTPServerState()
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    state.recordConnection()
                    channel.closeFuture.whenComplete { _ in
                        state.recordDisconnection()
                    }
                    do {
                        if let tlsContext {
                            try channel.pipeline.syncOperations.addHandler(
                                NIOSSLServerHandler(context: tlsContext)
                            )
                        }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                    if usesHTTP2 {
                        return channel.configureHTTP2Pipeline(
                            mode: .server,
                            connectionConfiguration: .init(),
                            streamConfiguration: .init()
                        ) { streamChannel in
                            streamChannel.eventLoop.makeCompletedFuture {
                                let operations = streamChannel.pipeline.syncOperations
                                try operations.addHandler(
                                    HTTP2FramePayloadToHTTP1ServerCodec()
                                )
                                try operations.addHandler(
                                    TestHTTPServerHandler(
                                        responseData: responseData,
                                        responds: responds,
                                        extraResponseHeaders: extraResponseHeaders,
                                        closeAfterPartialResponse: closeAfterPartialResponse,
                                        state: state
                                    )
                                )
                            }
                        }.map { _ in () }
                    }
                    return channel.eventLoop.makeCompletedFuture(
                        Result<Void, Error> {
                            let operations = channel.pipeline.syncOperations
                            try operations.configureHTTPServerPipeline(
                                withPipeliningAssistance: false,
                                withErrorHandling: true
                            )
                            try operations.addHandler(
                                TestHTTPServerHandler(
                                    responseData: responseData,
                                    responds: responds,
                                    extraResponseHeaders: extraResponseHeaders,
                                    closeAfterPartialResponse: closeAfterPartialResponse,
                                    state: state
                                )
                            )
                        }
                    )
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            return try TestHTTPServer(group: group, channel: channel, state: state)
        } catch {
            await shutdown(group)
            throw error
        }
    }

    func stop() async {
        _ = try? await channel.close().get()
        await shutdown(group)
    }
}

private final class TestHTTPServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var connectionCountValue = 0
    private var activeConnectionCountValue = 0
    private var requestCountValue = 0
    private var lastRequestURI: String?
    private var lastRequestMethod: String?
    private var lastRequestHeaders: [(String, String)] = []

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCountValue
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connectionCountValue
    }

    var activeConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeConnectionCountValue
    }

    func recordConnection() {
        lock.lock()
        connectionCountValue += 1
        activeConnectionCountValue += 1
        lock.unlock()
    }

    func recordDisconnection() {
        lock.lock()
        activeConnectionCountValue -= 1
        lock.unlock()
    }

    var requestURI: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequestURI
    }

    var requestMethod: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequestMethod
    }

    func recordRequest(
        method: NIOHTTP1.HTTPMethod,
        uri: String,
        headers: NIOHTTP1.HTTPHeaders
    ) {
        lock.lock()
        defer { lock.unlock() }
        requestCountValue += 1
        lastRequestURI = uri
        lastRequestMethod = method.rawValue
        lastRequestHeaders = headers.map { ($0.0, $0.1) }
    }

    func headerValue(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequestHeaders.first { $0.0.lowercased() == name.lowercased() }?.1
    }
}

private func testTLSServerContext(
    identity: CertificateIdentity,
    applicationProtocols: [String]
) throws -> NIOSSLContext {
    let certificates = try NIOSSLCertificate.fromPEMBytes(Array(identity.certificateData))
    let privateKey = try NIOSSLPrivateKey(
        bytes: Array(identity.privateKeyData),
        format: .pem
    )
    var configuration = TLSConfiguration.makeServerConfiguration(
        certificateChain: certificates.map { .certificate($0) },
        privateKey: .privateKey(privateKey)
    )
    configuration.minimumTLSVersion = .tlsv12
    configuration.applicationProtocols = applicationProtocols
    return try NIOSSLContext(configuration: configuration)
}

private final class TestHTTPServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let responseData: Data
    private let responds: Bool
    private let extraResponseHeaders: [(String, String)]
    private let closeAfterPartialResponse: Bool
    private let state: TestHTTPServerState
    private var requestBody = Data()

    init(
        responseData: Data,
        responds: Bool,
        extraResponseHeaders: [(String, String)],
        closeAfterPartialResponse: Bool,
        state: TestHTTPServerState
    ) {
        self.responseData = responseData
        self.responds = responds
        self.extraResponseHeaders = extraResponseHeaders
        self.closeAfterPartialResponse = closeAfterPartialResponse
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            state.recordRequest(method: head.method, uri: head.uri, headers: head.headers)
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                requestBody.append(contentsOf: bytes)
            }
        case .end:
            guard responds else {
                return
            }
            let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            if closeAfterPartialResponse {
                var headers = NIOHTTP1.HTTPHeaders()
                headers.add(name: "Content-Type", value: "text/plain")
                headers.add(name: "Content-Length", value: "32")
                headers.add(name: "Connection", value: "close")
                let head = HTTPResponseHead(
                    version: .http1_1,
                    status: .ok,
                    headers: headers
                )
                context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
                var body = context.channel.allocator.buffer(capacity: responseData.count)
                body.writeBytes(responseData)
                let flushed = context.eventLoop.makePromise(of: Void.self)
                context.writeAndFlush(
                    Self.wrapOutboundOut(.body(.byteBuffer(body))),
                    promise: flushed
                )
                flushed.futureResult.whenComplete { _ in
                    loopBoundContext.value.close(promise: nil)
                }
                return
            }
            var completeResponseData = responseData
            if !requestBody.isEmpty {
                completeResponseData.append(
                    Data(":\(String(decoding: requestBody, as: UTF8.self))".utf8)
                )
            }

            var body = context.channel.allocator.buffer(capacity: completeResponseData.count)
            body.writeBytes(completeResponseData)

            var headers = NIOHTTP1.HTTPHeaders()
            if !extraResponseHeaders.contains(where: {
                $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame
            }) {
                headers.add(name: "Content-Type", value: "text/plain")
            }
            headers.add(name: "Content-Length", value: "\(body.readableBytes)")
            headers.add(name: "Connection", value: "close")
            for (name, value) in extraResponseHeaders {
                headers.add(name: name, value: value)
            }

            let head = HTTPResponseHead(
                version: .http1_1,
                status: .ok,
                headers: headers
            )
            context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(Self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                loopBoundContext.value.close(promise: nil)
            }
        }
    }
}

private struct StubScriptExecutor: ScriptExecutor {
    let handler: @Sendable (ScriptExecutionRequest) async throws -> ScriptExecutionResult

    init(
        handler: @escaping @Sendable (ScriptExecutionRequest) async throws -> ScriptExecutionResult
    ) {
        self.handler = handler
    }

    func execute(_ request: ScriptExecutionRequest) async throws -> ScriptExecutionResult {
        try await handler(request)
    }
}

private func shutdown(_ group: MultiThreadedEventLoopGroup) async {
    await withCheckedContinuation { continuation in
        group.shutdownGracefully { _ in
            continuation.resume()
        }
    }
}

private enum SecureWebSocketTestClient {
    static func exchangeDetails(
        url: String,
        through proxy: NetworkEndpoint,
        trustedRootCertificate: Data,
        initialMessage: String,
        expectedResponseCount: Int
    ) async throws -> WebSocketTestExchange {
        guard let target = URL(string: url), let host = target.host, let port = target.port else {
            throw ProxyLensError.invalidURL(url)
        }
        let path = target.path.isEmpty ? "/" : target.path
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ClientBootstrap(group: group)
                .connect(host: proxy.host, port: Int(proxy.port))
                .get()

            let connectPromise = channel.eventLoop.makePromise(of: UInt.self)
            try await HTTPSTestPipeline.installConnectHandlers(
                on: channel,
                promise: connectPromise
            ).get()

            var connectHeaders = NIOHTTP1.HTTPHeaders()
            connectHeaders.add(name: "Host", value: "\(host):\(port)")
            channel.write(
                HTTPClientRequestPart.head(
                    HTTPRequestHead(
                        version: .http1_1,
                        method: .CONNECT,
                        uri: "\(host):\(port)",
                        headers: connectHeaders
                    )
                ),
                promise: nil
            )
            channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)

            let connectStatus = try await connectPromise.futureResult.get()
            guard connectStatus == 200 else {
                throw ProxyLensError.unsupportedOperation(
                    "The proxy rejected CONNECT with status \(connectStatus)"
                )
            }

            try await channel.setOption(ChannelOptions.autoRead, value: false).get()

            let trustedRoots = try NIOSSLCertificate.fromPEMBytes(Array(trustedRootCertificate))
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.minimumTLSVersion = .tlsv12
            tlsConfiguration.additionalTrustRoots = [.certificates(trustedRoots)]
            let tlsContext = try NIOSSLContext(configuration: tlsConfiguration)
            let handshakePromise = channel.eventLoop.makePromise(of: Void.self)

            try await HTTPSTestPipeline.replaceConnectHandlersWithTLSOnly(
                on: channel,
                tlsContext: tlsContext,
                serverHostname: host,
                handshakePromise: handshakePromise
            ).get()
            try await channel.setOption(ChannelOptions.autoRead, value: true).get()
            try await handshakePromise.futureResult.get()

            let responsePromise = channel.eventLoop.makePromise(of: WebSocketTestExchange.self)
            let upgrader = NIOWebSocketClientUpgrader(
                requestKey: "AQIDBAUGBwgJCgsMDQ4PEC==",
                upgradePipelineHandler: { channel, responseHead in
                    channel.pipeline.addHandler(
                        WebSocketTestResponseHandler(
                            promise: responsePromise,
                            expectedResponseCount: expectedResponseCount,
                            responseHeaders: responseHead.headers.map { ($0.name, $0.value) }
                        )
                    ).flatMap {
                        var payload = channel.allocator.buffer(capacity: initialMessage.utf8.count)
                        payload.writeString(initialMessage)
                        return channel.writeAndFlush(
                            WebSocketFrame(
                                fin: true,
                                opcode: .text,
                                maskKey: [1, 2, 3, 4],
                                data: payload
                            )
                        )
                    }
                }
            )
            let configuration: NIOHTTPClientUpgradeSendableConfiguration = (
                upgraders: [upgrader],
                completionHandler: { _ in }
            )
            try await channel.pipeline.addHTTPClientHandlers(
                withClientUpgrade: configuration
            ).get()

            let timeout = channel.eventLoop.scheduleTask(in: .seconds(5)) {
                responsePromise.fail(
                    ProxyLensError.unsupportedOperation(
                        "Timed out waiting for the secure WebSocket echo response"
                    )
                )
            }
            responsePromise.futureResult.whenComplete { _ in
                timeout.cancel()
            }

            var upgradeHeaders = NIOHTTP1.HTTPHeaders()
            upgradeHeaders.add(name: "Host", value: "\(host):\(port)")
            upgradeHeaders.add(name: "Content-Length", value: "0")
            channel.write(
                HTTPClientRequestPart.head(
                    HTTPRequestHead(
                        version: .http1_1,
                        method: .GET,
                        uri: path,
                        headers: upgradeHeaders
                    )
                ),
                promise: nil
            )
            channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)

            let result = try await responsePromise.futureResult.get()
            _ = try? await channel.close().get()
            await shutdown(group)
            return result
        } catch {
            await shutdown(group)
            throw error
        }
    }
}
