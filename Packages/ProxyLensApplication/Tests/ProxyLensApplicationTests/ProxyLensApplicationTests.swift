import XCTest
@testable import ProxyLensApplication

final class ProxyLensApplicationTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(ProxyLensApplicationModule.self)
    }
}
