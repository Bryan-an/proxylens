import Foundation

public struct FlowSummary: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: FlowID
    public let sessionID: SessionID
    public let source: FlowSource
    public let method: HTTPMethod
    public let url: URL
    public let statusCode: Int?
    public let state: FlowState
    public let startedAt: Date
    public let requestByteCount: Int64?
    public let responseByteCount: Int64?
    public let totalDuration: TimeInterval?

    public init(flow: Flow) {
        self.id = flow.id
        self.sessionID = flow.sessionID
        self.source = flow.source
        self.method = flow.request.method
        self.url = flow.request.url
        self.statusCode = flow.response?.statusCode
        self.state = flow.state
        self.startedAt = flow.createdAt
        self.requestByteCount = flow.request.body?.byteCount
        self.responseByteCount = flow.response?.body?.byteCount
        self.totalDuration = flow.timing.totalDuration
    }
}
