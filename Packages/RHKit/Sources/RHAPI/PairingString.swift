import CryptoKit
import Foundation
import RHCrypto

/// What `rhcore pair` puts in the QR code (contracts/vectors/pairing.json):
/// "rhpair:" + base64url without padding of JCS {"v":1,"url","core_key","code","exp"}.
public struct PairingString: Sendable {
    public static let prefix = "rhpair:"
    public static let minimumCodeBytes = 16

    /// https://host[:port]; http://127.0.0.1:port only when parsed with `allowLocalHTTP`.
    public let url: URL
    /// The core's public key, 65-byte X9.63; checked to be a valid point.
    public let coreKeyX963: Data
    /// The one-time pairing code, base64 as given: the nonce of the pair request.
    public let code: String
    public let exp: Date

    public enum ParseError: Error, Equatable, Sendable {
        case prefix
        case encoding
        case json
        case fields
        case version
        case url
        case coreKey
        case code
        case exp
    }

    /// `allowLocalHTTP`: the dev core on http://127.0.0.1 (Debug builds only).
    public init(parsing text: String, allowLocalHTTP: Bool) throws(ParseError) {
        guard text.hasPrefix(Self.prefix) else { throw .prefix }
        guard let payload = Base64.decodeURLNoPadding(String(text.dropFirst(Self.prefix.count))),
              let json = String(data: payload, encoding: .utf8)
        else { throw .encoding }
        guard case .object(let members)? = try? JCS.parse(json) else { throw .json }
        guard Set(members.keys) == ["v", "url", "core_key", "code", "exp"] else { throw .fields }
        guard members["v"] == .integer(1) else { throw .version }

        guard case .string(let urlText)? = members["url"], let url = Self.coreURL(urlText, allowLocalHTTP: allowLocalHTTP)
        else { throw .url }
        guard case .string(let keyText)? = members["core_key"], let coreKey = ECDSA.publicKey(x963Base64: keyText)
        else { throw .coreKey }
        guard case .string(let code)? = members["code"], let codeBytes = Base64.decode(code),
              codeBytes.count >= Self.minimumCodeBytes
        else { throw .code }
        guard case .string(let expText)? = members["exp"], let exp = ProtocolTime.parse(expText) else { throw .exp }

        self.url = url
        self.coreKeyX963 = coreKey.x963Representation
        self.code = code
        self.exp = exp
    }

    public var coreKey: P256.Signing.PublicKey {
        // Validated in init.
        ECDSA.publicKey(x963: coreKeyX963)!
    }

    public func isExpired(now: Date) -> Bool {
        now >= exp
    }

    private static func coreURL(_ text: String, allowLocalHTTP: Bool) -> URL? {
        guard let parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
              parts.user == nil, parts.password == nil
        else { return nil }
        switch parts.scheme {
        case "https":
            break
        case "http" where allowLocalHTTP && host == "127.0.0.1" && parts.port != nil:
            break
        default:
            return nil
        }
        return parts.url
    }
}
