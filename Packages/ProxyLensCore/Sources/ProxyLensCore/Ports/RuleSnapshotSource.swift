import Foundation
import os

public protocol RuleSnapshotSource: Sendable {
    func currentRules() -> RuleSet
}

public final class MutableRuleSnapshot: RuleSnapshotSource, Sendable {
    private let lock: OSAllocatedUnfairLock<RuleSet>

    public init(rules: RuleSet = RuleSet()) {
        lock = OSAllocatedUnfairLock(initialState: rules)
    }

    public func currentRules() -> RuleSet {
        lock.withLock { $0 }
    }

    public func replace(_ rules: RuleSet) {
        lock.withLock { $0 = rules }
    }
}
