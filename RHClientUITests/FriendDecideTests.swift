import XCTest

/// friend.decide against the dev core from scripts/test.sh: a question put to the core over
/// its admin socket (as rh-friend-ask does) shows up in the Chat tab with its text and exact
/// action; Allow asks Face ID (answered by the matching-face loop of the script) and the Mac
/// accepts the decision; a second question is denied without Face ID.
final class FriendDecideTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testQuestionIsShownAndDecided() throws {
        let path = try pairingFile()
        guard let socket = ProcessInfo.processInfo.environment["RH_ADMIN_SOCKET"] else {
            throw XCTSkip("needs RH_ADMIN_SOCKET from scripts/test.sh")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-RHPairing", try currentPairing(path)]
        app.launch()
        XCTAssertTrue(waitFor(app.staticTexts["home.connection"], label: "Connected · Secure session", timeout: 90))

        let action = #"{"input":{"command":"kill -CONT 4242","description":"ui test"},"tool":"Bash"}"#
        let asked = try AdminSocket(path: socket).call([
            "cmd": "friend.ask", "text": "UI test: resume pid 4242?", "action": action,
        ])
        XCTAssertEqual(asked["ok"] as? Bool, true, "\(asked)")

        app.tabBars.buttons["Chat"].tap()
        let text = app.descendants(matching: .any)["friend.question.text"].firstMatch
        if !text.exists {
            // The list loads on appear; a pull refreshes it.
            app.descendants(matching: .any)["friend.list"].firstMatch.swipeDown()
        }
        XCTAssertTrue(waitFor(text, timeout: 30), "the question did not appear")
        XCTAssertEqual(text.label, "UI test: resume pid 4242?")
        let shown = app.descendants(matching: .any)["friend.question.action"].firstMatch
        XCTAssertEqual(shown.label, action, "the action must be shown in full, as is")

        app.buttons["friend.allow"].tap()
        let allowed = NSPredicate(format: "label BEGINSWITH 'Allowed'")
        let row = app.descendants(matching: .any).matching(identifier: "friend.decided").matching(allowed).firstMatch
        XCTAssertTrue(waitFor(row, timeout: 60), "the allow was not accepted")
        XCTAssertFalse(app.descendants(matching: .any)["friend.allow"].firstMatch.exists, "the question must leave the list")

        // The core recorded it as a decision answering this question.
        let open = try AdminSocket(path: socket).call(["cmd": "friend.questions"])
        let ids = (open["questions"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        XCTAssertFalse(ids.contains(asked["id"] as? String ?? "?"), "the question is still open on the Mac")

        // Deny: no Face ID, same path.
        let second = try AdminSocket(path: socket).call([
            "cmd": "friend.ask", "text": "UI test: deny this one", "action": action,
        ])
        XCTAssertEqual(second["ok"] as? Bool, true, "\(second)")
        app.descendants(matching: .any)["friend.list"].firstMatch.swipeDown()
        XCTAssertTrue(waitFor(text, label: "UI test: deny this one", timeout: 30), "the second question did not appear")
        app.buttons["friend.deny"].tap()
        let denied = NSPredicate(format: "label BEGINSWITH 'Denied'")
        XCTAssertTrue(waitFor(app.descendants(matching: .any).matching(identifier: "friend.decided").matching(denied).firstMatch, timeout: 60))
    }
}

/// One JSON Lines command to the dev core's admin socket (the simulator shares the Mac's
/// file system, so the Unix socket of scripts/test.sh is reachable).
struct AdminSocket {
    let path: String

    func call(_ command: [String: Any]) throws -> [String: Any] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "AdminSocket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket()"]) }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: "AdminSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket path too long"])
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw NSError(domain: "AdminSocket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "connect(\(path)): \(String(cString: strerror(errno)))"])
        }
        var line = try JSONSerialization.data(withJSONObject: command)
        line.append(0x0A)
        try line.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                guard n > 0 else { throw NSError(domain: "AdminSocket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "write()"]) }
                sent += n
            }
        }
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !answer.contains(0x0A) {
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            answer.append(buffer, count: n)
        }
        guard let newline = answer.firstIndex(of: 0x0A),
              let doc = try JSONSerialization.jsonObject(with: answer[..<newline]) as? [String: Any]
        else { throw NSError(domain: "AdminSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "no answer from the core"]) }
        return doc
    }
}
