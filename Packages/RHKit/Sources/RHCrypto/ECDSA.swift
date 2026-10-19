import CryptoKit
import Foundation

/// ECDSA P-256 / SHA-256 with DER signatures and X9.63 public keys (contracts/vectors/ecdsa.json).
public enum ECDSA {
    /// Parses a 65-byte uncompressed X9.63 point given as padded base64.
    public static func publicKey(x963Base64 text: String) -> P256.Signing.PublicKey? {
        guard let bytes = Base64.decode(text) else { return nil }
        return publicKey(x963: bytes)
    }

    public static func publicKey(x963 bytes: Data) -> P256.Signing.PublicKey? {
        guard bytes.count == 65, bytes.first == 0x04 else { return nil }
        return try? P256.Signing.PublicKey(x963Representation: bytes)
    }

    /// Verifies a DER signature over `message` (hashed with SHA-256 here).
    /// High-S signatures are valid: Security.framework and the core may emit either form.
    public static func isValid(signatureDER: Data, message: Data, publicKey: P256.Signing.PublicKey) -> Bool {
        guard let parsed = parseDER(signatureDER) else { return false }
        if verify(r: parsed.r, s: parsed.s, message: message, publicKey: publicKey) { return true }
        // (r, s) and (r, n − s) are the same signature; try the other half of the range.
        guard let flipped = subtract(curveOrder, parsed.s) else { return false }
        return verify(r: parsed.r, s: flipped, message: message, publicKey: publicKey)
    }

    public static func isValid(signatureBase64: String, message: Data, publicKey: P256.Signing.PublicKey) -> Bool {
        guard let der = Base64.decode(signatureBase64) else { return false }
        return isValid(signatureDER: der, message: message, publicKey: publicKey)
    }

    private static func verify(r: [UInt8], s: [UInt8], message: Data, publicKey: P256.Signing.PublicKey) -> Bool {
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: r + s) else { return false }
        return publicKey.isValidSignature(signature, for: message)
    }

    // MARK: - DER

    /// SEQUENCE { INTEGER r, INTEGER s } in strict DER, returned as two 32-byte big-endian values.
    static func parseDER(_ der: Data) -> (r: [UInt8], s: [UInt8])? {
        let bytes = Array(der)
        guard bytes.count >= 8, bytes[0] == 0x30 else { return nil }
        // At most 2 + 2·(2 + 33) = 72 bytes, so the length always fits the short form.
        guard bytes[1] < 0x80, Int(bytes[1]) == bytes.count - 2 else { return nil }
        var offset = 2
        guard let r = parseInteger(bytes, &offset), let s = parseInteger(bytes, &offset),
              offset == bytes.count
        else { return nil }
        return (r, s)
    }

    private static func parseInteger(_ bytes: [UInt8], _ offset: inout Int) -> [UInt8]? {
        guard offset + 2 <= bytes.count, bytes[offset] == 0x02 else { return nil }
        let length = Int(bytes[offset + 1])
        let start = offset + 2
        guard length >= 1, length <= 33, start + length <= bytes.count else { return nil }
        var value = Array(bytes[start..<start + length])
        offset = start + length
        // Positive and minimally encoded: a leading 0x00 only when the next byte has its top bit set.
        guard value[0] & 0x80 == 0 else { return nil }
        if value[0] == 0x00 {
            guard value.count > 1, value[1] & 0x80 != 0 else { return nil }
            value.removeFirst()
        }
        guard value.count <= 32 else { return nil }
        let padded = [UInt8](repeating: 0, count: 32 - value.count) + value
        guard padded.contains(where: { $0 != 0 }), lessThan(padded, curveOrder) else { return nil }
        return padded
    }

    // MARK: - 256-bit arithmetic

    /// Order n of the P-256 group.
    static let curveOrder: [UInt8] = [
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
    ]

    private static func lessThan(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return false
    }

    /// a − b for 32-byte big-endian values, nil when b > a.
    private static func subtract(_ a: [UInt8], _ b: [UInt8]) -> [UInt8]? {
        guard !lessThan(a, b) else { return nil }
        var result = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for index in stride(from: 31, through: 0, by: -1) {
            var digit = Int(a[index]) - Int(b[index]) - borrow
            borrow = digit < 0 ? 1 : 0
            if digit < 0 { digit += 256 }
            result[index] = UInt8(digit)
        }
        return result
    }
}

public enum Digest {
    /// sha256 as lowercase hex: the `body` field of every signed object.
    public static func sha256Hex<D: DataProtocol>(_ bytes: D) -> String {
        Hex.encode(SHA256.hash(data: bytes))
    }
}
