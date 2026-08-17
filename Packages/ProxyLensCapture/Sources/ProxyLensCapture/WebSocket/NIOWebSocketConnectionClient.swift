import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import ProxyLensCore

public enum WebSocketConnectionError: Error, Equatable, LocalizedError, Sendable {
    case clientDirectionRequired
    case connectionClosed
    case connectionFailed(String)
    case invalidRequestMethod
    case payloadTooLarge(maximumBytes: Int)
    case requestBodyUnsupported
    case shutdown
    case timeout
    case unsupportedHTTPVersion(ProxyLensCore.HTTPVersion)
    case unsupportedOpcode
    case unsupportedScheme(String)
    case upgradeRejected(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .clientDirectionRequired:
            "A direct WebSocket client can only send frames to the server."
        case .connectionClosed:
            "The WebSocket connection is no longer open."
        case .connectionFailed(let message):
            "The WebSocket connection failed: \(message)"
        case .invalidRequestMethod:
            "A WebSocket handshake requires GET."
        case .payloadTooLarge(let maximumBytes):
            "The WebSocket frame exceeds the configured \(maximumBytes)-byte limit."
        case .requestBodyUnsupported:
            "A WebSocket handshake cannot include a request body."
        case .shutdown:
            "The WebSocket client has shut down."
        case .timeout:
            "The WebSocket handshake timed out."
        case .unsupportedHTTPVersion(let version):
            "A WebSocket handshake requires HTTP/1.1, not \(version.rawValue)."
        case .unsupportedOpcode:
            "The WebSocket composer supports text and binary messages."
        case .unsupportedScheme(let scheme):
            "WebSocket connections require ws:// or wss://, not \(scheme)."
        case .upgradeRejected(let statusCode):
            "The server rejected the WebSocket upgrade with HTTP \(statusCode)."
        }
    }
}

