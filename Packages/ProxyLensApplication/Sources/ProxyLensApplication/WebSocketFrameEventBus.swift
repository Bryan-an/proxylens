import Foundation
import ProxyLensCore

public actor WebSocketFrameEventBus: WebSocketFrameEventSink {
    public typealias BufferingPolicy =
        AsyncStream<CapturedWebSocketFrame>.Continuation.BufferingPolicy

    private var continuations: [UUID: AsyncStream<CapturedWebSocketFrame>.Continuation] = [:]

    public init() {}

    public func frames(
        bufferingPolicy: BufferingPolicy = .bufferingNewest(512)
    ) -> AsyncStream<CapturedWebSocketFrame> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: CapturedWebSocketFrame.self,
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

    public func publish(_ frame: CapturedWebSocketFrame) {
        for continuation in continuations.values {
            continuation.yield(frame)
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
