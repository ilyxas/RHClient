import Foundation
import RHCrypto
import Testing
@testable import RHAPI

/// contracts/vectors/pairing.json: pairing strings and fingerprints.
private struct PairingFile: Decodable {
    let version: Int
    let vectors: [PairingVector]
    let fingerprints: [FingerprintVector]
}

private struct PairingVector: Decodable {
    struct Expected: Decodable {
        let v: Int
        let url: String
        let core_key: String
        let code: String
        let exp: String
    }

    let name: String
    let string: String
    let expected: Expected?
    let expect_error: Bool?
}

private struct FingerprintVector: Decodable {
    struct Keys: Decodable {
        let normal: String
        let critical: String
        let ssh: String
    }

    let name: String
    let keys: Keys
    let expected: String
}

struct PairingStringVectorTests {
    private func file() throws -> PairingFile {
        let file = try JSONDecoder().decode(PairingFile.self, from: ContractsLocation.data("vectors/pairing.json"))
        #expect(file.version == 1)
        return file
    }

    @Test func pairingStrings() throws {
        let vectors = try file().vectors
        #expect(vectors.contains { $0.expected != nil })
        #expect(vectors.contains { $0.expect_error == true })
        for vector in vectors {
            if vector.expect_error == true {
                #expect(throws: PairingString.ParseError.self, "\(vector.name): must be rejected") {
                    try PairingString(parsing: vector.string, allowLocalHTTP: true)
                }
                continue
            }
            let expected = try #require(vector.expected, "\(vector.name): no expected")
            let parsed = try PairingString(parsing: vector.string, allowLocalHTTP: true)
            #expect(expected.v == 1)
            #expect(parsed.url.absoluteString == expected.url, "\(vector.name): url")
            #expect(Base64.encode(parsed.coreKey.x963Representation) == expected.core_key, "\(vector.name): core_key")
            #expect(parsed.code == expected.code, "\(vector.name): code")
            #expect(ProtocolTime.format(parsed.exp) == expected.exp, "\(vector.name): exp")
        }
    }

    /// Release builds parse with allowLocalHTTP false: the dev core is refused there.
    @Test func localHTTPOnlyWhenAllowed() throws {
        for vector in try file().vectors {
            guard let expected = vector.expected else { continue }
            if expected.url.hasPrefix("http://") {
                #expect(throws: PairingString.ParseError.url, "\(vector.name)") {
                    try PairingString(parsing: vector.string, allowLocalHTTP: false)
                }
            } else {
                #expect(throws: Never.self, "\(vector.name)") {
                    try PairingString(parsing: vector.string, allowLocalHTTP: false)
                }
            }
        }
    }

    @Test func expiry() throws {
        let vector = try #require(try file().vectors.first { $0.expected != nil })
        let parsed = try PairingString(parsing: vector.string, allowLocalHTTP: true)
        #expect(!parsed.isExpired(now: parsed.exp.addingTimeInterval(-1)))
        #expect(parsed.isExpired(now: parsed.exp))
    }

    @Test func fingerprints() throws {
        let vectors = try file().fingerprints
        #expect(!vectors.isEmpty)
        for vector in vectors {
            let keys = DeviceKeys(
                normal: try #require(Base64.decode(vector.keys.normal)),
                critical: try #require(Base64.decode(vector.keys.critical)),
                ssh: try #require(Base64.decode(vector.keys.ssh))
            )
            #expect(keys.fingerprint == vector.expected, "\(vector.name)")
        }
    }
}
