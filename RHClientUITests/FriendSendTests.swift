import XCTest

/// friend.send against the dev core from scripts/test.sh: a message typed in the Chat tab
/// is signed, accepted by the Mac and shown as accepted.
final class FriendSendTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testMessageToFriendIsAccepted() throws {
        let path = try pairingFile()
        let app = XCUIApplication()
        // Used only when this simulator is not paired yet (another test may have paired it).
        app.launchArguments = ["-RHPairing", try currentPairing(path)]
        app.launch()
        XCTAssertTrue(waitFor(app.staticTexts["home.connection"], label: "Connected · Secure session", timeout: 90))

        app.tabBars.buttons["Chat"].tap()
        // Addressed to the dev core's channel agent (status.channel), not to a built-in name.
        XCTAssertTrue(waitFor(app.navigationBars["Agent-Alpha"], timeout: 10))
        let input = app.descendants(matching: .any)["friend.input"].firstMatch
        XCTAssertTrue(waitFor(input, timeout: 10))
        input.tap()
        input.typeText("ui test message")
        app.buttons["friend.send"].tap()

        let accepted = NSPredicate(format: "label CONTAINS 'Accepted by the Mac'")
        let row = app.descendants(matching: .any).matching(identifier: "friend.message").matching(accepted).firstMatch
        XCTAssertTrue(waitFor(row, timeout: 30), "the message was not accepted")
        XCTAssertTrue(row.label.contains("ui test message"), row.label)

        // A tap outside the composer puts the keyboard away.
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard for the composer")
        row.tap()
        let gone = NSPredicate(format: "exists == false")
        let wait = XCTNSPredicateExpectation(predicate: gone, object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 5), .completed, "the keyboard stayed after a tap outside")
    }
}
