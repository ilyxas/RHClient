import CryptoKit
import Foundation

/// X-RH-Server-Sig: the core key's signature over JCS {"v":1,"nonce","status","body"}.
/// The client rejects any core response without a valid one.
public enum ServerSignature {
    public static let headerName = "X-RH-Server-Sig"

    /// `nonce`: the request nonce; for /v1/challenge the issued one ("" when refused),
    /// for /v1/pair the pairing code.
    public static func message(nonce: String, status: Int, body: Data) -> [UInt8] {
        JCS.canonicalize(.object([
            "v": .integer(1),
            "nonce": .string(nonce),
            "status": .integer(Int64(status)),
            "body": .string(Digest.sha256Hex(body)),
        ]))
    }

    public static func isValid(
        _ signatureBase64: String?, nonce: String, status: Int, body: Data, coreKey: P256.Signing.PublicKey
    ) -> Bool {
        guard let signatureBase64 else { return false }
        return ECDSA.isValid(
            signatureBase64: signatureBase64, message: Data(message(nonce: nonce, status: status, body: body)),
            publicKey: coreKey
        )
    }
}
