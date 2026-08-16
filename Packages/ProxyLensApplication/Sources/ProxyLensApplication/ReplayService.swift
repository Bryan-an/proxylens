import ProxyLensCore

public struct ReplayService: Sendable {
    private let client: any RequestReplayClient
    private let flowStore: any FlowStore

    public init(client: any RequestReplayClient, flowStore: any FlowStore) {
        self.client = client
        self.flowStore = flowStore
    }

    @discardableResult
    public func repeatRequest(_ flow: Flow) async throws -> Flow {
        try await repeatRequest(flow.request, sessionID: flow.sessionID)
    }

    @discardableResult
    public func repeatRequest(_ request: HTTPRequest, sessionID: SessionID) async throws -> Flow {
        let replayedFlow = try await client.replay(request, sessionID: sessionID)
        try await flowStore.save(replayedFlow)
        return replayedFlow
    }
}
