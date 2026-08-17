import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket
import ProxyLensCore

enum WebSocketBridge {
    static func install(
        clientChannel: Channel,
        upstreamChannel: Channel,
        transaction: FlowTransaction,
        flowID: FlowID,
        bodyStore: (any BodyStore)?,
        maximumCapturedFrameBytes: Int64,
        maximumFrameBytes: Int,
        eventSink: any WebSocketFrameEventSink
    ) -> EventLoopFuture<Void> {
        clientChannel.eventLoop.assertInEventLoop()
        upstreamChannel.eventLoop.assertInEventLoop()

        let state = WebSocketBridgeState()
        let recorder = bodyStore.map {
            WebSocketFrameRecorder(
                bodyStore: $0,
                maximumCapturedFrameBytes: maximumCapturedFrameBytes,
                eventSink: eventSink
            )
        }
        let clientRelay = WebSocketRelayHandler(
            peerChannel: upstreamChannel,
            transaction: transaction,
            flowID: flowID,
            direction: .clientToServer,
            recorder: recorder,
            state: state
        )
        let upstreamRelay = WebSocketRelayHandler(
            peerChannel: clientChannel,
            transaction: transaction,
            flowID: flowID,
            direction: .serverToClient,
            recorder: recorder,
            state: state
        )

        return clientChannel.setOption(ChannelOptions.autoRead, value: false)
            .and(upstreamChannel.setOption(ChannelOptions.autoRead, value: false))
            .flatMap { _ in
                prepareClientPipeline(
                    on: clientChannel,
                    relay: clientRelay,
                    maximumFrameBytes: maximumFrameBytes
                )
            }
            .flatMap {
                prepareUpstreamPipeline(
                    on: upstreamChannel,
                    relay: upstreamRelay,
                    maximumFrameBytes: maximumFrameBytes
                )
            }
            .flatMap {
                removeHandler(named: HTTPServerPipeline.responseEncoderName, from: clientChannel)
            }
            .flatMap {
                removeHandler(named: HTTPClientPipeline.requestEncoderName, from: upstreamChannel)
            }
            .flatMap {
                removeHandler(named: HTTPServerPipeline.requestDecoderName, from: clientChannel)
            }
            .flatMap {
                removeHandler(named: HTTPClientPipeline.responseDecoderName, from: upstreamChannel)
            }
            .map {
                clientRelay.activate()
                upstreamRelay.activate()
            }
            .flatMap {
                clientChannel.setOption(ChannelOptions.autoRead, value: true)
                    .and(upstreamChannel.setOption(ChannelOptions.autoRead, value: true))
                    .map { _ in () }
            }
    }

