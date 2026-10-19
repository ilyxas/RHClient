import Foundation

/// The three public keys a phone registers at pairing, as X9.63 bytes.
public struct DeviceKeys: Equatable, Sendable {
    public let normal: Data
    public let critical: Data
    public let ssh: Data

    public init(normal: Data, critical: Data, ssh: Data) {
        self.normal = normal
        self.critical = critical
        self.ssh = ssh
    }

    /// First 32 hex of sha256(normal public key bytes).
    public var deviceID: String { Self.deviceID(normalKey: normal) }

    public static func deviceID(normalKey: Data) -> String {
        String(Digest.sha256Hex(normalKey).prefix(32))
    }

    /// First 16 hex of sha256(JCS {"normal","critical","ssh"} of the base64 keys), in groups of 4.
    /// The terminal shows the same string while it waits for y/n.
    public var fingerprint: String {
        let object = JSONValue.object([
            "normal": .string(Base64.encode(normal)),
            "critical": .string(Base64.encode(critical)),
            "ssh": .string(Base64.encode(ssh)),
        ])
        let hex = Array(Digest.sha256Hex(JCS.canonicalize(object)).prefix(16))
        return stride(from: 0, to: hex.count, by: 4).map { String(hex[$0..<$0 + 4]) }.joined(separator: " ")
    }
}
