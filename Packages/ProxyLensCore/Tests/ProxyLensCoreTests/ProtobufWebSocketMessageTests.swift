import Foundation
import XCTest

@testable import ProxyLensCore

final class ProtobufWebSocketMessageTests: XCTestCase {
    func testExplicitMessageRenderingDoesNotRequireAnHTTPMediaType() {
        XCTAssertEqual(
            ProtobufBodyView.renderMessage(
                data: Data([0x08, 0x2A])
            ),
            .decoded("1  varint   42")
        )
    }

    func testExplicitMessageRenderingAppliesTheSelectedSchema() {
        let schema = ProtobufMessageSchema(
            fullName: "example.User",
            fields: [
                ProtobufFieldSchema(
                    number: 1,
                    name: "id",
                    label: .optional,
                    type: .int32
                )
            ]
        )
        let catalog = ProtobufSchemaCatalog(messages: [schema], enumerations: [])

        guard
            case .decoded(let text) = ProtobufBodyView.renderMessage(
                data: Data([0x08, 0x96, 0x01]),
                schema: schema,
                catalog: catalog
            )
        else {
            return XCTFail("expected schema-aware explicit Protobuf rendering")
        }

        XCTAssertTrue(text.contains("1  id"))
        XCTAssertTrue(text.contains("int32"))
        XCTAssertTrue(text.contains("150"))
    }

    func testExplicitMessageRenderingKeepsTruncationAndSizeBounds() {
        XCTAssertEqual(
            ProtobufBodyView.renderMessage(data: Data([0x08])),
            .unavailable(
                reason: ProtobufBodyView.invalidProtobufReason("Varint is incomplete.")
            )
        )
        XCTAssertEqual(
            ProtobufBodyView.renderMessage(
                data: Data([0x08]),
                isTruncated: true
            ),
            .unavailable(reason: ProtobufBodyView.truncatedReason)
        )
        XCTAssertEqual(
            ProtobufBodyView.renderMessage(
                data: Data(repeating: 0, count: ProtobufBodyView.maximumDecodedByteCount + 1)
            ),
            .unavailable(reason: ProtobufBodyView.exceedsDisplayLimitReason)
        )
    }
}
