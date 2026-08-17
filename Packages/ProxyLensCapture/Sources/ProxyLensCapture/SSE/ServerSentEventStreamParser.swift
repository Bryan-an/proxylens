import Foundation

struct ParsedServerSentEvent: Equatable, Sendable {
    let eventType: String
    let eventID: String?
    let retryMilliseconds: Int?
    let data: Data
    let isDataTruncated: Bool
    let receivedAt: Date
}

struct ServerSentEventStreamParser: Sendable {
    private let maximumLineBytes: Int
    private let maximumEventDataBytes: Int

    private var lineBytes: [UInt8] = []
    private var isCurrentLineTruncated = false
    private var shouldSkipLineFeed = false
    private var hasInspectedFirstLine = false

    private var eventDataBytes: [UInt8] = []
    private var hasDataField = false
    private var isCurrentEventDataTruncated = false
    private var currentEventType = ""
    private var lastEventID: String?
    private var reconnectionTimeMilliseconds: Int?

    init(
        maximumLineBytes: Int = 64 * 1_024,
        maximumEventDataBytes: Int = 1_024 * 1_024
    ) {
        self.maximumLineBytes = max(0, maximumLineBytes)
        self.maximumEventDataBytes = max(0, maximumEventDataBytes)
    }

    mutating func append(_ data: Data, receivedAt: Date) -> [ParsedServerSentEvent] {
        var events: [ParsedServerSentEvent] = []

        for byte in data {
            if shouldSkipLineFeed {
                shouldSkipLineFeed = false
                if byte == Self.lineFeed {
                    continue
                }
            }

            switch byte {
            case Self.carriageReturn:
                processCurrentLine(receivedAt: receivedAt, events: &events)
                shouldSkipLineFeed = true
            case Self.lineFeed:
                processCurrentLine(receivedAt: receivedAt, events: &events)
            default:
                appendToCurrentLine(byte)
            }
        }

        return events
    }

    mutating func finish(receivedAt: Date) -> [ParsedServerSentEvent] {
        var events: [ParsedServerSentEvent] = []
        shouldSkipLineFeed = false

        if !lineBytes.isEmpty || isCurrentLineTruncated {
            processCurrentLine(receivedAt: receivedAt, events: &events)
        }

        if let event = dispatchCurrentEvent(receivedAt: receivedAt) {
            events.append(event)
        }
        return events
    }

    private mutating func appendToCurrentLine(_ byte: UInt8) {
        guard lineBytes.count < maximumLineBytes else {
            isCurrentLineTruncated = true
            return
        }
        lineBytes.append(byte)
    }

    private mutating func processCurrentLine(
        receivedAt: Date,
        events: inout [ParsedServerSentEvent]
    ) {
        var bytes = lineBytes
        let wasTruncated = isCurrentLineTruncated
        lineBytes.removeAll(keepingCapacity: true)
        isCurrentLineTruncated = false

        if !hasInspectedFirstLine {
            hasInspectedFirstLine = true
            if bytes.starts(with: Self.utf8ByteOrderMark) {
                bytes.removeFirst(Self.utf8ByteOrderMark.count)
            }
        }

        guard !bytes.isEmpty else {
            if let event = dispatchCurrentEvent(receivedAt: receivedAt) {
                events.append(event)
            }
            return
        }

        guard bytes.first != Self.colon else {
            return
        }

        let line = String(decoding: bytes, as: UTF8.self)
        let fieldAndValue = Self.fieldAndValue(from: line)

        if wasTruncated, fieldAndValue.field != "data" {
            return
        }

        switch fieldAndValue.field {
        case "data":
            appendEventData(fieldAndValue.value)
            isCurrentEventDataTruncated = isCurrentEventDataTruncated || wasTruncated
        case "event":
            currentEventType = fieldAndValue.value
        case "id" where !fieldAndValue.value.contains("\0"):
            lastEventID = fieldAndValue.value
        case "retry":
            if fieldAndValue.value.allSatisfy(\.isASCIIWholeNumber),
                !fieldAndValue.value.isEmpty,
                let milliseconds = Int(fieldAndValue.value)
            {
                reconnectionTimeMilliseconds = milliseconds
            }
        default:
            break
        }
    }

    private mutating func appendEventData(_ value: String) {
        if hasDataField {
            appendEventDataBytes([Self.lineFeed])
        }
        hasDataField = true
        appendEventDataBytes(Array(value.utf8))
    }

    private mutating func appendEventDataBytes(_ bytes: [UInt8]) {
        let availableByteCount = maximumEventDataBytes - eventDataBytes.count
        guard availableByteCount > 0 else {
            isCurrentEventDataTruncated = isCurrentEventDataTruncated || !bytes.isEmpty
            return
        }

        let acceptedByteCount = min(availableByteCount, bytes.count)
        eventDataBytes.append(contentsOf: bytes.prefix(acceptedByteCount))
        if acceptedByteCount < bytes.count {
            isCurrentEventDataTruncated = true
        }
    }

    private mutating func dispatchCurrentEvent(receivedAt: Date) -> ParsedServerSentEvent? {
        defer {
            eventDataBytes.removeAll(keepingCapacity: true)
            hasDataField = false
            isCurrentEventDataTruncated = false
            currentEventType = ""
        }

        guard hasDataField else {
            return nil
        }

        return ParsedServerSentEvent(
            eventType: currentEventType.isEmpty ? "message" : currentEventType,
            eventID: lastEventID,
            retryMilliseconds: reconnectionTimeMilliseconds,
            data: Data(eventDataBytes),
            isDataTruncated: isCurrentEventDataTruncated,
            receivedAt: receivedAt
        )
    }

    private static func fieldAndValue(from line: String) -> (field: String, value: String) {
        guard let colonIndex = line.firstIndex(of: ":") else {
            return (line, "")
        }

        let field = String(line[..<colonIndex])
        var valueStart = line.index(after: colonIndex)
        if valueStart < line.endIndex, line[valueStart] == " " {
            valueStart = line.index(after: valueStart)
        }
        return (field, String(line[valueStart...]))
    }

    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let colon: UInt8 = 0x3A
    private static let utf8ByteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
}

extension Character {
    fileprivate var isASCIIWholeNumber: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map { 0x30...0x39 ~= $0.value } == true
    }
}
