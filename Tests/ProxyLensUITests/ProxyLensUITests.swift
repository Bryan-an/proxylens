import XCTest

@MainActor
final class ProxyLensUITests: XCTestCase {
    private var storageRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let storageRoot {
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }

    func testTrafficConsoleShowsNativeThreePaneWorkspace() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-ProxyLensStorageRoot", storageRoot.path
        ]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["capture.toggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["session.clear"].exists)
        XCTAssertTrue(app.buttons["certificate.trust"].exists)
        let sourceToggle = app.buttons["sourceList.toggle"]
        XCTAssertTrue(sourceToggle.exists)
        XCTAssertEqual(sourceToggle.label, "Hide Source List")
        XCTAssertTrue(app.searchFields["traffic.search"].exists)
        XCTAssertTrue(app.popUpButtons["traffic.filter.method"].exists)
        XCTAssertTrue(app.popUpButtons["traffic.filter.status"].exists)
        XCTAssertTrue(app.popUpButtons["traffic.filter.contentType"].exists)
        XCTAssertTrue(app.popUpButtons["traffic.filter.source"].exists)
        XCTAssertTrue(app.buttons["traffic.filter.clear"].exists)
        XCTAssertTrue(app.outlines["traffic.sources"].exists)
        XCTAssertTrue(app.tables["traffic.flows"].exists)
        XCTAssertTrue(app.textViews["inspector.request.content"].exists)
        XCTAssertTrue(app.textViews["inspector.response.content"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["inspector.request.section"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["inspector.response.section"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["inspector.split.messages"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["inspector.mode"].exists)
        XCTAssertTrue(app.staticTexts["All Traffic"].exists)
        XCTAssertTrue(app.staticTexts["Domains"].exists)
        XCTAssertTrue(app.staticTexts["No traffic captured yet"].exists)

        sourceToggle.click()
        XCTAssertEqual(sourceToggle.label, "Show Source List")
        sourceToggle.click()
        XCTAssertEqual(sourceToggle.label, "Hide Source List")

        let searchField = app.searchFields["traffic.search"]
        searchField.click()
        typeText("api.example.com", into: searchField)
        XCTAssertEqual(searchField.value as? String, "api.example.com")

        let clearButton = app.buttons["traffic.filter.clear"]
        let clearEnabled = expectation(
            for: NSPredicate(format: "enabled == true"), evaluatedWith: clearButton)
        wait(for: [clearEnabled], timeout: 2)
        clearButton.click()
        XCTAssertEqual(searchField.value as? String, "")

        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "ProxyLens traffic console"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    private func typeText(_ text: String, into element: XCUIElement) {
        for character in text {
            element.typeKey(String(character), modifierFlags: [])
        }
    }

}
