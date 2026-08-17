import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
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

    func testConnectIsRejectedWhenInterceptionIsDisabled() throws {
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

        _ = try channel.writeInbound(HTTPServerRequestPart.head(head))

        let response = try XCTUnwrap(channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .head(let responseHead) = response else {
            return XCTFail("Expected an HTTP response head")
        }

        XCTAssertEqual(responseHead.status.code, 501)
        XCTAssertEqual(responseHead.status.reasonPhrase, "Not Implemented")
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

private final class TestWebSocketServer {
    let endpoint: NetworkEndpoint

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(group: MultiThreadedEventLoopGroup, channel: Channel) throws {
        guard let address = channel.localAddress,
            let port = address.port,
            let boundPort = UInt16(exactly: port)
        else {
            throw ProxyLensError.unsupportedOperation("Test WebSocket server has no local address")
        }
        self.group = group
        self.channel = channel
        endpoint = NetworkEndpoint(host: address.ipAddress ?? "127.0.0.1", port: boundPort)
    }

    static func start() async throws -> TestWebSocketServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    let upgrader = NIOWebSocketServerUpgrader(
                        shouldUpgrade: { channel, request in
                            channel.eventLoop.makeSucceededFuture(
                                request.uri == "/echo" ? NIOHTTP1.HTTPHeaders() : nil
                            )
                        },
                        upgradePipelineHandler: { channel, _ in
                            channel.pipeline.addHandler(WebSocketEchoHandler())
                        }
                    )
                    let configuration: NIOHTTPServerUpgradeSendableConfiguration = (
                        upgraders: [upgrader],
                        completionHandler: { _ in }
                    )
                    return channel.pipeline.configureHTTPServerPipeline(
                        withPipeliningAssistance: false,
                        withServerUpgrade: configuration
                    )
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            return try TestWebSocketServer(group: group, channel: channel)
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

private enum WebSocketTestClient {
    static func exchange(
        url: String,
        through proxy: NetworkEndpoint,
        message: String
    ) async throws -> String {
        guard let target = URL(string: url), let host = target.host, let port = target.port else {
            throw ProxyLensError.invalidURL(url)
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let responsePromise = group.next().makePromise(of: String.self)
        let requestHandler = WebSocketUpgradeRequestHandler(
            url: url,
            hostHeader: "\(host):\(port)",
            responsePromise: responsePromise
        )
        let upgrader = NIOWebSocketClientUpgrader(
            requestKey: "AQIDBAUGBwgJCgsMDQ4PEC==",
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(
                    WebSocketTestResponseHandler(promise: responsePromise)
                ).flatMap {
                    var payload = channel.allocator.buffer(capacity: message.utf8.count)
                    payload.writeString(message)
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
            let response = try await responsePromise.futureResult.get()
            _ = try? await channel.close().get()
            await shutdown(group)
            return response
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
    private let responsePromise: EventLoopPromise<String>

    init(
        url: String,
        hostHeader: String,
        responsePromise: EventLoopPromise<String>
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

    private let promise: EventLoopPromise<String>
    private var completed = false

    init(promise: EventLoopPromise<String>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        guard frame.opcode == .text else {
            return
        }
        completed = true
        promise.succeed(String(decoding: frame.unmaskedData.readableBytesView, as: UTF8.self))
        context.close(promise: nil)
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
    let headers: [(String, String)]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
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

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent {
            promise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.fireErrorCaught(error)
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

private final class HTTPTestResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let promise: EventLoopPromise<HTTPTestResponse>
    private var statusCode: UInt = 0
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
            headers = head.headers.map { ($0.0, $0.1) }
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            isFinished = true
            promise.succeed(
                HTTPTestResponse(statusCode: statusCode, headers: headers, body: body)
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

    var requestURI: String? {
        state.requestURI
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
            responseBody: responseBody,
            tlsContext: nil,
            extraResponseHeaders: extraResponseHeaders
        )
    }

    static func startHanging() async throws -> TestHTTPServer {
        try await start(responseBody: "", tlsContext: nil, responds: false)
    }

    static func startDroppingAfterPartialResponse() async throws -> TestHTTPServer {
        try await start(
            responseBody: "partial",
            tlsContext: nil,
            closeAfterPartialResponse: true
        )
    }

    static func startHTTPS(
        responseBody: String,
        identity: CertificateIdentity
    ) async throws -> TestHTTPServer {
        try await start(
            responseBody: responseBody,
            tlsContext: TLSContextFactory.serverContext(identity: identity)
        )
    }

    private static func start(
        responseBody: String,
        tlsContext: NIOSSLContext?,
        responds: Bool = true,
        extraResponseHeaders: [(String, String)] = [],
        closeAfterPartialResponse: Bool = false
    ) async throws -> TestHTTPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let state = TestHTTPServerState()
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture(
                        Result<Void, Error> {
                            let operations = channel.pipeline.syncOperations
                            if let tlsContext {
                                try operations.addHandler(
                                    NIOSSLServerHandler(context: tlsContext)
                                )
                            }
                            try operations.configureHTTPServerPipeline(
                                withPipeliningAssistance: false,
                                withErrorHandling: true
                            )
                            try operations.addHandler(
                                TestHTTPServerHandler(
                                    responseBody: responseBody,
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
    private var requestCountValue = 0
    private var lastRequestURI: String?
    private var lastRequestHeaders: [(String, String)] = []

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCountValue
    }

    var requestURI: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequestURI
    }

    func recordRequest(uri: String, headers: NIOHTTP1.HTTPHeaders) {
        lock.lock()
        defer { lock.unlock() }
        requestCountValue += 1
        lastRequestURI = uri
        lastRequestHeaders = headers.map { ($0.0, $0.1) }
    }

    func headerValue(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequestHeaders.first { $0.0.lowercased() == name.lowercased() }?.1
    }
}

private final class TestHTTPServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let responseBody: String
    private let responds: Bool
    private let extraResponseHeaders: [(String, String)]
    private let closeAfterPartialResponse: Bool
    private let state: TestHTTPServerState
    private var requestBody = Data()

    init(
        responseBody: String,
        responds: Bool,
        extraResponseHeaders: [(String, String)],
        closeAfterPartialResponse: Bool,
        state: TestHTTPServerState
    ) {
        self.responseBody = responseBody
        self.responds = responds
        self.extraResponseHeaders = extraResponseHeaders
        self.closeAfterPartialResponse = closeAfterPartialResponse
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            state.recordRequest(uri: head.uri, headers: head.headers)
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
                var body = context.channel.allocator.buffer(capacity: responseBody.utf8.count)
                body.writeString(responseBody)
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
            let bodySuffix =
                requestBody.isEmpty
                ? ""
                : ":\(String(decoding: requestBody, as: UTF8.self))"
            let responseText = responseBody + bodySuffix

            var body = context.channel.allocator.buffer(capacity: responseText.utf8.count)
            body.writeString(responseText)

            var headers = NIOHTTP1.HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain")
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

private func shutdown(_ group: MultiThreadedEventLoopGroup) async {
    await withCheckedContinuation { continuation in
        group.shutdownGracefully { _ in
            continuation.resume()
        }
    }
}