/// Opens new RFC 6455 client connections while publishing them as normal replay flows.
public actor NIOWebSocketConnectionClient: WebSocketConnectionClient {
    private let eventSink: any FlowEventSink
    private let webSocketFrameEventSink: any WebSocketFrameEventSink
    private let bodyStore: (any BodyStore)?
    private let maximumCapturedFrameBytes: Int64
    private let maximumWebSocketFrameBytes: Int
    private let upstreamTLSConfiguration: UpstreamTLSConfiguration
    private let handshakeTimeout: TimeAmount
    private let closeHandshakeTimeout: TimeAmount
    private let group: MultiThreadedEventLoopGroup
    private let connections = DirectWebSocketConnectionRegistry()
    private var isShutdown = false

    public init(
        eventLoopThreads: Int = 1,
        eventSink: any FlowEventSink = NoOpFlowEventSink(),
        webSocketFrameEventSink: (any WebSocketFrameEventSink)? = nil,
        bodyStore: (any BodyStore)? = nil,
        maximumCapturedFrameBytes: Int64 = 16 * 1_024 * 1_024,
        maximumWebSocketFrameBytes: Int = 16 * 1_024 * 1_024,
        upstreamTLSConfiguration: UpstreamTLSConfiguration = UpstreamTLSConfiguration(),
        handshakeTimeout: TimeAmount = .seconds(10),
        closeHandshakeTimeout: TimeAmount = .seconds(1)
    ) {
        self.eventSink = eventSink
        self.webSocketFrameEventSink =
            webSocketFrameEventSink ?? NoOpWebSocketFrameEventSink()
        self.bodyStore = bodyStore
        self.maximumCapturedFrameBytes = max(0, maximumCapturedFrameBytes)
        self.maximumWebSocketFrameBytes = min(
            max(1, maximumWebSocketFrameBytes),
            Int(UInt32.max)
        )
        self.upstreamTLSConfiguration = upstreamTLSConfiguration
        self.handshakeTimeout = handshakeTimeout
        self.closeHandshakeTimeout = closeHandshakeTimeout
        group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, eventLoopThreads))
    }

    public func connect(
        _ request: HTTPRequest,
        initialMessage: WebSocketClientMessage?,
        sessionID: SessionID
    ) async throws -> Flow {
        guard !isShutdown else {
            throw WebSocketConnectionError.shutdown
        }
        try validate(request)
        if let initialMessage {
            try validate(message: initialMessage)
        }

        let target: ProxyTarget
        do {
            target = try ProxyTarget(url: request.url)
        } catch let error as ProxyTargetError {
            switch error {
            case .unsupportedScheme(let scheme):
                throw WebSocketConnectionError.unsupportedScheme(scheme)
            default:
                throw WebSocketConnectionError.connectionFailed(error.localizedDescription)
            }
        }
        guard
            request.url.scheme?.lowercased() == "ws"
                || request.url.scheme?.lowercased() == "wss"
        else {
            throw WebSocketConnectionError.unsupportedScheme(request.url.scheme ?? "")
        }

        let requestKey = NIOWebSocketClientUpgrader.randomRequestKey()
        let wireHeaders = Self.wireHeaders(
            from: request.headers,
            target: target,
            requestKey: requestKey
        )
        let capturedRequest = HTTPRequest(
            method: .get,
            url: request.url,
            headers: try HTTPConversion.coreHeaders(from: wireHeaders),
            version: .http11,
            rawTarget: target.originForm
        )
        let flow = Flow(
            sessionID: sessionID,
            source: .replay,
            request: capturedRequest,
            connection: ConnectionInfo(
                protocolKind: target.usesTLS ? .https : .http,
                upstreamHost: target.host,
                upstreamPort: UInt16(target.port)
            )
        )
        let transaction = FlowTransaction(flow: flow, eventSink: eventSink)
        await transaction.start(at: flow.createdAt)
        await transaction.finishRequestBody(nil, at: Date())

        let pendingUpgrade: DirectWebSocketPendingUpgrade
        do {
            pendingUpgrade = try await openChannel(
                target: target,
                requestHead: HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: target.originForm,
                    headers: Self.userWireHeaders(from: request.headers, target: target)
                ),
                requestKey: requestKey,
                transaction: transaction,
                flowID: flow.id
            )
        } catch {
            await transaction.fail(.upstreamUnavailable)
            throw error
        }
        let channel = pendingUpgrade.channel

        await transaction.markUpstreamConnected(at: Date())

        let result: DirectWebSocketUpgradeResult
        do {
            result = try await pendingUpgrade.future.get()
        } catch {
            if channel.isActive {
                try? await channel.close().get()
            }
            await transaction.fail(.protocolError(error.localizedDescription))
            throw error
        }

        do {
            if target.usesTLS {
                await transaction.markTLSHandshakeCompleted(at: Date())
            }
            let response = try HTTPResponse(
                statusCode: Int(result.responseHead.status.code),
                reasonPhrase: result.responseHead.status.reasonPhrase,
                headers: HTTPConversion.coreHeaders(from: result.responseHead.headers),
                version: HTTPConversion.coreVersion(from: result.responseHead.version)
            )
            await transaction.receiveResponse(response, at: Date())
            await connections.register(result.connection, for: flow.id, token: result.token)
            await transaction.beginWebSocket(secure: target.usesTLS, at: Date())
            result.handler.activate()
            if let initialMessage {
                try await connections.send(
                    WebSocketFrameTransmission(
                        flowID: flow.id,
                        direction: .clientToServer,
                        opcode: initialMessage.opcode,
                        payload: initialMessage.payload
                    )
                )
            }
            return await transaction.snapshot()
        } catch {
            if channel.isActive {
                try? await channel.close().get()
            }
            await transaction.fail(.protocolError(error.localizedDescription))
            throw error
        }
    }

    public func disconnect(flowID: FlowID) async {
        await connections.disconnect(flowID: flowID)
    }

    public func isConnectionOpen(for flowID: FlowID) async -> Bool {
        await connections.isConnectionOpen(for: flowID)
    }

    public func send(_ transmission: WebSocketFrameTransmission) async throws {
        guard transmission.direction == .clientToServer else {
            throw WebSocketConnectionError.clientDirectionRequired
        }
        guard transmission.payload.count <= maximumWebSocketFrameBytes else {
            throw WebSocketConnectionError.payloadTooLarge(
                maximumBytes: maximumWebSocketFrameBytes
            )
        }
        try await connections.send(transmission)
    }

    public func shutdown() async {
        guard !isShutdown else {
            return
        }
        isShutdown = true
        await connections.closeAll()
        await withCheckedContinuation { continuation in
            group.shutdownGracefully { _ in
                continuation.resume()
            }
        }
    }

    private func openChannel(
        target: ProxyTarget,
        requestHead: HTTPRequestHead,
        requestKey: String,
        transaction: FlowTransaction,
        flowID: FlowID
    ) async throws -> DirectWebSocketPendingUpgrade {
        let tlsContext = try TLSContextFactory.upstreamContext(
            configuration: upstreamTLSConfiguration
        )
        let upgradePromise = group.next().makePromise(of: DirectWebSocketUpgradeResult.self)
        let upgradeCompletion = DirectWebSocketUpgradeCompletion(promise: upgradePromise)
        let requestHandler = DirectWebSocketUpgradeRequestHandler(head: requestHead)
        let rejectionHandler = DirectWebSocketUpgradeRejectionHandler(
            completion: upgradeCompletion
        )
        let recorder = bodyStore.map {
            WebSocketFrameRecorder(
                bodyStore: $0,
                maximumCapturedFrameBytes: maximumCapturedFrameBytes,
                eventSink: webSocketFrameEventSink
            )
        }
        let maximumFrameBytes = maximumWebSocketFrameBytes
        let closeHandshakeTimeout = closeHandshakeTimeout
        let connectionRegistry = connections
        let token = UUID()
        let upgrader = NIOWebSocketClientUpgrader(
            requestKey: requestKey,
            maxFrameSize: maximumFrameBytes,
            upgradePipelineHandler: { channel, responseHead in
                let state = WebSocketBridgeState()
                let handler = DirectWebSocketFrameHandler(
                    transaction: transaction,
                    flowID: flowID,
                    recorder: recorder,
                    state: state,
                    connectionRegistry: connectionRegistry,
                    connectionToken: token
                )
                let connection = DirectWebSocketConnection(
                    channel: channel,
                    flowID: flowID,
                    state: state,
                    recorder: recorder,
                    maximumFrameBytes: maximumFrameBytes,
                    closeHandshakeTimeout: closeHandshakeTimeout
                )
                return channel.pipeline.addHandler(handler).map {
                    upgradeCompletion.succeed(
                        DirectWebSocketUpgradeResult(
                            responseHead: responseHead,
                            connection: connection,
                            handler: handler,
                            token: token
                        )
                    )
                }
            }
        )
        let configuration: NIOHTTPClientUpgradeSendableConfiguration = (
            upgraders: [upgrader],
            completionHandler: { context in
                context.pipeline.removeHandler(requestHandler, promise: nil)
                context.pipeline.removeHandler(rejectionHandler, promise: nil)
            }
        )

        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                do {
                    if target.usesTLS {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(
                                context: tlsContext,
                                serverHostname: target.host
                            )
                        )
                    }
                    return channel.pipeline.addHTTPClientHandlers(
                        withClientUpgrade: configuration
                    ).flatMap {
                        channel.pipeline.addHandler(requestHandler)
                    }.flatMap {
                        channel.pipeline.addHandler(rejectionHandler)
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: target.host, port: target.port)
            .get()

        let timeout = channel.eventLoop.scheduleTask(in: handshakeTimeout) {
            if upgradeCompletion.fail(WebSocketConnectionError.timeout) {
                channel.close(promise: nil)
            }
        }
        upgradePromise.futureResult.whenComplete { _ in
            timeout.cancel()
        }
        return DirectWebSocketPendingUpgrade(
            channel: channel,
            future: upgradePromise.futureResult
        )
    }

    private func validate(_ request: HTTPRequest) throws {
        guard request.method == .get else {
            throw WebSocketConnectionError.invalidRequestMethod
        }
        guard request.version == .http11 else {
            throw WebSocketConnectionError.unsupportedHTTPVersion(request.version)
        }
        guard request.body == nil else {
            throw WebSocketConnectionError.requestBodyUnsupported
        }
    }

    private func validate(message: WebSocketClientMessage) throws {
        guard message.payload.count <= maximumWebSocketFrameBytes else {
            throw WebSocketConnectionError.payloadTooLarge(
                maximumBytes: maximumWebSocketFrameBytes
            )
        }
        guard message.opcode == .text || message.opcode == .binary else {
            throw WebSocketConnectionError.unsupportedOpcode
        }
    }

    private static func userWireHeaders(
        from headers: ProxyLensCore.HTTPHeaders,
        target: ProxyTarget
    ) -> NIOHTTP1.HTTPHeaders {
        let transportHeaders: Set<String> = [
            "connection", "content-length", "host", "sec-websocket-extensions",
            "sec-websocket-key", "sec-websocket-version", "transfer-encoding", "upgrade"
        ]
        var result = NIOHTTP1.HTTPHeaders()
        result.add(name: "Host", value: target.hostHeader)
        for header in headers where !transportHeaders.contains(header.name.lowercased()) {
            result.add(name: header.name, value: header.value)
        }
        return result
    }

    private static func wireHeaders(
        from headers: ProxyLensCore.HTTPHeaders,
        target: ProxyTarget,
        requestKey: String
    ) -> NIOHTTP1.HTTPHeaders {
        var result = userWireHeaders(from: headers, target: target)
        result.add(name: "Connection", value: "upgrade")
        result.add(name: "Upgrade", value: "websocket")
        result.add(name: "Sec-WebSocket-Key", value: requestKey)
        result.add(name: "Sec-WebSocket-Version", value: "13")
        return result
    }
}

