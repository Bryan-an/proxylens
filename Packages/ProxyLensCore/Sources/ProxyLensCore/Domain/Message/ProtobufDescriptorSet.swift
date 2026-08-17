import Foundation

public enum ProtobufFieldLabel: String, Equatable, Sendable {
    case optional
    case required
    case repeated
}

public enum ProtobufFieldType: Equatable, Sendable {
    case double
    case float
    case int64
    case uint64
    case int32
    case fixed64
    case fixed32
    case bool
    case string
    case message(String)
    case bytes
    case uint32
    case enumeration(String)
    case sfixed32
    case sfixed64
    case sint32
    case sint64
}

public struct ProtobufFieldSchema: Equatable, Sendable {
    public let number: Int
    public let name: String
    public let label: ProtobufFieldLabel
    public let type: ProtobufFieldType
    public let isPacked: Bool

    public init(
        number: Int,
        name: String,
        label: ProtobufFieldLabel,
        type: ProtobufFieldType,
        isPacked: Bool = false
    ) {
        self.number = number
        self.name = name
        self.label = label
        self.type = type
        self.isPacked = isPacked
    }
}

public struct ProtobufMessageSchema: Equatable, Sendable {
    public let fullName: String
    public let fields: [ProtobufFieldSchema]
    private let fieldsByNumber: [Int: ProtobufFieldSchema]

    public init(fullName: String, fields: [ProtobufFieldSchema]) {
        self.fullName = fullName
        self.fields = fields
        var indexedFields: [Int: ProtobufFieldSchema] = [:]
        for field in fields where indexedFields[field.number] == nil {
            indexedFields[field.number] = field
        }
        fieldsByNumber = indexedFields
    }

    public func field(number: Int) -> ProtobufFieldSchema? {
        fieldsByNumber[number]
    }
}

public struct ProtobufEnumSchema: Equatable, Sendable {
    public let fullName: String
    public let valuesByNumber: [Int32: String]

    public init(fullName: String, valuesByNumber: [Int32: String]) {
        self.fullName = fullName
        self.valuesByNumber = valuesByNumber
    }

    public func valueName(for number: Int32) -> String? {
        valuesByNumber[number]
    }
}

public struct ProtobufSchemaCatalog: Equatable, Sendable {
    private let messagesByName: [String: ProtobufMessageSchema]
    private let enumsByName: [String: ProtobufEnumSchema]

    public var messageTypeNames: [String] {
        messagesByName.keys.sorted()
    }

    public init(
        messages: [ProtobufMessageSchema],
        enumerations: [ProtobufEnumSchema]
    ) {
        var indexedMessages: [String: ProtobufMessageSchema] = [:]
        for message in messages where indexedMessages[message.fullName] == nil {
            indexedMessages[message.fullName] = message
        }
        messagesByName = indexedMessages

        var indexedEnumerations: [String: ProtobufEnumSchema] = [:]
        for enumeration in enumerations where indexedEnumerations[enumeration.fullName] == nil {
            indexedEnumerations[enumeration.fullName] = enumeration
        }
        enumsByName = indexedEnumerations
    }

    public func message(named fullName: String) -> ProtobufMessageSchema? {
        messagesByName[Self.normalized(fullName)]
    }

    public func enumeration(named fullName: String) -> ProtobufEnumSchema? {
        enumsByName[Self.normalized(fullName)]
    }

    private static func normalized(_ fullName: String) -> String {
        fullName.hasPrefix(".") ? String(fullName.dropFirst()) : fullName
    }
}

public enum ProtobufDescriptorSetError: LocalizedError, Equatable, Sendable {
    case exceedsByteLimit(maximum: Int)
    case limitExceeded(String)
    case malformed(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .exceedsByteLimit(let maximum):
            "Descriptor set exceeds the \(maximum)-byte import limit."
        case .limitExceeded(let message), .malformed(let message), .invalid(let message):
            message
        }
    }
}

/// Parses the subset of `google.protobuf.FileDescriptorSet` required for runtime inspection.
/// Imported bytes are untrusted, so every collection, string, nesting level, and read is bounded.
public enum ProtobufDescriptorSetParser: Sendable {
    public static let maximumByteCount = 4 * 1_024 * 1_024
    public static let maximumFileCount = 256
    public static let maximumMessageCount = 10_000
    public static let maximumFieldCount = 50_000
    public static let maximumEnumCount = 10_000
    public static let maximumEnumValueCount = 50_000
    public static let maximumNestingDepth = 64
    public static let maximumStringByteCount = 1_024

