import CryptoKit
import Foundation
import RHCrypto
import Testing
@testable import RHAPI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CoreClientTests {
    private let signer = TestSigner()

    private func client(_ core: FakeCore) -> CoreClient {
        CoreClient(endpoint: core.endpoint, signer: signer, transport: core, now: { Date(timeIntervalSince1970: 1_792_411_200) })
    }

    @Test func pingSignsWithChallengeNonce() async throws {
        let core = try FakeCore(signer: signer)
        let pong = try await client(core).ping()
        #expect(pong.pong)
        let seen = core.seen
        #expect(seen.map(\.path) == ["/v1/challenge", "/v1/ping"])
        let object = try #require(seen[1].object)
        #expect(object["op"] == .string("ping"))
        #expect(object["key"] == .string("normal"))
        #expect(object["device"] == .string(core.deviceKeys.deviceID))
        #expect(object["body"] == .string(Digest.sha256Hex(Data("{}".utf8))))
        #expect(object["ts"] == .string("2026-10-19T12:00:00Z"))
        #expect(object["exp"] == .string("2026-10-19T12:01:00Z"))
        #expect(seen[1].headers["X-RH-Sig-Critical"] == nil)
        #expect(seen[1].method == "POST")
    }

    @Test func getHashesEmptyBody() async throws {
        let core = try FakeCore(signer: signer)
        let status = try await client(core).status()
        #expect(status.mode == .dev)
        #expect(status.agentVersion == nil)
        let object = try #require(core.seen.last?.object)
        #expect(core.seen.last?.method == "GET")
        #expect(object["body"] == .string(Digest.sha256Hex(Data())))
        let devices = try await client(core).devices()
        #expect(devices.devices.first?.current == true)
    }

    @Test func revokeUsesCriticalKey() async throws {
        let core = try FakeCore(signer: signer)
        let revoked = try await client(core).revoke(deviceID: "994a0fc227ccb566e3574cc026f1959c")
        #expect(revoked.status == "revoked")
        #expect(core.seen.last?.object?["key"] == .string("critical"))
        #expect(core.seen.last?.object?["op"] == .string("devices.revoke"))
    }

    @Test func answerSignedByOtherKeyIsPairingLost() async throws {
        let core = try FakeCore(signer: signer)
        core.wrongKey.withLock { $0 = P256.Signing.PrivateKey() }
        let error = await #expect(throws: CoreClientError.badServerSignature) { try await client(core).ping() }
        #expect(ConnectionState(error: try #require(error)) == .pairingLost)
    }

    @Test func unsignedAnswerIsRejected() async throws {
        let core = try FakeCore(signer: signer)
        let unsigned = UnsignedTransport(inner: core)
        let client = CoreClient(endpoint: core.endpoint, signer: signer, transport: unsigned)
        await #expect(throws: CoreClientError.badServerSignature) { try await client.ping() }
    }

    @Test func revokedDeviceIsPairingLost() async throws {
        let core = try FakeCore(signer: signer)
        core.overrides.withLock { $0["/v1/challenge"] = (403, Data(#"{"error":{"code":"revoked_device","message":"revoked"}}"#.utf8)) }
        do {
            _ = try await client(core).status()
            Issue.record("expected a rejection")
        } catch let error as CoreClientError {
            guard case .rejected(let rejection) = error else { Issue.record("\(error)"); return }
            #expect(rejection.code == .revokedDevice)
            #expect(ConnectionState(error: error) == .pairingLost)
        }
    }

    @Test func otherRejectionsAreAuthErrors() async throws {
        let core = try FakeCore(signer: signer)
        core.overrides.withLock { $0["/v1/ping"] = (401, Data(#"{"error":{"code":"clock_skew","message":"clock"}}"#.utf8)) }
        let error = await #expect(throws: CoreClientError.self) { try await client(core).ping() }
        #expect(ConnectionState(error: try #require(error)) == .authError(code: "clock_skew"))
    }

    @Test func dataGetSignsItsIDsInTheBody() async throws {
        let core = try FakeCore(signer: signer)
        let data = try await client(core).data(ids: BuiltinData.home)
        #expect(data.values[BuiltinData.cpu]?.value?.number == 38.4)
        let seen = try #require(core.seen.last)
        #expect(seen.method == "POST")
        #expect(seen.path == "/v1/data")
        #expect(seen.object?["op"] == .string("data.get"))
        #expect(seen.object?["key"] == .string("normal"))
        #expect(seen.object?["body"] == .string(Digest.sha256Hex(seen.body)))
        let sent = try JSONDecoder().decode([String: [String]].self, from: seen.body)
        #expect(sent == ["ids": BuiltinData.home])
    }

    @Test func logAndQuickAreSignedReads() async throws {
        let core = try FakeCore(signer: signer)
        let page = try await client(core).log(LogRequest(filter: .errors, query: "ping", limit: 50))
        #expect(page.entries.count == 2)
        let log = try #require(core.seen.last)
        #expect(log.method == "POST" && log.path == "/v1/log")
        #expect(log.object?["op"] == .string("log.list"))
        #expect(log.object?["body"] == .string(Digest.sha256Hex(log.body)))

        let quick = try await client(core).quick()
        #expect(quick.items.isEmpty)
        let seen = try #require(core.seen.last)
        #expect(seen.method == "GET" && seen.path == "/v1/quick")
        #expect(seen.object?["op"] == .string("quick.list"))
        #expect(seen.object?["body"] == .string(Digest.sha256Hex(Data())))
    }

    @Test func badRequestLeavesTheConnectionAlone() async throws {
        let core = try FakeCore(signer: signer)
        core.overrides.withLock { $0["/v1/log"] = (400, Data(#"{"error":{"code":"bad_request","message":"limit"}}"#.utf8)) }
        let error = await #expect(throws: CoreClientError.self) { try await client(core).log(LogRequest()) }
        guard case .rejected(let rejection)? = error else { Issue.record("\(String(describing: error))"); return }
        #expect(rejection.code == .badRequest)
        #expect(ConnectionState(error: rejection) == nil)
        #expect(ConnectionState(error: try #require(error)) == nil)
    }

    @Test func networkFailureIsUnreachable() async throws {
        let core = try FakeCore(signer: signer)
        core.unreachable.withLock { $0 = true }
        let error = await #expect(throws: CoreClientError.self) { try await client(core).ping() }
        #expect(ConnectionState(error: try #require(error)) == .unreachable)
    }

    @Test func pairIsSignedTwiceWithTheCode() async throws {
        let core = try FakeCore(signer: signer)
        let code = "3YO4PGkMMdRj4og3mLqkMc7HPEOyMGN4xrmHxj6cRkY="
        let pairing = try pairingString(core: core, code: code)
        let paired = try await CoreClient.pair(
            pairing, name: "Мой iPhone", keys: core.deviceKeys, replaces: "994a0fc227ccb566e3574cc026f1959c",
            signer: signer, transport: core
        )
        #expect(paired.deviceID == core.deviceKeys.deviceID)
        let seen = try #require(core.seen.last)
        #expect(core.seen.count == 1, "no challenge before pair")
        #expect(seen.object?["nonce"] == .string(code))
        #expect(seen.object?["key"] == .string("normal"))
        #expect(seen.timeout >= 300)
        #expect(seen.headers["X-RH-Sig-Critical"] != nil)
    }

    @Test func pairAnswerFromAnotherCoreIsRejected() async throws {
        let core = try FakeCore(signer: signer)
        let pairing = try pairingString(core: core, code: "3YO4PGkMMdRj4og3mLqkMc7HPEOyMGN4xrmHxj6cRkY=")
        core.wrongKey.withLock { $0 = P256.Signing.PrivateKey() }
        await #expect(throws: CoreClientError.badServerSignature) {
            try await CoreClient.pair(pairing, name: "Мой iPhone", keys: core.deviceKeys, replaces: nil, signer: signer, transport: core)
        }
    }

    @Test func eventStreamRequestIsSignedForWSOpen() async throws {
        let core = try FakeCore(signer: signer)
        let (request, nonce) = try await client(core).eventStreamRequest()
        #expect(request.url?.absoluteString == "wss://mac.tail1234.ts.net:8443/v1/ws")
        let auth = try #require(request.value(forHTTPHeaderField: "X-RH-Auth").flatMap(Base64.decode))
        guard case .object(let object) = try JCS.parse(String(decoding: auth, as: UTF8.self)) else {
            Issue.record("auth is not an object")
            return
        }
        #expect(object["op"] == .string("ws.open"))
        #expect(object["nonce"] == .string(nonce))
        #expect(object["body"] == .string(Digest.sha256Hex(Data())))
    }

    private func pairingString(core: FakeCore, code: String) throws -> PairingString {
        let payload = JCS.canonicalize(.object([
            "v": .integer(1), "url": .string("https://mac.tail1234.ts.net:8443"),
            "core_key": .string(Base64.encode(core.coreKey.publicKey.x963Representation)),
            "code": .string(code), "exp": .string("2026-10-19T12:05:00Z"),
        ]))
        return try PairingString(parsing: "rhpair:" + Base64.encodeURLNoPadding(payload), allowLocalHTTP: false)
    }
}

/// Drops X-RH-Server-Sig from every answer.
private struct UnsignedTransport: HTTPTransport {
    let inner: FakeCore

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await inner.send(request)
        return (data, HTTPURLResponse(url: response.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: [:])!)
    }
}
