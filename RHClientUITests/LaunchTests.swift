import XCTest

final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A fresh install opens on pairing; a paired one on the tab bar with every tab.
    @MainActor
    func testLaunchShowsPairingOrTabBar() {
        let app = XCUIApplication()
        app.launch()
        let pairing = app.navigationBars["Pair with your Mac"]
        let home = app.tabBars.buttons["Home"]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !pairing.exists, !home.exists {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if pairing.exists { return }
        for title in ["Home", "Chat", "Terminal", "Log", "Pages"] {
            XCTAssertTrue(app.tabBars.buttons[title].waitForExistence(timeout: 10), "missing tab \(title)")
        }
    }
}
