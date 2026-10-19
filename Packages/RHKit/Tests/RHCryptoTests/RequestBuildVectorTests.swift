import CryptoKit
import Foundation
import Testing
@testable import RHCrypto

/// contracts/vectors/request_build.json: X-RH-Auth must match byte for byte.
private struct RequestBuildFile: Decodable {
    let version: Int
    let vectors: [RequestBuildVector]
}

private struct RequestBuildVector: Decodable {
    let name: String
    let priv_scalar_b64: String
    let pub_x963_b64: String
    let normal_pub_x963_b64: String
    let device: String
    let key: String
    let nonce: String
    let ts: String
    let exp: String
    let op: String
    let body_b64: String
    let expected_body_sha256: String
    let expected_auth_text: String
    let expected_auth_b64: String
    let sig_der_b64: String
}

struct RequestBuildVectorTests {
    private func vectors() throws -> [RequestBuildVector] {
        let file = try JSONDecoder().decode(RequestBuildFile.self, from: ContractsLocation.data("vectors/request_build.json"))
        #expect(file.version == 1)
        #expect(!file.vectors.isEmpty)
        return file.vectors
    }

    @Test func authBytesMatch() throws {
        for vector in try vectors() {
            let normal = try #require(Base64.decode(vector.normal_pub_x963_b64))
            #expect(DeviceKeys.deviceID(normalKey: normal) == vector.device, "\(vector.name): device id")
            let body = try #require(Base64.decode(vector.body_b64), "\(vector.name): body")
            #expect(Digest.sha256Hex(body) == vector.expected_body_sha256, "\(vector.name): body sha256")

            let level = try #require(KeyLevel(rawValue: vector.key))
            let ts = try #require(ProtocolTime.parse(vector.ts))
            let exp = try #require(ProtocolTime.parse(vector.exp))
            let object = SignedObject(
                device: vector.device, key: level, nonce: vector.nonce, ts: ts, exp: exp, op: vector.op,
                bodySHA256: Digest.sha256Hex(body)
            )
            #expect(object.canonicalBytes == Array(vector.expected_auth_text.utf8), "\(vector.name): auth text")
            #expect(Base64.encode(object.canonicalBytes) == vector.expected_auth_b64, "\(vector.name): auth base64")

            if exp.timeIntervalSince(ts) == SignedObject.maxLifetime {
                let built = SignedObject(device: vector.device, key: level, nonce: vector.nonce, op: vector.op, body: body, now: ts)
                #expect(built == object, "\(vector.name): convenience init")
            }
        }
    }

    @Test func signaturesVerify() async throws {
        for vector in try vectors() {
            let publicKey = try #require(ECDSA.publicKey(x963Base64: vector.pub_x963_b64))
            let message = try #require(Base64.decode(vector.expected_auth_b64))
            #expect(
                ECDSA.isValid(signatureBase64: vector.sig_der_b64, message: message, publicKey: publicKey),
                "\(vector.name): given signature"
            )

            // Our own signature is randomized, so check it by verifying it.
            let scalar = try #require(Base64.decode(vector.priv_scalar_b64))
            let level = try #require(KeyLevel(rawValue: vector.key))
            let signer = TestSigner(normal: scalar, critical: scalar)
            #expect(try signer.privateKey(level).publicKey.x963Representation == Base64.decode(vector.pub_x963_b64))
            let object = SignedObject(
                device: vector.device, key: level, nonce: vector.nonce,
                ts: try #require(ProtocolTime.parse(vector.ts)), exp: try #require(ProtocolTime.parse(vector.exp)),
                op: vector.op, bodySHA256: vector.expected_body_sha256
            )
            let headers = try await SignedHeaders.sign(object, with: signer)
            #expect(headers.auth == vector.expected_auth_b64)
            #expect(headers.criticalSignature == nil)
            #expect(headers.fields.count == 2)
            #expect(
                ECDSA.isValid(signatureBase64: headers.signature, message: message, publicKey: publicKey),
                "\(vector.name): own signature"
            )
        }
    }

    @Test func pairingIsSignedByBothKeys() async throws {
        let signer = TestSigner()
        let normal = try signer.privateKey(.normal).publicKey
        let critical = try signer.privateKey(.critical).publicKey
        let object = SignedObject(
            device: DeviceKeys.deviceID(normalKey: normal.x963Representation), key: .normal,
            nonce: "3YO4PGkMMdRj4og3mLqkMc7HPEOyMGN4xrmHxj6cRkY=", op: "pair",
            body: Data("{}".utf8), now: Date(timeIntervalSince1970: 1_800_000_000.7)
        )
        #expect(ProtocolTime.format(object.ts) == "2027-01-15T08:00:00Z")
        let headers = try await SignedHeaders.sign(object, with: signer, criticalCosignature: true)
        let message = Data(object.canonicalBytes)
        #expect(ECDSA.isValid(signatureBase64: headers.signature, message: message, publicKey: normal))
        let criticalSignature = try #require(headers.criticalSignature)
        #expect(ECDSA.isValid(signatureBase64: criticalSignature, message: message, publicKey: critical))
        #expect(!ECDSA.isValid(signatureBase64: criticalSignature, message: message, publicKey: normal))
        #expect(headers.fields[SignedHeaders.criticalSignatureName] == criticalSignature)
    }
}
