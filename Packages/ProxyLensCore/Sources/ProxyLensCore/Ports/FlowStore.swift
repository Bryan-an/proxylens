import Foundation

public protocol FlowStore: Sendable {
    /// Saves a flow snapshot. Implementations should treat this as an upsert.
    func save(_ flow: Flow) async throws
    func load(flowID: FlowID) async throws -> Flow?
    func listFlows(in sessionID: SessionID) async throws -> [Flow]
    func listSummaries(in sessionID: SessionID) async throws -> [FlowSummary]
    func updateAnnotation(_ annotation: FlowAnnotation?, for flowID: FlowID) async throws -> Flow?
    func remove(flowID: FlowID) async throws
}

extension FlowStore {
    public func updateAnnotation(_ annotation: FlowAnnotation?, for flowID: FlowID) async throws
        -> Flow?
    {
        guard var flow = try await load(flowID: flowID) else {
            return nil
        }
        flow.setAnnotation(annotation)
        try await save(flow)
        return flow
    }
}
