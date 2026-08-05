import Foundation

public protocol FlowStore: Sendable {
    /// Saves a flow snapshot. Implementations should treat this as an upsert.
    func save(_ flow: Flow) async throws
    func load(flowID: FlowID) async throws -> Flow?
    func listSummaries(in sessionID: SessionID) async throws -> [FlowSummary]
    func remove(flowID: FlowID) async throws
}
