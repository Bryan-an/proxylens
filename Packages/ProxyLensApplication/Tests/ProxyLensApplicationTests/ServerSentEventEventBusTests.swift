import Foundation
import ProxyLensCore
import XCTest

@testable import ProxyLensApplication

final class ServerSentEventEventBusTests: XCTestCase {
    func testMulticastsCapturedEventsAndFinishesSubscriptions() async {
        let bus = ServerSentEventEventBus()
        let firstStream = await bus.events(bufferingPolicy: .unbounded)
        let secondStream = await bus.events(bufferingPolicy: .unbounded)
        let event = CapturedServerSentEvent(
            flowID: FlowID(),
            sequenceNumber: 1,
            eventType: "update",
            eventID: "42",
            retryMilliseconds: 1_000,
            data: BodyReference(inline: Data(#"{"value":1}"#.utf8)),
            receivedAt: Date(timeIntervalSince1970: 123)
        )

        await bus.publish(event)

        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()
        let firstEvent = await firstIterator.next()
        let secondEvent = await secondIterator.next()
        XCTAssertEqual(firstEvent, event)
        XCTAssertEqual(secondEvent, event)
        let subscriptionCount = await bus.subscriptionCount()
        XCTAssertEqual(subscriptionCount, 2)

        await bus.finish()
        let finishedSubscriptionCount = await bus.subscriptionCount()
        XCTAssertEqual(finishedSubscriptionCount, 0)
    }
}
