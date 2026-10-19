import XCTest

/// Shared by the UI tests that run against the dev core from scripts/test.sh.
extension XCTestCase {
    /// RH_PAIRING_FILE from scripts/test.sh; the test is skipped without a dev core.
    func pairingFile() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["RH_PAIRING_FILE"] else {
            throw XCTSkip("needs the dev core: run scripts/test.sh")
        }
        return path
    }

    func currentPairing(_ path: String) throws -> String {
        let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(text.hasPrefix("rhpair:"))
        return text
    }

    func nextPairing(_ path: String, after previous: String) throws -> String {
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
    func waitFor(_ element: XCUIElement, label: String? = nil, value: String? = nil, timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, label == nil || element.label == label,
               value == nil || element.value as? String == value { return true }
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
        if element.exists { print("\(element.identifier): \(element.label) = \(String(describing: element.value))") }
        return false
    }

    @MainActor
    func waitForConnected(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitFor(element, label: "Connected · Secure session", timeout: timeout)
    }
}
