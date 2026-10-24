import XCTest

/// friend.send against the dev core from scripts/test.sh: a message typed in the Chat tab is
/// signed, accepted by the Mac and shown as accepted; then the agent side's receipt and reply
/// (sent over the core's admin socket, as the hooks do) show up under it, and a task is sent as one.
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
        XCTAssertTrue(row.label.contains("Question"), "a message is a question unless the switch says task: \(row.label)")

        if let socket = ProcessInfo.processInfo.environment["RH_ADMIN_SOCKET"] {
            // The agent side reports: received, then the answer. The spool id is the newest
            // envelope in the dev core's inbox (the simulator shares the Mac's file system).
            let inbox = (socket as NSString).deletingLastPathComponent + "/inbox"
            let sid = try newestEnvelope(in: inbox)
            let received = try AdminSocket(path: socket).call(["cmd": "friend.received", "id": sid, "prompt_id": "ui-test"])
            XCTAssertEqual(received["ok"] as? Bool, true, "\(received)")
            let onIt = NSPredicate(format: "label CONTAINS 'received'")
            XCTAssertTrue(
                waitFor(app.descendants(matching: .any).matching(identifier: "friend.message").matching(onIt).firstMatch, timeout: 30),
                "the receipt did not reach the phone"
            )
            let replied = try AdminSocket(path: socket).call(["cmd": "friend.reply", "in_reply_to": sid, "text": "ui test answer"])
            XCTAssertEqual(replied["ok"] as? Bool, true, "\(replied)")
            let answered = NSPredicate(format: "label CONTAINS 'Answered' AND label CONTAINS 'ui test answer'")
            XCTAssertTrue(
                waitFor(app.descendants(matching: .any).matching(identifier: "friend.message").matching(answered).firstMatch, timeout: 30),
                "the answer did not reach the phone"
            )
        }

        // A task: the switch, then the body carries kind = task and the row says so.
        app.descendants(matching: .any)["friend.kind"].buttons["Task"].tap()
        input.tap()
        input.typeText("ui test task")
        app.buttons["friend.send"].tap()
        let task = NSPredicate(format: "label CONTAINS 'ui test task' AND label CONTAINS 'Task' AND label CONTAINS 'Accepted by the Mac'")
        XCTAssertTrue(
            waitFor(app.descendants(matching: .any).matching(identifier: "friend.message").matching(task).firstMatch, timeout: 30),
            "the task was not accepted as a task"
        )

        // A tap outside the composer puts the keyboard away.
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard for the composer")
        row.tap()
        let gone = NSPredicate(format: "exists == false")
        let wait = XCTNSPredicateExpectation(predicate: gone, object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 5), .completed, "the keyboard stayed after a tap outside")
    }
}

extension FriendSendTests {
    /// The spool id of the envelope the core wrote last (its file name).
    func newestEnvelope(in directory: String) throws -> String {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
        let dated = try names.map { name -> (String, Date) in
            let attributes = try fm.attributesOfItem(atPath: directory + "/" + name)
            return (name, attributes[.modificationDate] as? Date ?? .distantPast)
        }
        guard let newest = dated.max(by: { $0.1 < $1.1 }) else {
            throw NSError(domain: "FriendSendTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "no envelope in \(directory)"])
        }
        return String(newest.0.dropLast(".json".count))
    }
}
