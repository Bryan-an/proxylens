import Foundation
import NIOCore
import NIOWebSocket
import ProxyLensCore

final class DirectWebSocketFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame

    private let transaction: FlowTransaction
    private let flowID: FlowID
    private let recorder: WebSocketFrameRecorder?
    private let state: WebSocketBridgeState
    private let connectionRegistry: DirectWebSocketConnectionRegistry
    private let connectionToken: UUID
    private var context: ChannelHandlerContext?
    private var pendingFrames: [WebSocketFrame] = []
    private var isReady = false

    init(
        transaction: FlowTransaction,
        flowID: FlowID,
        recorder: WebSocketFrameRecorder?,
        state: WebSocketBridgeState,
        connectionRegistry: DirectWebSocketConnectionRegistry,
        connectionToken: UUID
    ) {
        self.transaction = transaction
        self.flowID = flowID
        self.recorder = recorder
        self.state = state
        self.connectionRegistry = connectionRegistry
        self.connectionToken = connectionToken
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func activate() {
        guard let eventLoop = context?.eventLoop else {
            return
        }
        eventLoop.execute {
            self.activateOnEventLoop()
        }
    }

    private func activateOnEventLoop() {
        guard !isReady, let context else {
            return
        }
        context.eventLoop.assertInEventLoop()
        isReady = true
        let frames = pendingFrames
        pendingFrames.removeAll(keepingCapacity: false)
        for frame in frames {
            receive(frame, context: context)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        guard isReady else {
            pendingFrames.append(frame)
            return
        }
        receive(frame, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finishConnection(eventLoop: context.eventLoop)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard state.beginTerminalTransition() else {
            context.close(promise: nil)
            return
        }
        state.cancelCaptureTasks()
        let transaction = self.transaction
        let tasks = state.captureTasks()
        let connectionRegistry = self.connectionRegistry
        let flowID = self.flowID
        let token = self.connectionToken
        let eventLoop = context.eventLoop
        Task {
            for task in tasks {
                _ = try? await task.value
            }
            _ = try? await eventLoop.submit {}.get()
            await transaction.fail(.protocolError(error.localizedDescription))
            await connectionRegistry.unregister(flowID: flowID, token: token)
        }
        context.close(promise: nil)
    }

    private func receive(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        let sequence = state.nextSequence()
        let captureFuture: EventLoopFuture<Void>
        if let recorder {
            captureFuture = state.capture(
                frame,
                flowID: flowID,
                sequenceNumber: sequence,
                direction: .serverToClient,
                recorder: recorder,
                eventLoop: context.eventLoop
            )
        } else {
            captureFuture = context.eventLoop.makeSucceededVoidFuture()
        }

        switch frame.opcode {
        case .ping:
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            let pong = WebSocketFrame(
                fin: true,
                opcode: .pong,
                maskKey: DirectWebSocketConnection.randomMask(),
                data: frame.unmaskedData
            )
            let capturedPong = DirectWebSocketConnection.capturedMaskedFrame(pong)
            let pongSequence = state.nextSequence()
            captureFuture.flatMap {
                boundContext.value.channel.writeAndFlush(pong)
            }.flatMap {
                guard let recorder = self.recorder else {
                    return boundContext.value.eventLoop.makeSucceededVoidFuture()
                }
                return self.state.capture(
                    capturedPong,
                    flowID: self.flowID,
                    sequenceNumber: pongSequence,
                    direction: .clientToServer,
                    recorder: recorder,
                    eventLoop: boundContext.value.eventLoop
                )
            }.whenFailure { _ in
                boundContext.value.close(promise: nil)
            }
        case .connectionClose:
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            guard state.beginCloseWrite() else {
                captureFuture.whenComplete { _ in
                    boundContext.value.close(promise: nil)
                }
                return
            }
            let reply = WebSocketFrame(
                fin: true,
                opcode: .connectionClose,
                maskKey: DirectWebSocketConnection.randomMask(),
                data: frame.unmaskedData
            )
            let capturedReply = DirectWebSocketConnection.capturedMaskedFrame(reply)
            let replySequence = state.nextSequence()
            captureFuture.flatMap {
                boundContext.value.channel.writeAndFlush(reply)
            }.flatMap {
                guard let recorder = self.recorder else {
                    return boundContext.value.eventLoop.makeSucceededVoidFuture()
                }
                return self.state.capture(
                    capturedReply,
                    flowID: self.flowID,
                    sequenceNumber: replySequence,
                    direction: .clientToServer,
                    recorder: recorder,
                    eventLoop: boundContext.value.eventLoop
                )
            }.whenComplete { _ in
                boundContext.value.close(promise: nil)
            }
        default:
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            captureFuture.whenFailure { _ in
                boundContext.value.close(promise: nil)
            }
        }
    }

    private func finishConnection(eventLoop: EventLoop) {
        guard state.beginTerminalTransition() else {
            return
        }
        let transaction = self.transaction
        let tasks = state.captureTasks()
        let connectionRegistry = self.connectionRegistry
        let flowID = self.flowID
        let token = self.connectionToken
        Task {
            do {
                for task in tasks {
                    try await task.value
                }
                _ = try await eventLoop.submit {}.get()
                await transaction.finishWebSocket(at: Date())
            } catch {
                await transaction.fail(.protocolError(error.localizedDescription))
            }
            await connectionRegistry.unregister(flowID: flowID, token: token)
        }
    }
}
