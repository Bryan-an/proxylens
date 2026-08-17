import Foundation
import ProxyLensCore

enum WebSocketFramesDocument {
    static let entrySeparator = Data(",\n".utf8)
    static let epilogue = Data("\n]}\n".utf8)

    static func preamble(flowID: FlowID, exportedAt: Date) throws -> Data {
        let header = Header(
            format: "proxylens-websocket-frames",
            version: 1,
            flowID: flowID.description,
            exportedAt: timestamp(exportedAt)
        )
        var data = try encoder().encode(header)
        guard data.last == Character("}").asciiValue else {
            throw ProxyLensError.unsupportedOperation(
                "Could not serialize the WebSocket frame export header"
            )
        }
        data.removeLast()
        data.append(contentsOf: Data(",\n\"frames\":[\n".utf8))
        return data
    }

    static func serializeEntry(
        frame: CapturedWebSocketFrame,
        payload: Data
    ) throws -> Data {
        let payloadEncoding: String
        let payloadValue: String
        if frame.opcode != .binary, let text = String(data: payload, encoding: .utf8) {
            payloadEncoding = "utf8"
            payloadValue = text
        } else {
            payloadEncoding = "base64"
            payloadValue = payload.base64EncodedString()
        }

        return try encoder().encode(
            Entry(
                id: frame.id.uuidString,
                sequenceNumber: frame.sequenceNumber,
                direction: direction(frame.direction),
                opcode: opcode(frame.opcode),
                isFinal: frame.isFinal,
                wasMasked: frame.wasMasked,
                reservedBits: reservedBits(frame.reservedBits),
                receivedAt: timestamp(frame.receivedAt),
                byteCount: frame.payloadByteCount,
                contentType: frame.payload.contentType,
                contentEncoding: frame.payload.contentEncoding,
                isTruncated: frame.payload.isTruncated,
                payloadEncoding: payloadEncoding,
                payload: payloadValue
            )
        )
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func direction(_ direction: WebSocketFrameDirection) -> String {
        switch direction {
        case .clientToServer: "sent"
        case .serverToClient: "received"
        }
    }

    private static func opcode(_ opcode: WebSocketFrameOpcode) -> String {
        switch opcode {
        case .continuation: "continuation"
        case .text: "text"
        case .binary: "binary"
        case .close: "close"
        case .ping: "ping"
        case .pong: "pong"
        case .unknown(let value): String(format: "unknown-0x%02X", value)
        }
    }

    private static func reservedBits(_ bits: WebSocketReservedBits) -> [String] {
        [
            bits.contains(.rsv1) ? "RSV1" : nil,
            bits.contains(.rsv2) ? "RSV2" : nil,
            bits.contains(.rsv3) ? "RSV3" : nil
        ].compactMap { $0 }
    }

    private struct Header: Encodable {
        let format: String
        let version: Int
        let flowID: String
        let exportedAt: String
    }

    private struct Entry: Encodable {
        let id: String
        let sequenceNumber: Int64
        let direction: String
        let opcode: String
        let isFinal: Bool
        let wasMasked: Bool
        let reservedBits: [String]
        let receivedAt: String
        let byteCount: Int64
        let contentType: String?
        let contentEncoding: String?
        let isTruncated: Bool
        let payloadEncoding: String
        let payload: String
    }
}