    public static func parse(_ data: Data) throws -> ProtobufSchemaCatalog {
        guard data.count <= maximumByteCount else {
            throw ProtobufDescriptorSetError.exceedsByteLimit(maximum: maximumByteCount)
        }

        let bytes = Array(data)
        var reader = WireReader(bytes: bytes, range: 0..<bytes.count)
        var limits = Limits()
        var files: [FileDraft] = []

        while let field = try reader.nextField() {
            if field.number == 1, field.wireType == 2 {
                limits.files += 1
                try limits.require(
                    limits.files <= maximumFileCount, "Too many files in descriptor set.")
                files.append(
                    try parseFile(
                        bytes: bytes,
                        range: reader.readLengthDelimitedRange(),
                        limits: &limits
                    )
                )
            } else {
                try reader.skip(field)
            }
        }

        var messageDrafts: [(fullName: String, draft: MessageDraft)] = []
        var enumDrafts: [(fullName: String, draft: EnumDraft)] = []
        for file in files {
            for message in file.messages {
                collect(
                    message,
                    prefix: file.package,
                    messages: &messageDrafts,
                    enumerations: &enumDrafts
                )
            }
            for enumeration in file.enumerations {
                enumDrafts.append((qualified(file.package, enumeration.name), enumeration))
            }
        }

        try requireUnique(messageDrafts.map(\.fullName), kind: "message")
        try requireUnique(enumDrafts.map(\.fullName), kind: "enum")
        let knownMessages = Set(messageDrafts.map(\.fullName))
        let knownEnums = Set(enumDrafts.map(\.fullName))

        let messages = try messageDrafts.map { entry in
            var numbers = Set<Int>()
            var names = Set<String>()
            let fields = try entry.draft.fields.map { draft in
                guard (1...0x1FFF_FFFF).contains(draft.number) else {
                    throw ProtobufDescriptorSetError.invalid(
                        "Invalid field number \(draft.number) in \(entry.fullName)."
                    )
                }
                guard numbers.insert(draft.number).inserted else {
                    throw ProtobufDescriptorSetError.invalid(
                        "Duplicate field number \(draft.number) in \(entry.fullName)."
                    )
                }
                guard names.insert(draft.name).inserted else {
                    throw ProtobufDescriptorSetError.invalid(
                        "Duplicate field name \(draft.name) in \(entry.fullName)."
                    )
                }
                return ProtobufFieldSchema(
                    number: draft.number,
                    name: draft.name,
                    label: try fieldLabel(draft.label, field: draft.name),
                    type: try fieldType(
                        draft.type,
                        typeName: draft.typeName,
                        scope: entry.fullName,
                        knownMessages: knownMessages,
                        knownEnums: knownEnums
                    ),
                    isPacked: draft.isPacked
                )
            }
            return ProtobufMessageSchema(fullName: entry.fullName, fields: fields)
        }

        let enumerations = try enumDrafts.map { entry in
            var valuesByNumber: [Int32: String] = [:]
            var names = Set<String>()
            for value in entry.draft.values {
                guard names.insert(value.name).inserted else {
                    throw ProtobufDescriptorSetError.invalid(
                        "Duplicate enum value name \(value.name) in \(entry.fullName)."
                    )
                }
                if valuesByNumber[value.number] == nil {
                    valuesByNumber[value.number] = value.name
                }
            }
            return ProtobufEnumSchema(fullName: entry.fullName, valuesByNumber: valuesByNumber)
        }

        return ProtobufSchemaCatalog(messages: messages, enumerations: enumerations)
    }