private final class DirectWebSocketPendingUpgrade: @unchecked Sendable {
    let channel: Channel
    let future: EventLoopFuture<DirectWebSocketUpgradeResult>

    init(channel: Channel, future: EventLoopFuture<DirectWebSocketUpgradeResult>) {
        self.channel = channel
        self.future = future
    }
}

private final class DirectWebSocketUpgradeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let promise: EventLoopPromise<DirectWebSocketUpgradeResult>
    private var isCompleted = false

    init(promise: EventLoopPromise<DirectWebSocketUpgradeResult>) {
        self.promise = promise
    }

    @discardableResult
    func succeed(_ result: DirectWebSocketUpgradeResult) -> Bool {
        guard beginCompletion() else {
            return false
        }
        promise.succeed(result)
        return true
    }

    @discardableResult
    func fail(_ error: Error) -> Bool {
        guard beginCompletion() else {
            return false
        }
        promise.fail(error)
        return true
    }

    private func beginCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCompleted else {
            return false
        }
        isCompleted = true
        return true
    }
}

private final class DirectWebSocketUpgradeResult: @unchecked Sendable {
    let responseHead: HTTPResponseHead
    let connection: DirectWebSocketConnection
    let handler: DirectWebSocketFrameHandler
    let token: UUID

    init(
        responseHead: HTTPResponseHead,
        connection: DirectWebSocketConnection,
        handler: DirectWebSocketFrameHandler,
        token: UUID
    ) {
        self.responseHead = responseHead
        self.connection = connection
        self.handler = handler
        self.token = token
    }
}

