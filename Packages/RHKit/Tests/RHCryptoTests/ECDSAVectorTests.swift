import Foundation
import Testing
@testable import RHCrypto

/// contracts/vectors/ecdsa.json: DER parsing and verification, high-S included.
private struct ECDSAVectorFile: Decodable {
    let version: Int
    let vectors: [ECDSAVector]
}

private struct ECDSAVector: Decodable {
    let name: String
    let pub_x963_b64: String
    let message_b64: String
    let sig_der_b64: String
    let valid: Bool
}

struct ECDSAVectorTests {
    @Test func vectors() throws {
        let file = try JSONDecoder().decode(ECDSAVectorFile.self, from: ContractsLocation.data("vectors/ecdsa.json"))
        #expect(file.version == 1)
        #expect(!file.vectors.isEmpty)
        for vector in file.vectors {
            let key = try #require(ECDSA.publicKey(x963Base64: vector.pub_x963_b64), "\(vector.name): public key")
            let message = try #require(Base64.decode(vector.message_b64), "\(vector.name): message")
            // Broken DER (empty, truncated) may not even be valid base64 of a signature; that is a rejection too.
            let valid = Base64.decode(vector.sig_der_b64).map {
                ECDSA.isValid(signatureDER: $0, message: message, publicKey: key)
            } ?? false
            #expect(valid == vector.valid, "\(vector.name)")
        }
    }

    @Test func derRejectsNonMinimalAndNegativeIntegers() {
        let one = [UInt8](repeating: 0x01, count: 32)
        func der(_ r: [UInt8], _ s: [UInt8]) -> Data {
            Data([0x30, UInt8(4 + r.count + s.count), 0x02, UInt8(r.count)] + r + [0x02, UInt8(s.count)] + s)
        }
        #expect(ECDSA.parseDER(der(one, one)) != nil)
        #expect(ECDSA.parseDER(der([0x00] + one, one)) == nil, "leading zero before a positive byte")
        #expect(ECDSA.parseDER(der([0x80] + one.dropFirst(), one)) == nil, "negative r")
        #expect(ECDSA.parseDER(der([0x00], one)) == nil, "zero r")
        #expect(ECDSA.parseDER(der([0x00] + ECDSA.curveOrder, one)) == nil, "r = n")
        #expect(ECDSA.parseDER(der(one, one) + Data([0x00])) == nil, "trailing byte")
    }
}
