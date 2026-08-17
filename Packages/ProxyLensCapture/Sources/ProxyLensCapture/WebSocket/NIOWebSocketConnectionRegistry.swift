import Foundation
import NIOCore
import NIOWebSocket
import ProxyLensCore

actor NIOWebSocketConnectionRegistry {
    private struct Entry {
        let token: UUID
        let connection: NIOWebSocketConnection
    }

    private var entries: [FlowID: Entry] = [:]

    func register(
        _ connection: NIOWebSocketConnection,
        for flowID: FlowID,
        token: UUID
    ) {
        entries[flowID] = Entry(token: token, connection: connection)
    }

    func unregister(flowID: FlowID, token: UUID) {
        guard entries[flowID]?.token == token else {
            return
        }
        entries.removeValue(forKey: flowID)
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }

    func isConnectionOpen(for flowID: FlowID) async -> Bool {
        guard let entry = entries[flowID] else {
            return false
        }
        return await entry.connection.isOpen()
    }

    func send(_ transmission: WebSocketFrameTransmission) async throws {
        guard let entry = entries[transmission.flowID] else {
            throw ProxyLensError.unsupportedOperation(
                "The selected WebSocket connection is no longer open"
            )
        }

        do {
            try await entry.connection.send(transmission)
        } catch {
            if !(await entry.connection.isOpen()) {
                unregister(flowID: transmission.flowID, token: entry.token)
            }
            throw error
        }
    }
}

final class NIOWebSocketConnection: @unchecked Sendable {
    private let clientChannel: Channel
    private let upstreamChannel: Channel
    private let state: WebSocketBridgeState
    private let recorder: WebSocketFrameRecorder?
    private let maximumFrameBytes: Int

    init(
        clientChannel: Channel,
        upstreamChannel: Channel,
        state: WebSocketBridgeState,
        recorder: WebSocketFrameRecorder?,
        maximumFrameBytes: Int
    ) {
        self.clientChannel = clientChannel
        self.upstreamChannel = upstreamChannel
        self.state = state
        self.recorder = recorder
        self.maximumFrameBytes = maximumFrameBytes
    }

    func isOpen() async -> Bool {
        let clientChannel = self.clientChannel
        let upstreamChannel = self.upstreamChannel
        let state = self.state
        return
            (try? await clientChannel.eventLoop.submit {
                clientChannel.isActive && upstreamChannel.isActive && !state.isTerminal
            }.get()) ?? false
    }

    func send(_ transmission: WebSocketFrameTransmission) async throws {
        guard transmission.payload.count <= maximumFrameBytes else {
            throw ProxyLensError.unsupportedOperation(
                "The WebSocket frame exceeds the configured \(maximumFrameBytes)-byte limit"
            )
        }

        let clientChannel = self.clientChannel
        let upstreamChannel = self.upstreamChannel
        let state = self.state
        let recorder = self.recorder
        let future = clientChannel.eventLoop.submit {
            state.send(
                transmission,
                clientChannel: clientChannel,
                upstreamChannel: upstreamChannel,
                recorder: recorder
            )
        }
        try await future.flatMap { $0 }.get()
    }
}
