import Foundation

/// One complete application-authored message sent immediately after a fresh WebSocket upgrade.
/// A direct client always sends toward the upstream server, so direction is intentionally absent.
public struct WebSocketClientMessage: Equatable, Sendable {
    public let opcode: WebSocketFrameOpcode
    public let payload: Data

    public init(opcode: WebSocketFrameOpcode, payload: Data) {
        self.opcode = opcode
        self.payload = payload
    }
}

/// Opens and owns direct WebSocket client connections independently of proxy capture.
public protocol WebSocketConnectionClient: WebSocketFrameTransmitter {
    func connect(
        _ request: HTTPRequest,
        initialMessage: WebSocketClientMessage?,
        sessionID: SessionID
    ) async throws -> Flow

    func disconnect(flowID: FlowID) async
}
