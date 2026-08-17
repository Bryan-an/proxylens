import Foundation
import XCTest

@testable import ProxyLensCore

final class ProtobufTransportFramingTests: XCTestCase {
    func testDelimitedContentTypeRendersEveryMessage() {
        let body = delimited([
            Data([0x08, 0x2A]),
            Data([0x12, 0x03, 0x41, 0x64, 0x61])
        ])

        let result = ProtobufBodyView.render(
            data: body,
            contentType: #"Application/X-Protobuf; charset=binary; DELIMITED="true""#,
            contentEncoding: nil
        )

        guard case .decoded(let text) = result else {
            return XCTFail("expected delimited Protobuf messages, got \(result)")
        }
        XCTAssertTrue(text.contains("Message 1 · 2 B · delimited"))
        XCTAssertTrue(text.contains("1  varint   42"))
        XCTAssertTrue(text.contains("Message 2 · 5 B · delimited"))
        XCTAssertTrue(text.contains("2  string   \"Ada\""))
    }

    func testDelimitedContentTypeAppliesSchemaToEveryMessage() {
        let schema = ProtobufMessageSchema(
            fullName: "example.Item",
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

        let result = ProtobufBodyView.render(
            data: delimited([Data([0x08, 0x01]), Data([0x08, 0x02])]),
            contentType: "application/protobuf; delimited=true",
            contentEncoding: nil,
            schema: schema,
            catalog: catalog
        )

        guard case .decoded(let text) = result else {
            return XCTFail("expected schema-aware delimited messages, got \(result)")
        }
        XCTAssertEqual(text.components(separatedBy: "1  id").count - 1, 2)
        XCTAssertTrue(text.contains("int32"))
    }

    func testDelimitedContentTypeRejectsMalformedPrefixesAndPayloads() {
        let malformedBodies = [
            Data([0x80]),
            Data([0x80, 0x80, 0x80, 0x80, 0x10]),
            Data([0x03, 0x08, 0x01])
        ]

        for body in malformedBodies {
            let result = ProtobufBodyView.render(
                data: body,
                contentType: "application/protobuf; delimited=true",
                contentEncoding: nil
            )
            guard case .unavailable(let reason) = result else {
                return XCTFail("expected malformed delimited stream rejection, got \(result)")
            }
            XCTAssertTrue(reason.hasPrefix("Invalid Protobuf:"))
        }
    }

    func testDelimitedContentTypeBoundsMessageCountAndDoesNotChangeSingleMessageMode() {
        let emptyMessages = Array(
            repeating: Data(),
            count: ProtobufBodyView.maximumGRPCMessageCount + 1
        )
        let bounded = ProtobufBodyView.render(
            data: delimited(emptyMessages),
            contentType: "application/protobuf; delimited=true",
            contentEncoding: nil
        )
        guard case .unavailable(let boundedReason) = bounded else {
            return XCTFail("expected a delimited message-count limit, got \(bounded)")
        }
        XCTAssertTrue(boundedReason.contains("1,000-message"))

        let oneDelimitedMessage = delimited([Data([0x08, 0x01])])
        let singleMessageResult = ProtobufBodyView.render(
            data: oneDelimitedMessage,
            contentType: "application/protobuf; delimited=false",
            contentEncoding: nil
        )
        guard case .unavailable(let reason) = singleMessageResult else {
            return XCTFail("expected ordinary single-message parsing, got \(singleMessageResult)")
        }
        XCTAssertTrue(reason.hasPrefix("Invalid Protobuf:"))
    }

    func testBinaryGRPCWebRendersSchemaAwareDataAndTerminalTrailers() {
        let schema = ProtobufMessageSchema(
            fullName: "example.Reply",
            fields: [
                ProtobufFieldSchema(
                    number: 1,
                    name: "answer",
                    label: .optional,
                    type: .int32
                )
            ]
        )
        let catalog = ProtobufSchemaCatalog(messages: [schema], enumerations: [])
        var body = grpcWebFrame(flag: 0x00, payload: Data([0x08, 0x2A]))
        body.append(
            grpcWebFrame(
                flag: 0x80,
                payload: Data("grpc-status: 0\r\ngrpc-message: OK".utf8)
            )
        )

        let result = ProtobufBodyView.render(
            data: body,
            contentType: "application/grpc-web+proto",
            contentEncoding: nil,
            schema: schema,
            catalog: catalog
        )

        guard case .decoded(let text) = result else {
            return XCTFail("expected binary gRPC-Web output, got \(result)")
        }
        XCTAssertTrue(text.contains("Message 1 · 2 B · uncompressed"))
        XCTAssertTrue(text.contains("1  answer"))
        XCTAssertTrue(text.contains("int32"))
        XCTAssertTrue(text.contains("42"))
        XCTAssertTrue(text.contains("Trailers · 32 B"))
        XCTAssertTrue(text.contains("grpc-status: 0"))
        XCTAssertTrue(text.contains("grpc-message: OK"))
    }

    func testTextGRPCWebDecodesWholeAndIndependentlyPaddedBase64Chunks() {
        let first = grpcWebFrame(flag: 0x00, payload: Data([0x08, 0x01]))
        let second = grpcWebFrame(flag: 0x00, payload: Data([0x08, 0x02]))
        let concatenatedChunks =
            " \n" + first.base64EncodedString() + "\r\n" + second.base64EncodedString() + "\t"

        let chunkedResult = ProtobufBodyView.render(
            data: Data(concatenatedChunks.utf8),
            contentType: "application/grpc-web-text+proto",
            contentEncoding: nil
        )
        guard case .decoded(let chunkedText) = chunkedResult else {
            return XCTFail("expected chunked text gRPC-Web output, got \(chunkedResult)")
        }
        XCTAssertTrue(chunkedText.contains("Message 1 · 2 B · uncompressed"))
        XCTAssertTrue(chunkedText.contains("1  varint   1"))
        XCTAssertTrue(chunkedText.contains("Message 2 · 2 B · uncompressed"))
        XCTAssertTrue(chunkedText.contains("1  varint   2"))

        var binary = first
        binary.append(second)
        let wholeResult = ProtobufBodyView.render(
            data: Data(binary.base64EncodedString().utf8),
            contentType: "application/grpc-web-text",
            contentEncoding: nil
        )
        guard case .decoded(let wholeText) = wholeResult else {
            return XCTFail("expected whole text gRPC-Web output, got \(wholeResult)")
        }
        XCTAssertTrue(wholeText.contains("Message 2 · 2 B · uncompressed"))
    }

    func testGRPCWebRejectsMalformedBase64FramesAndTrailerOrdering() {
        var dataAfterTrailers = grpcWebFrame(
            flag: 0x80,
            payload: Data("grpc-status: 0".utf8)
        )
        dataAfterTrailers.append(grpcWebFrame(flag: 0x00, payload: Data([0x08, 0x01])))

        let cases: [(Data, String)] = [
            (Data("%%%=".utf8), "application/grpc-web-text"),
            (Data([0x02, 0, 0, 0, 0]), "application/grpc-web+proto"),
            (Data([0x00, 0, 0, 0, 2, 0x08]), "application/grpc-web"),
            (dataAfterTrailers, "application/grpc-web+proto"),
            (
                grpcWebFrame(flag: 0x80, payload: Data([0x67, 0x72, 0x70, 0x63, 0x00])),
                "application/grpc-web"
            )
        ]

        for (body, contentType) in cases {
            let result = ProtobufBodyView.render(
                data: body,
                contentType: contentType,
                contentEncoding: nil
            )
            guard case .unavailable(let reason) = result else {
                return XCTFail("expected malformed gRPC-Web rejection, got \(result)")
            }
            XCTAssertTrue(reason.hasPrefix("Invalid Protobuf:"))
        }
    }

    func testGRPCWebSummarizesCompressedFramesWithoutGuessingAnEncoding() {
        var body = grpcWebFrame(flag: 0x01, payload: Data([0xDE, 0xAD]))
        body.append(grpcWebFrame(flag: 0x81, payload: Data([0xBE, 0xEF])))

        let result = ProtobufBodyView.render(
            data: body,
            contentType: "application/grpc-web+proto",
            contentEncoding: nil,
            grpcEncoding: "gzip"
        )

        guard case .decoded(let text) = result else {
            return XCTFail("expected compressed-frame summaries, got \(result)")
        }
        XCTAssertTrue(text.contains("Message 1 · 2 B · compressed"))
        XCTAssertTrue(text.contains("Compressed gRPC-Web payload omitted"))
        XCTAssertTrue(text.contains("Trailers · 2 B · compressed"))
        XCTAssertTrue(text.contains("Compressed gRPC-Web trailers omitted"))
    }

    func testGRPCWebBoundsDataMessageCount() {
        var body = Data()
        for _ in 0...ProtobufBodyView.maximumGRPCMessageCount {
            body.append(grpcWebFrame(flag: 0x00, payload: Data()))
        }
        XCTAssertEqual(
            ProtobufBodyView.render(
                data: body,
                contentType: "application/grpc-web+proto",
                contentEncoding: nil
            ),
            .unavailable(reason: ProtobufBodyView.grpcMessageLimitReason)
        )
    }

    private func delimited(_ messages: [Data]) -> Data {
        var body = Data()
        for message in messages {
            appendVarint(UInt64(message.count), to: &body)
            body.append(message)
        }
        return body
    }

    private func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    private func grpcWebFrame(flag: UInt8, payload: Data) -> Data {
        var frame = Data([flag])
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}
