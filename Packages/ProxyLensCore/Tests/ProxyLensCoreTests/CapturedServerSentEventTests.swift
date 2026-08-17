import Foundation
import XCTest

@testable import ProxyLensCore

final class CapturedServerSentEventTests: XCTestCase {
    func testPreservesDerivedEventMetadataAndPayloadReference() throws {
        let data = BodyReference(
            inline: Data(#"{"status":"ready"}"#.utf8),
            metadata: BodyMetadata(
                contentType: "application/json",
                isTruncated: true
            )
        )
        let event = CapturedServerSentEvent(
            flowID: FlowID(
                rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            ),
            sequenceNumber: 7,
            eventType: "status",
            eventID: "cursor-42",
            retryMilliseconds: 1_500,
            data: data,
            receivedAt: Date(timeIntervalSince1970: 1_234)
        )

        XCTAssertEqual(event.sequenceNumber, 7)
        XCTAssertEqual(event.eventType, "status")
        XCTAssertEqual(event.eventID, "cursor-42")
        XCTAssertEqual(event.retryMilliseconds, 1_500)
        XCTAssertEqual(event.dataByteCount, Int64(data.inlineData?.count ?? 0))
        XCTAssertTrue(event.isDataTruncated)

        let encoded = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(CapturedServerSentEvent.self, from: encoded), event)
    }

    func testNormalizesInvalidSequenceRetryAndEmptyEventType() {
        let event = CapturedServerSentEvent(
            flowID: FlowID(),
            sequenceNumber: -1,
            eventType: "",
            retryMilliseconds: -10,
            data: BodyReference(inline: Data())
        )

        XCTAssertEqual(event.sequenceNumber, 0)
        XCTAssertEqual(event.eventType, "message")
        XCTAssertEqual(event.retryMilliseconds, 0)
    }
}
