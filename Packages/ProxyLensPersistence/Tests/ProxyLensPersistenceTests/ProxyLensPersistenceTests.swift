import XCTest
@testable import ProxyLensPersistence

final class ProxyLensPersistenceTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(ProxyLensPersistenceModule.self)
    }
}
