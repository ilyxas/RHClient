import Foundation

/// Byte encodings used by the protocol. Decoders are strict: they accept only the
/// one spelling the encoder produces, so a value never has two valid forms.
public enum Base64 {
    /// RFC 4648 §4, standard alphabet, padded: keys, nonces, signatures, X-RH-Auth.
    public static func encode<D: DataProtocol>(_ bytes: D) -> String {
        Data(bytes).base64EncodedString()
    }

    public static func decode(_ text: String) -> Data? {
        guard let data = Data(base64Encoded: text), data.base64EncodedString() == text else { return nil }
        return data
    }

    /// RFC 4648 §5 without padding: the pairing string.
    public static func encodeURLNoPadding<D: DataProtocol>(_ bytes: D) -> String {
        String(encode(bytes).compactMap { char -> Character? in
            switch char {
            case "+": "-"
            case "/": "_"
            case "=": nil
            default: char
            }
        })
    }

    public static func decodeURLNoPadding(_ text: String) -> Data? {
        let allowed = text.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                true
            default:
                false
            }
        }
        guard allowed, text.utf8.count % 4 != 1 else { return nil }
        var standard = String(text.map { char -> Character in
            switch char {
            case "-": "+"
            case "_": "/"
            default: char
            }
        })
        standard += String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)
        guard let data = decode(standard), encodeURLNoPadding(data) == text else { return nil }
        return data
    }
}

public enum Hex {
    /// Lowercase hex, as the protocol writes sha256 digests and device ids.
    public static func encode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
