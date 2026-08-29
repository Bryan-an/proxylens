import Foundation
import os

public protocol TLSInterceptionPolicySource: Sendable {
    func currentPolicy() -> TLSInterceptionPolicy
}

public final class MutableTLSInterceptionPolicy: TLSInterceptionPolicySource,
    Sendable
{
    private let lock: OSAllocatedUnfairLock<TLSInterceptionPolicy>

    public init(policy: TLSInterceptionPolicy = TLSInterceptionPolicy()) {
        lock = OSAllocatedUnfairLock(initialState: policy)
    }

    public func currentPolicy() -> TLSInterceptionPolicy {
        lock.withLock { $0 }
    }

    public func replace(_ policy: TLSInterceptionPolicy) {
        lock.withLock { $0 = policy }
    }
}
