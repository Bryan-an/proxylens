import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import ProxyLensCore
import XCTest

@testable import ProxyLensCapture

/// Covers the two halves of device onboarding that live in the data plane: admitting a
/// client through the remote-access gate, and answering the local certificate routes.
final class RemoteDeviceOnboardingTests: XCTestCase {
    func testDeniedClientIsClosedWithoutCapturingAFlow() async throws {
        let eventSink = RecordingEventSink()
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            remoteAccessGate: FixedRemoteAccessGate(decision: .deny)
        )
        let proxy = try await start(engine)

        let response = try await ProxyHTTPClient.send(
            uri: "http://example.com/blocked",
            to: proxy
        )

        XCTAssertNil(response, "A denied client must be closed without a response")
        let events = await eventSink.events()
        XCTAssertTrue(events.isEmpty, "A denied client must not produce a flow")

        await engine.stop()
    }

    func testAllowedClientIsProxiedAndItsEndpointIsOfferedToTheGate() async throws {
        let upstream = try await LocalHTTPServer.start(body: "upstream response")
        let gate = RecordingRemoteAccessGate(decision: .allow)
        let engine = NIOProxyEngine(remoteAccessGate: gate)
        let proxy = try await start(engine)

        do {
            let response = try await ProxyHTTPClient.send(
                uri: "http://127.0.0.1:\(upstream.endpoint.port)/hello",
                to: proxy
            )

            XCTAssertEqual(response?.statusCode, 200)
            XCTAssertEqual(response?.body, Data("upstream response".utf8))

            let clients = await gate.clients()
            XCTAssertEqual(clients.count, 1)
            XCTAssertEqual(clients.first?.address, "127.0.0.1")
            XCTAssertTrue(clients.first?.isLoopback == true)
            XCTAssertGreaterThan(clients.first?.port ?? 0, 0)
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testTheGateIsNotConsultedForReverseProxyListeners() async throws {
        let upstream = try await LocalHTTPServer.start(body: "reverse response")
        let gate = RecordingRemoteAccessGate(decision: .deny)
        let engine = NIOProxyEngine(remoteAccessGate: gate)
        let listenPort = try await Self.reserveLoopbackPort()
        let route = try ReverseProxyRoute(
            name: "Local API",
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: listenPort),
            upstreamURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(upstream.endpoint.port)"))
        )

        _ = try await start(engine, reverseProxyRoutes: [route])

        do {
            // A reverse listener is loopback-only by construction and serves a fixed
            // upstream, so it must not be subject to the device gate. If it were, this
            // request would be closed unanswered by the denying gate.
            let response = try await ProxyHTTPClient.send(
                uri: "/hello",
                to: NetworkEndpoint(host: "127.0.0.1", port: listenPort)
            )

            XCTAssertEqual(response?.statusCode, 200)
            XCTAssertEqual(response?.body, Data("reverse response".utf8))
            let clients = await gate.clients()
            XCTAssertTrue(clients.isEmpty, "Reverse listeners must not consult the device gate")
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testForwardListenerBindsTheConfiguredLoopbackHostWhenRemoteAccessIsOff() async throws {
        let engine = NIOProxyEngine()
        let configuration = ProxyConfiguration(
            listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
            interceptHTTPS: false
        )

        try await engine.start(configuration: configuration, sessionID: SessionID())

        guard case .running(let endpoint) = await engine.state() else {
            await engine.stop()
            return XCTFail("Expected the proxy engine to be running")
        }
        XCTAssertEqual(endpoint.host, configuration.forwardListenHost)
        XCTAssertEqual(endpoint.host, "127.0.0.1")

        await engine.stop()
    }

    // MARK: - Certificate distribution

    func testSetupPageIsServedInOriginFormToADeviceThatIsNotProxyingYet() async throws {
        let engine = NIOProxyEngine(certificateProvider: StubCertificateProvider())
        let proxy = try await start(engine)

        let response = try await ProxyHTTPClient.send(uri: "/ssl", to: proxy)

        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.headerValue("Content-Type"), "text/html; charset=utf-8")
        let html = String(decoding: response?.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(html.contains("127.0.0.1"))
        XCTAssertTrue(html.contains(String(proxy.port)))
        XCTAssertTrue(html.contains(CertificateDistribution.derCertificatePath))

        await engine.stop()
    }

    func testSetupPageIsServedInAbsoluteFormThroughTheReservedHost() async throws {
        let engine = NIOProxyEngine(certificateProvider: StubCertificateProvider())
        let proxy = try await start(engine)

        let response = try await ProxyHTTPClient.send(
            uri: "http://proxy.lens/ssl",
            to: proxy
        )

        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.headerValue("Content-Type"), "text/html; charset=utf-8")

        await engine.stop()
    }

    func testCertificateDownloadsCarryTheRootCertificateInBothEncodings() async throws {
        let provider = StubCertificateProvider()
        let engine = NIOProxyEngine(certificateProvider: provider)
        let proxy = try await start(engine)

        let der = try await ProxyHTTPClient.send(uri: "/proxylens.crt", to: proxy)
        let pem = try await ProxyHTTPClient.send(uri: "/proxylens.pem", to: proxy)

        XCTAssertEqual(der?.statusCode, 200)
        XCTAssertEqual(der?.headerValue("Content-Type"), "application/x-x509-ca-cert")
        XCTAssertEqual(
            der?.headerValue("Content-Disposition"),
            "attachment; filename=\"proxylens.crt\""
        )
        XCTAssertEqual(
            der?.body,
            try CertificateDistribution.derEncodedCertificate(
                fromPEM: StubCertificateProvider.rootPEM
            )
        )

        XCTAssertEqual(pem?.statusCode, 200)
        XCTAssertEqual(pem?.headerValue("Content-Type"), "application/x-pem-file")
        XCTAssertEqual(pem?.body, StubCertificateProvider.rootPEM)

        await engine.stop()
    }

    func testARealRequestForTheSamePathIsStillProxied() async throws {
        let upstream = try await LocalHTTPServer.start(body: "upstream response")
        let eventSink = RecordingEventSink()
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            certificateProvider: StubCertificateProvider()
        )
        let proxy = try await start(engine)

        do {
            let response = try await ProxyHTTPClient.send(
                uri: "http://127.0.0.1:\(upstream.endpoint.port)/ssl",
                to: proxy
            )

            XCTAssertEqual(response?.statusCode, 200)
            XCTAssertEqual(response?.body, Data("upstream response".utf8))
        } catch {
            await engine.stop()
            await upstream.stop()
            throw error
        }

        await engine.stop()
        await upstream.stop()
    }

    func testCertificateDownloadIsUnavailableWithoutACertificateProvider() async throws {
        let engine = NIOProxyEngine()
        let proxy = try await start(engine)

        let response = try await ProxyHTTPClient.send(uri: "/proxylens.crt", to: proxy)

        XCTAssertEqual(response?.statusCode, 503)

        await engine.stop()
    }

    func testTheSetupPageIsNotRecordedAsAFlow() async throws {
        let eventSink = RecordingEventSink()
        let engine = NIOProxyEngine(
            eventSink: eventSink,
            certificateProvider: StubCertificateProvider()
        )
        let proxy = try await start(engine)

        _ = try await ProxyHTTPClient.send(uri: "/ssl", to: proxy)

        let events = await eventSink.events()
        XCTAssertTrue(events.isEmpty, "Serving ProxyLens' own page is not captured traffic")

        await engine.stop()
    }

    // MARK: - Helpers

    /// Binds an ephemeral loopback port and releases it, so a listener that needs a known
    /// port up front can use it. Reverse-proxy listeners do not publish their bound port.
    private static func reserveLoopbackPort() async throws -> UInt16 {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = channel.localAddress?.port
        try? await channel.close().get()
        try? await group.shutdownGracefully()

        guard let port, port > 0 else {
            throw ProxyLensError.unsupportedOperation("Could not reserve a loopback port")
        }
        return UInt16(port)
    }

    private func start(
        _ engine: NIOProxyEngine,
        reverseProxyRoutes: [ReverseProxyRoute] = []
    ) async throws -> NetworkEndpoint {
        try await engine.start(
            configuration: ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                interceptHTTPS: false,
                reverseProxyRoutes: reverseProxyRoutes
            ),
            sessionID: SessionID()
        )
        guard case .running(let endpoint) = await engine.state() else {
            throw XCTSkip("The proxy engine did not start")
        }
        return endpoint
    }
}

