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
    /// The one agent on the channel: `to` of every message and decision, and its name on screen.
    public let channel: Channel

    enum CodingKeys: String, CodingKey {
        case macName = "mac_name"
        case coreVersion = "core_version"
        case agentVersion = "agent_version"
        case mode
        case serverTime = "server_time"
        case channel
    }
}

/// `status.channel`: the agent the owner put on the channel (the core's `[channel] agent`).
/// It can change between two status calls when the owner switches the agent.
public struct Channel: Decodable, Equatable, Sendable {
    public let agent: String
    public let title: String

    public init(agent: String, title: String) {
        self.agent = agent
        self.title = title
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

/// friend.send body: `to` is the channel agent (`status.channel.agent`); `id` is this phone's
/// message id. "friend" names the mechanism, not the agent.
public struct FriendSendRequest: Encodable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let to: String

    public init(id: String = UUID().uuidString, text: String, to agent: String) {
        self.id = id
        self.text = text
        self.to = agent
    }

    /// Sorted keys, no spaces, UTF-8 as is — the encoding of contracts/vectors/friend.json.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct FriendSendResponse: Decodable, Equatable, Sendable {
    /// Where the core keeps the signed request; the agent's session sees ⟦rh:<id>⟧.
    public let id: String
    public let messageID: String
    public let acceptedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case messageID = "message_id"
        case acceptedAt = "accepted_at"
    }
}

// MARK: - friend.questions / friend.decide

/// A question the channel agent asked before a protected action. `action` is canonical JSON
/// of the exact tool call; the phone shows it as is and signs it as is.
public struct FriendQuestion: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let action: String
    public let askedAt: String

    public init(id: String, text: String, action: String, askedAt: String) {
        self.id = id
        self.text = text
        self.action = action
        self.askedAt = askedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, text, action
        case askedAt = "asked_at"
    }

    /// sha256 of the text as shown (UTF-8): what the decision names.
    public var textSHA256: String {
        Digest.sha256Hex(Data(text.utf8))
    }

    /// The tool the action names, for a one-line summary; nil when the action is not readable.
    public var tool: String? {
        guard case .object(let members)? = try? JCS.parse(action), case .string(let tool)? = members["tool"] else { return nil }
        return tool
    }
}

public struct FriendQuestionsResponse: Decodable, Equatable, Sendable {
    /// Oldest first.
    public let questions: [FriendQuestion]
    public let serverTime: String

    enum CodingKeys: String, CodingKey {
        case questions
        case serverTime = "server_time"
    }
}

public enum FriendDecision: String, Codable, Equatable, Sendable {
    case allow
    case deny

    /// allow: critical (fresh Face ID); deny: normal.
    public var keyLevel: KeyLevel {
        self == .allow ? .critical : .normal
    }
}

/// friend.decide body: the question answered, the hash of its text as shown, its action unchanged.
public struct FriendDecideRequest: Encodable, Equatable, Sendable {
    public let to: String
    public let id: String
    public let questionSHA256: String
    public let action: String
    public let decision: FriendDecision

    public init(question: FriendQuestion, decision: FriendDecision, to agent: String) {
        self.to = agent
        self.id = question.id
        self.questionSHA256 = question.textSHA256
        self.action = question.action
        self.decision = decision
    }

    enum CodingKeys: String, CodingKey {
        case to, id, action, decision
        case questionSHA256 = "question_sha256"
    }

    /// Sorted keys, no spaces, UTF-8 as is — the encoding of contracts/vectors/friend_decide.json.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct FriendDecideResponse: Decodable, Equatable, Sendable {
    /// Where the core keeps the signed decision; the agent's session sees ⟦rh:<id>⟧.
    public let id: String
    public let questionID: String
    public let decision: FriendDecision
    public let acceptedAt: String

    enum CodingKeys: String, CodingKey {
        case id, decision
        case questionID = "question_id"
        case acceptedAt = "accepted_at"
    }
}
