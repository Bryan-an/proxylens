/// Receives immutable WebSocket frame records after their payload has been captured.
public protocol WebSocketFrameEventSink: Sendable {
    func publish(_ frame: CapturedWebSocketFrame) async
}
