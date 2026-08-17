import Foundation

public enum WebSocketFrameDirection: String, Codable, Equatable, Hashable, Sendable {
    case clientToServer
    case serverToClient
}

public enum WebSocketFrameOpcode: Codable, Equatable, Hashable, Sendable {
    case continuation
    case text
    case binary
    case close
    case ping
    case pong
    case unknown(UInt8)
}

public struct WebSocketReservedBits: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue & 0b111
    }

    public static let rsv1 = WebSocketReservedBits(rawValue: 1 << 0)
    public static let rsv2 = WebSocketReservedBits(rawValue: 1 << 1)
    public static let rsv3 = WebSocketReservedBits(rawValue: 1 << 2)
}

/// Immutable metadata for one RFC 6455 frame. The payload reference points to the authoritative
/// unmasked application bytes in `BodyStore`; decoded text, JSON, and hex views are derived.
public struct CapturedWebSocketFrame: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let flowID: FlowID
    public let sequenceNumber: Int64
    public let direction: WebSocketFrameDirection
    public let opcode: WebSocketFrameOpcode
    public let isFinal: Bool
    public let reservedBits: WebSocketReservedBits
    public let wasMasked: Bool
    public let payload: BodyReference
    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        flowID: FlowID,
        sequenceNumber: Int64,
        direction: WebSocketFrameDirection,
        opcode: WebSocketFrameOpcode,
        isFinal: Bool,
        reservedBits: WebSocketReservedBits = [],
        wasMasked: Bool = false,
        payload: BodyReference,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.flowID = flowID
        self.sequenceNumber = max(0, sequenceNumber)
        self.direction = direction
        self.opcode = opcode
        self.isFinal = isFinal
        self.reservedBits = reservedBits
        self.wasMasked = wasMasked
        self.payload = payload
        self.receivedAt = receivedAt
    }

    public var payloadByteCount: Int64 {
        payload.byteCount
    }
}