    private static func parseFile(
        bytes: [UInt8],
        range: Range<Int>,
        limits: inout Limits
    ) throws -> FileDraft {
        var reader = WireReader(bytes: bytes, range: range)
        var package = ""
        var messages: [MessageDraft] = []
        var enumerations: [EnumDraft] = []
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (2, 2):
                package = try reader.readString(maximumByteCount: maximumStringByteCount)
            case (4, 2):
                messages.append(
                    try parseMessage(
                        bytes: bytes,
                        range: reader.readLengthDelimitedRange(),
                        depth: 0,
                        limits: &limits
                    )
                )
            case (5, 2):
                enumerations.append(
                    try parseEnum(
                        bytes: bytes,
                        range: reader.readLengthDelimitedRange(),
                        limits: &limits
                    )
                )
            default:
                try reader.skip(field)
            }
        }
        return FileDraft(
            package: normalizedPackage(package), messages: messages, enumerations: enumerations)
    }

    private static func parseMessage(
        bytes: [UInt8],
        range: Range<Int>,
        depth: Int,
        limits: inout Limits
    ) throws -> MessageDraft {
        guard depth <= maximumNestingDepth else {
            throw ProtobufDescriptorSetError.limitExceeded(
                "Descriptor message nesting is too deep.")
        }
        limits.messages += 1
        try limits.require(
            limits.messages <= maximumMessageCount, "Too many messages in descriptor set.")

        var reader = WireReader(bytes: bytes, range: range)
        var name: String?
        var fields: [FieldDraft] = []
        var messages: [MessageDraft] = []
        var enumerations: [EnumDraft] = []
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, 2):
                name = try reader.readString(maximumByteCount: maximumStringByteCount)
            case (2, 2):
                limits.fields += 1
                try limits.require(
                    limits.fields <= maximumFieldCount, "Too many fields in descriptor set.")
                fields.append(
                    try parseField(bytes: bytes, range: reader.readLengthDelimitedRange())
                )
            case (3, 2):
                messages.append(
                    try parseMessage(
                        bytes: bytes,
                        range: reader.readLengthDelimitedRange(),
                        depth: depth + 1,
                        limits: &limits
                    )
                )
            case (4, 2):
                enumerations.append(
                    try parseEnum(
                        bytes: bytes,
                        range: reader.readLengthDelimitedRange(),
                        limits: &limits
                    )
                )
            default:
                try reader.skip(field)
            }
        }
        return MessageDraft(
            name: try requiredName(name, kind: "message"),
            fields: fields,
            messages: messages,
            enumerations: enumerations
        )
    }

    private static func parseField(bytes: [UInt8], range: Range<Int>) throws -> FieldDraft {
        var reader = WireReader(bytes: bytes, range: range)
        var name: String?
        var number: Int?
        var label: Int?
        var type: Int?
        var typeName: String?
        var isPacked = false
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, 2):
                name = try reader.readString(maximumByteCount: maximumStringByteCount)
            case (3, 0):
                number = Int(truncatingIfNeeded: try reader.readVarint())
            case (4, 0):
                label = Int(truncatingIfNeeded: try reader.readVarint())
            case (5, 0):
                type = Int(truncatingIfNeeded: try reader.readVarint())
            case (6, 2):
                typeName = try reader.readString(maximumByteCount: maximumStringByteCount)
            case (8, 2):
                isPacked = try parseFieldOptions(
                    bytes: bytes,
                    range: reader.readLengthDelimitedRange()
                )
            default:
                try reader.skip(field)
            }
        }
        guard let number else {
            throw ProtobufDescriptorSetError.invalid(
                "Descriptor field is missing its field number.")
        }
        guard let label else {
            throw ProtobufDescriptorSetError.invalid("Descriptor field is missing its label.")
        }
        guard let type else {
            throw ProtobufDescriptorSetError.invalid("Descriptor field is missing its type.")
        }
        return FieldDraft(
            name: try requiredName(name, kind: "field"),
            number: number,
            label: label,
            type: type,
            typeName: typeName,
            isPacked: isPacked
        )
    }

    private static func parseFieldOptions(bytes: [UInt8], range: Range<Int>) throws -> Bool {
        var reader = WireReader(bytes: bytes, range: range)
        var isPacked = false
        while let field = try reader.nextField() {
            if field.number == 2, field.wireType == 0 {
                isPacked = try reader.readVarint() != 0
            } else {
                try reader.skip(field)
            }
        }
        return isPacked
    }

    private static func parseEnum(
        bytes: [UInt8],
        range: Range<Int>,
        limits: inout Limits
    ) throws -> EnumDraft {
        limits.enumerations += 1
        try limits.require(
            limits.enumerations <= maximumEnumCount, "Too many enums in descriptor set.")
        var reader = WireReader(bytes: bytes, range: range)
        var name: String?
        var values: [EnumValueDraft] = []
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, 2):
                name = try reader.readString(maximumByteCount: maximumStringByteCount)
            case (2, 2):
                limits.enumValues += 1
                try limits.require(
                    limits.enumValues <= maximumEnumValueCount,
                    "Too many enum values in descriptor set."
                )
                values.append(
                    try parseEnumValue(
                        bytes: bytes,
                        range: reader.readLengthDelimitedRange()
                    )
                )
            default:
                try reader.skip(field)
            }
        }
        return EnumDraft(name: try requiredName(name, kind: "enum"), values: values)
    }

    private static func parseEnumValue(bytes: [UInt8], range: Range<Int>) throws -> EnumValueDraft {
        var reader = WireReader(bytes: bytes, range: range)
        var name: String?
        var number: Int32?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, 2):
                name = try reader.readString(maximumByteCount: maximumStringByteCount)
            case (2, 0):
                number = Int32(truncatingIfNeeded: try reader.readVarint())
            default:
                try reader.skip(field)
            }
        }
        guard let number else {
            throw ProtobufDescriptorSetError.invalid("Descriptor enum value is missing its number.")
        }
        return EnumValueDraft(name: try requiredName(name, kind: "enum value"), number: number)
    }

    private static func collect(
        _ message: MessageDraft,
        prefix: String,
        messages: inout [(fullName: String, draft: MessageDraft)],
        enumerations: inout [(fullName: String, draft: EnumDraft)]
    ) {
        let fullName = qualified(prefix, message.name)
        messages.append((fullName, message))
        for enumeration in message.enumerations {
            enumerations.append((qualified(fullName, enumeration.name), enumeration))
        }
        for nested in message.messages {
            collect(
                nested,
                prefix: fullName,
                messages: &messages,
                enumerations: &enumerations
            )
        }
    }

    private static func fieldLabel(_ rawValue: Int, field: String) throws -> ProtobufFieldLabel {
        switch rawValue {
        case 1: .optional
        case 2: .required
        case 3: .repeated
        default:
            throw ProtobufDescriptorSetError.invalid(
                "Invalid label \(rawValue) for field \(field)."
            )
        }
    }

    private static func fieldType(
        _ rawValue: Int,
        typeName: String?,
        scope: String,
        knownMessages: Set<String>,
        knownEnums: Set<String>
    ) throws -> ProtobufFieldType {
        switch rawValue {
        case 1: return .double
        case 2: return .float
        case 3: return .int64
        case 4: return .uint64
        case 5: return .int32
        case 6: return .fixed64
        case 7: return .fixed32
        case 8: return .bool
        case 9: return .string
        case 10:
            throw ProtobufDescriptorSetError.invalid("Deprecated Protobuf groups are unsupported.")
        case 11:
            return .message(
                try resolvedTypeName(
                    typeName,
                    scope: scope,
                    knownNames: knownMessages,
                    kind: "message"
                )
            )
        case 12: return .bytes
        case 13: return .uint32
        case 14:
            return .enumeration(
                try resolvedTypeName(
                    typeName,
                    scope: scope,
                    knownNames: knownEnums,
                    kind: "enum"
                )
            )
        case 15: return .sfixed32
        case 16: return .sfixed64
        case 17: return .sint32
        case 18: return .sint64
        default:
            throw ProtobufDescriptorSetError.invalid("Invalid Protobuf field type \(rawValue).")
        }
    }

    private static func resolvedTypeName(
        _ typeName: String?,
        scope: String,
        knownNames: Set<String>,
        kind: String
    ) throws -> String {
        guard let typeName, !typeName.isEmpty else {
            throw ProtobufDescriptorSetError.invalid(
                "Descriptor \(kind) field is missing type_name.")
        }
        if typeName.hasPrefix(".") {
            let absolute = String(typeName.dropFirst())
            guard knownNames.contains(absolute) else {
                throw ProtobufDescriptorSetError.invalid("Unknown \(kind) type \(typeName).")
            }
            return absolute
        }
        if knownNames.contains(typeName) {
            return typeName
        }
        var components = scope.split(separator: ".").map(String.init)
        while !components.isEmpty {
            let candidate = (components + [typeName]).joined(separator: ".")
            if knownNames.contains(candidate) {
                return candidate
            }
            components.removeLast()
        }
        throw ProtobufDescriptorSetError.invalid("Unknown \(kind) type \(typeName).")
    }

    private static func requiredName(_ name: String?, kind: String) throws -> String {
        guard let name, !name.isEmpty else {
            throw ProtobufDescriptorSetError.invalid("Descriptor \(kind) is missing its name.")
        }
        return name
    }

    private static func requireUnique(_ names: [String], kind: String) throws {
        var seen = Set<String>()
        for name in names where !seen.insert(name).inserted {
            throw ProtobufDescriptorSetError.invalid("Duplicate \(kind) \(name).")
        }
    }

    private static func qualified(_ prefix: String, _ name: String) -> String {
        prefix.isEmpty ? name : "\(prefix).\(name)"
    }

    private static func normalizedPackage(_ package: String) -> String {
        package.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

private struct FileDraft {
    let package: String
    let messages: [MessageDraft]
    let enumerations: [EnumDraft]
}

private struct MessageDraft {
    let name: String
    let fields: [FieldDraft]
    let messages: [MessageDraft]
    let enumerations: [EnumDraft]
}

private struct FieldDraft {
    let name: String
    let number: Int
    let label: Int
    let type: Int
    let typeName: String?
    let isPacked: Bool
}

private struct EnumDraft {
    let name: String
    let values: [EnumValueDraft]
}

private struct EnumValueDraft {
    let name: String
    let number: Int32
}

private struct Limits {
    var files = 0
    var messages = 0
    var fields = 0
    var enumerations = 0
    var enumValues = 0

    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ProtobufDescriptorSetError.limitExceeded(message)
        }
    }
}

