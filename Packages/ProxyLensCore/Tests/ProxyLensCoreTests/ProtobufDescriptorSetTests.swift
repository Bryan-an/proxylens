import Foundation
import XCTest

@testable import ProxyLensCore

final class ProtobufDescriptorSetTests: XCTestCase {
    func testParserBuildsFullyQualifiedMessagesFieldsAndEnums() throws {
        var descriptorSet = Data([0x10, 0x01])  // Unknown top-level varint must be skipped.
        descriptorSet.append(field(1, message: exampleFileDescriptor()))

        let catalog = try ProtobufDescriptorSetParser.parse(descriptorSet)

        XCTAssertEqual(catalog.messageTypeNames, ["example.User", "example.User.Profile"])
        let user = try XCTUnwrap(catalog.message(named: "example.User"))
        XCTAssertEqual(user.fields.map(\.name), ["id", "name", "state", "profile", "scores"])
        XCTAssertEqual(user.fields[0].type, .int32)
        XCTAssertEqual(user.fields[2].type, .enumeration("example.State"))
        XCTAssertEqual(user.fields[3].type, .message("example.User.Profile"))
        XCTAssertEqual(user.fields[4].label, .repeated)
        XCTAssertTrue(user.fields[4].isPacked)

        let state = try XCTUnwrap(catalog.enumeration(named: "example.State"))
        XCTAssertEqual(state.valueName(for: 1), "ACTIVE")
    }

    func testParserRejectsMalformedDuplicateAndOversizedDescriptorSetsWithoutTrapping() throws {
        XCTAssertThrowsError(
            try ProtobufDescriptorSetParser.parse(Data([0x0A, 0x05, 0x01]))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("extends past"))
        }

        let duplicateMessages = fileDescriptor(
            package: "example",
            messages: [messageDescriptor(name: "User"), messageDescriptor(name: "User")]
        )
        XCTAssertThrowsError(
            try ProtobufDescriptorSetParser.parse(field(1, message: duplicateMessages))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Duplicate message"))
        }

        let invalidField = messageDescriptor(
            name: "Invalid",
            fields: [fieldDescriptor(name: "zero", number: 0, type: 5)]
        )
        XCTAssertThrowsError(
            try ProtobufDescriptorSetParser.parse(
                field(1, message: fileDescriptor(package: "example", messages: [invalidField]))
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("field number"))
        }

        XCTAssertThrowsError(
            try ProtobufDescriptorSetParser.parse(
                Data(repeating: 0, count: ProtobufDescriptorSetParser.maximumByteCount + 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? ProtobufDescriptorSetError,
                .exceedsByteLimit(maximum: ProtobufDescriptorSetParser.maximumByteCount)
            )
        }
    }

    func testSchemaAwareBodyViewRendersNamesTypesEnumsNestingPackedValuesAndFallbacks() throws {
        let catalog = try ProtobufDescriptorSetParser.parse(
            field(1, message: exampleFileDescriptor())
        )
        let user = try XCTUnwrap(catalog.message(named: "example.User"))
        let payload = Data([
            0x08, 0x96, 0x01,  // id = 150
            0x12, 0x03, 0x41, 0x64, 0x61,  // name = "Ada"
            0x18, 0x01,  // state = ACTIVE
            0x22, 0x02, 0x08, 0x01,  // profile.active = true
            0x2A, 0x02, 0x01, 0x04,  // packed scores = [-1, 2]
            0x48, 0x07  // unknown field 9
        ])

        let result = ProtobufBodyView.render(
            data: payload,
            contentType: "application/protobuf",
            contentEncoding: nil,
            schema: user,
            catalog: catalog
        )

        guard case .decoded(let text) = result else {
            return XCTFail("expected schema-aware Protobuf output, got \(result)")
        }
        XCTAssertTrue(text.contains("1  id"))
        XCTAssertTrue(text.contains("int32"))
        XCTAssertTrue(text.contains("150"))
        XCTAssertTrue(text.contains("2  name"))
        XCTAssertTrue(text.contains("string"))
        XCTAssertTrue(text.contains("\"Ada\""))
        XCTAssertTrue(text.contains("3  state"))
        XCTAssertTrue(text.contains("ACTIVE (1)"))
        XCTAssertTrue(text.contains("4  profile"))
        XCTAssertTrue(text.contains("example.User.Profile"))
        XCTAssertTrue(text.contains("  1  active"))
        XCTAssertTrue(text.contains("true"))
        XCTAssertTrue(text.contains("5  scores"))
        XCTAssertTrue(text.contains("[-1, 2]"))
        XCTAssertTrue(text.contains("9  varint"))
        XCTAssertTrue(text.contains("7"))
    }

