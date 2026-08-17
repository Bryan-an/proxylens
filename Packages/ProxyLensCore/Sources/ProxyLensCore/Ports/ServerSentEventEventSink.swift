/// Receives immutable Server-Sent Event records after their normalized data has been captured.
public protocol ServerSentEventEventSink: Sendable {
    func publish(_ event: CapturedServerSentEvent) async
}
