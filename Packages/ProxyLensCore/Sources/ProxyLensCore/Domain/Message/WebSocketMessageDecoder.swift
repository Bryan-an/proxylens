import Foundation
import zlib

public struct WebSocketMessageFrameInput: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sequenceNumber: Int64
    public let direction: WebSocketFrameDirection
    public let opcode: WebSocketFrameOpcode
    public let isFinal: Bool
    public let reservedBits: WebSocketReservedBits
    public let payload: Data
    public let isPayloadTruncated: Bool

    public init(
        id: UUID = UUID(),
        sequenceNumber: Int64,
        direction: WebSocketFrameDirection,
        opcode: WebSocketFrameOpcode,
        isFinal: Bool = true,
        reservedBits: WebSocketReservedBits = [],
        payload: Data,
        isPayloadTruncated: Bool = false
    ) {
        self.id = id
        self.sequenceNumber = max(0, sequenceNumber)
        self.direction = direction
        self.opcode = opcode
        self.isFinal = isFinal
        self.reservedBits = reservedBits
        self.payload = payload
        self.isPayloadTruncated = isPayloadTruncated
    }
}

public struct DecodedWebSocketMessage: Equatable, Sendable {
    public let frameIDs: [UUID]
    public let firstSequenceNumber: Int64
    public let lastSequenceNumber: Int64
    public let direction: WebSocketFrameDirection
    public let opcode: WebSocketFrameOpcode
    public let payload: Data
    public let wirePayloadByteCount: Int
    public let isCompressed: Bool

    public var isFragmented: Bool {
        frameIDs.count > 1
    }
}

public enum WebSocketMessageDecodingResult: Equatable, Sendable {
    case decoded(DecodedWebSocketMessage)
    case unavailable(String)
}

public struct WebSocketPerMessageDeflateConfiguration: Equatable, Sendable {
    public enum ParsingError: Error, Equatable, LocalizedError, Sendable {
        case malformedHeader
        case duplicateExtension
        case duplicateParameter(String)
        case unknownParameter(String)
        case invalidParameter(String)

        public var errorDescription: String? {
            switch self {
            case .malformedHeader:
                "Malformed Sec-WebSocket-Extensions response"
            case .duplicateExtension:
                "The server accepted permessage-deflate more than once"
            case .duplicateParameter(let parameter):
                "Duplicate permessage-deflate parameter: \(parameter)"
            case .unknownParameter(let parameter):
                "Unknown permessage-deflate parameter: \(parameter)"
            case .invalidParameter(let parameter):
                "Invalid permessage-deflate parameter: \(parameter)"
            }
        }
    }

    public let clientNoContextTakeover: Bool
    public let serverNoContextTakeover: Bool
    public let clientMaxWindowBits: Int
    public let serverMaxWindowBits: Int

    public static func parse(acceptedExtensions values: [String]) throws -> Self? {
        let extensionValues = try values.flatMap { try split($0, separator: ",") }
        let parsedExtensions = try extensionValues.map { try split($0, separator: ";") }
        let accepted = parsedExtensions.filter { components in
            guard let name = components.first else {
                return false
            }
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("permessage-deflate") == .orderedSame
        }
        guard !accepted.isEmpty else {
            return nil
        }
        guard accepted.count == 1 else {
            throw ParsingError.duplicateExtension
        }

        let components = accepted[0]
        guard let name = components.first,
            name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("permessage-deflate") == .orderedSame
        else {
            throw ParsingError.malformedHeader
        }

        var seen: Set<String> = []
        var clientNoContextTakeover = false
        var serverNoContextTakeover = false
        var clientMaxWindowBits = 15
        var serverMaxWindowBits = 15

        for rawParameter in components.dropFirst() {
            let assignment = try splitParameter(rawParameter)
            let parameter = assignment.name.lowercased()
            guard seen.insert(parameter).inserted else {
                throw ParsingError.duplicateParameter(parameter)
            }
            switch parameter {
            case "client_no_context_takeover":
                guard assignment.value == nil else {
                    throw ParsingError.invalidParameter(parameter)
                }
                clientNoContextTakeover = true
            case "server_no_context_takeover":
                guard assignment.value == nil else {
                    throw ParsingError.invalidParameter(parameter)
                }
                serverNoContextTakeover = true
            case "client_max_window_bits":
                clientMaxWindowBits = try windowBits(
                    assignment.value,
                    parameter: parameter
                )
            case "server_max_window_bits":
                serverMaxWindowBits = try windowBits(
                    assignment.value,
                    parameter: parameter
                )
            default:
                throw ParsingError.unknownParameter(parameter)
            }
        }

        return Self(
            clientNoContextTakeover: clientNoContextTakeover,
            serverNoContextTakeover: serverNoContextTakeover,
            clientMaxWindowBits: clientMaxWindowBits,
            serverMaxWindowBits: serverMaxWindowBits
        )
    }

