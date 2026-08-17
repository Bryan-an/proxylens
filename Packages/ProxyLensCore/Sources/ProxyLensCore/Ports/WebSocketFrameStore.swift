public protocol WebSocketFrameStore: Sendable {
    func saveWebSocketFrame(_ frame: CapturedWebSocketFrame) async throws
    func listWebSocketFrames(for flowID: FlowID) async throws -> [CapturedWebSocketFrame]
    func removeWebSocketFrames(for flowID: FlowID) async throws
}
