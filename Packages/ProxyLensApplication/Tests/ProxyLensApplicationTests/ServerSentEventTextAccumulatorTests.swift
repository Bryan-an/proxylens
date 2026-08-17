import Foundation
import XCTest

@testable import ProxyLensApplication

final class ServerSentEventTextAccumulatorTests: XCTestCase {
    func testAccumulatesOpenAIChatCompletionsAndResponsesTextDeltas() {
        var accumulator = ServerSentEventTextAccumulator(
            maximumOutputBytes: 1_024,
            maximumEventDataBytes: 1_024
        )

        accumulator.consume(
            eventType: "message",
            data: Data(#"{"choices":[{"delta":{"content":"Hello "}}]}"#.utf8)
        )
        accumulator.consume(
            eventType: "response.output_text.delta",
            data: Data(
                #"{"type":"response.output_text.delta","delta":"world"}"#.utf8
            )
        )
        accumulator.consume(eventType: "message", data: Data("[DONE]".utf8))

        XCTAssertEqual(accumulator.preview.text, "Hello world")
        XCTAssertEqual(accumulator.preview.contributingEventCount, 2)
        XCTAssertEqual(accumulator.preview.terminalEventCount, 1)
        XCTAssertEqual(accumulator.preview.ignoredEventCount, 0)
        XCTAssertEqual(accumulator.preview.skippedOversizedEventCount, 0)
        XCTAssertFalse(accumulator.preview.isTruncated)
    }

    func testAccumulatesArrayBasedChatContentWithoutDuplicatingUnknownEvents() {
        var accumulator = ServerSentEventTextAccumulator(
            maximumOutputBytes: 1_024,
            maximumEventDataBytes: 1_024
        )

        accumulator.consume(
            eventType: "message",
            data: Data(
                #"{"choices":[{"delta":{"content":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}}]}"#
                    .utf8
            )
        )
        accumulator.consume(
            eventType: "telemetry",
            data: Data(#"{"usage":{"input_tokens":12}}"#.utf8)
        )
        accumulator.consume(eventType: "message", data: Data("not json".utf8))

        XCTAssertEqual(accumulator.preview.text, "AB")
        XCTAssertEqual(accumulator.preview.contributingEventCount, 1)
        XCTAssertEqual(accumulator.preview.ignoredEventCount, 2)
    }

    func testBoundsEventInputAndOutputAtAValidUTF8Boundary() {
        var accumulator = ServerSentEventTextAccumulator(
            maximumOutputBytes: 5,
            maximumEventDataBytes: 80
        )

        accumulator.consume(
            eventType: "response.output_text.delta",
            data: Data(#"{"delta":"éabcd"}"#.utf8)
        )
        accumulator.consume(
            eventType: "response.output_text.delta",
            data: Data(repeating: 0x61, count: 81)
        )

        XCTAssertEqual(accumulator.preview.text, "éabc")
        XCTAssertEqual(Data(accumulator.preview.text.utf8).count, 5)
        XCTAssertEqual(accumulator.preview.contributingEventCount, 1)
        XCTAssertEqual(accumulator.preview.skippedOversizedEventCount, 1)
        XCTAssertTrue(accumulator.preview.isTruncated)
    }
}
