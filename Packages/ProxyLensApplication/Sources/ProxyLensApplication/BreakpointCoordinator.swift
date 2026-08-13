import Foundation
import ProxyLensCore

public actor BreakpointCoordinator: BreakpointGate {
    private var pending: [FlowID: PendingBreakpoint] = [:]

    public init() {}

    public func pause(_ hit: BreakpointHit) async -> BreakpointDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let existing = pending.removeValue(forKey: hit.flowID) {
                    existing.continuation.resume(returning: .abort)
                }
                pending[hit.flowID] = PendingBreakpoint(hit: hit, continuation: continuation)
            }
        } onCancel: {
            Task {
                await self.abort(flowID: hit.flowID)
            }
        }
    }

    public func resume(flowID: FlowID, decision: BreakpointDecision) {
        guard let pending = pending.removeValue(forKey: flowID) else {
            return
        }
        pending.continuation.resume(returning: decision)
    }

    public func abort(flowID: FlowID) {
        resume(flowID: flowID, decision: .abort)
    }

    public func abortAll() {
        let flowIDs = Array(pending.keys)
        for flowID in flowIDs {
            abort(flowID: flowID)
        }
    }

    public func hit(for flowID: FlowID) -> BreakpointHit? {
        pending[flowID]?.hit
    }

    private struct PendingBreakpoint {
        let hit: BreakpointHit
        let continuation: CheckedContinuation<BreakpointDecision, Never>
    }
}
