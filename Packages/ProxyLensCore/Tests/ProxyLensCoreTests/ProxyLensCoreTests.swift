import XCTest
@testable import ProxyLensCore

final class ProxyLensCoreTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(ProxyLensCoreModule.self)
    }
}
