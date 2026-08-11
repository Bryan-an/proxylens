import XCTest

final class ProxyLensUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTrafficConsoleShowsNativeThreePaneWorkspace() {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["capture.toggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.outlines["traffic.sources"].exists)
        XCTAssertTrue(app.tables["traffic.flows"].exists)
        XCTAssertTrue(app.textViews["inspector.content"].exists)
        XCTAssertTrue(app.staticTexts["All Traffic"].exists)
        XCTAssertTrue(app.staticTexts["Domains"].exists)
        XCTAssertTrue(app.staticTexts["No traffic captured yet"].exists)

        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "ProxyLens traffic console"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
