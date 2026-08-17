import Foundation
import ProxyLensCore

enum ServerSentEventsDocument {
    static let entrySeparator = Data(",\n".utf8)
    static let epilogue = Data("\n]}\n".utf8)

    static func preamble(flowID: FlowID, exportedAt: Date) throws -> Data {
        let header = Header(
            format: "proxylens-server-sent-events",
            version: 1,
            flowID: flowID.description,
            exportedAt: timestamp(exportedAt)
        )
        var data = try encoder().encode(header)
        guard data.last == Character("}").asciiValue else {
            throw ProxyLensError.unsupportedOperation(
                "Could not serialize the Server-Sent Event export header"
            )
        }
        data.removeLast()
        data.append(contentsOf: Data(",\n\"events\":[\n".utf8))
        return data
    }

    static func serializeEntry(
        event: CapturedServerSentEvent,
        data: Data
    ) throws -> Data {
        let dataEncoding: String
        let dataValue: String
        if let text = String(data: data, encoding: .utf8) {
            dataEncoding = "utf8"
            dataValue = text
        } else {
            dataEncoding = "base64"
            dataValue = data.base64EncodedString()
        }

        return try encoder().encode(
            Entry(
                id: event.id.uuidString,
                sequenceNumber: event.sequenceNumber,
                eventType: event.eventType,
                eventID: event.eventID,
                retryMilliseconds: event.retryMilliseconds,
                receivedAt: timestamp(event.receivedAt),
                byteCount: event.dataByteCount,
                contentType: event.data.contentType,
                contentEncoding: event.data.contentEncoding,
                isTruncated: event.isDataTruncated,
                dataEncoding: dataEncoding,
                data: dataValue
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

    private struct Header: Encodable {
        let format: String
        let version: Int
        let flowID: String
        let exportedAt: String
    }

    private struct Entry: Encodable {
        let id: String
        let sequenceNumber: Int64
        let eventType: String
        let eventID: String?
        let retryMilliseconds: Int?
        let receivedAt: String
        let byteCount: Int64
        let contentType: String?
        let contentEncoding: String?
        let isTruncated: Bool
        let dataEncoding: String
        let data: String
    }
}
