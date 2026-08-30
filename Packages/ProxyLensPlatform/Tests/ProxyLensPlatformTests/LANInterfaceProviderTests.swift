import Darwin
import Foundation
import ProxyLensCore
import XCTest

@testable import ProxyLensPlatform

final class LANInterfaceProviderTests: XCTestCase {
    private let up = UInt32(IFF_UP) | UInt32(IFF_RUNNING)

    func testAnOrdinaryEthernetOrWiFiInterfaceIsOffered() {
        XCTAssertTrue(
            LANInterfaceProvider.isUsable(name: "en0", flags: up, address: "192.168.1.7")
        )
        XCTAssertTrue(
            LANInterfaceProvider.isUsable(name: "en1", flags: up, address: "10.0.4.2")
        )
    }

    func testLoopbackAndUnusableInterfacesAreRejected() {
        XCTAssertFalse(
            LANInterfaceProvider.isUsable(name: "lo0", flags: up, address: "127.0.0.1"),
            "A device cannot reach this Mac over its loopback interface"
        )
        XCTAssertFalse(
            LANInterfaceProvider.isUsable(name: "en0", flags: up, address: "169.254.3.4"),
            "A self-assigned address means no working network"
        )
        XCTAssertFalse(
            LANInterfaceProvider.isUsable(name: "awdl0", flags: up, address: "192.168.1.7"),
            "AirDrop's interface is not a route a device can be pointed at"
        )
        XCTAssertFalse(
            LANInterfaceProvider.isUsable(name: "llw0", flags: up, address: "192.168.1.7")
        )
        XCTAssertFalse(
            LANInterfaceProvider.isUsable(name: "utun3", flags: up, address: "192.168.1.7"),
            "A tunnel is not the local network"
        )
    }

    func testAnInterfaceThatIsNotRunningIsRejected() {
        XCTAssertFalse(
            LANInterfaceProvider.isUsable(
                name: "en0",
                flags: UInt32(IFF_UP),
                address: "192.168.1.7"
            )
        )
        XCTAssertFalse(
            LANInterfaceProvider.isUsable(name: "en0", flags: 0, address: "192.168.1.7")
        )
    }

    func testEnumerationOnlyOffersAddressesADeviceCouldUse() {
        // This machine may legitimately have no LAN address, so only the shape is asserted.
        for interface in LANInterfaceProvider.current() {
            XCTAssertFalse(interface.name.isEmpty)
            XCTAssertFalse(NetworkAddress.isLoopback(interface.address))
            XCTAssertTrue(
                LANInterfaceProvider.isUsable(
                    name: interface.name,
                    flags: up,
                    address: interface.address
                )
            )
        }
    }

    func testRemoteClientsAreAttributedToADeviceWithoutAProcessLookup() async {
        let locator = FailingSocketLocator()
        let resolver = MacOSFlowSourceResolver(
            socketLocator: locator,
            applicationInspector: FailingApplicationInspector()
        )

        let source = await resolver.resolveSource(
            clientEndpoint: NetworkEndpoint(host: "192.168.1.7", port: 51_000),
            proxyEndpoint: NetworkEndpoint(host: "192.168.1.5", port: 9_090)
        )

        XCTAssertEqual(source.kind, .remoteDevice)
        XCTAssertEqual(source.label, "192.168.1.7")
        XCTAssertEqual(source.clientAddress, "192.168.1.7:51000")
        XCTAssertNil(source.application)
        XCTAssertFalse(
            locator.wasCalled,
            "A remote peer has no local process, so the lookup must be skipped"
        )
    }

    func testLocalClientsStillGetProcessAttribution() async {
        let resolver = MacOSFlowSourceResolver(
            socketLocator: StubSocketLocator(processIdentifier: 4_242),
            applicationInspector: StubApplicationInspector(
                application: FlowApplication(name: "Test Browser")
            )
        )

        let source = await resolver.resolveSource(
            clientEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 51_000),
            proxyEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090)
        )

        XCTAssertEqual(source.kind, .desktopProxy)
        XCTAssertEqual(source.label, "Test Browser")
        XCTAssertEqual(source.application?.name, "Test Browser")
    }
}

private final class FailingSocketLocator: ProcessSocketLocating, @unchecked Sendable {
    private(set) var wasCalled = false

    func processIdentifier(clientPort _: UInt16, proxyPort _: UInt16) -> pid_t? {
        wasCalled = true
        return nil
    }
}

private struct FailingApplicationInspector: ProcessApplicationInspecting {
    func application(processIdentifier _: pid_t) -> FlowApplication? {
        nil
    }
}

private struct StubSocketLocator: ProcessSocketLocating {
    let processIdentifier: pid_t

    func processIdentifier(clientPort _: UInt16, proxyPort _: UInt16) -> pid_t? {
        processIdentifier
    }
}

private struct StubApplicationInspector: ProcessApplicationInspecting {
    let application: FlowApplication

    func application(processIdentifier _: pid_t) -> FlowApplication? {
        application
    }
}
