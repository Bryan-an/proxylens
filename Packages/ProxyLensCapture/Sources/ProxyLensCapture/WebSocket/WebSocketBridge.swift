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
        usesTLS: Bool,
        bodyStore: (any BodyStore)?,
        maximumCapturedFrameBytes: Int64,
        maximumFrameBytes: Int,
        eventSink: any WebSocketFrameEventSink,
        connectionRegistry: NIOWebSocketConnectionRegistry,
        ruleSnapshot: (any RuleSnapshotSource)?,
        ruleContext: RuleMatchContext,
        breakpointGate: any BreakpointGate
    ) -> EventLoopFuture<Void> {
        clientChannel.eventLoop.assertInEventLoop()
        upstreamChannel.eventLoop.assertInEventLoop()

        let state = WebSocketBridgeState()
        let connectionToken = UUID()
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
            state: state,
            connectionRegistry: connectionRegistry,
            connectionToken: connectionToken,
            ruleSnapshot: nil,
            ruleContext: ruleContext,
            breakpointGate: ImmediateBreakpointGate()
        )
        let upstreamRelay = WebSocketRelayHandler(
            peerChannel: clientChannel,
            transaction: transaction,
            flowID: flowID,
            direction: .serverToClient,
            recorder: recorder,
            state: state,
            connectionRegistry: connectionRegistry,
            connectionToken: connectionToken,
            ruleSnapshot: ruleSnapshot,
            ruleContext: ruleContext,
            breakpointGate: breakpointGate
        )
        let connection = NIOWebSocketConnection(
            clientChannel: clientChannel,
            upstreamChannel: upstreamChannel,
            state: state,
            recorder: recorder,
            maximumFrameBytes: maximumFrameBytes
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
            .flatMap {
                clientChannel.eventLoop.makeFutureWithTask {
                    await connectionRegistry.register(
                        connection,
                        for: flowID,
                        token: connectionToken
                    )
                }
            }
            .flatMap {
                clientChannel.eventLoop.makeFutureWithTask {
                    await transaction.beginWebSocket(secure: usesTLS, at: Date())
                }
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

final class WebSocketBridgeState: @unchecked Sendable {
    private var nextSequenceNumber: Int64 = 1
    private var latestCaptureTasks: [WebSocketFrameDirection: Task<Void, Error>] = [:]
    private var hasSentClose = false

    var isTerminal: Bool {
        isTerminalStorage
    }

    private var isTerminalStorage = false

    func nextSequence() -> Int64 {
        defer {
            nextSequenceNumber =
                nextSequenceNumber == Int64.max ? Int64.max : nextSequenceNumber + 1
        }
        return nextSequenceNumber
    }

    func beginTerminalTransition() -> Bool {
        guard !isTerminalStorage else {
            return false
        }
        isTerminalStorage = true
        return true
    }

    func beginCloseWrite() -> Bool {
        guard !hasSentClose else {
            return false
        }
        hasSentClose = true
        return true
    }

    func send(
        _ transmission: WebSocketFrameTransmission,
        clientChannel: Channel,
        upstreamChannel: Channel,
        recorder: WebSocketFrameRecorder?
    ) -> EventLoopFuture<Void> {
        clientChannel.eventLoop.assertInEventLoop()
        guard !isTerminalStorage, clientChannel.isActive, upstreamChannel.isActive else {
            return clientChannel.eventLoop.makeFailedFuture(
                ProxyLensError.unsupportedOperation(
                    "The selected WebSocket connection is no longer open"
                )
            )
        }

        let opcode: WebSocketOpcode
        switch transmission.opcode {
        case .text:
            opcode = .text
        case .binary:
            opcode = .binary
        default:
            return clientChannel.eventLoop.makeFailedFuture(
                ProxyLensError.unsupportedOperation(
                    "The WebSocket composer supports text and binary messages"
                )
            )
        }

        let targetChannel: Channel
        let maskKey: WebSocketMaskingKey?
        switch transmission.direction {
        case .clientToServer:
            targetChannel = upstreamChannel
            maskKey = [
                UInt8.random(in: .min ... .max),
                UInt8.random(in: .min ... .max),
                UInt8.random(in: .min ... .max),
                UInt8.random(in: .min ... .max)
            ]
        case .serverToClient:
            targetChannel = clientChannel
            maskKey = nil
        }

        var data = targetChannel.allocator.buffer(capacity: transmission.payload.count)
        data.writeBytes(transmission.payload)
        let frame = WebSocketFrame(
            fin: true,
            opcode: opcode,
            maskKey: maskKey,
            data: data
        )
        let sequenceNumber = nextSequence()
        let writeFuture = targetChannel.writeAndFlush(frame)
        guard let recorder else {
            return writeFuture
        }
        return writeFuture.flatMap {
            self.capture(
                frame,
                flowID: transmission.flowID,
                sequenceNumber: sequenceNumber,
                direction: transmission.direction,
                recorder: recorder,
                eventLoop: targetChannel.eventLoop
            )
        }
    }

    func capture(
        _ frame: WebSocketFrame,
        flowID: FlowID,
        sequenceNumber: Int64,
        direction: WebSocketFrameDirection,
        recorder: WebSocketFrameRecorder,
        eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        let previousTask = latestCaptureTasks[direction]
        let promise = eventLoop.makePromise(of: Void.self)
        let captureTask = Task { [previousTask, recorder, frame, flowID, direction] in
            do {
                try await previousTask?.value
                try await recorder.record(
                    frame,
                    flowID: flowID,
                    sequenceNumber: sequenceNumber,
                    direction: direction
                )
                promise.succeed(())
            } catch {
                promise.fail(error)
                throw error
            }
        }
        trackCaptureTask(captureTask, direction: direction)
        return promise.futureResult
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
    private let connectionRegistry: NIOWebSocketConnectionRegistry
    private let connectionToken: UUID
    private let ruleSnapshot: (any RuleSnapshotSource)?
    private let ruleContext: RuleMatchContext
    private let breakpointGate: any BreakpointGate
    private let maximumEditableBreakpointPayloadBytes = 1 * 1_024 * 1_024
    private var context: ChannelHandlerContext?
    private var pendingFrames: [WebSocketFrame] = []
    private var pendingOperations = 0
    private var isReady = false
    private var breakpointTask: Task<Void, Never>?

    init(
        peerChannel: Channel,
        transaction: FlowTransaction,
        flowID: FlowID,
        direction: WebSocketFrameDirection,
        recorder: WebSocketFrameRecorder?,
        state: WebSocketBridgeState,
        connectionRegistry: NIOWebSocketConnectionRegistry,
        connectionToken: UUID,
        ruleSnapshot: (any RuleSnapshotSource)?,
        ruleContext: RuleMatchContext,
        breakpointGate: any BreakpointGate
    ) {
        self.peerChannel = peerChannel
        self.transaction = transaction
        self.flowID = flowID
        self.direction = direction
        self.recorder = recorder
        self.state = state
        self.connectionRegistry = connectionRegistry
        self.connectionToken = connectionToken
        self.ruleSnapshot = ruleSnapshot
        self.ruleContext = ruleContext
        self.breakpointGate = breakpointGate
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context _: ChannelHandlerContext) {
        breakpointTask?.cancel()
        breakpointTask = nil
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
        let opcode = WebSocketFrameRelay.capturedOpcode(frame.opcode)
        if direction == .serverToClient,
            WebSocketBreakpointFrame.isEligibleDataOpcode(opcode)
        {
            let plan = RulePlanner.plan(
                rules: ruleSnapshot?.currentRules() ?? RuleSet(),
                context: ruleContext,
                phase: .webSocketFrame
            )
            if plan.shouldBreakpoint {
                relayThroughBreakpoint(
                    frame,
                    opcode: opcode,
                    sequenceNumber: sequenceNumber,
                    plan: plan,
                    context: context
                )
                return
            }
            if !plan.traces.isEmpty {
                let transaction = self.transaction
                Task { [transaction, traces = plan.traces] in
                    await transaction.appendRuleTraces(traces)
                }
            }
        }

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
        state.capture(
            frame,
            flowID: flowID,
            sequenceNumber: sequenceNumber,
            direction: direction,
            recorder: recorder,
            eventLoop: context.eventLoop
        ).whenComplete { result in
            boundSelf.value.completeOperation(result, context: boundContext.value)
        }
    }

    private func relayThroughBreakpoint(
        _ frame: WebSocketFrame,
        opcode: WebSocketFrameOpcode,
        sequenceNumber: Int64,
        plan: RulePlan,
        context: ChannelHandlerContext
    ) {
        guard let request = ruleContext.request else {
            terminateWithFailure(
                "A WebSocket breakpoint could not recover the upgrade request",
                context: context
            )
            return
        }

        let payloadBuffer = frame.unmaskedData
        let payloadByteCount = payloadBuffer.readableBytes
        let editablePayload =
            payloadByteCount <= maximumEditableBreakpointPayloadBytes
            ? Data(payloadBuffer.readableBytesView) : nil
        let breakpointFrame = WebSocketBreakpointFrame(
            sequenceNumber: Int(clamping: sequenceNumber),
            opcode: opcode,
            isFinal: frame.fin,
            reservedBits: WebSocketFrameRelay.reservedBits(frame),
            payload: editablePayload,
            originalPayloadByteCount: payloadByteCount,
            maximumEditablePayloadBytes: maximumEditableBreakpointPayloadBytes
        )
        let hit = BreakpointHit(
            flowID: flowID,
            phase: .webSocketResponse,
            request: request,
            response: ruleContext.response,
            webSocketFrame: breakpointFrame
        )
        let boundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)

        beginOperation(context: context)
        let captureFuture: EventLoopFuture<Void>
        if let recorder {
            captureFuture = state.capture(
                frame,
                flowID: flowID,
                sequenceNumber: sequenceNumber,
                direction: direction,
                recorder: recorder,
                eventLoop: context.eventLoop
            )
        } else {
            captureFuture = context.eventLoop.makeSucceededVoidFuture()
        }

        captureFuture.whenComplete { captureResult in
            guard case .success = captureResult else {
                boundSelf.value.completeOperation(captureResult, context: boundContext.value)
                return
            }
            guard !boundSelf.value.state.isTerminal else {
                boundSelf.value.completeOperation(.success(()), context: boundContext.value)
                return
            }

            let transaction = boundSelf.value.transaction
            let gate = boundSelf.value.breakpointGate
            let eventLoop = boundContext.value.eventLoop
            let task = Task { [transaction, gate, hit, traces = plan.traces] in
                await transaction.appendRuleTraces(traces)
                await transaction.pause(.webSocketResponse)
                let decision = await gate.pause(hit)
                eventLoop.execute {
                    boundSelf.value.applyBreakpointDecision(
                        decision,
                        originalFrame: frame,
                        breakpointFrame: breakpointFrame,
                        context: boundContext.value
                    )
                }
            }
            boundSelf.value.breakpointTask = task
        }
    }

    private func applyBreakpointDecision(
        _ decision: BreakpointDecision,
        originalFrame: WebSocketFrame,
        breakpointFrame: WebSocketBreakpointFrame,
        context: ChannelHandlerContext
    ) {
        breakpointTask = nil
        guard !state.isTerminal else {
            completeOperation(.success(()), context: context)
            return
        }

        switch decision {
        case .abort:
            terminateWithFailure(
                "Aborted at WebSocket response breakpoint",
                context: context
            )
        case .continue(let decidedHit):
            let replacementPayload = validatedReplacementPayload(
                from: decidedHit,
                original: breakpointFrame
            )
            let forwardedFrame = WebSocketFrameRelay.forwardedFrame(
                originalFrame,
                direction: direction,
                replacingPayload: replacementPayload
            )
            let transaction = self.transaction
            let peerChannel = self.peerChannel
            let boundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.eventLoop.makeFutureWithTask {
                await transaction.resumeWebSocketBreakpoint()
            }.flatMap {
                peerChannel.writeAndFlush(forwardedFrame)
            }.whenComplete { result in
                boundSelf.value.completeOperation(result, context: boundContext.value)
            }
        }
    }

    private func validatedReplacementPayload(
        from decidedHit: BreakpointHit,
        original: WebSocketBreakpointFrame
    ) -> Data? {
        guard decidedHit.flowID == flowID,
            decidedHit.phase == .webSocketResponse,
            let candidate = decidedHit.webSocketFrame,
            candidate.sequenceNumber == original.sequenceNumber,
            candidate.opcode == original.opcode,
            let payload = candidate.payload,
            let validated = try? original.replacingPayload(payload)
        else {
            return nil
        }
        return validated.payload
    }

    func channelInactive(context: ChannelHandlerContext) {
        breakpointTask?.cancel()
        breakpointTask = nil
        if state.beginTerminalTransition() {
            let transaction = self.transaction
            let captureTasks = state.captureTasks()
            let connectionRegistry = self.connectionRegistry
            let flowID = self.flowID
            let connectionToken = self.connectionToken
            Task { [transaction, captureTasks, connectionRegistry, flowID, connectionToken] in
                await connectionRegistry.unregister(flowID: flowID, token: connectionToken)
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
        breakpointTask?.cancel()
        breakpointTask = nil
        state.cancelCaptureTasks()
        let transaction = self.transaction
        let connectionRegistry = self.connectionRegistry
        let flowID = self.flowID
        let connectionToken = self.connectionToken
        Task { [transaction, connectionRegistry, flowID, connectionToken] in
            await connectionRegistry.unregister(flowID: flowID, token: connectionToken)
            await transaction.fail(.protocolError(message))
        }
        peerChannel.close(promise: nil)
        context.close(promise: nil)
    }
}
