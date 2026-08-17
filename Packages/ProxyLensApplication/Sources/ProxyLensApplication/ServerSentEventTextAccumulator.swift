import Foundation

public struct ServerSentEventAccumulatedPreview: Equatable, Sendable {
    public let text: String
    public let contributingEventCount: Int
    public let terminalEventCount: Int
    public let ignoredEventCount: Int
    public let skippedOversizedEventCount: Int
    public let isTruncated: Bool

    public init(
        text: String,
        contributingEventCount: Int,
        terminalEventCount: Int,
        ignoredEventCount: Int,
        skippedOversizedEventCount: Int,
        isTruncated: Bool
    ) {
        self.text = text
        self.contributingEventCount = contributingEventCount
        self.terminalEventCount = terminalEventCount
        self.ignoredEventCount = ignoredEventCount
        self.skippedOversizedEventCount = skippedOversizedEventCount
        self.isTruncated = isTruncated
    }
}

/// Builds a bounded, derived text preview from recognized Server-Sent Event payloads. Captured
/// event data and the authoritative response body are never modified.
public struct ServerSentEventTextAccumulator: Sendable {
    public private(set) var preview: ServerSentEventAccumulatedPreview

    private let maximumOutputBytes: Int
    private let maximumEventDataBytes: Int

    public init(maximumOutputBytes: Int, maximumEventDataBytes: Int) {
        self.maximumOutputBytes = max(0, maximumOutputBytes)
        self.maximumEventDataBytes = max(0, maximumEventDataBytes)
        preview = ServerSentEventAccumulatedPreview(
            text: "",
            contributingEventCount: 0,
            terminalEventCount: 0,
            ignoredEventCount: 0,
            skippedOversizedEventCount: 0,
            isTruncated: false
        )
    }

    public mutating func consume(eventType: String, data: Data) {
        guard data.count <= maximumEventDataBytes else {
            skipOversizedEvent()
            return
        }
        guard let source = String(data: data, encoding: .utf8) else {
            ignoreEvent()
            return
        }
        if source.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            update(terminalEventCount: preview.terminalEventCount + 1)
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let delta = Self.textDelta(eventType: eventType, object: object),
            !delta.isEmpty
        else {
            ignoreEvent()
            return
        }

        let currentByteCount = Data(preview.text.utf8).count
        let remainingByteCount = max(0, maximumOutputBytes - currentByteCount)
        let deltaData = Data(delta.utf8)
        let appendedData = Self.validUTF8Prefix(of: deltaData, maximumBytes: remainingByteCount)
        let appendedText = String(decoding: appendedData, as: UTF8.self)
        update(
            text: preview.text + appendedText,
            contributingEventCount: preview.contributingEventCount + 1,
            isTruncated: preview.isTruncated || appendedData.count < deltaData.count
        )
    }

    public mutating func skipOversizedEvent() {
        update(
            skippedOversizedEventCount: preview.skippedOversizedEventCount + 1,
            isTruncated: true
        )
    }

    public mutating func ignoreEvent() {
        update(ignoredEventCount: preview.ignoredEventCount + 1)
    }

    public mutating func markSourceTruncated() {
        update(isTruncated: true)
    }

    private static func textDelta(eventType: String, object: [String: Any]) -> String? {
        let payloadType = object["type"] as? String
        if eventType == "response.output_text.delta"
            || payloadType == "response.output_text.delta"
        {
            return object["delta"] as? String
        }

        guard let choices = object["choices"] as? [[String: Any]] else {
            return nil
        }
        let fragments = choices.flatMap { choice -> [String] in
            guard let delta = choice["delta"] as? [String: Any] else {
                return []
            }
            if let content = delta["content"] as? String {
                return [content]
            }
            guard let content = delta["content"] as? [[String: Any]] else {
                return []
            }
            return content.compactMap { item in
                guard item["type"] as? String == "text" else {
                    return nil
                }
                return item["text"] as? String
            }
        }
        return fragments.isEmpty ? nil : fragments.joined()
    }

    private static func validUTF8Prefix(of data: Data, maximumBytes: Int) -> Data {
        var prefix = Data(data.prefix(max(0, maximumBytes)))
        while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil {
            prefix.removeLast()
        }
        return prefix
    }

    private mutating func update(
        text: String? = nil,
        contributingEventCount: Int? = nil,
        terminalEventCount: Int? = nil,
        ignoredEventCount: Int? = nil,
        skippedOversizedEventCount: Int? = nil,
        isTruncated: Bool? = nil
    ) {
        preview = ServerSentEventAccumulatedPreview(
            text: text ?? preview.text,
            contributingEventCount: contributingEventCount ?? preview.contributingEventCount,
            terminalEventCount: terminalEventCount ?? preview.terminalEventCount,
            ignoredEventCount: ignoredEventCount ?? preview.ignoredEventCount,
            skippedOversizedEventCount: skippedOversizedEventCount
                ?? preview.skippedOversizedEventCount,
            isTruncated: isTruncated ?? preview.isTruncated
        )
    }
}
