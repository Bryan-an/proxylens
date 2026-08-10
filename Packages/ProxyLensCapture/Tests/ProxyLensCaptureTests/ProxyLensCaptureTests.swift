import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTLS
import ProxyLensCore
import ProxyLensPersistence
import ProxyLensPlatform
import XCTest

@testable import ProxyLensCapture

final class ProxyLensCaptureTests: XCTestCase {
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

        try await engine.start(configuration: configuration)

        let runningState = await engine.state()
        guard case .running(let endpoint) = runningState else {
            return XCTFail("Expected the proxy engine to be running")
        }
        XCTAssertGreaterThan(endpoint.port, 0)

        await engine.stop()
        let stoppedState = await engine.state()
        XCTAssertEqual(stoppedState, .stopped)
    }

    func testEngineStartPerformsPersistenceRecovery() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensStartupRecoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let database = try DatabaseController(
            configuration: DatabaseConfiguration(
                databaseURL: storageRoot.appendingPathComponent("capture.sqlite"),
                bodyDirectoryURL: storageRoot.appendingPathComponent("Bodies"),
                inlineBodyThreshold: 4
            )
        )
        let bodyStore = FileBodyStore(database: database)
        let sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
        let session = Session()
        try await sessionStore.saveSession(session)
        var incompleteFlow = Flow(
            sessionID: session.id,
            request: HTTPRequest(
                method: .get,
                url: URL(string: "http://example.test/incomplete")!
            )
        )
        try incompleteFlow.transition(to: .receivingRequest)
        try await sessionStore.save(incompleteFlow)
        let orphanedBody = try await bodyStore.put(
            Data("orphaned body".utf8),
            metadata: BodyMetadata()
        )
        let persistenceSink = PersistingFlowEventSink(flowStore: sessionStore)
        let engine = NIOProxyEngine(
            eventSink: persistenceSink,
            bodyStore: bodyStore
        )

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                )
            )
            let loadedSession = try await sessionStore.loadSession(sessionID: session.id)
            let loadedFlow = try await sessionStore.load(flowID: incompleteFlow.id)
            let recoveredSession = try XCTUnwrap(loadedSession)
            let recoveredFlow = try XCTUnwrap(loadedFlow)
            XCTAssertEqual(recoveredSession.state, .interrupted)
            guard case .failed(.persistenceError) = recoveredFlow.state else {
                XCTFail("Expected engine startup to fail an incomplete persisted flow")
                await engine.stop()
                return
            }
            do {
                _ = try await bodyStore.read(orphanedBody)
                XCTFail("Expected engine startup to remove the orphaned body")
            } catch {
                XCTAssertEqual(error as? PersistenceError, .bodyNotFound(orphanedBody.id))
            }
        } catch {
            await engine.stop()
            throw error
        }

        await engine.stop()
    }

    func testHTTPForwardingPublishesCompletedFlow() async throws {
        let upstream = try await TestHTTPServer.start(responseBody: "upstream response")
        let eventSink = RecordingFlowEventSink()
        let engine = NIOProxyEngine(eventSink: eventSink)

        do {
            try await engine.start(
                configuration: ProxyConfiguration(
                    listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                    interceptHTTPS: false
                )
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
                )
            )

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
                )
            )
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
                )
            )

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
}

private actor RecordingFlowEventSink: FlowEventSink {
    private var events: [FlowEvent] = []
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []

    func publish(_ event: FlowEvent) async {
        events.append(event)
        if case .finished = event {
            let waiters = finishedWaiters
            finishedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
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

    func snapshot() -> [FlowEvent] {
        events
    }
}

private struct HTTPTestResponse: Sendable {
    let statusCode: UInt
    let body: Data
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
    static func get(url: String, through proxy: NetworkEndpoint) async throws -> HTTPTestResponse {
        try await request(method: .GET, url: url, body: nil, through: proxy)
    }

    static func post(
        url: String,
        body: Data,
        through proxy: NetworkEndpoint
    ) async throws -> HTTPTestResponse {
        try await request(method: .POST, url: url, body: body, through: proxy)
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
        through proxy: NetworkEndpoint
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
            if let body {
                headers.add(name: "Content-Length", value: "\(body.count)")
                headers.add(name: "Content-Type", value: "text/plain")
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
    private var body = Data()

    init(promise: EventLoopPromise<HTTPTestResponse>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            statusCode = head.status.code
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            promise.succeed(HTTPTestResponse(statusCode: statusCode, body: body))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

private final class TestHTTPServer {
    let endpoint: NetworkEndpoint

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(group: MultiThreadedEventLoopGroup, channel: Channel) throws {
        guard let address = channel.localAddress,
            let port = address.port,
            let boundPort = UInt16(exactly: port)
        else {
            throw ProxyLensError.unsupportedOperation("Test server has no local address")
        }

        self.group = group
        self.channel = channel
        self.endpoint = NetworkEndpoint(
            host: address.ipAddress ?? "127.0.0.1",
            port: boundPort
        )
    }

    static func start(responseBody: String) async throws -> TestHTTPServer {
        try await start(responseBody: responseBody, tlsContext: nil)
    }

    static func startHanging() async throws -> TestHTTPServer {
        try await start(responseBody: "", tlsContext: nil, responds: false)
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
        responds: Bool = true
    ) async throws -> TestHTTPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
                                    responds: responds
                                )
                            )
                        }
                    )
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            return try TestHTTPServer(group: group, channel: channel)
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

private final class TestHTTPServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let responseBody: String
    private let responds: Bool
    private var requestBody = Data()

    init(responseBody: String, responds: Bool) {
        self.responseBody = responseBody
        self.responds = responds
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head:
            break
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                requestBody.append(contentsOf: bytes)
            }
        case .end:
            guard responds else {
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

            let head = HTTPResponseHead(
                version: .http1_1,
                status: .ok,
                headers: headers
            )
            context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
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