    private static func prepareClientPipeline(
        on channel: Channel,
        relay: WebSocketRelayHandler,
        maximumFrameBytes: Int
    ) -> EventLoopFuture<Void> {
        do {
            let operations = channel.pipeline.syncOperations
            let proxyHandler = try operations.context(name: HTTPServerPipeline.proxyHandlerName)
            let protocolError = try operations.context(
                name: HTTPServerPipeline.protocolErrorHandlerName
            )
            let responseValidator = try operations.context(
                name: HTTPServerPipeline.responseValidatorName
            )
            let boundOperations = NIOLoopBound(operations, eventLoop: channel.eventLoop)
            let boundProtocolError = NIOLoopBound(protocolError, eventLoop: channel.eventLoop)
            let boundResponseValidator = NIOLoopBound(
                responseValidator,
                eventLoop: channel.eventLoop
            )
            return operations.removeHandler(context: proxyHandler)
                .flatMap {
                    boundOperations.value.removeHandler(context: boundProtocolError.value)
                }
                .flatMap {
                    boundOperations.value.removeHandler(context: boundResponseValidator.value)
                }
                .flatMapThrowing {
                    try boundOperations.value.addHandler(WebSocketFrameEncoder())
                    try boundOperations.value.addHandler(
                        ByteToMessageHandler(
                            WebSocketFrameDecoder(maxFrameSize: maximumFrameBytes)
                        )
                    )
                    try boundOperations.value.addHandler(
                        WebSocketProtocolErrorHandler(isServer: true)
                    )
                    try boundOperations.value.addHandler(relay)
                }
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    private static func prepareUpstreamPipeline(
        on channel: Channel,
        relay: WebSocketRelayHandler,
        maximumFrameBytes: Int
    ) -> EventLoopFuture<Void> {
        do {
            let operations = channel.pipeline.syncOperations
            let responseHandler = try operations.context(
                name: HTTPClientPipeline.responseHandlerName)
            let requestValidator = try operations.context(
                name: HTTPClientPipeline.requestValidatorName)
            let boundOperations = NIOLoopBound(operations, eventLoop: channel.eventLoop)
            let boundRequestValidator = NIOLoopBound(
                requestValidator,
                eventLoop: channel.eventLoop
            )
            return operations.removeHandler(context: responseHandler)
                .flatMap {
                    boundOperations.value.removeHandler(context: boundRequestValidator.value)
                }
                .flatMapThrowing {
                    try boundOperations.value.addHandler(WebSocketFrameEncoder())
                    try boundOperations.value.addHandler(
                        ByteToMessageHandler(
                            WebSocketFrameDecoder(maxFrameSize: maximumFrameBytes)
                        )
                    )
                    try boundOperations.value.addHandler(
                        WebSocketProtocolErrorHandler(isServer: false)
                    )
                    try boundOperations.value.addHandler(relay)
                }
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    private static func removeHandler(
        named name: String,
        from channel: Channel
    ) -> EventLoopFuture<Void> {
        do {
            let operations = channel.pipeline.syncOperations
            let context = try operations.context(name: name)
            return operations.removeHandler(context: context)
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }
}

private final class WebSocketBridgeState {
    private var nextSequenceNumber: Int64 = 1
    private var isTerminal = false
    private var latestCaptureTasks: [WebSocketFrameDirection: Task<Void, Error>] = [:]

    func nextSequence() -> Int64 {
        defer {
            nextSequenceNumber =
                nextSequenceNumber == Int64.max ? Int64.max : nextSequenceNumber + 1
        }
        return nextSequenceNumber
    }

    func beginTerminalTransition() -> Bool {
        guard !isTerminal else {
            return false
        }
        isTerminal = true
        return true
    }

    func trackCaptureTask(
        _ task: Task<Void, Error>,
        direction: WebSocketFrameDirection
    ) {
        latestCaptureTasks[direction] = task
    }

    func captureTasks() -> [Task<Void, Error>] {
        Array(latestCaptureTasks.values)
    }

    func cancelCaptureTasks() {
        for task in latestCaptureTasks.values {
            task.cancel()
        }
    }
}

private final class WebSocketRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame

    private let peerChannel: Channel
    private let transaction: FlowTransaction
    private let flowID: FlowID
    private let direction: WebSocketFrameDirection
    private let recorder: WebSocketFrameRecorder?
    private let state: WebSocketBridgeState
    private var captureTask: Task<Void, Error>?
    private var context: ChannelHandlerContext?
    private var pendingFrames: [WebSocketFrame] = []
    private var pendingOperations = 0
    private var isReady = false

    init(
        peerChannel: Channel,
        transaction: FlowTransaction,
        flowID: FlowID,
        direction: WebSocketFrameDirection,
        recorder: WebSocketFrameRecorder?,
        state: WebSocketBridgeState
    ) {
        self.peerChannel = peerChannel
        self.transaction = transaction
        self.flowID = flowID
        self.direction = direction
        self.recorder = recorder
        self.state = state
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context _: ChannelHandlerContext) {
        context = nil
        pendingFrames.removeAll(keepingCapacity: false)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        guard isReady else {
            pendingFrames.append(frame)
            return
        }
        relay(frame, context: context)
    }

    func activate() {
        guard !isReady, let context else {
            return
        }
        isReady = true
        let frames = pendingFrames
        pendingFrames.removeAll(keepingCapacity: false)
        for frame in frames {
            relay(frame, context: context)
        }
    }

    private func relay(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        let sequenceNumber = state.nextSequence()
        let boundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        beginOperation(context: context)
        peerChannel.writeAndFlush(
            WebSocketFrameRelay.forwardedFrame(frame, direction: direction)
        ).whenComplete { result in
            boundSelf.value.completeOperation(result, context: boundContext.value)
        }

        guard let recorder else {
            return
        }
        beginOperation(context: context)
        let previousTask = captureTask
        let flowID = self.flowID
        let direction = self.direction
        let recordTask = Task { [previousTask, recorder, frame, flowID, direction] in
            try await previousTask?.value
            try await recorder.record(
                frame,
                flowID: flowID,
                sequenceNumber: sequenceNumber,
                direction: direction
            )
        }
        captureTask = recordTask
        state.trackCaptureTask(recordTask, direction: direction)
        context.eventLoop.makeFutureWithTask { [recordTask] in
            try await recordTask.value
        }.whenComplete { result in
            boundSelf.value.completeOperation(result, context: boundContext.value)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if state.beginTerminalTransition() {
            let transaction = self.transaction
            let captureTasks = state.captureTasks()
            Task { [transaction, captureTasks] in
                do {
                    for task in captureTasks {
                        try await task.value
                    }
                    await transaction.finishWebSocket(at: Date())
                } catch {
                    await transaction.fail(.protocolError(error.localizedDescription))
                }
            }
            peerChannel.close(promise: nil)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        terminateWithFailure(error.localizedDescription, context: context)
    }

    private func beginOperation(context: ChannelHandlerContext) {
        pendingOperations += 1
        updateAutoRead(context: context)
    }

    private func completeOperation(
        _ result: Result<Void, Error>,
        context: ChannelHandlerContext
    ) {
        pendingOperations = max(0, pendingOperations - 1)
        if case .failure(let error) = result {
            terminateWithFailure(error.localizedDescription, context: context)
            return
        }
        updateAutoRead(context: context)
    }

    private func updateAutoRead(context: ChannelHandlerContext) {
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.channel.setOption(
            ChannelOptions.autoRead,
            value: pendingOperations == 0
        ).whenFailure { _ in
            boundContext.value.close(promise: nil)
        }
    }

    private func terminateWithFailure(
        _ message: String,
        context: ChannelHandlerContext
    ) {
        guard state.beginTerminalTransition() else {
            context.close(promise: nil)
            return
        }
        state.cancelCaptureTasks()
        let transaction = self.transaction
        Task { [transaction] in
            await transaction.fail(.protocolError(message))
        }
        peerChannel.close(promise: nil)
        context.close(promise: nil)
    }
}
