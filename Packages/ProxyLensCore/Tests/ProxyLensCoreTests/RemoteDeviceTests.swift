import Foundation
import XCTest

@testable import ProxyLensCore

final class RemoteDeviceTests: XCTestCase {
    private let seenAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testDeviceNormalizesItsAddressAndFallsBackToItForDisplay() {
        let device = RemoteDevice(address: "::ffff:192.168.1.7", firstSeenAt: seenAt)

        XCTAssertEqual(device.address, "192.168.1.7")
        XCTAssertEqual(device.id, "192.168.1.7")
        XCTAssertEqual(device.displayName, "192.168.1.7")
        XCTAssertFalse(device.isTrusted)
        XCTAssertEqual(device.firstSeenAt, seenAt)
        XCTAssertEqual(device.lastSeenAt, seenAt)
    }

    func testNamedDeviceDisplaysItsName() {
        let device = RemoteDevice(
            address: "192.168.1.7",
            name: "Test iPhone",
            isTrusted: true,
            firstSeenAt: seenAt,
            lastSeenAt: seenAt.addingTimeInterval(60)
        )

        XCTAssertEqual(device.displayName, "Test iPhone")
        XCTAssertTrue(device.isTrusted)
        XCTAssertEqual(device.lastSeenAt, seenAt.addingTimeInterval(60))
    }

    func testDeviceRoundTripsThroughCoding() throws {
        let device = RemoteDevice(
            address: "192.168.1.7",
            name: "Test iPhone",
            isTrusted: true,
            firstSeenAt: seenAt,
            lastSeenAt: seenAt
        )

        let encoded = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(RemoteDevice.self, from: encoded)

        XCTAssertEqual(decoded, device)
    }

    func testInMemoryStoreReturnsWhatItSaved() async {
        let store = InMemoryRemoteDeviceStore()
        let device = RemoteDevice(address: "192.168.1.7", firstSeenAt: seenAt)

        var loaded = await store.loadDevices()
        XCTAssertTrue(loaded.isEmpty)

        await store.save([device])
        loaded = await store.loadDevices()

        XCTAssertEqual(loaded, [device])
    }

    func testRemoteDeviceFlowSourceCarriesTheNormalizedAddress() {
        let source = FlowSource.remoteDevice(address: "::ffff:192.168.1.7", port: 51_000)

        XCTAssertEqual(source.kind, .remoteDevice)
        XCTAssertEqual(source.label, "192.168.1.7")
        XCTAssertEqual(source.clientAddress, "192.168.1.7:51000")
        XCTAssertNil(source.application)
    }

    func testRemoteDeviceFlowSourceKindSurvivesCoding() throws {
        let source = FlowSource.remoteDevice(address: "192.168.1.7", port: 51_000)

        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(FlowSource.self, from: encoded)

        XCTAssertEqual(decoded, source)
        XCTAssertEqual(FlowSourceKind(rawValue: "remoteDevice"), .remoteDevice)
    }
}