actor DirectWebSocketConnectionRegistry {
    private struct Entry {
        let token: UUID
        let connection: DirectWebSocketConnection
    }

    private var entries: [FlowID: Entry] = [:]

    func register(_ connection: DirectWebSocketConnection, for flowID: FlowID, token: UUID) {
        entries[flowID] = Entry(token: token, connection: connection)
    }

    func unregister(flowID: FlowID, token: UUID) {
        guard entries[flowID]?.token == token else {
            return
        }
        entries.removeValue(forKey: flowID)
    }

    func isConnectionOpen(for flowID: FlowID) async -> Bool {
        guard let entry = entries[flowID] else {
            return false
        }
        return await entry.connection.isOpen()
    }

    func send(_ transmission: WebSocketFrameTransmission) async throws {
        guard transmission.direction == .clientToServer else {
            throw WebSocketConnectionError.clientDirectionRequired
        }
        guard let entry = entries[transmission.flowID] else {
            throw WebSocketConnectionError.connectionClosed
        }
        try await entry.connection.send(transmission)
    }

    func disconnect(flowID: FlowID) async {
        guard let entry = entries[flowID] else {
            return
        }
        await entry.connection.disconnect()
    }

    func closeAll() async {
        let connections = entries.values.map(\.connection)
        entries.removeAll(keepingCapacity: false)
        for connection in connections {
            await connection.disconnect()
        }
    }
}

