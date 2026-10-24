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
        let expectedBodyText: String

        enum CodingKeys: String, CodingKey {
            case name, id, text
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
        let body = try FriendSendRequest(id: v.id, text: v.text, to: Self.file.agent).encoded()
        #expect(String(decoding: body, as: UTF8.self) == v.expectedBodyText)
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
