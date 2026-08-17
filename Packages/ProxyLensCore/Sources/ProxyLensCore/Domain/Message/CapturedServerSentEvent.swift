import Foundation

/// Immutable metadata for one decoded Server-Sent Event. The event data reference points to a
/// bounded, normalized UTF-8 representation in `BodyStore`; the flow response body remains the
/// authoritative raw byte stream.
public struct CapturedServerSentEvent: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let flowID: FlowID
    public let sequenceNumber: Int64
    public let eventType: String
    public let eventID: String?
    public let retryMilliseconds: Int?
    public let data: BodyReference
    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        flowID: FlowID,
        sequenceNumber: Int64,
        eventType: String = "message",
        eventID: String? = nil,
        retryMilliseconds: Int? = nil,
        data: BodyReference,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.flowID = flowID
        self.sequenceNumber = max(0, sequenceNumber)
        self.eventType = eventType.isEmpty ? "message" : eventType
        self.eventID = eventID
        self.retryMilliseconds = retryMilliseconds.map { max(0, $0) }
        self.data = data
        self.receivedAt = receivedAt
    }

    public var dataByteCount: Int64 {
        data.byteCount
    }

    public var isDataTruncated: Bool {
        data.isTruncated
    }
}
