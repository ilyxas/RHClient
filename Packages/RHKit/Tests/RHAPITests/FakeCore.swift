import CryptoKit
import Foundation
import RHCrypto
@testable import RHAPI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// A tiny rh-core for client tests: issues nonces, checks the signed object and the
/// device signature, and signs every answer with its own key like the real core.
final class FakeCore: HTTPTransport {
    struct Seen: Sendable {
        let method: String
        let path: String
        let object: [String: JSONValue]?
        let timeout: TimeInterval
        let headers: [String: String]
        let body: Data
    }

    private let coreKeyRaw = P256.Signing.PrivateKey().rawRepresentation
    var coreKey: P256.Signing.PrivateKey { try! P256.Signing.PrivateKey(rawRepresentation: coreKeyRaw) }
    let deviceKeys: DeviceKeys
    private let state = Mutex<(nonces: [String], seen: [Seen])>(([], []))
    /// Replaces the normal answer to a path: status and body.
    let overrides = Mutex<[String: (Int, Data)]>([:])
    /// Signs answers with this key instead of the core key when set.
    let wrongKey = Mutex<P256.Signing.PrivateKey?>(nil)
    let unreachable = Mutex(false)

    init(signer: TestSigner) throws {
        deviceKeys = DeviceKeys(
            normal: try signer.privateKey(.normal).publicKey.x963Representation,
            critical: try signer.privateKey(.critical).publicKey.x963Representation,
            ssh: P256.Signing.PrivateKey().publicKey.x963Representation
        )
    }

    var endpoint: CoreEndpoint {
        CoreEndpoint(baseURL: URL(string: "https://mac.tail1234.ts.net:8443")!, coreKeyX963: coreKey.publicKey.x963Representation, deviceID: deviceKeys.deviceID)
    }

    var seen: [Seen] { state.withLock { $0.seen } }
    /// What /v1/friend accepted: (spool id, message id, text, kind, re).
    let messages = Mutex<[(String, String, String, String, String?)]>([])

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if unreachable.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path
        let body = request.httpBody ?? Data()
        var object: [String: JSONValue]?
        if let auth = request.value(forHTTPHeaderField: "X-RH-Auth"), let bytes = Base64.decode(auth),
           case .object(let members) = try JCS.parse(String(decoding: bytes, as: UTF8.self)) {
            object = members
        }
        var headers: [String: String] = [:]
        for name in ["X-RH-Auth", "X-RH-Sig", "X-RH-Sig-Critical", "Content-Type"] {
            headers[name] = request.value(forHTTPHeaderField: name)
        }
        state.withLock {
            $0.seen.append(Seen(method: request.httpMethod ?? "", path: path, object: object, timeout: request.timeoutInterval, headers: headers, body: body))
        }

