import Foundation

/// A rejection from the core: {"error":{"code","message"}} (SPEC §4.3, openapi ErrorCode).
public struct CoreError: Error, Equatable, Sendable {
    public enum Code: String, Sendable {
        case malformedAuth = "malformed_auth"
        case unknownDevice = "unknown_device"
        case revokedDevice = "revoked_device"
        case wrongKeyLevel = "wrong_key_level"
        case opMismatch = "op_mismatch"
        case nonceUnknown = "nonce_unknown"
        case nonceUsed = "nonce_used"
        case nonceExpired = "nonce_expired"
        case expired
        case clockSkew = "clock_skew"
        case bodyMismatch = "body_mismatch"
        case badSignature = "bad_signature"
        case badPairCode = "bad_pair_code"
        case pairRejected = "pair_rejected"
        case peerMismatch = "peer_mismatch"
        /// The signature checks passed but the body does not fit the operation (stage 2 operations onwards).
        case badRequest = "bad_request"
        /// /v1/devices/revoke only.
        case notFound = "not_found"
    }

    public let status: Int
    /// nil when the core sent a code this client does not know yet.
    public let code: Code?
    public let rawCode: String
    public let message: String

    /// The phone is no longer paired with this Mac: show "Pairing lost" and offer Re-pair.
    /// (A response whose X-RH-Server-Sig does not verify means the same; that is checked before decoding.)
    public var losesPairing: Bool {
        code == .unknownDevice || code == .revokedDevice
    }

    public init(status: Int, rawCode: String, message: String) {
        self.status = status
        self.code = Code(rawValue: rawCode)
        self.rawCode = rawCode
        self.message = message
    }

    /// Decodes an error body; nil when it is not one.
    public init?(status: Int, body: Data) {
        guard let decoded = try? JSONDecoder().decode(Body.self, from: body) else { return nil }
        self.init(status: status, rawCode: decoded.error.code, message: decoded.error.message)
    }

    private struct Body: Decodable {
        struct Inner: Decodable {
            let code: String
            let message: String
        }

        let error: Inner
    }
}
