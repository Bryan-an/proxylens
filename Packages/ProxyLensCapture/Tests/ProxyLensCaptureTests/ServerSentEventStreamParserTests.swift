import Foundation
import XCTest

@testable import ProxyLensCapture

final class ServerSentEventStreamParserTests: XCTestCase {
    func testParsesFragmentedMultilineEventsAndPersistsIDAndRetry() {
        let receivedAt = Date(timeIntervalSince1970: 1_789_000_000)
        var parser = ServerSentEventStreamParser()

        XCTAssertEqual(parser.append(Data([0xEF, 0xBB]), receivedAt: receivedAt), [])
        XCTAssertEqual(
            parser.append(
                Data(
                    [0xBF]
                        + Array("id: 42\r\nretry: 1500\r\nevent: update\r\ndata: first".utf8)),
                receivedAt: receivedAt
            ),
            []
        )
        let events = parser.append(
            Data(" line\ndata: second line\n\n".utf8),
            receivedAt: receivedAt
        )

        XCTAssertEqual(
            events,
            [
                ParsedServerSentEvent(
                    eventType: "update",
                    eventID: "42",
                    retryMilliseconds: 1_500,
                    data: Data("first line\nsecond line".utf8),
                    isDataTruncated: false,
                    receivedAt: receivedAt
                )
            ]
        )

        XCTAssertEqual(
            parser.append(Data("data: next\n\n".utf8), receivedAt: receivedAt),
            [
                ParsedServerSentEvent(
                    eventType: "message",
                    eventID: "42",
                    retryMilliseconds: 1_500,
                    data: Data("next".utf8),
                    isDataTruncated: false,
                    receivedAt: receivedAt
                )
            ]
        )
    }

    func testIgnoresCommentsUnknownFieldsAndInvalidRetryThenDispatchesAtEOF() {
        let receivedAt = Date(timeIntervalSince1970: 1_789_000_001)
        var parser = ServerSentEventStreamParser()

        XCTAssertEqual(
            parser.append(
                Data(": heartbeat\runknown: value\rretry: 1.5\rdata\r".utf8),
                receivedAt: receivedAt
            ),
            []
        )

        XCTAssertEqual(
            parser.finish(receivedAt: receivedAt),
            [
                ParsedServerSentEvent(
                    eventType: "message",
                    eventID: nil,
                    retryMilliseconds: nil,
                    data: Data(),
                    isDataTruncated: false,
                    receivedAt: receivedAt
                )
            ]
        )
    }

    func testBoundsOversizedDataAndRecoversForTheNextEvent() {
        let receivedAt = Date(timeIntervalSince1970: 1_789_000_002)
        var parser = ServerSentEventStreamParser(
            maximumLineBytes: 12,
            maximumEventDataBytes: 5
        )

        let events = parser.append(
            Data("data: abcdefghijklmnopqrstuvwxyz\n\ndata: ok\n\n".utf8),
            receivedAt: receivedAt
        )

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].data, Data("abcde".utf8))
        XCTAssertTrue(events[0].isDataTruncated)
        XCTAssertEqual(events[1].data, Data("ok".utf8))
        XCTAssertFalse(events[1].isDataTruncated)
    }
}