// MARK: - Test doubles

private struct FixedRemoteAccessGate: RemoteAccessGate {
    let decision: RemoteAccessDecision

    func authorize(_: RemoteAccessClient) async -> RemoteAccessDecision {
        decision
    }
}

private actor RecordingRemoteAccessGate: RemoteAccessGate {
    private let decision: RemoteAccessDecision
    private var recorded: [RemoteAccessClient] = []

    init(decision: RemoteAccessDecision) {
        self.decision = decision
    }

    func authorize(_ client: RemoteAccessClient) async -> RemoteAccessDecision {
        recorded.append(client)
        return decision
    }

    func clients() -> [RemoteAccessClient] {
        recorded
    }
}

/// Returns fixed material so certificate distribution can be tested without a keychain.
private struct StubCertificateProvider: CertificateProvider {
    static let rootDER = Data([0x30, 0x82, 0x00, 0x04, 0x01, 0x02, 0x03, 0x04])

    static let rootPEM = Data(
        """
        -----BEGIN CERTIFICATE-----
        \(rootDER.base64EncodedString())
        -----END CERTIFICATE-----

        """.utf8
    )

    func rootCertificate() async throws -> Data {
        Self.rootPEM
    }

    func leafCertificate(for _: String) async throws -> CertificateIdentity {
        throw ProxyLensError.unsupportedOperation("The stub provider issues no leaves")
    }
}

