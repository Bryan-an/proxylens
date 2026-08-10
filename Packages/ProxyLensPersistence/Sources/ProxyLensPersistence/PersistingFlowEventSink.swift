import Foundation
import ProxyLensCore

public struct FlowPersistenceFailure: Equatable, Sendable {
    public let flowID: FlowID
    public let message: String
    public let occurredAt: Date

    public init(flowID: FlowID, message: String, occurredAt: Date = Date()) {
        self.flowID = flowID
        self.message = message
        self.occurredAt = occurredAt
    }
}

/// Persists immutable flow snapshots before forwarding them to another consumer.
public actor PersistingFlowEventSink: FlowEventSink, CaptureStartupRecovery {
    private let flowStore: any FlowStore
    private let downstream: (any FlowEventSink)?
    private let maximumRetainedFailures: Int
    private var retainedFailures: [FlowPersistenceFailure] = []

    public init(
        flowStore: any FlowStore,
        downstream: (any FlowEventSink)? = nil,
        maximumRetainedFailures: Int = 100
    ) {
        self.flowStore = flowStore
        self.downstream = downstream
        self.maximumRetainedFailures = max(1, maximumRetainedFailures)
    }

    public func publish(_ event: FlowEvent) async {
        let flow = event.flow
        do {
            try await flowStore.save(flow)
        } catch {
            retainedFailures.append(
                FlowPersistenceFailure(
                    flowID: flow.id,
                    message: error.localizedDescription
                )
            )
            if retainedFailures.count > maximumRetainedFailures {
                retainedFailures.removeFirst(retainedFailures.count - maximumRetainedFailures)
            }
        }

        if let downstream {
            await downstream.publish(event)
        }
    }

    public func prepareForCaptureStart() async throws {
        guard let startupRecovery = flowStore as? any CaptureStartupRecovery else {
            return
        }
        try await startupRecovery.prepareForCaptureStart()
    }

    public func failures() -> [FlowPersistenceFailure] {
        retainedFailures
    }
}

extension FlowEvent {
    fileprivate var flow: Flow {
        switch self {
        case .started(let flow), .updated(let flow), .finished(let flow):
            flow
        }
    }
}
