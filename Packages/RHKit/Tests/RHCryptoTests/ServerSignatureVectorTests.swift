import Foundation
import Testing
@testable import RHCrypto

/// contracts/vectors/server_sig.json: X-RH-Server-Sig over every core response.
private struct ServerSigFile: Decodable {
    let version: Int
    let core_pub_x963_b64: String
    let vectors: [ServerSigVector]
}

private struct ServerSigVector: Decodable {
    let name: String
    let request_nonce: String
    let status: Int
    let body_b64: String
    let expected_message_text: String?
    let sig_der_b64: String
    let valid: Bool
}

struct ServerSignatureVectorTests {
    @Test func vectors() throws {
        let file = try JSONDecoder().decode(ServerSigFile.self, from: ContractsLocation.data("vectors/server_sig.json"))
        #expect(file.version == 1)
        #expect(!file.vectors.isEmpty)
        let coreKey = try #require(ECDSA.publicKey(x963Base64: file.core_pub_x963_b64))
        for vector in file.vectors {
            let body = try #require(Base64.decode(vector.body_b64), "\(vector.name): body")
            if let expected = vector.expected_message_text {
                let message = ServerSignature.message(nonce: vector.request_nonce, status: vector.status, body: body)
                #expect(message == Array(expected.utf8), "\(vector.name): message")
            }
            let valid = ServerSignature.isValid(
                vector.sig_der_b64, nonce: vector.request_nonce, status: vector.status, body: body, coreKey: coreKey
            )
            #expect(valid == vector.valid, "\(vector.name)")
        }
    }

    @Test func missingHeaderIsInvalid() throws {
        let file = try JSONDecoder().decode(ServerSigFile.self, from: ContractsLocation.data("vectors/server_sig.json"))
        let coreKey = try #require(ECDSA.publicKey(x963Base64: file.core_pub_x963_b64))
        #expect(!ServerSignature.isValid(nil, nonce: "", status: 200, body: Data(), coreKey: coreKey))
        #expect(!ServerSignature.isValid("", nonce: "", status: 200, body: Data(), coreKey: coreKey))
    }
}