final class DirectWebSocketConnection: @unchecked Sendable {
    private let channel: Channel
    private let flowID: FlowID
    private let state: WebSocketBridgeState
    private let recorder: WebSocketFrameRecorder?
    private let maximumFrameBytes: Int
    private let closeHandshakeTimeout: TimeAmount

    init(
        channel: Channel,
        flowID: FlowID,
        state: WebSocketBridgeState,
        recorder: WebSocketFrameRecorder?,
        maximumFrameBytes: Int,
        closeHandshakeTimeout: TimeAmount
    ) {
        self.channel = channel
        self.flowID = flowID
        self.state = state
        self.recorder = recorder
        self.maximumFrameBytes = maximumFrameBytes
        self.closeHandshakeTimeout = closeHandshakeTimeout
    }

    func isOpen() async -> Bool {
        let channel = self.channel
        let state = self.state
        return
            (try? await channel.eventLoop.submit {
                channel.isActive && !state.isTerminal
            }.get()) ?? false
    }

    func send(_ transmission: WebSocketFrameTransmission) async throws {
        guard transmission.direction == .clientToServer else {
            throw WebSocketConnectionError.clientDirectionRequired
        }
        guard transmission.payload.count <= maximumFrameBytes else {
            throw WebSocketConnectionError.payloadTooLarge(maximumBytes: maximumFrameBytes)
        }
        let channel = self.channel
        let state = self.state
        let recorder = self.recorder
        try await channel.eventLoop.submit {
            guard channel.isActive, !state.isTerminal else {
                throw WebSocketConnectionError.connectionClosed
            }
            let opcode: WebSocketOpcode
            switch transmission.opcode {
            case .text: opcode = .text
            case .binary: opcode = .binary
            default: throw WebSocketConnectionError.unsupportedOpcode
            }
            var payload = channel.allocator.buffer(capacity: transmission.payload.count)
            payload.writeBytes(transmission.payload)
            let frame = WebSocketFrame(
                fin: true,
                opcode: opcode,
                maskKey: Self.randomMask(),
                data: payload
            )
            let capturedFrame = Self.capturedMaskedFrame(frame)
            let sequence = state.nextSequence()
            return channel.writeAndFlush(frame).flatMap {
                guard let recorder else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                return state.capture(
                    capturedFrame,
                    flowID: transmission.flowID,
                    sequenceNumber: sequence,
                    direction: .clientToServer,
                    recorder: recorder,
                    eventLoop: channel.eventLoop
                )
            }
        }.flatMap { $0 }.get()
    }

