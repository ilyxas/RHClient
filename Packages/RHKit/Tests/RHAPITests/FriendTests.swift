import Foundation
import RHCrypto
import Testing
@testable import RHAPI

/// friend.send: the body encoding of contracts/vectors/friend.json and the signed call.
struct FriendTests {
    private let signer = TestSigner()

    struct BuildVector: Decodable {
        let name: String
        let id: String
        let text: String
        /// Only in the vectors that set them; the body carries them only then.
        let kind: MessageKind?
        let re: String?
        let expectedBodyText: String

        enum CodingKeys: String, CodingKey {
            case name, id, text, kind, re
            case expectedBodyText = "expected_body_text"
        }
    }

    struct Vectors: Decodable {
        /// The channel agent every body is addressed to.
        let agent: String
        let build: [BuildVector]
    }

    static let file: Vectors = {
        let data = try! ContractsLocation.data("vectors/friend.json")
        return try! JSONDecoder().decode(Vectors.self, from: data)
    }()
    static let vectors: [BuildVector] = file.build

    @Test(arguments: FriendTests.vectors.map(\.name))
    func bodyMatchesTheVector(name: String) throws {
        let v = try #require(Self.vectors.first { $0.name == name })
        let body = try FriendSendRequest(id: v.id, text: v.text, to: Self.file.agent, kind: v.kind, re: v.re).encoded()
        #expect(String(decoding: body, as: UTF8.self) == v.expectedBodyText)
    }

    @Test func theVectorsCoverKindAndRe() {
        #expect(Self.vectors.contains { $0.kind == .task && $0.re == nil })
        #expect(Self.vectors.contains { $0.kind == .task && $0.re != nil })
        #expect(Self.vectors.contains { $0.kind == nil && $0.re == nil })
    }

    @Test func kindAndReAreOnlyInTheBodyWhenSet() throws {
        let agent = Self.file.agent
        let plain = try FriendSendRequest(id: "m-1", text: "x", to: agent).encoded()
        #expect(String(decoding: plain, as: UTF8.self) == "{\"id\":\"m-1\",\"text\":\"x\",\"to\":\"\(agent)\"}")
        let re = String(repeating: "a", count: 32)
        let task = try FriendSendRequest(id: "m-1", text: "x", to: agent, kind: .task, re: re).encoded()
        #expect(String(decoding: task, as: UTF8.self) == "{\"id\":\"m-1\",\"kind\":\"task\",\"re\":\"\(re)\",\"text\":\"x\",\"to\":\"\(agent)\"}")
    }

    @Test func aTaskFollowingUpAMessageIsAccepted() async throws {
        let core = try FakeCore(signer: signer)
        let client = CoreClient(endpoint: core.endpoint, signer: signer, transport: core)
        let first = try await client.sendToFriend(FriendSendRequest(id: "m-1", text: "why?", to: FakeCore.agent))
        let second = try await client.sendToFriend(FriendSendRequest(id: "m-2", text: "go ahead", to: FakeCore.agent, kind: .task, re: first.id))
        #expect(second.messageID == "m-2")
        let kept = core.messages.withLock { $0 }
        #expect(kept.map { $0.3 } == ["question", "task"])
        #expect(kept[1].4 == first.id)
        await #expect(throws: CoreClientError.self) {
            try await client.sendToFriend(FriendSendRequest(text: "x", to: FakeCore.agent, re: "not-a-spool-id"))
        }
    }

    @Test func messagesAreReadWithACursorOverASignedPost() async throws {
        let core = try FakeCore(signer: signer)
        let client = CoreClient(endpoint: core.endpoint, signer: signer, transport: core)
        let page = try await client.friendMessages(FriendMessagesRequest(since: 3, limit: 20))
        let seen = core.seen
        #expect(seen.map(\.path) == ["/v1/challenge", "/v1/friend/messages"])
        #expect(seen[1].method == "POST")
        let object = try #require(seen[1].object)
        #expect(object["op"] == .string("friend.messages"))
        #expect(object["key"] == .string("normal"))
        #expect(try JSONDecoder().decode([String: Int].self, from: seen[1].body) == ["since": 3, "limit": 20])
        #expect(page.next == 9 && page.more == false)
        #expect(page.messages.map(\.state) == [.answered, .received])
        let answered = page.messages[0]
        #expect(answered.kind == .question && answered.re == nil && answered.finalReply?.text.hasPrefix("Xcode holds") == true)
        #expect(answered.closedAt == "2026-10-25T09:12:41Z" && !answered.state.isOpen)
        let task = page.messages[1]
        #expect(task.kind == .task && task.re == answered.id && task.state.isOpen && task.finalReply == nil)
        #expect(task.replies.map(\.kind) == [.progress])
        // Round trip through Codable: the app caches messages on disk.
        let data = try JSONEncoder().encode(page.messages)
        #expect(try JSONDecoder().decode([FriendMessage].self, from: data) == page.messages)
        await #expect(throws: CoreClientError.self) {
            try await client.friendMessages(FriendMessagesRequest(since: 0, limit: 500))
        }
    }

    @Test func sendToFriendIsSignedWithTheNormalKey() async throws {
        let core = try FakeCore(signer: signer)
        let client = CoreClient(endpoint: core.endpoint, signer: signer, transport: core)
        let message = FriendSendRequest(id: "m-1", text: "проверь сборку", to: FakeCore.agent)
        let answer = try await client.sendToFriend(message)
        #expect(answer.messageID == "m-1")
        #expect(answer.id.count == 32)
        let seen = core.seen
        #expect(seen.map(\.path) == ["/v1/challenge", "/v1/friend"])
        let object = try #require(seen[1].object)
        #expect(object["op"] == .string("friend.send"))
        #expect(object["key"] == .string("normal"))
        #expect(seen[1].method == "POST")
        #expect(seen[1].body == (try message.encoded()))
        #expect(object["body"] == .string(Digest.sha256Hex(seen[1].body)))
    }

    @Test func aMessageToAnotherAgentIsRefused() async throws {
        let core = try FakeCore(signer: signer)
        let client = CoreClient(endpoint: core.endpoint, signer: signer, transport: core)
        await #expect(throws: CoreClientError.self) {
            try await client.sendToFriend(FriendSendRequest(text: "x", to: "Agent-Beta"))
        }
    }

    @Test func newMessageIDsFitTheContract() {
        let id = FriendSendRequest(text: "x", to: FakeCore.agent).id
        #expect(!id.isEmpty && id.count <= 64)
        #expect(id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    }
}