    func testSchemaAwareBodyViewAppliesSchemaAfterGRPCDecompression() throws {
        let catalog = try ProtobufDescriptorSetParser.parse(
            field(1, message: exampleFileDescriptor())
        )
        let user = try XCTUnwrap(catalog.message(named: "example.User"))
        let payload = Data([0x08, 0x2A])
        let compressed = try HTTPContentCoding.encode(payload, contentEncoding: "gzip")
        var body = Data([0x01])
        let length = UInt32(compressed.count).bigEndian
        withUnsafeBytes(of: length) { body.append(contentsOf: $0) }
        body.append(compressed)

        let result = ProtobufBodyView.render(
            data: body,
            contentType: "application/grpc",
            contentEncoding: nil,
            grpcEncoding: "gzip",
            schema: user,
            catalog: catalog
        )

        guard case .decoded(let text) = result else {
            return XCTFail("expected schema-aware gRPC output, got \(result)")
        }
        XCTAssertTrue(text.contains("Message 1"))
        XCTAssertTrue(text.contains("1  id"))
        XCTAssertTrue(text.contains("42"))
    }

    func testSchemaAwareBodyViewRendersEveryScalarEncoding() throws {
        let enumeration = ProtobufEnumSchema(
            fullName: "example.State",
            valuesByNumber: [1: "ACTIVE"]
        )
        let schema = ProtobufMessageSchema(
            fullName: "example.Scalars",
            fields: [
                ProtobufFieldSchema(
                    number: 1, name: "double_value", label: .optional, type: .double),
                ProtobufFieldSchema(number: 2, name: "float_value", label: .optional, type: .float),
                ProtobufFieldSchema(number: 3, name: "int64_value", label: .optional, type: .int64),
                ProtobufFieldSchema(
                    number: 4, name: "uint64_value", label: .optional, type: .uint64),
                ProtobufFieldSchema(number: 5, name: "int32_value", label: .optional, type: .int32),
                ProtobufFieldSchema(
                    number: 6, name: "fixed64_value", label: .optional, type: .fixed64),
                ProtobufFieldSchema(
                    number: 7, name: "fixed32_value", label: .optional, type: .fixed32),
                ProtobufFieldSchema(number: 8, name: "bool_value", label: .optional, type: .bool),
                ProtobufFieldSchema(
                    number: 9, name: "string_value", label: .optional, type: .string),
                ProtobufFieldSchema(
                    number: 10, name: "bytes_value", label: .optional, type: .bytes),
                ProtobufFieldSchema(
                    number: 11, name: "uint32_value", label: .optional, type: .uint32),
                ProtobufFieldSchema(
                    number: 12,
                    name: "enum_value",
                    label: .optional,
                    type: .enumeration("example.State")
                ),
                ProtobufFieldSchema(
                    number: 13, name: "sfixed32_value", label: .optional, type: .sfixed32),
                ProtobufFieldSchema(
                    number: 14, name: "sfixed64_value", label: .optional, type: .sfixed64),
                ProtobufFieldSchema(
                    number: 15, name: "sint32_value", label: .optional, type: .sint32),
                ProtobufFieldSchema(
                    number: 16, name: "sint64_value", label: .optional, type: .sint64)
            ]
        )
        let catalog = ProtobufSchemaCatalog(messages: [schema], enumerations: [enumeration])
        var payload = fixed64Field(1, value: Double(1.5).bitPattern)
        payload.append(fixed32Field(2, value: Float(-2.25).bitPattern))
        payload.append(field(3, varint: UInt64(bitPattern: -2)))
        payload.append(field(4, varint: 300))
        payload.append(field(5, varint: UInt64(bitPattern: -123)))
        payload.append(fixed64Field(6, value: 500))
        payload.append(fixed32Field(7, value: 400))
        payload.append(field(8, varint: 1))
        payload.append(field(9, string: "hi"))
        payload.append(field(10, message: Data([0xFF, 0x00])))
        payload.append(field(11, varint: 42))
        payload.append(field(12, varint: 1))
        payload.append(fixed32Field(13, value: UInt32(bitPattern: -7)))
        payload.append(fixed64Field(14, value: UInt64(bitPattern: -9)))
        payload.append(field(15, varint: 9))
        payload.append(field(16, varint: 11))

        let result = ProtobufBodyView.render(
            data: payload,
            contentType: "application/protobuf",
            contentEncoding: nil,
            schema: schema,
            catalog: catalog
        )

        guard case .decoded(let text) = result else {
            return XCTFail("expected scalar Protobuf output, got \(result)")
        }
        for expected in [
            "double_value", "double      1.5",
            "float_value", "float       -2.25",
            "int64_value", "int64       -2",
            "uint64_value", "uint64      300",
            "int32_value", "int32       -123",
            "fixed64_value", "fixed64     500",
            "fixed32_value", "fixed32     400",
            "bool_value", "bool        true",
            "string_value", "string      \"hi\"",
            "bytes_value", "bytes       ff 00",
            "uint32_value", "uint32      42",
            "enum_value", "enum        ACTIVE (1)",
            "sfixed32_value", "sfixed32    -7",
            "sfixed64_value", "sfixed64    -9",
            "sint32_value", "sint32      -5",
            "sint64_value", "sint64      -6"
        ] {
            XCTAssertTrue(text.contains(expected), "Missing \(expected) in:\n\(text)")
        }
    }