    func noContextTakeover(for direction: WebSocketFrameDirection) -> Bool {
        switch direction {
        case .clientToServer: clientNoContextTakeover
        case .serverToClient: serverNoContextTakeover
        }
    }

    func windowBits(for direction: WebSocketFrameDirection) -> Int {
        switch direction {
        case .clientToServer: clientMaxWindowBits
        case .serverToClient: serverMaxWindowBits
        }
    }

    private init(
        clientNoContextTakeover: Bool,
        serverNoContextTakeover: Bool,
        clientMaxWindowBits: Int,
        serverMaxWindowBits: Int
    ) {
        self.clientNoContextTakeover = clientNoContextTakeover
        self.serverNoContextTakeover = serverNoContextTakeover
        self.clientMaxWindowBits = clientMaxWindowBits
        self.serverMaxWindowBits = serverMaxWindowBits
    }

    private static func split(_ value: String, separator: Character) throws -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if quoted, character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                quoted.toggle()
                current.append(character)
                continue
            }
            if character == separator, !quoted {
                guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ParsingError.malformedHeader
                }
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !quoted, !escaped,
            !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ParsingError.malformedHeader
        }
        result.append(current)
        return result
    }

    private static func splitParameter(_ raw: String) throws -> (name: String, value: String?) {
        let pieces = try split(raw, separator: "=")
        guard pieces.count <= 2 else {
            throw ParsingError.malformedHeader
        }
        let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw ParsingError.malformedHeader
        }
        guard pieces.count == 2 else {
            return (name, nil)
        }
        let rawValue = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else {
            throw ParsingError.invalidParameter(name)
        }
        if rawValue.first == "\"" || rawValue.last == "\"" {
            guard rawValue.count >= 2, rawValue.first == "\"", rawValue.last == "\"" else {
                throw ParsingError.malformedHeader
            }
            return (name, try unquote(rawValue))
        }
        return (name, rawValue)
    }

    private static func unquote(_ rawValue: String) throws -> String {
        var value = ""
        var escaped = false
        for character in rawValue.dropFirst().dropLast() {
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                throw ParsingError.malformedHeader
            } else {
                value.append(character)
            }
        }
        guard !escaped else {
            throw ParsingError.malformedHeader
        }
        return value
    }

    private static func windowBits(_ value: String?, parameter: String) throws -> Int {
        guard let value, !value.isEmpty,
            value.utf8.allSatisfy({ (48...57).contains($0) }),
            value.count == 1 || value.first != "0",
            let bits = Int(value),
            (8...15).contains(bits)
        else {
            throw ParsingError.invalidParameter(parameter)
        }
        return bits
    }
}

public enum WebSocketMessageDecoder {
    public struct Limits: Equatable, Sendable {
        public let maximumFrameCount: Int
        public let maximumInputByteCount: Int
        public let maximumMessageOutputByteCount: Int
        public let maximumHistoryOutputByteCount: Int

        public init(
            maximumFrameCount: Int = 10_000,
            maximumInputByteCount: Int = 8 * 1_024 * 1_024,
            maximumMessageOutputByteCount: Int = 1 * 1_024 * 1_024,
            maximumHistoryOutputByteCount: Int = 16 * 1_024 * 1_024
        ) {
            self.maximumFrameCount = max(1, maximumFrameCount)
            self.maximumInputByteCount = max(0, maximumInputByteCount)
            self.maximumMessageOutputByteCount = max(0, maximumMessageOutputByteCount)
            self.maximumHistoryOutputByteCount = max(0, maximumHistoryOutputByteCount)
        }
    }

    private struct Accumulator {
        let direction: WebSocketFrameDirection
        let opcode: WebSocketFrameOpcode
        let isCompressed: Bool
        var frames: [WebSocketMessageFrameInput]

        var containsTruncatedPayload: Bool {
            frames.contains(where: \.isPayloadTruncated)
        }

        var containsSelectedFrame: Bool = false
    }

