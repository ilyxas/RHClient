import Foundation
import RHCrypto
import Testing
@testable import RHAPI

/// friend.questions / friend.decide: the question hash and body encoding of
/// contracts/vectors/friend_decide.json, and the signed calls with the right key level.
struct FriendDecideTests {
    private let signer = TestSigner()

    struct Hashed: Decodable {
        let text: String
        let expectedSHA256: String

        enum CodingKeys: String, CodingKey {
            case text
            case expectedSHA256 = "expected_sha256"
        }
    }

    struct DecideBody: Decodable {
        let name: String
        let decision: FriendDecision
        let expectedBodyText: String
        let keyLevel: KeyLevel

        enum CodingKeys: String, CodingKey {
            case name, decision
            case expectedBodyText = "expected_body_text"
            case keyLevel = "key_level"
        }
    }

    struct Build: Decodable {
        let question: Hashed
        let questionUnicode: Hashed
        let decideBody: [DecideBody]

        enum CodingKeys: String, CodingKey {
            case question
            case questionUnicode = "question_unicode"
            case decideBody = "decide_body"
        }
    }

    struct Vectors: Decodable {
        let question: FriendQuestion
        let build: Build
        let decideWindowS: Int

        enum CodingKeys: String, CodingKey {
            case question, build
            case decideWindowS = "decide_window_s"
        }
    }

    static let vectors: Vectors = {
        let data = try! ContractsLocation.data("vectors/friend_decide.json")
        return try! JSONDecoder().decode(Vectors.self, from: data)
    }()

    @Test func questionHashIsSHA256OfTheTextShown() {
        let b = Self.vectors.build
        for hashed in [b.question, b.questionUnicode] {
            let question = FriendQuestion(id: Self.vectors.question.id, text: hashed.text, action: "{}", askedAt: "2026-10-23T03:12:05Z")
            #expect(question.textSHA256 == hashed.expectedSHA256)
        }
    }

    @Test(arguments: FriendDecideTests.vectors.build.decideBody.map(\.name))
    func decideBodyMatchesTheVector(name: String) throws {
        let v = try #require(Self.vectors.build.decideBody.first { $0.name == name })
        let body = try FriendDecideRequest(question: Self.vectors.question, decision: v.decision).encoded()
        #expect(String(decoding: body, as: UTF8.self) == v.expectedBodyText)
        #expect(v.decision.keyLevel == v.keyLevel)
        #expect(CoreOperation.friendDecide(v.decision).auth == .signed(v.keyLevel))
    }

    @Test func questionDecodesAndNamesItsTool() throws {
        let response = try JSONDecoder().decode(FriendQuestionsResponse.self, from: Data(FakeCore.questionsExample.utf8))
        #expect(response.questions == [Self.vectors.question])
        #expect(response.questions[0].tool == "Bash")
        #expect(response.questions[0].action.hasPrefix(#"{"input":{"command":"#))
        #expect(Self.vectors.decideWindowS == 120)
    }

    @Test func questionsIsASignedGet() async throws {
        let core = try FakeCore(signer: signer)
        let client = CoreClient(endpoint: core.endpoint, signer: signer, transport: core)
        let listed = try await client.friendQuestions()
        #expect(listed.questions.map(\.id) == [FakeCore.question.id])
        let seen = core.seen
        #expect(seen.map(\.path) == ["/v1/challenge", "/v1/friend/questions"])
        #expect(seen[1].method == "GET")
        let object = try #require(seen[1].object)
        #expect(object["op"] == .string("friend.questions"))
        #expect(object["key"] == .string("normal"))
        #expect(object["body"] == .string(Digest.sha256Hex(Data())))
    }

    @Test func allowIsSignedWithTheCriticalKey() async throws {
        let core = try FakeCore(signer: signer)
        let client = CoreClient(endpoint: core.endpoint, signer: signer, transport: core)
        let request = FriendDecideRequest(question: FakeCore.question, decision: .allow)
        let answer = try await client.decide(request)
        #expect(answer.decision == .allow && answer.questionID == FakeCore.question.id && answer.id.count == 32)
        let seen = core.seen
        #expect(seen.map(\.path) == ["/v1/challenge", "/v1/friend/decide"])
        let object = try #require(seen[1].object)
        #expect(object["op"] == .string("friend.decide"))
        #expect(object["key"] == .string("critical"))
        #expect(seen[1].body == (try request.encoded()))
        #expect(object["body"] == .string(Digest.sha256Hex(seen[1].body)))
    }

    @Test func denyIsSignedWithTheNormalKey() async throws {
        let core = try FakeCore(signer: signer)
        let client = CoreClient(endpoint: core.endpoint, signer: signer, transport: core)
        let answer = try await client.decide(FriendDecideRequest(question: FakeCore.question, decision: .deny))
        #expect(answer.decision == .deny)
        #expect(core.seen.last?.object?["key"] == .string("normal"))
    }

    @Test func aChangedQuestionIsRefusedByTheCore() async throws {
        let core = try FakeCore(signer: signer)
        let client = CoreClient(endpoint: core.endpoint, signer: signer, transport: core)
        let q = FakeCore.question
        let changed = FriendQuestion(id: q.id, text: q.text + " ", action: q.action, askedAt: q.askedAt)
        await #expect(throws: CoreClientError.self) {
            try await client.decide(FriendDecideRequest(question: changed, decision: .allow))
        }
        do {
            _ = try await client.decide(FriendDecideRequest(question: changed, decision: .deny))
            Issue.record("a changed question was accepted")
        } catch CoreClientError.rejected(let rejection) {
            #expect(rejection.code == .badRequest)
        }
    }
}
