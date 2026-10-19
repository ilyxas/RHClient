import Foundation

public enum KeyLevel: String, Codable, Sendable {
    case normal
    case critical
}

/// The object a request signs (SPEC §4.3), sent as X-RH-Auth.
public struct SignedObject: Equatable, Sendable {
    /// exp may be at most this far after ts.
    public static let maxLifetime: TimeInterval = 60

    public let device: String
    public let key: KeyLevel
    public let nonce: String
    public let ts: Date
    public let exp: Date
    public let op: String
    /// sha256 hex of the raw body bytes (of no bytes for GET).
    public let bodySHA256: String

    public init(device: String, key: KeyLevel, nonce: String, ts: Date, exp: Date, op: String, bodySHA256: String) {
        self.device = device
        self.key = key
        self.nonce = nonce
        self.ts = ProtocolTime.truncated(ts)
        self.exp = ProtocolTime.truncated(exp)
        self.op = op
        self.bodySHA256 = bodySHA256
    }

    /// ts = now in whole seconds, exp = ts + 60 s.
    public init(device: String, key: KeyLevel, nonce: String, op: String, body: Data, now: Date) {
        let ts = ProtocolTime.truncated(now)
        self.init(
            device: device, key: key, nonce: nonce, ts: ts, exp: ts.addingTimeInterval(Self.maxLifetime),
            op: op, bodySHA256: Digest.sha256Hex(body)
        )
    }

    public var canonicalBytes: [UInt8] {
        JCS.canonicalize(.object([
            "v": .integer(1),
            "device": .string(device),
            "key": .string(key.rawValue),
            "nonce": .string(nonce),
            "ts": .string(ProtocolTime.format(ts)),
            "exp": .string(ProtocolTime.format(exp)),
            "op": .string(op),
            "body": .string(bodySHA256),
        ]))
    }
}

/// Signs with the phone's keys. Implementations: Secure Enclave, and in Debug a software key.
public protocol MessageSigner: Sendable {
    /// ECDSA P-256 / SHA-256 signature over `message` in DER, by the key of `level`.
    /// For `.critical` this is where Face ID is asked.
    func signature(for message: Data, level: KeyLevel) async throws -> Data
}

public struct SignedHeaders: Equatable, Sendable {
    public static let authName = "X-RH-Auth"
    public static let signatureName = "X-RH-Sig"
    public static let criticalSignatureName = "X-RH-Sig-Critical"

    public let auth: String
    public let signature: String
    /// Pairing only.
    public let criticalSignature: String?

    public var fields: [String: String] {
        var fields = [Self.authName: auth, Self.signatureName: signature]
        fields[Self.criticalSignatureName] = criticalSignature
        return fields
    }

    /// X-RH-Sig by the key the object names; for pairing also X-RH-Sig-Critical over the same bytes.
    public static func sign(
        _ object: SignedObject, with signer: some MessageSigner, criticalCosignature: Bool = false
    ) async throws -> SignedHeaders {
        let message = Data(object.canonicalBytes)
        let signature = try await signer.signature(for: message, level: object.key)
        var critical: Data?
        if criticalCosignature {
            critical = try await signer.signature(for: message, level: .critical)
        }
        return SignedHeaders(
            auth: Base64.encode(message),
            signature: Base64.encode(signature),
            criticalSignature: critical.map { Base64.encode($0) }
        )
    }
}