        if let (status, data) = overrides.withLock({ $0[path] }) {
            let nonce: String
            if case .string(let value)? = object?["nonce"] { nonce = value } else { nonce = "" }
            return answer(status, data, nonce: nonce, path: path)
        }
        if path == "/v1/challenge" {
            let nonce = Base64.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
            state.withLock { $0.nonces.append(nonce) }
            let data = Data(#"{"nonce":"\#(nonce)","expires":"2026-10-19T12:01:00Z","server_time":"2026-10-19T12:00:00Z"}"#.utf8)
            return answer(200, data, nonce: nonce, path: path)
        }

        // Signed request: the object must match what was sent, and the signature the key level.
        guard let object, case .string(let nonce)? = object["nonce"], case .string(let level)? = object["key"],
              case .string(let bodyHash)? = object["body"], bodyHash == Digest.sha256Hex(body),
              let signature = request.value(forHTTPHeaderField: "X-RH-Sig"),
              let auth = Base64.decode(request.value(forHTTPHeaderField: "X-RH-Auth")!)
        else { return error(400, "malformed_auth", nonce: "", path: path) }
        let key = level == "critical" ? deviceKeys.critical : deviceKeys.normal
        guard ECDSA.isValid(signatureBase64: signature, message: auth, publicKey: ECDSA.publicKey(x963: key)!) else {
            return error(401, "bad_signature", nonce: nonce, path: path)
        }
        if path != "/v1/pair" {
            let known = state.withLock { state -> Bool in
                guard let index = state.nonces.firstIndex(of: nonce) else { return false }
                state.nonces.remove(at: index)
                return true
            }
            guard known else { return error(401, "nonce_unknown", nonce: nonce, path: path) }
        }
        switch path {
        case "/v1/ping":
            return answer(200, Data(#"{"pong": true, "server_time": "2026-10-19T12:00:00Z"}"#.utf8), nonce: nonce, path: path)
        case "/v1/status":
            return answer(200, Data(#"{"mac_name":"Mac","core_version":"0.1.0","agent_version":null,"mode":"dev","server_time":"2026-10-19T12:00:00Z","channel":{"agent":"\#(Self.agent)","title":"\#(Self.agent)"}}"#.utf8), nonce: nonce, path: path)
        case "/v1/devices":
            let id = deviceKeys.deviceID
            return answer(200, Data(#"{"devices":[{"id":"\#(id)","name":"Мой iPhone","fingerprint":"\#(deviceKeys.fingerprint)","paired_at":"2026-10-19T12:00:00Z","status":"active","current":true}]}"#.utf8), nonce: nonce, path: path)
        case "/v1/data":
            return answer(200, Data(Self.dataExample.utf8), nonce: nonce, path: path)
        case "/v1/log":
            return answer(200, Data(Self.logExample.utf8), nonce: nonce, path: path)
        case "/v1/quick":
            return answer(200, Data(#"{"items":[]}"#.utf8), nonce: nonce, path: path)
        case "/v1/friend":
            // The real core: to, id, text and at most kind (question | task) and re (a spool id).
            guard let doc = try? JSONDecoder().decode([String: String].self, from: body), doc["to"] == Self.agent,
                  let id = doc["id"], !(doc["text"] ?? "").isEmpty,
                  Set(doc.keys).isSubset(of: ["to", "id", "text", "kind", "re"]),
                  doc["kind"] == nil || ["question", "task"].contains(doc["kind"]!),
                  doc["re"] == nil || (doc["re"]!.count == 32 && doc["re"]!.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            else { return error(400, "bad_request", nonce: nonce, path: path) }
            let sid = String(repeating: "a", count: 32)
            messages.withLock { $0.append((sid, id, doc["text"]!, doc["kind"] ?? "question", doc["re"])) }
            return answer(200, Data(#"{"id":"\#(sid)","message_id":"\#(id)","accepted_at":"2026-10-19T12:00:00Z"}"#.utf8), nonce: nonce, path: path)
        case "/v1/friend/messages":
            guard let doc = try? JSONDecoder().decode([String: Int].self, from: body),
                  Set(doc.keys).isSubset(of: ["since", "limit"]), (doc["since"] ?? 0) >= 0, (1...200).contains(doc["limit"] ?? 50)
            else { return error(400, "bad_request", nonce: nonce, path: path) }
            return answer(200, Data(Self.messagesExample.utf8), nonce: nonce, path: path)
        case "/v1/friend/questions":
            return answer(200, Data(Self.questionsExample.utf8), nonce: nonce, path: path)
        case "/v1/friend/decide":
            // The real core: the body must fit, the key level must fit the decision, and the
            // decision must name the one open question exactly.
            guard let doc = try? JSONDecoder().decode([String: String].self, from: body), doc["to"] == Self.agent,
                  let id = doc["id"], let decision = doc["decision"], ["allow", "deny"].contains(decision),
                  let digest = doc["question_sha256"], let action = doc["action"]
            else { return error(400, "bad_request", nonce: nonce, path: path) }
            guard level == (decision == "allow" ? "critical" : "normal") else {
                return error(401, "wrong_key_level", nonce: nonce, path: path)
            }
            let known = Self.question
            guard id == known.id, digest == known.textSHA256, action == known.action else {
                return error(400, "bad_request", nonce: nonce, path: path)
            }
            return answer(200, Data(#"{"id":"\#(String(repeating: "b", count: 32))","question_id":"\#(id)","decision":"\#(decision)","accepted_at":"2026-10-23T03:13:02Z"}"#.utf8), nonce: nonce, path: path)
        case "/v1/devices/revoke":
            let target = try JSONDecoder().decode([String: String].self, from: body)["device_id"]!
            return answer(200, Data(#"{"device_id":"\#(target)","status":"revoked"}"#.utf8), nonce: nonce, path: path)
        case "/v1/pair":
            guard let critical = request.value(forHTTPHeaderField: "X-RH-Sig-Critical"),
                  ECDSA.isValid(signatureBase64: critical, message: auth, publicKey: ECDSA.publicKey(x963: deviceKeys.critical)!)
            else { return error(401, "bad_signature", nonce: nonce, path: path) }
            return answer(200, Data(#"{"device_id":"\#(deviceKeys.deviceID)","mac_name":"Mac","ssh_host_keys":[]}"#.utf8), nonce: nonce, path: path)
        default:
            return error(404, "not_found", nonce: nonce, path: path)
        }
    }

    /// The channel agent, as the contract vectors name it (deliberately not the mechanism's
    /// namesake): `status.channel` and the only `to` this core accepts.
    static let agent = "Agent-Alpha"

    /// The one open question of contracts/vectors/friend_decide.json.
    static let question: FriendQuestion = {
        struct File: Decodable { let question: FriendQuestion }
        let data = try! ContractsLocation.data("vectors/friend_decide.json")
        return try! JSONDecoder().decode(File.self, from: data).question
    }()

    /// friend.questions with that question.
    /// The friend.messages example of contracts/api/openapi.yaml, plus one open task that follows it up.
    static let messagesExample = #"""
    {"messages":[{"id":"2f6c0d1e4b5a6f708192837465564700","seq":7,"message_id":"m-1","device":"3f2a9c0d1e4b5a6f7081928374655647","agent":"Agent-Alpha","kind":"question","text":"Is there a reason the RAM is so full right now?","accepted_at":"2026-10-25T09:12:05Z","state":"answered","received_at":"2026-10-25T09:12:07Z","closed_at":"2026-10-25T09:12:41Z","replies":[{"seq":6,"kind":"final","text":"Xcode holds 9 GB after the last build; nothing else is unusual. Want me to quit it?","at":"2026-10-25T09:12:41Z"}]},{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","seq":9,"message_id":"m-2","device":"3f2a9c0d1e4b5a6f7081928374655647","agent":"Agent-Alpha","kind":"task","re":"2f6c0d1e4b5a6f708192837465564700","text":"go ahead","accepted_at":"2026-10-25T09:13:00Z","state":"received","received_at":"2026-10-25T09:13:02Z","replies":[{"seq":8,"kind":"progress","text":"quitting Xcode","at":"2026-10-25T09:13:10Z"}]}],"next":9,"more":false,"server_time":"2026-10-25T09:13:30Z"}
    """#

    static var questionsExample: String {
        let q = try! JSONEncoder().encode(["id": question.id, "text": question.text, "action": question.action, "asked_at": question.askedAt])
        return #"{"questions":[\#(String(decoding: q, as: UTF8.self))],"server_time":"2026-10-23T03:12:30Z"}"#
    }

    /// The data.get response example of contracts/api/openapi.yaml (stage 2), plus rows with `at`.
    static let dataExample = #"""
    {"values":{
      "sys.cpu":{"status":"active","type":"number","value":38.4,"unit":"%","at":"2026-10-19T12:00:00Z"},
      "sys.memory":{"status":"active","type":"number","value":61.2,"unit":"%","at":"2026-10-19T12:00:00Z"},
      "sys.disk_free":{"status":"active","type":"number","value":112400000000,"unit":"bytes","at":"2026-10-19T12:00:00Z"},
      "rh.status":{"status":"active","type":"status","value":{"state":"ok","text":"rh-core 0.2.0"},"at":"2026-10-19T12:00:00Z"},
      "rh.approvals":{"status":"active","type":"rows","value":[],"at":"2026-10-19T12:00:00Z"},
      "rh.questions":{"status":"active","type":"rows","value":[],"at":"2026-10-19T12:00:00Z"},
      "rh.activity":{"status":"active","type":"rows","at":"2026-10-19T12:00:00Z","value":[
        {"id":"1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d","title":"Paired Мой iPhone","subtitle":"fingerprint 3f2a 9c0d 1e4b 5a6f","at":"2026-10-19T11:58:00Z"}]},
      "agents.status":{"status":"active","type":"rows","at":"2026-10-19T12:00:00Z","value":[
        {"id":"Agent-Alpha","title":"Agent-Alpha","subtitle":"observer","status":{"state":"ok","text":"monitoring"}},
        {"id":"RemoteHands","title":"RemoteHands","subtitle":"executor on the Mac","status":{"state":"off","text":"unknown"}}]},
      "render.queue":{"status":"pending"},
      "render.night":{"status":"error","message":"provider failed"}},
     "server_time":"2026-10-19T12:00:00Z"}
    """#

    /// The log.list response example of contracts/api/openapi.yaml (stage 2).
    static let logExample = #"""
    {"entries":[
      {"id":"9b1f6c0e5a7d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f","ts":"2026-10-19T12:00:05Z","kind":"error","event":"request",
       "title":"Rejected ping: bad_signature","detail":"signature does not verify","device":"3f2a9c0d1e4b5a6f7081928374655647","op":"ping"},
      {"id":"1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d","ts":"2026-10-19T11:58:00Z","kind":"command","event":"pairing",
       "title":"Paired Мой iPhone","detail":"fingerprint 3f2a 9c0d 1e4b 5a6f","device":"3f2a9c0d1e4b5a6f7081928374655647"}],
     "next":"MjAyNjEwMTk6MTI"}
    """#

    func error(_ status: Int, _ code: String, nonce: String, path: String) -> (Data, HTTPURLResponse) {
        answer(status, Data(#"{"error":{"code":"\#(code)","message":"\#(code)"}}"#.utf8), nonce: nonce, path: path)
    }

    func answer(_ status: Int, _ data: Data, nonce: String, path: String) -> (Data, HTTPURLResponse) {
        let message = Data(ServerSignature.message(nonce: nonce, status: status, body: data))
        let key = wrongKey.withLock { $0 } ?? coreKey
        let signature = try! key.signature(for: message).derRepresentation
        let response = HTTPURLResponse(
            url: URL(string: "https://mac.tail1234.ts.net:8443" + path)!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: [ServerSignature.headerName: Base64.encode(signature)]
        )!
        return (data, response)
    }
}
