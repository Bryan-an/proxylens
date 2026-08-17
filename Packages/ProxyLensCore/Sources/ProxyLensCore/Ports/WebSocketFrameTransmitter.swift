import Foundation

/// One complete application-authored WebSocket message destined for a live upgraded flow.
/// Only text and binary opcodes are accepted by the compose use case.
public struct WebSocketFrameTransmission: Equatable, Sendable {
    public let flowID: FlowID
    public let direction: WebSocketFrameDirection
    public let opcode: WebSocketFrameOpcode
    public let payload: Data

    public init(
        flowID: FlowID,
        direction: WebSocketFrameDirection,
        opcode: WebSocketFrameOpcode,
        payload: Data
    ) {
        self.flowID = flowID
        self.direction = direction
        self.opcode = opcode
        self.payload = payload
    }
}

/// Control-plane port for writing an authored frame to an already-open WebSocket connection.
public protocol WebSocketFrameTransmitter: Sendable {
    func isConnectionOpen(for flowID: FlowID) async -> Bool
    func send(_ transmission: WebSocketFrameTransmission) async throws
}