    func disconnect() async {
        let channel = self.channel
        let flowID = self.flowID
        let state = self.state
        let recorder = self.recorder
        _ = try? await channel.eventLoop.submit {
            guard channel.isActive, !state.isTerminal, state.beginCloseWrite() else {
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            let frame = WebSocketFrame(
                fin: true,
                opcode: .connectionClose,
                maskKey: Self.randomMask(),
                data: channel.allocator.buffer(capacity: 0)
            )
            let capturedFrame = Self.capturedMaskedFrame(frame)
            let sequence = state.nextSequence()
            return channel.writeAndFlush(frame).flatMap {
                guard let recorder else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                return state.capture(
                    capturedFrame,
                    flowID: flowID,
                    sequenceNumber: sequence,
                    direction: .clientToServer,
                    recorder: recorder,
                    eventLoop: channel.eventLoop
                )
            }
        }.flatMap { $0 }.get()
        guard channel.isActive else {
            await drainCaptureTasks()
            return
        }
        let timeout = channel.eventLoop.scheduleTask(in: closeHandshakeTimeout) {
            channel.close(promise: nil)
        }
        _ = try? await channel.closeFuture.get()
        timeout.cancel()
        await drainCaptureTasks()
    }

    private func drainCaptureTasks() async {
        let channel = self.channel
        let state = self.state
        let tasks =
            (try? await channel.eventLoop.submit {
                state.captureTasks()
            }.get()) ?? []
        for task in tasks {
            _ = try? await task.value
        }
        _ = try? await channel.eventLoop.submit {}.get()
    }

    static func randomMask() -> WebSocketMaskingKey {
        [
            UInt8.random(in: .min ... .max), UInt8.random(in: .min ... .max),
            UInt8.random(in: .min ... .max), UInt8.random(in: .min ... .max)
        ]
    }

    static func capturedMaskedFrame(_ frame: WebSocketFrame) -> WebSocketFrame {
        guard let maskKey = frame.maskKey else {
            return frame
        }
        var maskedData = frame.data
        maskedData.webSocketMask(maskKey)
        return WebSocketFrame(
            fin: frame.fin,
            rsv1: frame.rsv1,
            rsv2: frame.rsv2,
            rsv3: frame.rsv3,
            opcode: frame.opcode,
            maskKey: maskKey,
            data: maskedData,
            extensionData: frame.extensionData
        )
    }
}

private final class DirectWebSocketUpgradeRequestHandler:
    ChannelInboundHandler,
    RemovableChannelHandler,
    Sendable
{
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let head: HTTPRequestHead

    init(head: HTTPRequestHead) {
        self.head = head
    }

    func channelActive(context: ChannelHandlerContext) {
        context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
}

private final class DirectWebSocketUpgradeRejectionHandler:
    ChannelInboundHandler,
    RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPClientResponsePart

    private let completion: DirectWebSocketUpgradeCompletion
    private var isFinished = false

    init(completion: DirectWebSocketUpgradeCompletion) {
        self.completion = completion
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = Self.unwrapInboundIn(data)
        if case .head(let head) = part, head.status != .switchingProtocols {
            finish(.upgradeRejected(statusCode: Int(head.status.code)), context: context)
            return
        }
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !isFinished {
            isFinished = true
            completion.fail(WebSocketConnectionError.connectionClosed)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !isFinished else {
            context.close(promise: nil)
            return
        }
        isFinished = true
        completion.fail(WebSocketConnectionError.connectionFailed(error.localizedDescription))
        context.close(promise: nil)
    }

    private func finish(_ error: WebSocketConnectionError, context: ChannelHandlerContext) {
        guard !isFinished else {
            return
        }
        isFinished = true
        completion.fail(error)
        context.close(promise: nil)
    }
}
