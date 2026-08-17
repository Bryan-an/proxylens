import Foundation
import ProxyLensCore

public actor ServerSentEventEventBus: ServerSentEventEventSink {
    public typealias BufferingPolicy =
        AsyncStream<CapturedServerSentEvent>.Continuation.BufferingPolicy

    private var continuations: [UUID: AsyncStream<CapturedServerSentEvent>.Continuation] = [:]

    public init() {}

    public func events(
        bufferingPolicy: BufferingPolicy = .bufferingNewest(512)
    ) -> AsyncStream<CapturedServerSentEvent> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: CapturedServerSentEvent.self,
            bufferingPolicy: bufferingPolicy
        )
        continuations[subscriptionID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscription(subscriptionID)
            }
        }
        return stream
    }

    public func publish(_ event: CapturedServerSentEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    public func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll(keepingCapacity: false)
    }

    public func subscriptionCount() -> Int {
        continuations.count
    }

    private func removeSubscription(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
