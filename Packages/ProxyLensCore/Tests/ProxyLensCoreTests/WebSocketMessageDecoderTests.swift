import Foundation
import XCTest

@testable import ProxyLensCore

final class WebSocketMessageDecoderTests: XCTestCase {
    func testReconstructsFragmentedMessageAroundInterleavedControlFrame() throws {
        let frames = [
            frame(sequence: 1, opcode: .text, isFinal: false, payload: "Hel"),
            frame(sequence: 2, opcode: .ping, isFinal: true, payload: "?"),
            frame(sequence: 3, opcode: .continuation, isFinal: true, payload: "lo")
        ]

        let message = try decoded(
            WebSocketMessageDecoder.decode(
                selectedFrameID: frames[0].id,
                frames: frames,
                acceptedExtensions: []
            )
        )

        XCTAssertEqual(message.payload, Data("Hello".utf8))
        XCTAssertEqual(message.opcode, .text)
        XCTAssertEqual(message.frameIDs, [frames[0].id, frames[2].id])
        XCTAssertEqual(message.firstSequenceNumber, 1)
        XCTAssertEqual(message.lastSequenceNumber, 3)
        XCTAssertFalse(message.isCompressed)
        XCTAssertTrue(message.isFragmented)
    }

    func testReconstructsMessagesIndependentlyByDirection() throws {
        let clientStart = frame(
            sequence: 1,
            direction: .clientToServer,
            opcode: .text,
            isFinal: false,
            payload: "cli"
        )
        let serverStart = frame(
            sequence: 2,
            direction: .serverToClient,
            opcode: .text,
            isFinal: false,
            payload: "ser"
        )
        let clientEnd = frame(
            sequence: 3,
            direction: .clientToServer,
            opcode: .continuation,
            isFinal: true,
            payload: "ent"
        )
        let serverEnd = frame(
            sequence: 4,
            direction: .serverToClient,
            opcode: .continuation,
            isFinal: true,
            payload: "ver"
        )

        let message = try decoded(
            WebSocketMessageDecoder.decode(
                selectedFrameID: serverStart.id,
                frames: [clientStart, serverStart, clientEnd, serverEnd],
                acceptedExtensions: []
            )
        )

        XCTAssertEqual(message.payload, Data("server".utf8))
        XCTAssertEqual(message.frameIDs, [serverStart.id, serverEnd.id])
        XCTAssertEqual(message.direction, .serverToClient)
    }

    func testDecompressesRFC7692FragmentedMessage() throws {
        let first = frame(
            sequence: 1,
            opcode: .text,
            isFinal: false,
            reservedBits: .rsv1,
            payload: Data([0xF2, 0x48, 0xCD])
        )
        let last = frame(
            sequence: 2,
            opcode: .continuation,
            isFinal: true,
            payload: Data([0xC9, 0xC9, 0x07, 0x00])
        )

        let message = try decoded(
            WebSocketMessageDecoder.decode(
                selectedFrameID: last.id,
                frames: [first, last],
                acceptedExtensions: ["permessage-deflate"]
            )
        )

        XCTAssertEqual(message.payload, Data("Hello".utf8))
        XCTAssertEqual(message.wirePayloadByteCount, 7)
        XCTAssertTrue(message.isCompressed)
        XCTAssertTrue(message.isFragmented)
    }

    func testReplaysCompressedHistoryForContextTakeover() throws {
        let first = frame(
            sequence: 1,
            opcode: .text,
            reservedBits: .rsv1,
            payload: Data([0xF2, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00])
        )
        let second = frame(
            sequence: 2,
            opcode: .text,
            reservedBits: .rsv1,
            payload: Data([0xF2, 0x00, 0x11, 0x00, 0x00])
        )

        let message = try decoded(
            WebSocketMessageDecoder.decode(
                selectedFrameID: second.id,
                frames: [first, second],
                acceptedExtensions: ["permessage-deflate"]
            )
        )

        XCTAssertEqual(message.payload, Data("Hello".utf8))
    }

    func testHonorsNoContextTakeoverAndDirectionalWindowParameters() throws {
        let configuration = try XCTUnwrap(
            WebSocketPerMessageDeflateConfiguration.parse(
                acceptedExtensions: [
                    "permessage-deflate; client_no_context_takeover; "
                        + "server_no_context_takeover; client_max_window_bits=10; "
                        + "server_max_window_bits=12"
                ]
            )
        )
        XCTAssertTrue(configuration.clientNoContextTakeover)
        XCTAssertTrue(configuration.serverNoContextTakeover)
        XCTAssertEqual(configuration.clientMaxWindowBits, 10)
        XCTAssertEqual(configuration.serverMaxWindowBits, 12)

        let independent = frame(
            sequence: 1,
            direction: .serverToClient,
            opcode: .text,
            reservedBits: .rsv1,
            payload: Data([0xF2, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00])
        )
        let message = try decoded(
            WebSocketMessageDecoder.decode(
                selectedFrameID: independent.id,
                frames: [independent],
                acceptedExtensions: [
                    "permessage-deflate; server_no_context_takeover; "
                        + "server_max_window_bits=12"
                ]
            )
        )
        XCTAssertEqual(message.payload, Data("Hello".utf8))

        let historyDependent = frame(
            sequence: 2,
            opcode: .text,
            reservedBits: .rsv1,
            payload: Data([0xF2, 0x00, 0x11, 0x00, 0x00])
        )
        assertUnavailable(
            WebSocketMessageDecoder.decode(
                selectedFrameID: historyDependent.id,
                frames: [historyDependent],
                acceptedExtensions: [
                    "permessage-deflate; client_no_context_takeover"
                ]
            ),
            containing: "decompress"
        )
    }

