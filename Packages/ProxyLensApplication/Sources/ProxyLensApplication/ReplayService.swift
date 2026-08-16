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
        let replayedFlow = try await client.replay(
            flow.request,
            sessionID: flow.sessionID
        )
        try await flowStore.save(replayedFlow)
        return replayedFlow
    }
}