    public static func decode(
        selectedFrameID: UUID,
        frames: [WebSocketMessageFrameInput],
        acceptedExtensions: [String],
        limits: Limits = Limits()
    ) -> WebSocketMessageDecodingResult {
        guard let selected = frames.first(where: { $0.id == selectedFrameID }) else {
            return .unavailable("The selected WebSocket frame is unavailable.")
        }
        guard isDataFrame(selected.opcode) else {
            return .unavailable("Control and unknown WebSocket frames are inspected individually.")
        }

        let configuration: WebSocketPerMessageDeflateConfiguration?
        do {
            configuration = try WebSocketPerMessageDeflateConfiguration.parse(
                acceptedExtensions: acceptedExtensions
            )
        } catch {
            return .unavailable(
                "The permessage-deflate negotiation is invalid: \(error.localizedDescription)"
            )
        }

        var seen: Set<UUID> = []
        let orderedFrames =
            frames
            .filter { $0.direction == selected.direction && seen.insert($0.id).inserted }
            .sorted {
                if $0.sequenceNumber == $1.sequenceNumber {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.sequenceNumber < $1.sequenceNumber
            }
        guard orderedFrames.count <= limits.maximumFrameCount else {
            return .unavailable("WebSocket reconstruction exceeds the frame limit.")
        }

        let noContextTakeover = configuration?.noContextTakeover(for: selected.direction) ?? true
        var inflater: RawDeflateMessageInflater?
        if let configuration {
            do {
                inflater = try RawDeflateMessageInflater(
                    windowBits: configuration.windowBits(for: selected.direction)
                )
            } catch {
                return .unavailable("Could not initialize permessage-deflate decompression.")
            }
        }

        var current: Accumulator?
        var consumedInputByteCount = 0
        var historyOutputByteCount = 0

        for frame in orderedFrames {
            switch frame.opcode {
            case .close, .ping, .pong:
                guard frame.isFinal, frame.reservedBits.isEmpty, frame.payload.count <= 125 else {
                    return .unavailable("The WebSocket control-frame sequence is invalid.")
                }
                continue
            case .unknown(let value) where value >= 0x8:
                guard frame.isFinal, frame.reservedBits.isEmpty, frame.payload.count <= 125 else {
                    return .unavailable("The WebSocket control-frame sequence is invalid.")
                }
                continue
            case .unknown:
                return .unavailable("The WebSocket data opcode is unsupported.")
            case .text, .binary:
                guard current == nil else {
                    return .unavailable(
                        "A new WebSocket data frame arrived before the fragmented message ended."
                    )
                }
                guard frame.reservedBits.intersection([.rsv2, .rsv3]).isEmpty else {
                    return .unavailable("RSV2 and RSV3 WebSocket extensions are unsupported.")
                }
                if frame.reservedBits.contains(.rsv1), configuration == nil {
                    return .unavailable(
                        "RSV1 marks a compressed message, but permessage-deflate was not negotiated."
                    )
                }
                current = Accumulator(
                    direction: frame.direction,
                    opcode: frame.opcode,
                    isCompressed: frame.reservedBits.contains(.rsv1),
                    frames: [frame],
                    containsSelectedFrame: frame.id == selectedFrameID
                )
            case .continuation:
                guard frame.reservedBits.isEmpty else {
                    return .unavailable("A WebSocket continuation frame has reserved bits set.")
                }
                guard current != nil else {
                    return .unavailable("A WebSocket continuation frame has no opening data frame.")
                }
                current?.frames.append(frame)
                if frame.id == selectedFrameID {
                    current?.containsSelectedFrame = true
                }
            }

            guard frame.isFinal, let message = current else {
                continue
            }
            current = nil
            let isSelectedMessage = message.containsSelectedFrame
            let mustDecodeForHistory = message.isCompressed && !noContextTakeover
            guard isSelectedMessage || mustDecodeForHistory else {
                continue
            }
            guard !message.containsTruncatedPayload else {
                return .unavailable("The WebSocket message contains a truncated frame payload.")
            }

            var wirePayload = Data()
            for messageFrame in message.frames {
                let (nextCount, overflow) = consumedInputByteCount.addingReportingOverflow(
                    messageFrame.payload.count
                )
                guard !overflow, nextCount <= limits.maximumInputByteCount else {
                    return .unavailable("WebSocket reconstruction exceeds the input limit.")
                }
                consumedInputByteCount = nextCount
                wirePayload.append(messageFrame.payload)
            }

            let applicationPayload: Data
            if message.isCompressed {
                guard let inflater else {
                    return .unavailable("permessage-deflate decompression is unavailable.")
                }
                let outputLimit =
                    isSelectedMessage
                    ? limits.maximumMessageOutputByteCount
                    : max(0, limits.maximumHistoryOutputByteCount - historyOutputByteCount)
                do {
                    applicationPayload = try inflater.decompress(
                        wirePayload,
                        resetContext: noContextTakeover,
                        maximumOutputByteCount: outputLimit
                    )
                } catch RawDeflateMessageInflater.Error.exceedsLimit {
                    return .unavailable("WebSocket decompression exceeds the output limit.")
                } catch {
                    return .unavailable("Could not decompress the WebSocket message.")
                }
            } else {
                guard
                    wirePayload.count <= limits.maximumMessageOutputByteCount || !isSelectedMessage
                else {
                    return .unavailable("WebSocket reconstruction exceeds the output limit.")
                }
                applicationPayload = wirePayload
            }

            if !isSelectedMessage {
                let (nextHistoryCount, overflow) = historyOutputByteCount.addingReportingOverflow(
                    applicationPayload.count
                )
                guard !overflow, nextHistoryCount <= limits.maximumHistoryOutputByteCount else {
                    return .unavailable("WebSocket reconstruction exceeds the history limit.")
                }
                historyOutputByteCount = nextHistoryCount
                continue
            }

            return .decoded(
                DecodedWebSocketMessage(
                    frameIDs: message.frames.map(\.id),
                    firstSequenceNumber: message.frames[0].sequenceNumber,
                    lastSequenceNumber: message.frames[message.frames.count - 1].sequenceNumber,
                    direction: message.direction,
                    opcode: message.opcode,
                    payload: applicationPayload,
                    wirePayloadByteCount: wirePayload.count,
                    isCompressed: message.isCompressed
                )
            )
        }

        if current?.containsSelectedFrame == true {
            return .unavailable("The selected WebSocket message is incomplete.")
        }
        return .unavailable("The selected WebSocket message could not be reconstructed.")
    }

    private static func isDataFrame(_ opcode: WebSocketFrameOpcode) -> Bool {
        switch opcode {
        case .text, .binary, .continuation:
            true
        case .close, .ping, .pong, .unknown:
            false
        }
    }
}

private final class RawDeflateMessageInflater {
    enum Error: Swift.Error {
        case initializeFailed(Int32)
        case resetFailed(Int32)
        case inflateFailed(Int32)
        case noProgress
        case exceedsLimit
    }

