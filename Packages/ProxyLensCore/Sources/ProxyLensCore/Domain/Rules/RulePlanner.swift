import Foundation

public struct RulePlan: Equatable, Sendable {
    public let phase: RulePhase
    public let traces: [RuleTrace]
    public let shouldBlock: Bool
    public let blockReason: String?
    public let applyNoCache: Bool
    public let mapLocalResourceID: String?
    public let mapRemoteURL: URL?
    public let redirectURL: URL?
    public let replacementBody: BodyReference?
    public let throttleProfile: ThrottleProfile?
    public let shouldBreakpoint: Bool

    public init(
        phase: RulePhase,
        traces: [RuleTrace] = [],
        shouldBlock: Bool = false,
        blockReason: String? = nil,
        applyNoCache: Bool = false,
        mapLocalResourceID: String? = nil,
        mapRemoteURL: URL? = nil,
        redirectURL: URL? = nil,
        replacementBody: BodyReference? = nil,
        throttleProfile: ThrottleProfile? = nil,
        shouldBreakpoint: Bool = false
    ) {
        self.phase = phase
        self.traces = traces
        self.shouldBlock = shouldBlock
        self.blockReason = blockReason
        self.applyNoCache = applyNoCache
        self.mapLocalResourceID = mapLocalResourceID
        self.mapRemoteURL = mapRemoteURL
        self.redirectURL = redirectURL
        self.replacementBody = replacementBody
        self.throttleProfile = throttleProfile
        self.shouldBreakpoint = shouldBreakpoint
    }
}

public enum RulePlanner: Sendable {
    public enum Decision {
        public static let alreadyDecidedReason =
            "A previous allow or block rule already decided this phase"
        public static let blockAllowPhaseReason =
            "Block applies during request headers or request body; allow applies during request headers"
        public static let noCachePhaseReason =
            "No-cache currently applies during request or response headers"
        public static let mapLocalPhaseReason =
            "Map Local currently applies during request headers or request body"
        public static let mapRemotePhaseReason =
            "Map Remote currently applies during request headers or request body"
        public static let alreadyMappedReason =
            "A previous mapping rule already decided this request"
        public static let redirectPhaseReason =
            "Redirect currently applies during request headers"
        public static let alreadyRedirectedReason =
            "A previous Redirect rule already answered this request"
        public static let replaceBodyPhaseReason =
            "Replace Body currently applies during request or response body"
        public static let alreadyReplacedBodyReason =
            "A previous Replace Body rule already rewrote this message"
        public static let throttlePhaseReason =
            "Throttle currently applies during request headers"
        public static let alreadyThrottledReason =
            "A previous Throttle rule already selected network conditions"
        public static let breakpointPhaseReason =
            "Breakpoint currently applies during request headers, request body, or response headers"
        public static let alreadyPausedReason =
            "A previous breakpoint rule already paused this phase"
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
        var mapLocalResourceID: String?
        var mapRemoteURL: URL?
        var redirectURL: URL?
        var replacementBody: BodyReference?
        var throttleProfile: ThrottleProfile?
        var shouldBreakpoint = false

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
                } else if phase == .requestHeaders || phase == .requestBody {
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
            case .mapLocal(let resourceID):
                if shouldBlock {
                    outcome = .skipped(reason: Decision.alreadyDecidedReason)
                } else if mapLocalResourceID != nil || mapRemoteURL != nil || redirectURL != nil {
                    outcome = .skipped(reason: Decision.alreadyMappedReason)
                } else if phase == .requestHeaders || phase == .requestBody {
                    outcome = .applied
                    mapLocalResourceID = resourceID
                    terminated = true
                } else {
                    outcome = .skipped(reason: Decision.mapLocalPhaseReason)
                }
            case .mapRemote(let url):
                if shouldBlock {
                    outcome = .skipped(reason: Decision.alreadyDecidedReason)
                } else if mapLocalResourceID != nil || mapRemoteURL != nil || redirectURL != nil {
                    outcome = .skipped(reason: Decision.alreadyMappedReason)
                } else if phase == .requestHeaders || phase == .requestBody {
                    outcome = .applied
                    mapRemoteURL = url
                    terminated = true
                } else {
                    outcome = .skipped(reason: Decision.mapRemotePhaseReason)
                }
            case .redirect(let url):
                if shouldBlock {
                    outcome = .skipped(reason: Decision.alreadyDecidedReason)
                } else if mapLocalResourceID != nil || mapRemoteURL != nil {
                    outcome = .skipped(reason: Decision.alreadyMappedReason)
                } else if redirectURL != nil {
                    outcome = .skipped(reason: Decision.alreadyRedirectedReason)
                } else if phase == .requestHeaders {
                    outcome = .applied
                    redirectURL = url
                    terminated = true
                } else {
                    outcome = .skipped(reason: Decision.redirectPhaseReason)
                }
            case .breakpoint:
                if shouldBlock {
                    outcome = .skipped(reason: Decision.alreadyDecidedReason)
                } else if mapLocalResourceID != nil || redirectURL != nil {
                    outcome = .skipped(reason: Decision.alreadyMappedReason)
                } else if shouldBreakpoint {
                    outcome = .skipped(reason: Decision.alreadyPausedReason)
                } else if phase == .requestHeaders || phase == .requestBody
                    || phase == .responseHeaders
                {
                    outcome = .applied
                    shouldBreakpoint = true
                } else {
                    outcome = .skipped(reason: Decision.breakpointPhaseReason)
                }
            case .replaceBody(let body):
                if shouldBlock {
                    outcome = .skipped(reason: Decision.alreadyDecidedReason)
                } else if mapLocalResourceID != nil || redirectURL != nil {
                    outcome = .skipped(reason: Decision.alreadyMappedReason)
                } else if replacementBody != nil {
                    outcome = .skipped(reason: Decision.alreadyReplacedBodyReason)
                } else if phase == .requestBody || phase == .responseBody {
                    outcome = .applied
                    replacementBody = body
                } else {
                    outcome = .skipped(reason: Decision.replaceBodyPhaseReason)
                }
            case .throttle(let profile):
                if terminated {
                    outcome = .skipped(reason: Decision.alreadyDecidedReason)
                } else if throttleProfile != nil {
                    outcome = .skipped(reason: Decision.alreadyThrottledReason)
                } else if phase == .requestHeaders {
                    outcome = .applied
                    throttleProfile = profile
                } else {
                    outcome = .skipped(reason: Decision.throttlePhaseReason)
                }
            case .annotate:
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
            applyNoCache: applyNoCache,
            mapLocalResourceID: mapLocalResourceID,
            mapRemoteURL: mapRemoteURL,
            redirectURL: redirectURL,
            replacementBody: replacementBody,
            throttleProfile: throttleProfile,
            shouldBreakpoint: shouldBreakpoint
        )
    }
}
