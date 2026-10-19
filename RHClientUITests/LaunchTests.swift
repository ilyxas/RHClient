import XCTest

final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTabBarShowsAllTabs() {
        let app = XCUIApplication()
        app.launch()
        for title in ["Home", "Chat", "Terminal", "Log", "Pages"] {
            XCTAssertTrue(app.tabBars.buttons[title].waitForExistence(timeout: 10), "missing tab \(title)")
        }
    }
}