    func testRejectsInvalidNegotiationAndProtocolSequences() {
        XCTAssertThrowsError(
            try WebSocketPerMessageDeflateConfiguration.parse(
                acceptedExtensions: [
                    "x-example;; value=1, permessage-deflate"
                ]
            )
        )
        XCTAssertThrowsError(
            try WebSocketPerMessageDeflateConfiguration.parse(
                acceptedExtensions: [
                    "permessage-deflate; client_max_window_bits=16"
                ]
            )
        )
        XCTAssertThrowsError(
            try WebSocketPerMessageDeflateConfiguration.parse(
                acceptedExtensions: [
                    "permessage-deflate; client_no_context_takeover; "
                        + "client_no_context_takeover"
                ]
            )
        )
        XCTAssertThrowsError(
            try WebSocketPerMessageDeflateConfiguration.parse(
                acceptedExtensions: ["permessage-deflate; unknown=1"]
            )
        )
        XCTAssertThrowsError(
            try WebSocketPerMessageDeflateConfiguration.parse(
                acceptedExtensions: [
                    "permessage-deflate; client_max_window_bits=\u{0661}\u{0665}"
                ]
            )
        )

        XCTAssertEqual(
            try WebSocketPerMessageDeflateConfiguration.parse(
                acceptedExtensions: [
                    #"permessage-deflate; client_max_window_bits="1\5""#
                ]
            )?.clientMaxWindowBits,
            15
        )

        let orphan = frame(
            sequence: 1,
            opcode: .continuation,
            payload: "orphan"
        )
        assertUnavailable(
            WebSocketMessageDecoder.decode(
                selectedFrameID: orphan.id,
                frames: [orphan],
                acceptedExtensions: []
            ),
            containing: "continuation"
        )

        let encodedWithoutNegotiation = frame(
            sequence: 1,
            opcode: .text,
            reservedBits: .rsv1,
            payload: Data([0xF2, 0x48])
        )
        assertUnavailable(
            WebSocketMessageDecoder.decode(
                selectedFrameID: encodedWithoutNegotiation.id,
                frames: [encodedWithoutNegotiation],
                acceptedExtensions: []
            ),
            containing: "not negotiated"
        )
    }

    func testRejectsTruncatedIncompleteAndOversizedMessages() {
        let truncated = frame(
            sequence: 1,
            opcode: .binary,
            payload: Data([0x08, 0x2A]),
            isPayloadTruncated: true
        )
        assertUnavailable(
            WebSocketMessageDecoder.decode(
                selectedFrameID: truncated.id,
                frames: [truncated],
                acceptedExtensions: []
            ),
            containing: "truncated"
        )

        let incomplete = frame(
            sequence: 1,
            opcode: .text,
            isFinal: false,
            payload: "incomplete"
        )
        assertUnavailable(
            WebSocketMessageDecoder.decode(
                selectedFrameID: incomplete.id,
                frames: [incomplete],
                acceptedExtensions: []
            ),
            containing: "incomplete"
        )

        let oversized = frame(
            sequence: 1,
            opcode: .text,
            payload: "12345"
        )
        assertUnavailable(
            WebSocketMessageDecoder.decode(
                selectedFrameID: oversized.id,
                frames: [oversized],
                acceptedExtensions: [],
                limits: .init(
                    maximumFrameCount: 10,
                    maximumInputByteCount: 4,
                    maximumMessageOutputByteCount: 4,
                    maximumHistoryOutputByteCount: 8
                )
            ),
            containing: "limit"
        )
    }

    private func decoded(
        _ result: WebSocketMessageDecodingResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DecodedWebSocketMessage {
        guard case .decoded(let message) = result else {
            XCTFail("expected decoded message, got \(result)", file: file, line: line)
            throw CocoaError(.coderInvalidValue)
        }
        return message
    }

    private func assertUnavailable(
        _ result: WebSocketMessageDecodingResult,
        containing expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(let reason) = result else {
            return XCTFail("expected unavailable result, got \(result)", file: file, line: line)
        }
        XCTAssertTrue(
            reason.localizedCaseInsensitiveContains(expected),
            "\(reason) does not contain \(expected)",
            file: file,
            line: line
        )
    }

    private func frame(
        sequence: Int64,
        direction: WebSocketFrameDirection = .clientToServer,
        opcode: WebSocketFrameOpcode,
        isFinal: Bool = true,
        reservedBits: WebSocketReservedBits = [],
        payload: Data,
        isPayloadTruncated: Bool = false
    ) -> WebSocketMessageFrameInput {
        WebSocketMessageFrameInput(
            sequenceNumber: sequence,
            direction: direction,
            opcode: opcode,
            isFinal: isFinal,
            reservedBits: reservedBits,
            payload: payload,
            isPayloadTruncated: isPayloadTruncated
        )
    }

    private func frame(
        sequence: Int64,
        direction: WebSocketFrameDirection = .clientToServer,
        opcode: WebSocketFrameOpcode,
        isFinal: Bool = true,
        reservedBits: WebSocketReservedBits = [],
        payload: String,
        isPayloadTruncated: Bool = false
    ) -> WebSocketMessageFrameInput {
        frame(
            sequence: sequence,
            direction: direction,
            opcode: opcode,
            isFinal: isFinal,
            reservedBits: reservedBits,
            payload: Data(payload.utf8),
            isPayloadTruncated: isPayloadTruncated
        )
    }
}
