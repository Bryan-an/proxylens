import Foundation
import ProxyLensCore

public struct ServerSentEventPersistenceFailure: Equatable, Sendable {
    public let eventID: UUID
    public let flowID: FlowID
    public let message: String
    public let occurredAt: Date

    public init(
        eventID: UUID,
        flowID: FlowID,
        message: String,
        occurredAt: Date = Date()
    ) {
        self.eventID = eventID
        self.flowID = flowID
        self.message = message
        self.occurredAt = occurredAt
    }
}

/// Persists decoded event metadata before exposing it to live UI subscribers.
public actor PersistingServerSentEventEventSink: ServerSentEventEventSink {
    private let eventStore: any ServerSentEventStore
    private let downstream: (any ServerSentEventEventSink)?
    private let maximumRetainedFailures: Int
    private var retainedFailures: [ServerSentEventPersistenceFailure] = []

    public init(
        eventStore: any ServerSentEventStore,
        downstream: (any ServerSentEventEventSink)? = nil,
        maximumRetainedFailures: Int = 100
    ) {
        self.eventStore = eventStore
        self.downstream = downstream
        self.maximumRetainedFailures = max(1, maximumRetainedFailures)
    }

    public func publish(_ event: CapturedServerSentEvent) async {
        do {
            try await eventStore.saveServerSentEvent(event)
            if let downstream {
                await downstream.publish(event)
            }
        } catch {
            retainedFailures.append(
                ServerSentEventPersistenceFailure(
                    eventID: event.id,
                    flowID: event.flowID,
                    message: error.localizedDescription
                )
            )
            if retainedFailures.count > maximumRetainedFailures {
                retainedFailures.removeFirst(retainedFailures.count - maximumRetainedFailures)
            }
        }
    }

    public func failures() -> [ServerSentEventPersistenceFailure] {
        retainedFailures
    }
}
