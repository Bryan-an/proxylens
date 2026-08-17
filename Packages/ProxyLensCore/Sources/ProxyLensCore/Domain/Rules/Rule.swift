import Foundation

public struct Rule: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: RuleID
    public let name: String
    public let enabled: Bool
    public let priority: Int
    public let phase: RulePhase
    public let matcher: Matcher
    public let action: RuleAction

    public init(
        id: RuleID = RuleID(),
        name: String,
        enabled: Bool = true,
        priority: Int = 0,
        phase: RulePhase,
        matcher: Matcher = .any,
        action: RuleAction
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.priority = priority
        self.phase = phase
        self.matcher = matcher
        self.action = action
    }

    public func matches(_ context: RuleMatchContext) -> Bool {
        enabled && matcher.matches(context)
    }
}

public struct RuleSet: Codable, Equatable, Hashable, Sendable {
    public let rules: [Rule]

    public init(rules: [Rule] = []) {
        self.rules = rules
    }

    /// Rules are evaluated from the lowest priority number to the highest.
    /// Rule IDs provide a stable tie-breaker for equal priorities.
    public var orderedRules: [Rule] {
        rules.sorted {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }

            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }

    public func matchingRules(for context: RuleMatchContext, phase: RulePhase? = nil) -> [Rule] {
        orderedRules.filter { rule in
            (phase == nil || rule.phase == phase) && rule.matches(context)
        }
    }

    public func hasEnabledRules(for phase: RulePhase) -> Bool {
        rules.contains { $0.enabled && $0.phase == phase }
    }
}
