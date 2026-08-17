import Foundation
import ProxyLensCore

struct ServerSentEventRecorder: Sendable {
    private let bodyStore: any BodyStore
    private let maximumCapturedDataBytes: Int64
    private let eventSink: any ServerSentEventEventSink

    init(
        bodyStore: any BodyStore,
        maximumCapturedDataBytes: Int64,
        eventSink: any ServerSentEventEventSink
    ) {
        self.bodyStore = bodyStore
        self.maximumCapturedDataBytes = max(0, maximumCapturedDataBytes)
        self.eventSink = eventSink
    }

    func record(
        _ parsedEvent: ParsedServerSentEvent,
        flowID: FlowID,
        sequenceNumber: Int64
    ) async throws {
        let writer = try await bodyStore.beginWrite(
            metadata: BodyMetadata(
                contentType: Self.contentType(for: parsedEvent.data),
                isTruncated: parsedEvent.isDataTruncated
            ),
            maximumByteCount: maximumCapturedDataBytes
        )
        do {
            try await writer.append(parsedEvent.data)
            let data = try await writer.finalize()
            await eventSink.publish(
                CapturedServerSentEvent(
                    flowID: flowID,
                    sequenceNumber: sequenceNumber,
                    eventType: parsedEvent.eventType,
                    eventID: parsedEvent.eventID,
                    retryMilliseconds: parsedEvent.retryMilliseconds,
                    data: data,
                    receivedAt: parsedEvent.receivedAt
                )
            )
        } catch {
            await writer.cancel()
            throw error
        }
    }

    private static func contentType(for data: Data) -> String {
        if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
            return "application/json"
        }
        return "text/plain; charset=utf-8"
    }
}

struct NoOpServerSentEventEventSink: ServerSentEventEventSink {
    func publish(_: CapturedServerSentEvent) async {}
}