private actor RecordingEventSink: FlowEventSink {
    private var recorded: [FlowEvent] = []

    func publish(_ event: FlowEvent) async {
        recorded.append(event)
    }

    func events() -> [FlowEvent] {
        recorded
    }
}

// MARK: - Local HTTP client and server

private struct ProxyHTTPResponse {
    let statusCode: Int
    let headers: [(name: String, value: String)]
    let body: Data

    func headerValue(_ name: String) -> String? {
        headers.first { $0.name.lowercased() == name.lowercased() }?.value
    }
}

private enum ProxyHTTPClient {
    /// Sends one request to `endpoint` and returns the response, or `nil` when the peer
    /// closed the connection without sending one.
    ///
    /// `uri` is used verbatim, so it can be either an absolute proxy target or an
    /// origin-form path aimed at the listener itself.
    static func send(
        uri: String,
        host: String? = nil,
        to endpoint: NetworkEndpoint
    ) async throws -> ProxyHTTPResponse? {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let response = try await send(uri: uri, host: host, to: endpoint, group: group)
            try? await group.shutdownGracefully()
            return response
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private static func send(
        uri: String,
        host: String?,
        to endpoint: NetworkEndpoint,
        group: MultiThreadedEventLoopGroup
    ) async throws -> ProxyHTTPResponse? {
        let promise = group.next().makePromise(of: CollectedResponse.self)
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(
                        ResponseCollector(promise: promise)
                    )
                }
            }
            .connect(host: endpoint.host, port: Int(endpoint.port))
            .get()

        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Host", value: host ?? Self.host(for: uri, fallback: endpoint))
        headers.add(name: "Connection", value: "close")
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: headers)

        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        let collected = try await promise.futureResult.get()
        try? await channel.close().get()

        guard let head = collected.head else {
            return nil
        }
        return ProxyHTTPResponse(
            statusCode: Int(head.status.code),
            headers: head.headers.map { (name: $0.name, value: $0.value) },
            body: collected.body
        )
    }

    private static func host(for uri: String, fallback: NetworkEndpoint) -> String {
        guard let url = URL(string: uri), let host = url.host else {
            return "\(fallback.host):\(fallback.port)"
        }
        guard let port = url.port else {
            return host
        }
        return "\(host):\(port)"
    }

    fileprivate struct CollectedResponse: Sendable {
        var head: HTTPResponseHead?
        var body: Data
    }

    private final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPClientResponsePart

        private let promise: EventLoopPromise<CollectedResponse>
        private var collected = CollectedResponse(head: nil, body: Data())
        private var isFinished = false

        init(promise: EventLoopPromise<CollectedResponse>) {
            self.promise = promise
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                collected.head = head
            case .body(var buffer):
                if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                    collected.body.append(contentsOf: bytes)
                }
            case .end:
                finish()
                context.close(promise: nil)
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            finish()
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error _: Error) {
            finish()
            context.close(promise: nil)
        }

        private func finish() {
            guard !isFinished else {
                return
            }
            isFinished = true
            promise.succeed(collected)
        }
    }
}

/// A minimal upstream so the proxy has somewhere to forward to. Loopback only.
private final class LocalHTTPServer {
    let endpoint: NetworkEndpoint
    private let channel: Channel
    private let group: MultiThreadedEventLoopGroup

    private init(channel: Channel, group: MultiThreadedEventLoopGroup, endpoint: NetworkEndpoint) {
        self.channel = channel
        self.group = group
        self.endpoint = endpoint
    }

    static func start(body: String) async throws -> LocalHTTPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(StaticResponder(body: body))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        guard let port = channel.localAddress?.port else {
            try? await channel.close().get()
            try? await group.shutdownGracefully()
            throw ProxyLensError.unsupportedOperation("The local test server did not bind")
        }

        return LocalHTTPServer(
            channel: channel,
            group: group,
            endpoint: NetworkEndpoint(host: "127.0.0.1", port: UInt16(port))
        )
    }

    func stop() async {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    private final class StaticResponder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let body: String

        init(body: String) {
            self.body = body
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .end = unwrapInboundIn(data) else {
                return
            }

            var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)

            var headers = NIOHTTP1.HTTPHeaders()
            headers.add(name: "Content-Length", value: "\(buffer.readableBytes)")
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")

            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }
}
