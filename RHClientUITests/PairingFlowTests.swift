import UIKit
import XCTest

/// Stage 1 end to end against the dev core (`rhcore dev up --auto-pair`), started by
/// scripts/test.sh: pair from the launch argument → Home → Settings → Connection → ping →
/// revoke this phone → Pairing lost → Re-pair with the next code.
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

        let home = app.staticTexts["home.connection"]
        XCTAssertTrue(waitForConnected(home, timeout: 90), "not connected after pairing")

        app.buttons["home.settings"].tap()
        app.buttons["settings.connection"].tap()
        app.buttons["status.ping"].tap()
        // The identifier sits on a Label, so both its text and its icon carry it.
        XCTAssertTrue(waitForConnected(app.staticTexts["status.connection"], timeout: 30))
        app.navigationBars.buttons.element(boundBy: 0).tap()

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

        XCTAssertTrue(waitForConnected(home, timeout: 90), "not connected after Re-pair")
    }
}
