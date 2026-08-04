import XCTest
@testable import ProxyLensCapture

final class ProxyLensCaptureTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(ProxyLensCaptureModule.self)
    }
}
