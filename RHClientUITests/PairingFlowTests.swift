import UIKit
import XCTest

/// Stage 1 end to end against the dev core (`rhcore dev up --auto-pair`), started by
/// scripts/test.sh: pair from the launch argument → status → ping → revoke this phone →
/// Pairing lost → Re-pair with the next code.
final class PairingFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPairPingRevokeRePair() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let pairingFile = environment["RH_PAIRING_FILE"] else {
            throw XCTSkip("needs the dev core: run scripts/test.sh")
        }
        let first = try currentPairing(pairingFile)

        let app = XCUIApplication()
        app.launchArguments = ["-RHPairing", first]
        app.launch()

        // The identifier sits on a Label, so both its text and its icon carry it.
        let connection = app.staticTexts["status.connection"]
        XCTAssertTrue(waitForConnected(connection, timeout: 90), "not connected after pairing")

        app.buttons["status.ping"].tap()
        XCTAssertTrue(waitForConnected(connection, timeout: 30))

        app.buttons["status.settings"].tap()
        app.buttons["settings.devices"].tap()
        let revoke = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'devices.revoke.'")).firstMatch
        XCTAssertTrue(revoke.waitForExistence(timeout: 30))
        revoke.tap()

        XCTAssertTrue(waitFor(app.staticTexts["Pairing lost"], timeout: 60), "no Pairing lost after revoking this phone")
        app.buttons["Re-pair"].tap()

        // The dev core issues a new code after every pairing.
        let second = try nextPairing(pairingFile, after: first)
        UIPasteboard.general.string = second
        app.buttons["pairing.paste"].tap()
        let allowPaste = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 5) { allowPaste.tap() }

        XCTAssertTrue(waitForConnected(connection, timeout: 90), "not connected after Re-pair")
    }

    private func currentPairing(_ path: String) throws -> String {
        let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(text.hasPrefix("rhpair:"))
        return text
    }

    private func nextPairing(_ path: String, after previous: String) throws -> String {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let text = try currentPairing(path)
            if text != previous { return text }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("the dev core did not issue a new pairing code")
        return previous
    }

    /// Waits for the element while answering system alerts (the first Face ID use asks for permission).
    @MainActor
    private func waitFor(_ element: XCUIElement, label: String? = nil, timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, label == nil || element.label == label { return true }
            for title in ["OK", "Allow"] where springboard.buttons[title].exists {
                springboard.buttons[title].tap()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Keep what the screen showed, so a failed run says where it stopped.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "timeout waiting for \(element.identifier.isEmpty ? element.label : element.identifier)"
        shot.lifetime = .keepAlways
        add(shot)
        if element.exists { print("\(element.identifier): \(element.label)") }
        return false
    }

    @MainActor
    private func waitForConnected(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitFor(element, label: "Connected · Secure session", timeout: timeout)
    }
}
