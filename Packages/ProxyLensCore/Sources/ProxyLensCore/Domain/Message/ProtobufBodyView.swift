import Foundation

/// Produces a bounded, schema-less view of declared Protobuf wire-format bodies.
public enum ProtobufBodyView: Sendable {
    public static let maximumDecodedByteCount = 1_048_576
    public static let maximumFieldCount = 10_000
    public static let maximumGRPCMessageCount = 1_000
    public static let maximumNestingDepth = 16
    public static let maximumRenderedUTF8ByteCount = 1_048_576
    public static let notProtobufReason = "This body is not declared as Protobuf."
    public static let truncatedReason = "Capture truncated"
    public static let exceedsDisplayLimitReason =
        "Protobuf exceeds the 1 MB display limit."
    public static let fieldLimitReason =
        "Protobuf exceeds the 10,000-field display limit."
    public static let renderedOutputLimitReason =
        "Protobuf decoded output exceeds the 1 MB display limit."
    public static let grpcMessageLimitReason =
        "gRPC body exceeds the 1,000-message display limit."
    public static let delimitedMessageLimitReason =
        "Delimited Protobuf body exceeds the 1,000-message display limit."

    public enum Result: Equatable, Sendable {
        case decoded(String)
        case unavailable(reason: String)
    }

    public static func invalidProtobufReason(_ message: String) -> String {
        "Invalid Protobuf: \(message)"
    }

    /// Renders bytes that the user explicitly chose to interpret as one Protobuf message.
    /// This path is intended for transports such as WebSocket that do not carry an HTTP
    /// media type for each message. The authoritative input bytes are never changed.
    public static func renderMessage(
        data: Data,
        contentEncoding: String? = nil,
        isTruncated: Bool = false,
        schema: ProtobufMessageSchema? = nil,
        catalog: ProtobufSchemaCatalog? = nil
    ) -> Result {
        render(
            data: data,
            contentType: "application/protobuf",
            contentEncoding: contentEncoding,
            isTruncated: isTruncated,
            schema: schema,
            catalog: catalog
        )
    }

