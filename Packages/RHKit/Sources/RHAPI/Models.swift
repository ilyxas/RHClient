import Foundation
import RHCrypto

// Request and response bodies of contracts/api/openapi.yaml. Timestamps stay strings
// (ProtocolTime parses them) so that a body decodes the same way everywhere.

public struct ChallengeRequest: Encodable, Sendable {
    public let device: String

    public init(device: String) {
        self.device = device
    }
}

public struct ChallengeResponse: Decodable, Equatable, Sendable {
    public let nonce: String
    public let expires: String
    public let serverTime: String

    enum CodingKeys: String, CodingKey {
        case nonce
        case expires
        case serverTime = "server_time"
    }
}

public struct PairRequest: Encodable, Sendable {
    public struct Keys: Encodable, Sendable {
        public let normal: String
        public let critical: String
        public let ssh: String
    }

    /// 1–64 characters, shown in the terminal.
    public let name: String
    public let keys: Keys
    /// The device id this phone had before, when re-pairing.
    public let replaces: String?

    public init(name: String, keys: DeviceKeys, replaces: String?) {
        self.name = name
        self.keys = Keys(
            normal: Base64.encode(keys.normal),
            critical: Base64.encode(keys.critical),
            ssh: Base64.encode(keys.ssh)
        )
        self.replaces = replaces
    }
}

public struct PairResponse: Decodable, Equatable, Sendable {
    public let deviceID: String
    public let macName: String
    /// OpenSSH public host key lines of the Mac's sshd; may be empty.
    public let sshHostKeys: [String]

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case macName = "mac_name"
        case sshHostKeys = "ssh_host_keys"
    }
}

public struct PingResponse: Decodable, Equatable, Sendable {
    public let pong: Bool
    public let serverTime: String

    enum CodingKeys: String, CodingKey {
        case pong
        case serverTime = "server_time"
    }
}

public struct StatusResponse: Decodable, Equatable, Sendable {
    public enum Mode: String, Decodable, Sendable {
        case dev
        case production
    }

    public let macName: String
    public let coreVersion: String
    /// nil until rh-agent exists (stage 3) or while it is not running.
    public let agentVersion: String?
    public let mode: Mode
    public let serverTime: String

    enum CodingKeys: String, CodingKey {
        case macName = "mac_name"
        case coreVersion = "core_version"
        case agentVersion = "agent_version"
        case mode
        case serverTime = "server_time"
    }
}

public struct DevicesResponse: Decodable, Equatable, Sendable {
    public struct Device: Decodable, Equatable, Sendable, Identifiable {
        public enum Status: String, Decodable, Sendable {
            case active
            case revoked
        }

        public let id: String
        public let name: String
        public let fingerprint: String
        public let pairedAt: String
        public let revokedAt: String?
        public let status: Status
        /// true for the device that sent the request.
        public let current: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case fingerprint
            case pairedAt = "paired_at"
            case revokedAt = "revoked_at"
            case status
            case current
        }
    }

    /// Newest first.
    public let devices: [Device]
}

public struct RevokeRequest: Encodable, Sendable {
    public let deviceID: String

    public init(deviceID: String) {
        self.deviceID = deviceID
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
    }
}

public struct RevokeResponse: Decodable, Equatable, Sendable {
    public let deviceID: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case status
    }
}

/// friend.send body: `to` is always "Friend"; `id` is this phone's message id.
public struct FriendSendRequest: Encodable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let to: String

    public init(id: String = UUID().uuidString, text: String) {
        self.id = id
        self.text = text
        self.to = "Friend"
    }

    /// Sorted keys, no spaces, UTF-8 as is — the encoding of contracts/vectors/friend.json.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct FriendSendResponse: Decodable, Equatable, Sendable {
    /// Where the core keeps the signed request; the Friend session sees ⟦rh:<id>⟧.
    public let id: String
    public let messageID: String
    public let acceptedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case messageID = "message_id"
        case acceptedAt = "accepted_at"
    }
}
