import Foundation
import os

public protocol RuleSnapshotSource: Sendable {
    func currentRules() -> RuleSet
    func mappedLocal(for resourceID: String) -> MapLocalSpec?
}

extension RuleSnapshotSource {
    public func mappedLocal(for resourceID: String) -> MapLocalSpec? {
        nil
    }
}

public final class MutableRuleSnapshot: RuleSnapshotSource, Sendable {
    private struct State: Sendable {
        var rules: RuleSet
        var mappedLocals: [String: MapLocalSpec]
    }

    private let lock: OSAllocatedUnfairLock<State>

    public init(rules: RuleSet = RuleSet(), mappedLocals: [MapLocalSpec] = []) {
        var mapped: [String: MapLocalSpec] = [:]
        for spec in mappedLocals {
            mapped[spec.resourceID] = spec
        }
        lock = OSAllocatedUnfairLock(initialState: State(rules: rules, mappedLocals: mapped))
    }

    public func currentRules() -> RuleSet {
        lock.withLock { $0.rules }
    }

    public func mappedLocal(for resourceID: String) -> MapLocalSpec? {
        lock.withLock { $0.mappedLocals[resourceID] }
    }

    public func replace(_ rules: RuleSet) {
        lock.withLock { $0.rules = rules }
    }

    public func replaceMappedLocal(_ spec: MapLocalSpec) {
        lock.withLock { $0.mappedLocals[spec.resourceID] = spec }
    }

    public func retainMappedLocals(_ resourceIDs: Set<String>) {
        lock.withLock { state in
            state.mappedLocals = state.mappedLocals.filter { resourceIDs.contains($0.key) }
        }
    }
}