    func testPackedValuesShareTheGlobalFieldLimit() {
        let schema = ProtobufMessageSchema(
            fullName: "example.Many",
            fields: [
                ProtobufFieldSchema(
                    number: 1,
                    name: "values",
                    label: .repeated,
                    type: .uint32,
                    isPacked: true
                )
            ]
        )
        let packed = Data(repeating: 0, count: ProtobufBodyView.maximumFieldCount)
        let payload = field(1, message: packed)

        XCTAssertEqual(
            ProtobufBodyView.render(
                data: payload,
                contentType: "application/protobuf",
                contentEncoding: nil,
                schema: schema,
                catalog: ProtobufSchemaCatalog(messages: [schema], enumerations: [])
            ),
            .unavailable(reason: ProtobufBodyView.fieldLimitReason)
        )
    }
}

private func exampleFileDescriptor() -> Data {
    let state = enumDescriptor(
        name: "State",
        values: [("UNKNOWN", 0), ("ACTIVE", 1)]
    )
    let profile = messageDescriptor(
        name: "Profile",
        fields: [fieldDescriptor(name: "active", number: 1, type: 8)]
    )
    let user = messageDescriptor(
        name: "User",
        fields: [
            fieldDescriptor(name: "id", number: 1, type: 5),
            fieldDescriptor(name: "name", number: 2, type: 9),
            fieldDescriptor(name: "state", number: 3, type: 14, typeName: ".example.State"),
            fieldDescriptor(
                name: "profile",
                number: 4,
                type: 11,
                typeName: ".example.User.Profile"
            ),
            fieldDescriptor(name: "scores", number: 5, label: 3, type: 17, packed: true)
        ],
        nestedMessages: [profile]
    )
    return fileDescriptor(package: "example", messages: [user], enums: [state])
}

private func fileDescriptor(
    package: String,
    messages: [Data],
    enums: [Data] = []
) -> Data {
    var data = field(1, string: "example.proto")
    data.append(field(2, string: package))
    for message in messages {
        data.append(field(4, message: message))
    }
    for enumeration in enums {
        data.append(field(5, message: enumeration))
    }
    return data
}

private func messageDescriptor(
    name: String,
    fields: [Data] = [],
    nestedMessages: [Data] = [],
    enums: [Data] = []
) -> Data {
    var data = field(1, string: name)
    for fieldDescriptor in fields {
        data.append(field(2, message: fieldDescriptor))
    }
    for nestedMessage in nestedMessages {
        data.append(field(3, message: nestedMessage))
    }
    for enumeration in enums {
        data.append(field(4, message: enumeration))
    }
    return data
}

private func fieldDescriptor(
    name: String,
    number: Int,
    label: Int = 1,
    type: Int,
    typeName: String? = nil,
    packed: Bool = false
) -> Data {
    var data = field(1, string: name)
    data.append(field(3, varint: UInt64(number)))
    data.append(field(4, varint: UInt64(label)))
    data.append(field(5, varint: UInt64(type)))
    if let typeName {
        data.append(field(6, string: typeName))
    }
    if packed {
        data.append(field(8, message: field(2, varint: 1)))
    }
    return data
}

private func enumDescriptor(name: String, values: [(String, Int)]) -> Data {
    var data = field(1, string: name)
    for (valueName, number) in values {
        var value = field(1, string: valueName)
        value.append(field(2, varint: UInt64(UInt32(bitPattern: Int32(number)))))
        data.append(field(2, message: value))
    }
    return data
}

private func field(_ number: UInt64, string: String) -> Data {
    field(number, message: Data(string.utf8))
}

private func field(_ number: UInt64, message: Data) -> Data {
    var data = protobufVarint(number << 3 | 2)
    data.append(protobufVarint(UInt64(message.count)))
    data.append(message)
    return data
}

private func field(_ number: UInt64, varint: UInt64) -> Data {
    var data = protobufVarint(number << 3)
    data.append(protobufVarint(varint))
    return data
}

private func fixed32Field(_ number: UInt64, value: UInt32) -> Data {
    var data = protobufVarint(number << 3 | 5)
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    return data
}

private func fixed64Field(_ number: UInt64, value: UInt64) -> Data {
    var data = protobufVarint(number << 3 | 1)
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    return data
}

private func protobufVarint(_ value: UInt64) -> Data {
    var remaining = value
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(remaining & 0x7F)
        remaining >>= 7
        if remaining != 0 {
            byte |= 0x80
        }
        bytes.append(byte)
    } while remaining != 0
    return Data(bytes)
}
