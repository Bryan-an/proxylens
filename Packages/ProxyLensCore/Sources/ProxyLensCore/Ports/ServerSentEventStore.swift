public protocol ServerSentEventStore: Sendable {
    func saveServerSentEvent(_ event: CapturedServerSentEvent) async throws
    func listServerSentEvents(for flowID: FlowID) async throws -> [CapturedServerSentEvent]
    func removeServerSentEvents(for flowID: FlowID) async throws
}
