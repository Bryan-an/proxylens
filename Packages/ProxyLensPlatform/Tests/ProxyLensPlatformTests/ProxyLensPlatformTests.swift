import XCTest
@testable import ProxyLensPlatform

final class ProxyLensPlatformTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(ProxyLensPlatformModule.self)
    }
}