private struct WireField {
    let number: UInt64
    let wireType: UInt8
}

private struct WireReader {
    let bytes: [UInt8]
    let end: Int
    var index: Int

    init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        index = range.lowerBound
        end = range.upperBound
    }

    mutating func nextField() throws -> WireField? {
        guard index < end else {
            return nil
        }
        let key = try readVarint()
        let number = key >> 3
        let wireType = UInt8(key & 0x07)
        guard number > 0, number <= 0x1FFF_FFFF else {
            throw ProtobufDescriptorSetError.malformed(
                "Descriptor field number is outside the valid range.")
        }
        guard wireType <= 5 else {
            throw ProtobufDescriptorSetError.malformed(
                "Descriptor uses invalid wire type \(wireType).")
        }
        return WireField(number: number, wireType: wireType)
    }

    mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < end else {
                throw ProtobufDescriptorSetError.malformed("Descriptor varint is incomplete.")
            }
            let byte = bytes[index]
            index += 1
            if shift == 63, byte > 1 {
                throw ProtobufDescriptorSetError.malformed("Descriptor varint exceeds 64 bits.")
            }
            value |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 {
                return value
            }
        }
        throw ProtobufDescriptorSetError.malformed("Descriptor varint exceeds 10 bytes.")
    }

    mutating func readLengthDelimitedRange() throws -> Range<Int> {
        let length = try readVarint()
        guard length <= UInt64(end - index) else {
            throw ProtobufDescriptorSetError.malformed(
                "Length-delimited descriptor field extends past its containing message."
            )
        }
        let range = index..<(index + Int(length))
        index = range.upperBound
        return range
    }

    mutating func readString(maximumByteCount: Int) throws -> String {
        let range = try readLengthDelimitedRange()
        guard range.count <= maximumByteCount else {
            throw ProtobufDescriptorSetError.limitExceeded(
                "Descriptor string exceeds import limit.")
        }
        guard let value = String(bytes: bytes[range], encoding: .utf8) else {
            throw ProtobufDescriptorSetError.malformed("Descriptor string is not valid UTF-8.")
        }
        return value
    }

    mutating func skip(_ field: WireField, depth: Int = 0) throws {
        switch field.wireType {
        case 0:
            _ = try readVarint()
        case 1:
            try advance(8)
        case 2:
            _ = try readLengthDelimitedRange()
        case 3:
            guard depth < ProtobufDescriptorSetParser.maximumNestingDepth else {
                throw ProtobufDescriptorSetError.limitExceeded(
                    "Descriptor group nesting is too deep.")
            }
            while let nested = try nextField() {
                if nested.wireType == 4 {
                    guard nested.number == field.number else {
                        throw ProtobufDescriptorSetError.malformed(
                            "Descriptor group end does not match its start.")
                    }
                    return
                }
                try skip(nested, depth: depth + 1)
            }
            throw ProtobufDescriptorSetError.malformed("Descriptor group is incomplete.")
        case 4:
            throw ProtobufDescriptorSetError.malformed("Descriptor has an unexpected group end.")
        case 5:
            try advance(4)
        default:
            throw ProtobufDescriptorSetError.malformed("Descriptor uses an invalid wire type.")
        }
    }

    private mutating func advance(_ count: Int) throws {
        guard count <= end - index else {
            throw ProtobufDescriptorSetError.malformed(
                "Descriptor fixed-width field is incomplete.")
        }
        index += count
    }
}
