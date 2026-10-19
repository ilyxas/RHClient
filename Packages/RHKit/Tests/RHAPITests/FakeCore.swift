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
            return answer(200, Data(#"{"mac_name":"Mac","core_version":"0.1.0","agent_version":null,"mode":"dev","server_time":"2026-10-19T12:00:00Z"}"#.utf8), nonce: nonce, path: path)
        case "/v1/devices":
            let id = deviceKeys.deviceID
            return answer(200, Data(#"{"devices":[{"id":"\#(id)","name":"Мой iPhone","fingerprint":"\#(deviceKeys.fingerprint)","paired_at":"2026-10-19T12:00:00Z","status":"active","current":true}]}"#.utf8), nonce: nonce, path: path)
        case "/v1/data":
            return answer(200, Data(Self.dataExample.utf8), nonce: nonce, path: path)
        case "/v1/log":
            return answer(200, Data(Self.logExample.utf8), nonce: nonce, path: path)
        case "/v1/quick":
            return answer(200, Data(#"{"items":[]}"#.utf8), nonce: nonce, path: path)
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
        {"id":"Friend","title":"Friend","subtitle":"observer","status":{"state":"ok","text":"monitoring"}},
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
