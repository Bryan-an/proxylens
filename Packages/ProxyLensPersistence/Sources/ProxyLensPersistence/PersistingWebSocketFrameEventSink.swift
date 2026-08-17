import Foundation
import ProxyLensCore

public struct WebSocketFramePersistenceFailure: Equatable, Sendable {
    public let frameID: UUID
    public let flowID: FlowID
    public let message: String
    public let occurredAt: Date

    public init(
        frameID: UUID,
        flowID: FlowID,
        message: String,
        occurredAt: Date = Date()
    ) {
        self.frameID = frameID
        self.flowID = flowID
        self.message = message
        self.occurredAt = occurredAt
    }
}

/// Persists frame metadata before exposing it to live UI subscribers.
public actor PersistingWebSocketFrameEventSink: WebSocketFrameEventSink {
    private let frameStore: any WebSocketFrameStore
    private let downstream: (any WebSocketFrameEventSink)?
    private let maximumRetainedFailures: Int
    private var retainedFailures: [WebSocketFramePersistenceFailure] = []

    public init(
        frameStore: any WebSocketFrameStore,
        downstream: (any WebSocketFrameEventSink)? = nil,
        maximumRetainedFailures: Int = 100
    ) {
        self.frameStore = frameStore
        self.downstream = downstream
        self.maximumRetainedFailures = max(1, maximumRetainedFailures)
    }

    public func publish(_ frame: CapturedWebSocketFrame) async {
        do {
            try await frameStore.saveWebSocketFrame(frame)
            if let downstream {
                await downstream.publish(frame)
            }
        } catch {
            retainedFailures.append(
                WebSocketFramePersistenceFailure(
                    frameID: frame.id,
                    flowID: frame.flowID,
                    message: error.localizedDescription
                )
            )
            if retainedFailures.count > maximumRetainedFailures {
                retainedFailures.removeFirst(retainedFailures.count - maximumRetainedFailures)
            }
        }
    }

    public func failures() -> [WebSocketFramePersistenceFailure] {
        retainedFailures
    }
}