    private var stream = z_stream()
    private var hasDecodedMessage = false
    private var reachedStreamEnd = false

    init(windowBits: Int) throws {
        let status = inflateInit2_(
            &stream,
            -Int32(windowBits),
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw Error.initializeFailed(status)
        }
    }

    deinit {
        inflateEnd(&stream)
    }

    func decompress(
        _ compressed: Data,
        resetContext: Bool,
        maximumOutputByteCount: Int
    ) throws -> Data {
        guard maximumOutputByteCount >= 0 else {
            throw Error.exceedsLimit
        }
        if (resetContext && hasDecodedMessage) || reachedStreamEnd {
            let status = inflateReset(&stream)
            guard status == Z_OK else {
                throw Error.resetFailed(status)
            }
            reachedStreamEnd = false
        }

        var input = compressed
        input.append(contentsOf: [0x00, 0x00, 0xFF, 0xFF])
        var output = Data()
        output.reserveCapacity(min(maximumOutputByteCount, max(64, compressed.count * 2)))

        try input.withUnsafeBytes { rawInput in
            guard let inputBase = rawInput.bindMemory(to: Bytef.self).baseAddress else {
                if input.isEmpty {
                    return
                }
                throw Error.inflateFailed(Z_DATA_ERROR)
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(rawInput.count)

            let chunkSize = 16 * 1_024
            while true {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                let inputBefore = stream.avail_in
                let status = chunk.withUnsafeMutableBytes { rawOutput -> Int32 in
                    stream.next_out = rawOutput.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(rawOutput.count)
                    return inflate(&stream, Z_SYNC_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                let (nextOutputCount, overflow) = output.count.addingReportingOverflow(produced)
                guard !overflow, nextOutputCount <= maximumOutputByteCount else {
                    throw Error.exceedsLimit
                }
                if produced > 0 {
                    output.append(contentsOf: chunk.prefix(produced))
                }

                if status == Z_STREAM_END {
                    reachedStreamEnd = true
                    break
                }
                guard status == Z_OK || status == Z_BUF_ERROR else {
                    throw Error.inflateFailed(status)
                }
                if stream.avail_in == 0, stream.avail_out > 0 {
                    break
                }
                guard stream.avail_in < inputBefore || produced > 0 else {
                    throw Error.noProgress
                }
            }
        }
        hasDecodedMessage = true
        return output
    }
}
