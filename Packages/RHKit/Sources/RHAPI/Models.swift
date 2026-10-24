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

/// What the owner asks for. A question is answered in text (the agent's gate lets read-only tools
/// through and routes anything else through a decision); a task lets the agent work.
public enum MessageKind: String, Codable, Equatable, Sendable, CaseIterable {
    case question
    case task
}

/// friend.send body: `to` is the channel agent (`status.channel.agent`); `id` is this phone's
/// message id; `kind` (default question) and `re` (the message this one follows up, "make it a
/// task") are only in the body when set. "friend" names the mechanism, not the agent.
public struct FriendSendRequest: Encodable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let to: String
    public let kind: MessageKind?
    public let re: String?

    public init(id: String = UUID().uuidString, text: String, to agent: String, kind: MessageKind? = nil, re: String? = nil) {
        self.id = id
        self.text = text
        self.to = agent
        self.kind = kind
        self.re = re
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

// MARK: - friend.messages

/// friend.messages body: everything changed after `since` (the `next` of the previous answer).
public struct FriendMessagesRequest: Encodable, Equatable, Sendable {
    public var since: Int
    public var limit: Int

    public init(since: Int = 0, limit: Int = 50) {
        self.since = since
        self.limit = limit
    }
}

/// One reply of the agent to an owner's message: progress on the way, or the final answer.
public struct FriendReply: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case progress
        case final
    }

    public let seq: Int
    public let kind: Kind
    public let text: String
    public let at: String

    public var id: Int { seq }

    public init(seq: Int, kind: Kind, text: String, at: String) {
        self.seq = seq
        self.kind = kind
        self.text = text
        self.at = at
    }
}

/// An owner's message as the core keeps it: its state and the agent's replies. The states after
/// accepted, the reject code and the replies are what the agent side reported over the Mac's
/// local socket, unsigned; accepted and superseded are the core's own.
public struct FriendMessage: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Equatable, Sendable {
        /// The core has it; the bridge delivers the pointer to the agent's session.
        case accepted
        /// The agent-side verifier delivered it to the session.
        case received
        /// The agent asked the owner a decision since; the reply so far is progress.
        case waiting
        /// The final reply is in `replies`.
        case answered
        /// The verifier blocked it; `rejectCode` says why.
        case rejected
        /// A newer message from the owner replaced it; `supersededBy` names it.
        case superseded

        /// The agent still owes an answer.
        public var isOpen: Bool { self == .accepted || self == .received || self == .waiting }
    }

    /// Spool id, as friend.send answered; the agent's session sees ⟦rh:<id>⟧.
    public let id: String
    /// Changes on every update; the cursor of friend.messages.
    public let seq: Int
    public let messageID: String
    public let device: String
    public let agent: String
    public let kind: MessageKind
    public let re: String?
    public let text: String
    public let acceptedAt: String
    public let state: State
    public let receivedAt: String?
    public let closedAt: String?
    public let rejectCode: String?
    public let supersededBy: String?
    public let replies: [FriendReply]

    public init(
        id: String, seq: Int, messageID: String, device: String, agent: String, kind: MessageKind, re: String? = nil,
        text: String, acceptedAt: String, state: State, receivedAt: String? = nil, closedAt: String? = nil,
        rejectCode: String? = nil, supersededBy: String? = nil, replies: [FriendReply] = []
    ) {
        self.id = id
        self.seq = seq
        self.messageID = messageID
        self.device = device
        self.agent = agent
        self.kind = kind
        self.re = re
        self.text = text
        self.acceptedAt = acceptedAt
        self.state = state
        self.receivedAt = receivedAt
        self.closedAt = closedAt
        self.rejectCode = rejectCode
        self.supersededBy = supersededBy
        self.replies = replies
    }

    enum CodingKeys: String, CodingKey {
        case id, seq, device, agent, kind, re, text, state, replies
        case messageID = "message_id"
        case acceptedAt = "accepted_at"
        case receivedAt = "received_at"
        case closedAt = "closed_at"
        case rejectCode = "reject_code"
        case supersededBy = "superseded_by"
    }

    /// The agent's final answer, if any.
    public var finalReply: FriendReply? { replies.last { $0.kind == .final } }
}

public struct FriendMessagesResponse: Decodable, Equatable, Sendable {
    /// Oldest change first.
    public let messages: [FriendMessage]
    /// `since` for the next call; unchanged when nothing changed.
    public let next: Int
    /// More changed messages follow: call again with `next`.
    public let more: Bool
    public let serverTime: String

    enum CodingKeys: String, CodingKey {
        case messages, next, more
        case serverTime = "server_time"
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