    public static func render(
        data: Data,
        contentType: String?,
        contentEncoding: String?,
        grpcEncoding: String? = nil,
        isTruncated: Bool = false,
        schema: ProtobufMessageSchema? = nil,
        catalog: ProtobufSchemaCatalog? = nil
    ) -> Result {
        let isGRPC = isGRPCProtobufMediaType(contentType)
        let isGRPCWebBinary = isGRPCWebBinaryProtobufMediaType(contentType)
        let isGRPCWebText = isGRPCWebTextProtobufMediaType(contentType)
        let isDelimited = isDelimitedProtobufMediaType(contentType)
        guard isGRPC || isGRPCWebBinary || isGRPCWebText || isProtobufMediaType(contentType)
        else {
            return .unavailable(reason: notProtobufReason)
        }

        let decoded: Data
        switch DerivedBodyData.unwrap(
            data,
            contentEncoding: contentEncoding,
            maximumOutputByteCount: maximumDecodedByteCount,
            exceedsLimitReason: exceedsDisplayLimitReason,
            isTruncated: isTruncated,
            truncatedReason: truncatedReason
        ) {
        case .decoded(let value):
            decoded = value
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }

        guard !decoded.isEmpty else {
            return unavailableAfterParseFailure(
                isTruncated: isTruncated,
                message: "The body is empty."
            )
        }

        do {
            let bytes: [UInt8]
            if isGRPCWebText {
                bytes = try decodeGRPCWebText(decoded)
            } else {
                bytes = Array(decoded)
            }
            var fieldCount = 0
            var renderedUTF8ByteCount = 0
            let lines: [String]
            if isGRPC {
                lines = try decodeGRPCMessages(
                    bytes,
                    grpcEncoding: grpcEncoding,
                    schema: schema,
                    catalog: catalog,
                    fieldCount: &fieldCount,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            } else if isGRPCWebBinary || isGRPCWebText {
                lines = try decodeGRPCWebMessages(
                    bytes,
                    schema: schema,
                    catalog: catalog,
                    fieldCount: &fieldCount,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            } else if isDelimited {
                lines = try decodeDelimitedMessages(
                    bytes,
                    schema: schema,
                    catalog: catalog,
                    fieldCount: &fieldCount,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            } else {
                lines = try decodeMessage(
                    bytes,
                    range: 0..<bytes.count,
                    depth: 0,
                    schema: schema,
                    catalog: catalog,
                    fieldCount: &fieldCount,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            }
            return .decoded(lines.joined(separator: "\n"))
        } catch DecodeError.decodedByteLimit {
            return .unavailable(reason: exceedsDisplayLimitReason)
        } catch DecodeError.fieldLimit {
            return .unavailable(reason: fieldLimitReason)
        } catch DecodeError.grpcMessageLimit {
            return .unavailable(reason: grpcMessageLimitReason)
        } catch DecodeError.delimitedMessageLimit {
            return .unavailable(reason: delimitedMessageLimitReason)
        } catch DecodeError.outputLimit {
            return .unavailable(reason: renderedOutputLimitReason)
        } catch let error as DecodeError {
            return unavailableAfterParseFailure(
                isTruncated: isTruncated,
                message: error.description
            )
        } catch {
            return unavailableAfterParseFailure(
                isTruncated: isTruncated,
                message: "The wire data could not be decoded."
            )
        }
    }

    private static func decodeGRPCWebText(_ data: Data) throws -> [UInt8] {
        var quantum: [UInt8] = []
        var decoded: [UInt8] = []
        quantum.reserveCapacity(4)
        decoded.reserveCapacity(min(data.count, maximumDecodedByteCount))

        for byte in data {
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                continue
            }
            guard isBase64Byte(byte) else {
                throw DecodeError.malformed("gRPC-Web text body is not valid base64.")
            }
            quantum.append(byte)
            guard quantum.count == 4 else {
                continue
            }
            guard isValidBase64Quantum(quantum),
                let chunk = Data(base64Encoded: Data(quantum))
            else {
                throw DecodeError.malformed("gRPC-Web text body is not valid base64.")
            }
            guard decoded.count <= maximumDecodedByteCount - chunk.count else {
                throw DecodeError.decodedByteLimit
            }
            decoded.append(contentsOf: chunk)
            quantum.removeAll(keepingCapacity: true)
        }

        guard quantum.isEmpty else {
            throw DecodeError.malformed("gRPC-Web text body has an incomplete base64 quantum.")
        }
        guard !decoded.isEmpty else {
            throw DecodeError.malformed("gRPC-Web text body decodes to an empty body.")
        }
        return decoded
    }

    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2B
            || byte == 0x2F
            || byte == 0x3D
    }

    private static func isValidBase64Quantum(_ quantum: [UInt8]) -> Bool {
        guard quantum.count == 4, quantum[0] != 0x3D, quantum[1] != 0x3D else {
            return false
        }
        if quantum[2] == 0x3D {
            return quantum[3] == 0x3D
        }
        return true
    }

    private static func decodeGRPCWebMessages(
        _ bytes: [UInt8],
        schema: ProtobufMessageSchema?,
        catalog: ProtobufSchemaCatalog?,
        fieldCount: inout Int,
        renderedUTF8ByteCount: inout Int
    ) throws -> [String] {
        guard !bytes.isEmpty else {
            throw DecodeError.malformed("gRPC-Web body is empty.")
        }

        var index = 0
        var messageCount = 0
        var payloadByteCount = 0
        var sawTrailers = false
        var lines: [String] = []

        while index < bytes.count {
            if sawTrailers {
                throw DecodeError.malformed("gRPC-Web trailer frame must be final.")
            }
            guard bytes.count - index >= 5 else {
                throw DecodeError.malformed("gRPC-Web frame header is incomplete.")
            }
            let flag = bytes[index]
            index += 1
            guard flag == 0x00 || flag == 0x01 || flag == 0x80 || flag == 0x81 else {
                throw DecodeError.malformed(
                    "gRPC-Web frame flag 0x\(hex(UInt64(flag), width: 2)) is unsupported."
                )
            }

            let payloadLength =
                UInt32(bytes[index]) << 24
                | UInt32(bytes[index + 1]) << 16
                | UInt32(bytes[index + 2]) << 8
                | UInt32(bytes[index + 3])
            index += 4
            guard payloadLength <= UInt32(bytes.count - index) else {
                throw DecodeError.malformed("gRPC-Web frame extends past the body.")
            }

            let payloadRange = index..<(index + Int(payloadLength))
            index = payloadRange.upperBound
            payloadByteCount += payloadRange.count
            guard payloadByteCount <= maximumDecodedByteCount else {
                throw DecodeError.decodedByteLimit
            }
            if !lines.isEmpty {
                try appendRenderedLine(
                    "",
                    to: &lines,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            }

            if flag & 0x80 != 0 {
                sawTrailers = true
                if flag == 0x81 {
                    try appendRenderedLine(
                        "Trailers · \(byteCountText(payloadRange.count)) · compressed",
                        to: &lines,
                        renderedUTF8ByteCount: &renderedUTF8ByteCount
                    )
                    try appendRenderedLine(
                        "[Compressed gRPC-Web trailers omitted.]",
                        to: &lines,
                        renderedUTF8ByteCount: &renderedUTF8ByteCount
                    )
                } else {
                    try appendRenderedLine(
                        "Trailers · \(byteCountText(payloadRange.count))",
                        to: &lines,
                        renderedUTF8ByteCount: &renderedUTF8ByteCount
                    )
                    for trailerLine in try decodeGRPCWebTrailers(bytes[payloadRange]) {
                        try appendRenderedLine(
                            trailerLine,
                            to: &lines,
                            renderedUTF8ByteCount: &renderedUTF8ByteCount
                        )
                    }
                }
                continue
            }

            messageCount += 1
            guard messageCount <= maximumGRPCMessageCount else {
                throw DecodeError.grpcMessageLimit
            }
            if flag == 0x01 {
                try appendRenderedLine(
                    "Message \(messageCount) · \(byteCountText(payloadRange.count)) · compressed",
                    to: &lines,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
                try appendRenderedLine(
                    "[Compressed gRPC-Web payload omitted.]",
                    to: &lines,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            } else {
                try appendFramedMessage(
                    Array(bytes[payloadRange]),
                    number: messageCount,
                    framingLabel: "uncompressed",
                    schema: schema,
                    catalog: catalog,
                    fieldCount: &fieldCount,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount,
                    lines: &lines
                )
            }
        }

        return lines
    }

    private static func decodeGRPCWebTrailers(
        _ bytes: ArraySlice<UInt8>
    ) throws -> [String] {
        guard !bytes.isEmpty else {
            return ["[Empty trailers]"]
        }
        guard
            bytes.allSatisfy({ byte in
                byte == 0x09 || byte == 0x0A || byte == 0x0D || (byte >= 0x20 && byte <= 0x7E)
            }),
            let text = String(bytes: bytes, encoding: .utf8)
        else {
            throw DecodeError.malformed("gRPC-Web trailers contain invalid text bytes.")
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\r"), !normalized.hasSuffix("\n") else {
            throw DecodeError.malformed("gRPC-Web trailers use invalid line endings.")
        }
        let trailerLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard trailerLines.allSatisfy(isValidGRPCWebTrailerLine) else {
            throw DecodeError.malformed("gRPC-Web trailers contain an invalid header line.")
        }
        return trailerLines.map(String.init)
    }

    private static func isValidGRPCWebTrailerLine(_ line: Substring) -> Bool {
        guard !line.isEmpty, let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
            return false
        }
        return line[..<colon].utf8.allSatisfy(isHTTPTokenByte)
    }

    private static func isHTTPTokenByte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || (byte >= 0x30 && byte <= 0x39)
            || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }

    private static func decodeDelimitedMessages(
        _ bytes: [UInt8],
        schema: ProtobufMessageSchema?,
        catalog: ProtobufSchemaCatalog?,
        fieldCount: inout Int,
        renderedUTF8ByteCount: inout Int
    ) throws -> [String] {
        var index = 0
        var messageCount = 0
        var decodedPayloadByteCount = 0
        var lines: [String] = []

        while index < bytes.count {
            let messageLength = try readDelimitedMessageLength(
                bytes,
                index: &index,
                end: bytes.count
            )
            guard messageLength <= bytes.count - index else {
                throw DecodeError.malformed("Delimited message extends past the body.")
            }

            messageCount += 1
            guard messageCount <= maximumGRPCMessageCount else {
                throw DecodeError.delimitedMessageLimit
            }
            decodedPayloadByteCount += messageLength
            guard decodedPayloadByteCount <= maximumDecodedByteCount else {
                throw DecodeError.decodedByteLimit
            }

            let messageRange = index..<(index + messageLength)
            index = messageRange.upperBound
            if messageCount > 1 {
                try appendRenderedLine(
                    "",
                    to: &lines,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            }
            try appendFramedMessage(
                Array(bytes[messageRange]),
                number: messageCount,
                framingLabel: "delimited",
                schema: schema,
                catalog: catalog,
                fieldCount: &fieldCount,
                renderedUTF8ByteCount: &renderedUTF8ByteCount,
                lines: &lines
            )
        }

        return lines
    }

    private static func decodeGRPCMessages(
        _ bytes: [UInt8],
        grpcEncoding: String?,
        schema: ProtobufMessageSchema?,
        catalog: ProtobufSchemaCatalog?,
        fieldCount: inout Int,
        renderedUTF8ByteCount: inout Int
    ) throws -> [String] {
        var index = 0
        var messageCount = 0
        var decodedPayloadByteCount = 0
        var lines: [String] = []

        while index < bytes.count {
            guard bytes.count - index >= 5 else {
                throw DecodeError.malformed("gRPC frame header is incomplete.")
            }
            let compressedFlag = bytes[index]
            index += 1
            guard compressedFlag == 0 || compressedFlag == 1 else {
                throw DecodeError.malformed(
                    "gRPC compressed flag must be 0 or 1, not \(compressedFlag)."
                )
            }

            let messageLength =
                UInt32(bytes[index]) << 24
                | UInt32(bytes[index + 1]) << 16
                | UInt32(bytes[index + 2]) << 8
                | UInt32(bytes[index + 3])
            index += 4
            guard messageLength <= UInt32(bytes.count - index) else {
                throw DecodeError.malformed("gRPC message extends past the body.")
            }

            messageCount += 1
            guard messageCount <= maximumGRPCMessageCount else {
                throw DecodeError.grpcMessageLimit
            }

            let frameRange = index..<(index + Int(messageLength))
            index = frameRange.upperBound
            let frameData = Data(bytes[frameRange])

            if messageCount > 1 {
                try appendRenderedLine(
                    "",
                    to: &lines,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            }

            if compressedFlag == 1 {
                guard let encoding = normalizedGRPCEncoding(grpcEncoding) else {
                    throw DecodeError.malformed(
                        "Compressed gRPC message has no grpc-encoding header."
                    )
                }
                guard isSupportedGRPCEncoding(encoding) else {
                    try appendRenderedLine(
                        "Message \(messageCount) · \(byteCountText(frameData.count)) · \(encoding) (compressed)",
                        to: &lines,
                        renderedUTF8ByteCount: &renderedUTF8ByteCount
                    )
                    try appendRenderedLine(
                        "[Compressed payload omitted: unsupported grpc-encoding \"\(encoding)\".]",
                        to: &lines,
                        renderedUTF8ByteCount: &renderedUTF8ByteCount
                    )
                    continue
                }

                let remainingByteCount = maximumDecodedByteCount - decodedPayloadByteCount
                guard remainingByteCount >= 0 else {
                    throw DecodeError.decodedByteLimit
                }
                let message: Data
                do {
                    message = try HTTPContentCoding.decode(
                        frameData,
                        contentEncoding: encoding,
                        maximumOutputByteCount: remainingByteCount
                    )
                } catch HTTPContentCoding.CodingError.exceedsLimit {
                    throw DecodeError.decodedByteLimit
                } catch {
                    throw DecodeError.malformed(
                        "Compressed gRPC message could not be decoded as \(encoding)."
                    )
                }
                decodedPayloadByteCount += message.count
                try appendFramedMessage(
                    Array(message),
                    number: messageCount,
                    framingLabel: encoding,
                    schema: schema,
                    catalog: catalog,
                    fieldCount: &fieldCount,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount,
                    lines: &lines
                )
            } else {
                decodedPayloadByteCount += frameData.count
                guard decodedPayloadByteCount <= maximumDecodedByteCount else {
                    throw DecodeError.decodedByteLimit
                }
                try appendFramedMessage(
                    Array(frameData),
                    number: messageCount,
                    framingLabel: "uncompressed",
                    schema: schema,
                    catalog: catalog,
                    fieldCount: &fieldCount,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount,
                    lines: &lines
                )
            }
        }

        return lines
    }

    private static func appendFramedMessage(
        _ message: [UInt8],
        number: Int,
        framingLabel: String,
        schema: ProtobufMessageSchema?,
        catalog: ProtobufSchemaCatalog?,
        fieldCount: inout Int,
        renderedUTF8ByteCount: inout Int,
        lines: inout [String]
    ) throws {
        try appendRenderedLine(
            "Message \(number) · \(byteCountText(message.count)) · \(framingLabel)",
            to: &lines,
            renderedUTF8ByteCount: &renderedUTF8ByteCount
        )
        guard !message.isEmpty else {
            try appendRenderedLine(
                "[Empty message]",
                to: &lines,
                renderedUTF8ByteCount: &renderedUTF8ByteCount
            )
            return
        }

        renderedUTF8ByteCount += 1
        guard renderedUTF8ByteCount <= maximumRenderedUTF8ByteCount else {
            throw DecodeError.outputLimit
        }
        let messageLines = try decodeMessage(
            message,
            range: 0..<message.count,
            depth: 0,
            schema: schema,
            catalog: catalog,
            fieldCount: &fieldCount,
            renderedUTF8ByteCount: &renderedUTF8ByteCount
        )
        lines.append(contentsOf: messageLines)
    }

    private static func appendRenderedLine(
        _ line: String,
        to lines: inout [String],
        renderedUTF8ByteCount: inout Int
    ) throws {
        renderedUTF8ByteCount += line.utf8.count + (lines.isEmpty ? 0 : 1)
        guard renderedUTF8ByteCount <= maximumRenderedUTF8ByteCount else {
            throw DecodeError.outputLimit
        }
        lines.append(line)
    }

    private static func unavailableAfterParseFailure(
        isTruncated: Bool,
        message: String
    ) -> Result {
        if isTruncated {
            return .unavailable(reason: truncatedReason)
        }
        return .unavailable(reason: invalidProtobufReason(message))
    }

    private static func decodeMessage(
        _ bytes: [UInt8],
        range: Range<Int>,
        depth: Int,
        schema: ProtobufMessageSchema?,
        catalog: ProtobufSchemaCatalog?,
        fieldCount: inout Int,
        renderedUTF8ByteCount: inout Int
    ) throws -> [String] {
        var index = range.lowerBound
        var lines: [String] = []

        while index < range.upperBound {
            let key = try readVarint(bytes, index: &index, end: range.upperBound)
            let fieldNumber = key >> 3
            let wireType = UInt8(key & 0x07)
            guard fieldNumber > 0, fieldNumber <= 0x1FFF_FFFF else {
                throw DecodeError.malformed("Field number is outside the valid range.")
            }
            fieldCount += 1
            guard fieldCount <= maximumFieldCount else {
                throw DecodeError.fieldLimit
            }

            if let fieldSchema = schema?.field(number: Int(fieldNumber)),
                isCompatible(fieldSchema, wireType: wireType)
            {
                try appendSchemaField(
                    bytes,
                    index: &index,
                    end: range.upperBound,
                    wireType: wireType,
                    field: fieldSchema,
                    depth: depth,
                    catalog: catalog,
                    fieldCount: &fieldCount,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount,
                    lines: &lines
                )
                continue
            }

            switch wireType {
            case 0:
                let value = try readVarint(bytes, index: &index, end: range.upperBound)
                try appendLine(
                    fieldNumber: fieldNumber,
                    kind: "varint",
                    value: String(value),
                    depth: depth,
                    to: &lines,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            case 1:
                let value = try readFixed64(bytes, index: &index, end: range.upperBound)
                let double = Double(bitPattern: value)
                try appendLine(
                    fieldNumber: fieldNumber,
                    kind: "fixed64",
                    value:
                        "0x\(hex(value, width: 16))  uint64 \(value)  double \(double)",
                    depth: depth,
                    to: &lines,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            case 2:
                let length = try readVarint(bytes, index: &index, end: range.upperBound)
                guard length <= UInt64(range.upperBound - index) else {
                    throw DecodeError.malformed("Length-delimited field extends past the body.")
                }
                let valueRange = index..<(index + Int(length))
                index = valueRange.upperBound
                try appendLengthDelimitedField(
                    bytes,
                    range: valueRange,
                    fieldNumber: fieldNumber,
                    depth: depth,
                    schema: nil,
                    catalog: catalog,
                    fieldCount: &fieldCount,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount,
                    lines: &lines
                )
            case 5:
                let value = try readFixed32(bytes, index: &index, end: range.upperBound)
                let float = Float(bitPattern: value)
                try appendLine(
                    fieldNumber: fieldNumber,
                    kind: "fixed32",
                    value: "0x\(hex(UInt64(value), width: 8))  uint32 \(value)  float \(float)",
                    depth: depth,
                    to: &lines,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            case 3, 4:
                throw DecodeError.malformed("Deprecated group wire types are not supported.")
            default:
                throw DecodeError.malformed("Unsupported wire type \(wireType).")
            }
        }
        return lines
    }

    private static func isCompatible(
        _ field: ProtobufFieldSchema,
        wireType: UInt8
    ) -> Bool {
        if field.label == .repeated, wireType == 2, isPackable(field.type) {
            return true
        }
        return expectedWireType(field.type) == wireType
    }

    private static func expectedWireType(_ type: ProtobufFieldType) -> UInt8 {
        switch type {
        case .int64, .uint64, .int32, .bool, .uint32, .enumeration, .sint32, .sint64:
            0
        case .double, .fixed64, .sfixed64:
            1
        case .string, .message, .bytes:
            2
        case .float, .fixed32, .sfixed32:
            5
        }
    }

    private static func isPackable(_ type: ProtobufFieldType) -> Bool {
        switch type {
        case .string, .message, .bytes:
            false
        default:
            true
        }
    }

    private static func appendSchemaField(
        _ bytes: [UInt8],
        index: inout Int,
        end: Int,
        wireType: UInt8,
        field: ProtobufFieldSchema,
        depth: Int,
        catalog: ProtobufSchemaCatalog?,
        fieldCount: inout Int,
        renderedUTF8ByteCount: inout Int,
        lines: inout [String]
    ) throws {
        if field.label == .repeated, wireType == 2, isPackable(field.type) {
            let range = try readLengthDelimitedRange(bytes, index: &index, end: end)
            let values = try decodePackedValues(
                bytes,
                range: range,
                type: field.type,
                catalog: catalog,
                fieldCount: &fieldCount
            )
            try appendSchemaLine(
                field: field,
                kind: "\(fieldTypeLabel(field.type))[]",
                value: "[\(values.joined(separator: ", "))]",
                depth: depth,
                to: &lines,
                renderedUTF8ByteCount: &renderedUTF8ByteCount
            )
            return
        }

        switch wireType {
        case 0:
            let rawValue = try readVarint(bytes, index: &index, end: end)
            try appendSchemaLine(
                field: field,
                kind: fieldTypeLabel(field.type),
                value: scalarVarintValue(rawValue, type: field.type, catalog: catalog),
                depth: depth,
                to: &lines,
                renderedUTF8ByteCount: &renderedUTF8ByteCount
            )
        case 1:
            let rawValue = try readFixed64(bytes, index: &index, end: end)
            try appendSchemaLine(
                field: field,
                kind: fieldTypeLabel(field.type),
                value: scalarFixed64Value(rawValue, type: field.type),
                depth: depth,
                to: &lines,
                renderedUTF8ByteCount: &renderedUTF8ByteCount
            )
        case 2:
            let range = try readLengthDelimitedRange(bytes, index: &index, end: end)
            switch field.type {
            case .string:
                guard let value = String(bytes: bytes[range], encoding: .utf8) else {
                    throw DecodeError.malformed("String field \(field.number) is not valid UTF-8.")
                }
                try appendSchemaLine(
                    field: field,
                    kind: "string",
                    value: "\"\(escapedAndBounded(value))\"",
                    depth: depth,
                    to: &lines,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            case .bytes:
                try appendSchemaLine(
                    field: field,
                    kind: "bytes",
                    value: bytesPreview(bytes[range]),
                    depth: depth,
                    to: &lines,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
            case .message(let typeName):
                guard depth < maximumNestingDepth,
                    let nestedSchema = catalog?.message(named: typeName)
                else {
                    try appendSchemaLine(
                        field: field,
                        kind: "message",
                        value: "\(typeName) · \(bytesPreview(bytes[range]))",
                        depth: depth,
                        to: &lines,
                        renderedUTF8ByteCount: &renderedUTF8ByteCount
                    )
                    return
                }
                try appendSchemaLine(
                    field: field,
                    kind: "message",
                    value: "\(typeName) · \(byteCountText(range.count))",
                    depth: depth,
                    to: &lines,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
                renderedUTF8ByteCount += 1
                guard renderedUTF8ByteCount <= maximumRenderedUTF8ByteCount else {
                    throw DecodeError.outputLimit
                }
                lines.append(
                    contentsOf: try decodeMessage(
                        bytes,
                        range: range,
                        depth: depth + 1,
                        schema: nestedSchema,
                        catalog: catalog,
                        fieldCount: &fieldCount,
                        renderedUTF8ByteCount: &renderedUTF8ByteCount
                    )
                )
            default:
                throw DecodeError.malformed(
                    "Field \(field.number) uses an incompatible length-delimited value."
                )
            }
        case 5:
            let rawValue = try readFixed32(bytes, index: &index, end: end)
            try appendSchemaLine(
                field: field,
                kind: fieldTypeLabel(field.type),
                value: scalarFixed32Value(rawValue, type: field.type),
                depth: depth,
                to: &lines,
                renderedUTF8ByteCount: &renderedUTF8ByteCount
            )
        default:
            throw DecodeError.malformed("Unsupported wire type \(wireType).")
        }
    }

    private static func decodePackedValues(
        _ bytes: [UInt8],
        range: Range<Int>,
        type: ProtobufFieldType,
        catalog: ProtobufSchemaCatalog?,
        fieldCount: inout Int
    ) throws -> [String] {
        var index = range.lowerBound
        var values: [String] = []
        while index < range.upperBound {
            fieldCount += 1
            guard fieldCount <= maximumFieldCount else {
                throw DecodeError.fieldLimit
            }
            switch expectedWireType(type) {
            case 0:
                values.append(
                    scalarVarintValue(
                        try readVarint(bytes, index: &index, end: range.upperBound),
                        type: type,
                        catalog: catalog
                    )
                )
            case 1:
                values.append(
                    scalarFixed64Value(
                        try readFixed64(bytes, index: &index, end: range.upperBound),
                        type: type
                    )
                )
            case 5:
                values.append(
                    scalarFixed32Value(
                        try readFixed32(bytes, index: &index, end: range.upperBound),
                        type: type
                    )
                )
            default:
                throw DecodeError.malformed("Packed field uses a non-packable type.")
            }
        }
        return values
    }

    private static func scalarVarintValue(
        _ value: UInt64,
        type: ProtobufFieldType,
        catalog: ProtobufSchemaCatalog?
    ) -> String {
        switch type {
        case .int64:
            return String(Int64(bitPattern: value))
        case .uint64:
            return String(value)
        case .int32:
            return String(Int32(truncatingIfNeeded: value))
        case .bool:
            return value == 0 ? "false" : "true"
        case .uint32:
            return String(UInt32(truncatingIfNeeded: value))
        case .enumeration(let typeName):
            let number = Int32(truncatingIfNeeded: value)
            if let name = catalog?.enumeration(named: typeName)?.valueName(for: number) {
                return "\(name) (\(number))"
            }
            return String(number)
        case .sint32:
            return String(Int32(truncatingIfNeeded: zigZagDecoded(value)))
        case .sint64:
            return String(zigZagDecoded(value))
        default:
            return String(value)
        }
    }

    private static func scalarFixed32Value(
        _ value: UInt32,
        type: ProtobufFieldType
    ) -> String {
        switch type {
        case .float:
            return String(Float(bitPattern: value))
        case .sfixed32:
            return String(Int32(bitPattern: value))
        default:
            return String(value)
        }
    }

    private static func scalarFixed64Value(
        _ value: UInt64,
        type: ProtobufFieldType
    ) -> String {
        switch type {
        case .double:
            return String(Double(bitPattern: value))
        case .sfixed64:
            return String(Int64(bitPattern: value))
        default:
            return String(value)
        }
    }

    private static func zigZagDecoded(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(value & 1)
    }

    private static func fieldTypeLabel(_ type: ProtobufFieldType) -> String {
        switch type {
        case .double: "double"
        case .float: "float"
        case .int64: "int64"
        case .uint64: "uint64"
        case .int32: "int32"
        case .fixed64: "fixed64"
        case .fixed32: "fixed32"
        case .bool: "bool"
        case .string: "string"
        case .message: "message"
        case .bytes: "bytes"
        case .uint32: "uint32"
        case .enumeration: "enum"
        case .sfixed32: "sfixed32"
        case .sfixed64: "sfixed64"
        case .sint32: "sint32"
        case .sint64: "sint64"
        }
    }

    private static func appendSchemaLine(
        field: ProtobufFieldSchema,
        kind: String,
        value: String,
        depth: Int,
        to lines: inout [String],
        renderedUTF8ByteCount: inout Int
    ) throws {
        let name = field.name + String(repeating: " ", count: max(1, 20 - field.name.count))
        let type = kind + String(repeating: " ", count: max(1, 12 - kind.count))
        let line =
            "\(String(repeating: "  ", count: depth))\(field.number)  \(name)\(type)\(value)"
        renderedUTF8ByteCount += line.utf8.count + (lines.isEmpty ? 0 : 1)
        guard renderedUTF8ByteCount <= maximumRenderedUTF8ByteCount else {
            throw DecodeError.outputLimit
        }
        lines.append(line)
    }

    private static func readLengthDelimitedRange(
        _ bytes: [UInt8],
        index: inout Int,
        end: Int
    ) throws -> Range<Int> {
        let length = try readVarint(bytes, index: &index, end: end)
        guard length <= UInt64(end - index) else {
            throw DecodeError.malformed("Length-delimited field extends past the body.")
        }
        let range = index..<(index + Int(length))
        index = range.upperBound
        return range
    }

    private static func appendLengthDelimitedField(
        _ bytes: [UInt8],
        range: Range<Int>,
        fieldNumber: UInt64,
        depth: Int,
        schema: ProtobufMessageSchema?,
        catalog: ProtobufSchemaCatalog?,
        fieldCount: inout Int,
        renderedUTF8ByteCount: inout Int,
        lines: inout [String]
    ) throws {
        if let string = printableUTF8(bytes[range]) {
            try appendLine(
                fieldNumber: fieldNumber,
                kind: "string",
                value: "\"\(escapedAndBounded(string))\"",
                depth: depth,
                to: &lines,
                renderedUTF8ByteCount: &renderedUTF8ByteCount
            )
            return
        }

        if !range.isEmpty, depth < maximumNestingDepth {
            var nestedFieldCount = fieldCount
            var nestedRenderedUTF8ByteCount = renderedUTF8ByteCount
            let renderedUTF8ByteCountBeforeNestedMessage = renderedUTF8ByteCount
            if let nestedLines = try? decodeMessage(
                bytes,
                range: range,
                depth: depth + 1,
                schema: schema,
                catalog: catalog,
                fieldCount: &nestedFieldCount,
                renderedUTF8ByteCount: &nestedRenderedUTF8ByteCount
            ), !nestedLines.isEmpty {
                try appendLine(
                    fieldNumber: fieldNumber,
                    kind: "message",
                    value: byteCountText(range.count),
                    depth: depth,
                    to: &lines,
                    renderedUTF8ByteCount: &renderedUTF8ByteCount
                )
                fieldCount = nestedFieldCount
                let nestedOutputUTF8ByteCount =
                    nestedRenderedUTF8ByteCount - renderedUTF8ByteCountBeforeNestedMessage + 1
                renderedUTF8ByteCount += nestedOutputUTF8ByteCount
                guard renderedUTF8ByteCount <= maximumRenderedUTF8ByteCount else {
                    throw DecodeError.outputLimit
                }
                lines.append(contentsOf: nestedLines)
                return
            }
        }

        try appendLine(
            fieldNumber: fieldNumber,
            kind: "bytes",
            value: bytesPreview(bytes[range]),
            depth: depth,
            to: &lines,
            renderedUTF8ByteCount: &renderedUTF8ByteCount
        )
    }

    private static func appendLine(
        fieldNumber: UInt64,
        kind: String,
        value: String,
        depth: Int,
        to lines: inout [String],
        renderedUTF8ByteCount: inout Int
    ) throws {
        let paddedKind = kind.padding(toLength: 9, withPad: " ", startingAt: 0)
        let line = "\(String(repeating: "  ", count: depth))\(fieldNumber)  \(paddedKind)\(value)"
        renderedUTF8ByteCount += line.utf8.count + (lines.isEmpty ? 0 : 1)
        guard renderedUTF8ByteCount <= maximumRenderedUTF8ByteCount else {
            throw DecodeError.outputLimit
        }
        lines.append(line)
    }

    private static func readVarint(
        _ bytes: [UInt8],
        index: inout Int,
        end: Int
    ) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < end else {
                throw DecodeError.malformed("Varint is incomplete.")
            }
            let byte = bytes[index]
            index += 1
            if shift == 63, byte > 1 {
                throw DecodeError.malformed("Varint exceeds 64 bits.")
            }
            value |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 {
                return value
            }
        }
        throw DecodeError.malformed("Varint exceeds 10 bytes.")
    }

    private static func readDelimitedMessageLength(
        _ bytes: [UInt8],
        index: inout Int,
        end: Int
    ) throws -> Int {
        var value: UInt32 = 0
        for byteIndex in 0..<5 {
            guard index < end else {
                throw DecodeError.malformed("Delimited message length is incomplete.")
            }
            let byte = bytes[index]
            index += 1
            if byteIndex == 4, byte & 0xF0 != 0 {
                throw DecodeError.malformed("Delimited message length exceeds 32 bits.")
            }
            value |= UInt32(byte & 0x7F) << UInt32(byteIndex * 7)
            if byte & 0x80 == 0 {
                return Int(value)
            }
        }
        throw DecodeError.malformed("Delimited message length exceeds 5 bytes.")
    }

    private static func readFixed32(
        _ bytes: [UInt8],
        index: inout Int,
        end: Int
    ) throws -> UInt32 {
        guard end - index >= 4 else {
            throw DecodeError.malformed("Fixed32 field is incomplete.")
        }
        var value: UInt32 = 0
        for offset in 0..<4 {
            value |= UInt32(bytes[index + offset]) << UInt32(offset * 8)
        }
        index += 4
        return value
    }

    private static func readFixed64(
        _ bytes: [UInt8],
        index: inout Int,
        end: Int
    ) throws -> UInt64 {
        guard end - index >= 8 else {
            throw DecodeError.malformed("Fixed64 field is incomplete.")
        }
        var value: UInt64 = 0
        for offset in 0..<8 {
            value |= UInt64(bytes[index + offset]) << UInt64(offset * 8)
        }
        index += 8
        return value
    }

    private static func printableUTF8(_ bytes: ArraySlice<UInt8>) -> String? {
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            return nil
        }
        guard
            value.unicodeScalars.allSatisfy({ scalar in
                scalar.value >= 0x20 || scalar == "\t" || scalar == "\n" || scalar == "\r"
            })
        else {
            return nil
        }
        return value
    }

    private static func escapedAndBounded(_ value: String) -> String {
        let maximumCharacterCount = 4_096
        let shown = String(value.prefix(maximumCharacterCount))
        let escaped =
            shown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return value.count > maximumCharacterCount ? "\(escaped)…" : escaped
    }

    private static func bytesPreview(_ bytes: ArraySlice<UInt8>) -> String {
        let maximumPreviewByteCount = 64
        let shown = bytes.prefix(maximumPreviewByteCount).map { hex(UInt64($0), width: 2) }
            .joined(separator: " ")
        if bytes.count > maximumPreviewByteCount {
            return "\(shown) … (\(byteCountText(bytes.count)))"
        }
        return shown.isEmpty ? "[empty]" : shown
    }

    private static func hex(_ value: UInt64, width: Int) -> String {
        let rendered = String(value, radix: 16)
        return String(repeating: "0", count: max(0, width - rendered.count)) + rendered
    }

    private static func byteCountText(_ count: Int) -> String {
        count == 1 ? "1 B" : "\(count) B"
    }

    private static func isProtobufMediaType(_ contentType: String?) -> Bool {
        guard let mediaType = normalizedMediaType(contentType) else {
            return false
        }
        return mediaType == "application/protobuf"
            || mediaType == "application/x-protobuf"
            || mediaType == "application/vnd.google.protobuf"
            || mediaType.hasSuffix("+protobuf")
    }

    private static func isGRPCProtobufMediaType(_ contentType: String?) -> Bool {
        guard let mediaType = normalizedMediaType(contentType) else {
            return false
        }
        return mediaType == "application/grpc" || mediaType == "application/grpc+proto"
    }

    private static func isGRPCWebBinaryProtobufMediaType(_ contentType: String?) -> Bool {
        guard let mediaType = normalizedMediaType(contentType) else {
            return false
        }
        return mediaType == "application/grpc-web"
            || mediaType == "application/grpc-web+proto"
    }

    private static func isGRPCWebTextProtobufMediaType(_ contentType: String?) -> Bool {
        guard let mediaType = normalizedMediaType(contentType) else {
            return false
        }
        return mediaType == "application/grpc-web-text"
            || mediaType == "application/grpc-web-text+proto"
    }

    private static func isDelimitedProtobufMediaType(_ contentType: String?) -> Bool {
        guard isProtobufMediaType(contentType),
            let value = contentTypeParameter(named: "delimited", in: contentType)
        else {
            return false
        }
        return value.caseInsensitiveCompare("true") == .orderedSame
    }

    private static func contentTypeParameter(
        named requestedName: String,
        in contentType: String?
    ) -> String? {
        guard let contentType else {
            return nil
        }
        for component in contentType.split(separator: ";").dropFirst() {
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare(requestedName) == .orderedSame else {
                continue
            }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                return String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    private static func normalizedGRPCEncoding(_ grpcEncoding: String?) -> String? {
        guard let grpcEncoding else {
            return nil
        }
        let value = grpcEncoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value != "identity", !value.contains(",") else {
            return nil
        }
        return value
    }

    private static func isSupportedGRPCEncoding(_ encoding: String) -> Bool {
        encoding == "gzip" || encoding == "x-gzip" || encoding == "deflate"
    }

    private enum DecodeError: Error {
        case malformed(String)
        case decodedByteLimit
        case fieldLimit
        case grpcMessageLimit
        case delimitedMessageLimit
        case outputLimit

        var description: String {
            switch self {
            case .malformed(let message): message
            case .decodedByteLimit: ProtobufBodyView.exceedsDisplayLimitReason
            case .fieldLimit: ProtobufBodyView.fieldLimitReason
            case .grpcMessageLimit: ProtobufBodyView.grpcMessageLimitReason
            case .delimitedMessageLimit: ProtobufBodyView.delimitedMessageLimitReason
            case .outputLimit: ProtobufBodyView.renderedOutputLimitReason
            }
        }
    }
}
