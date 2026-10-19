import XCTest

/// Stage 2 against the dev core with the RHServer fixture `tests/fixtures/stage2`
/// (fixed metrics and a fictional team), started by scripts/test.sh: Home shows live
/// data, Last Activity → Log, Log filters and search.
final class HomeLogTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeAndLog() throws {
        let path = try pairingFile()
        let app = XCUIApplication()
        // Used only when this simulator is not paired yet (another test may have paired it).
        app.launchArguments = ["-RHPairing", try currentPairing(path)]
        app.launch()

        XCTAssertTrue(waitFor(app.staticTexts["home.connection"], label: "Connected · Secure session", timeout: 90))

        if ProcessInfo.processInfo.environment["RH_FIXTURE"] == "stage2" {
            // tests/fixtures/stage2/system.json: 38.4 %, 61.2 %, 112400000000 bytes free.
            XCTAssertTrue(waitFor(metric(app, "sys.cpu"), value: "38%", timeout: 30))
            XCTAssertTrue(waitFor(metric(app, "sys.memory"), value: "61%", timeout: 5))
            XCTAssertTrue(waitFor(metric(app, "sys.disk_free"), value: "112 GB free", timeout: 5))
            // tests/fixtures/stage2/team.md: no status rules in dev, so every agent is unknown.
            let alpha = app.descendants(matching: .any)["home.agent.Agent-Alpha"].firstMatch
            XCTAssertTrue(waitFor(alpha, timeout: 5))
            XCTAssertTrue(alpha.label.contains("unknown"), alpha.label)
        } else {
            XCTAssertTrue(waitFor(metric(app, "sys.cpu"), timeout: 30))
        }
        XCTAssertTrue(app.descendants(matching: .any)["home.attention"].firstMatch.exists)

        // Last Activity has this phone's pairing; View all opens the Log tab.
        let paired = NSPredicate(format: "label BEGINSWITH 'Paired'")
        XCTAssertTrue(waitFor(app.descendants(matching: .any).matching(paired).firstMatch, timeout: 10))
        app.buttons["home.activity.all"].tap()

        let entry = app.descendants(matching: .any).matching(identifier: "log.entry").firstMatch
        XCTAssertTrue(waitFor(entry, timeout: 30), "no Log entries")

        app.buttons["log.filter.commands"].tap()
        XCTAssertTrue(waitFor(app.descendants(matching: .any).matching(identifier: "log.entry").matching(paired).firstMatch, timeout: 30))

        app.buttons["log.filter.chat"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["No entries"], timeout: 30), "chat arrives at stage 3, the feed is empty")

        app.buttons["log.filter.all"].tap()
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("no-such-entry-xyz")
        XCTAssertTrue(waitFor(app.staticTexts["No Results for “no-such-entry-xyz”"], timeout: 30))
    }

    @MainActor
    private func metric(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["home.metric.\(id)"].firstMatch
    }
}
