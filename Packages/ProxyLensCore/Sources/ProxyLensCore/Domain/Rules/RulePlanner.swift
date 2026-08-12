import Foundation

public struct RulePlan: Equatable, Sendable {
    public let phase: RulePhase
    public let traces: [RuleTrace]
    public let shouldBlock: Bool
    public let blockReason: String?
    public let applyNoCache: Bool

    public init(
        phase: RulePhase,
        traces: [RuleTrace] = [],
        shouldBlock: Bool = false,
        blockReason: String? = nil,
        applyNoCache: Bool = false
    ) {
        self.phase = phase
        self.traces = traces
        self.shouldBlock = shouldBlock
        self.blockReason = blockReason
        self.applyNoCache = applyNoCache
    }
}

public enum RulePlanner: Sendable {
    public enum Decision {
        public static let alreadyDecidedReason =
            "A previous allow or block rule already decided this phase"
        public static let blockAllowPhaseReason =
            "Block and allow currently apply during request headers"
        public static let noCachePhaseReason =
            "No-cache currently applies during request or response headers"
        public static let unimplementedActionReason = "Action is not implemented yet"
    }

    public static func plan(
        rules: RuleSet,
        context: RuleMatchContext,
        phase: RulePhase,
        recordedAt: Date = Date()
    ) -> RulePlan {
        var traces: [RuleTrace] = []
        var terminated = false
        var shouldBlock = false
        var blockReason: String?
        var applyNoCache = false

        for rule in rules.matchingRules(for: context, phase: phase) {
            let outcome: RuleTraceOutcome
            switch rule.action {
            case .allow:
                if terminated {
                    outcome = .skipped(reason: Decision.alreadyDecidedReason)
                } else if phase == .requestHeaders {
                    outcome = .applied
                    terminated = true
                } else {
                    outcome = .skipped(reason: Decision.blockAllowPhaseReason)
                }
            case .block(let reason):
                if terminated {
                    outcome = .skipped(reason: Decision.alreadyDecidedReason)
                } else if phase == .requestHeaders {
                    outcome = .applied
                    terminated = true
                    shouldBlock = true
                    blockReason = reason
                } else {
                    outcome = .skipped(reason: Decision.blockAllowPhaseReason)
                }
            case .noCache:
                if phase == .requestHeaders || phase == .responseHeaders {
                    outcome = .applied
                    applyNoCache = true
                } else {
                    outcome = .skipped(reason: Decision.noCachePhaseReason)
                }
            case .mapLocal, .mapRemote, .breakpoint, .replaceBody, .throttle, .redirect,
                .annotate:
                if terminated {
                    outcome = .skipped(reason: Decision.alreadyDecidedReason)
                } else {
                    outcome = .skipped(reason: Decision.unimplementedActionReason)
                }
            }

            traces.append(
                RuleTrace(
                    ruleID: rule.id,
                    phase: phase,
                    outcome: outcome,
                    recordedAt: recordedAt,
                    ruleName: rule.name
                )
            )
        }

        return RulePlan(
            phase: phase,
            traces: traces,
            shouldBlock: shouldBlock,
            blockReason: blockReason,
            applyNoCache: applyNoCache
        )
    }
}
