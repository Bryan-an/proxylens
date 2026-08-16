public protocol RequestReplayClient: Sendable {
    /// Sends a captured request again and returns the resulting replay flow.
    func replay(_ request: HTTPRequest, sessionID: SessionID) async throws -> Flow
}
