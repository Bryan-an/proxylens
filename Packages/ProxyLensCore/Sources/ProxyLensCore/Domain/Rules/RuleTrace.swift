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
    public let logs: [String]

    public init(
        traceID: UUID = UUID(),
        ruleID: RuleID,
        phase: RulePhase,
        outcome: RuleTraceOutcome,
        recordedAt: Date = Date(),
        ruleName: String? = nil,
        logs: [String] = []
    ) {
        self.traceID = traceID
        self.ruleID = ruleID
        self.phase = phase
        self.outcome = outcome
        self.recordedAt = recordedAt
        self.ruleName = ruleName
        self.logs = Self.boundedLogs(logs)
    }

    private enum CodingKeys: String, CodingKey {
        case traceID
        case ruleID
        case phase
        case outcome
        case recordedAt
        case ruleName
        case logs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let logs = try container.decodeIfPresent([String].self, forKey: .logs) ?? []
        guard Self.logsAreWithinLimits(logs) else {
            throw DecodingError.dataCorruptedError(
                forKey: .logs,
                in: container,
                debugDescription: "Script logs exceed their persisted limits."
            )
        }
        self.init(
            traceID: try container.decode(UUID.self, forKey: .traceID),
            ruleID: try container.decode(RuleID.self, forKey: .ruleID),
            phase: try container.decode(RulePhase.self, forKey: .phase),
            outcome: try container.decode(RuleTraceOutcome.self, forKey: .outcome),
            recordedAt: try container.decode(Date.self, forKey: .recordedAt),
            ruleName: try container.decodeIfPresent(String.self, forKey: .ruleName),
            logs: logs
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(traceID, forKey: .traceID)
        try container.encode(ruleID, forKey: .ruleID)
        try container.encode(phase, forKey: .phase)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encodeIfPresent(ruleName, forKey: .ruleName)
        if !logs.isEmpty {
            try container.encode(logs, forKey: .logs)
        }
    }

    private static func logsAreWithinLimits(_ logs: [String]) -> Bool {
        logs.count <= ScriptExecutionLimits.maximumLogCount
            && logs.reduce(0, { $0 + $1.utf8.count })
                <= ScriptExecutionLimits.maximumLogByteCount
    }

    private static func boundedLogs(_ logs: [String]) -> [String] {
        guard !logs.isEmpty else {
            return []
        }
        var byteCount = 0
        return logs.prefix(ScriptExecutionLimits.maximumLogCount).prefix { entry in
            byteCount += entry.utf8.count
            return byteCount <= ScriptExecutionLimits.maximumLogByteCount
        }.map(\.self)
    }
}
