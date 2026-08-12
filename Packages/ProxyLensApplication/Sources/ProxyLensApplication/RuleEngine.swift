import Foundation
import ProxyLensCore

public actor RuleEngine {
    public nonisolated let snapshot: MutableRuleSnapshot
    private var rules: [Rule]

    public init(snapshot: MutableRuleSnapshot = MutableRuleSnapshot()) {
        self.snapshot = snapshot
        self.rules = snapshot.currentRules().rules
    }

    public func currentRules() -> RuleSet {
        RuleSet(rules: rules)
    }

    public func replace(_ ruleSet: RuleSet) {
        rules = ruleSet.rules
        snapshot.replace(ruleSet)
    }

    public func add(_ rule: Rule) {
        replace(RuleSet(rules: rules + [rule]))
    }

    public func remove(id: RuleID) {
        replace(RuleSet(rules: rules.filter { $0.id != id }))
    }

    @discardableResult
    public func blockHost(_ host: String, reason: String? = nil) -> Rule {
        let rule = Rule(
            name: "Block \(host)",
            priority: 10,
            phase: .requestHeaders,
            matcher: .host(.exact(host)),
            action: .block(reason: reason ?? "Blocked host")
        )
        add(rule)
        return rule
    }

    @discardableResult
    public func allowHost(_ host: String) -> Rule {
        let rule = Rule(
            name: "Allow \(host)",
            priority: 0,
            phase: .requestHeaders,
            matcher: .host(.exact(host)),
            action: .allow
        )
        add(rule)
        return rule
    }

    @discardableResult
    public func disableCaching(forHost host: String) -> [Rule] {
        let requestRule = Rule(
            name: "No cache \(host) request",
            priority: 20,
            phase: .requestHeaders,
            matcher: .host(.exact(host)),
            action: .noCache
        )
        let responseRule = Rule(
            name: "No cache \(host) response",
            priority: 20,
            phase: .responseHeaders,
            matcher: .host(.exact(host)),
            action: .noCache
        )
        add(requestRule)
        add(responseRule)
        return [requestRule, responseRule]
    }
}
