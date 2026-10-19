import Foundation
import Testing
@testable import RHAPI

struct CoreErrorTests {
    @Test func decodesErrorBody() throws {
        let body = Data(#"{"error":{"code":"revoked_device","message":"device revoked"}}"#.utf8)
        let error = try #require(CoreError(status: 403, body: body))
        #expect(error.code == .revokedDevice)
        #expect(error.message == "device revoked")
        #expect(error.losesPairing)
    }

    @Test func pairingLostOnlyForUnknownAndRevoked() {
        let losing = ["unknown_device", "revoked_device"]
        for code in ["malformed_auth", "unknown_device", "revoked_device", "wrong_key_level", "op_mismatch",
                     "nonce_unknown", "nonce_used", "nonce_expired", "expired", "clock_skew", "body_mismatch",
                     "bad_signature", "bad_pair_code", "pair_rejected", "peer_mismatch", "not_found"] {
            let error = CoreError(status: 403, rawCode: code, message: "")
            #expect(error.code != nil, "\(code) is known")
            #expect(error.losesPairing == losing.contains(code), "\(code)")
        }
    }

    @Test func unknownCodeIsKept() throws {
        let error = try #require(CoreError(status: 401, body: Data(#"{"error":{"code":"new_code","message":"m"}}"#.utf8)))
        #expect(error.code == nil)
        #expect(error.rawCode == "new_code")
        #expect(!error.losesPairing)
        #expect(CoreError(status: 500, body: Data("oops".utf8)) == nil)
    }
}
