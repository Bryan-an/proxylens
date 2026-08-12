import Foundation

public enum RulePhase: String, Codable, Equatable, Hashable, Sendable {
    case connection
    case requestHeaders
    case requestBody
    case responseHeaders
    case responseBody
    case webSocketFrame
}

public enum RuleTraceOutcome: Codable, Equatable, Hashable, Sendable {
    case matched
    case applied
    case skipped(reason: String)
    case failed(message: String)
}

public struct RuleTrace: Codable, Equatable, Hashable, Sendable {
    public let traceID: UUID
    public let ruleID: RuleID
    public let phase: RulePhase
    public let outcome: RuleTraceOutcome
    public let recordedAt: Date
    public let ruleName: String?

    public init(
        traceID: UUID = UUID(),
        ruleID: RuleID,
        phase: RulePhase,
        outcome: RuleTraceOutcome,
        recordedAt: Date = Date(),
        ruleName: String? = nil
    ) {
        self.traceID = traceID
        self.ruleID = ruleID
        self.phase = phase
        self.outcome = outcome
        self.recordedAt = recordedAt
        self.ruleName = ruleName
    }
}
