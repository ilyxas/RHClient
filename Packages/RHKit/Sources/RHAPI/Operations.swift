import RHCrypto

/// A core API operation as contracts/api/openapi.yaml declares it (x-rh-op, x-rh-key).
public struct CoreOperation: Equatable, Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public enum Auth: Equatable, Sendable {
        /// Not signed: /v1/challenge.
        case none
        /// Signed with the key of this level after a challenge.
        case signed(KeyLevel)
        /// /v1/pair: key "normal", nonce = pairing code, signed by both the normal and the critical key.
        case pairing
    }

    public let op: String
    public let method: Method
    public let path: String
    public let auth: Auth

    public init(op: String, method: Method, path: String, auth: Auth) {
        self.op = op
        self.method = method
        self.path = path
        self.auth = auth
    }

    public static let challenge = CoreOperation(op: "challenge", method: .post, path: "/v1/challenge", auth: .none)
    public static let pair = CoreOperation(op: "pair", method: .post, path: "/v1/pair", auth: .pairing)
    public static let ping = CoreOperation(op: "ping", method: .post, path: "/v1/ping", auth: .signed(.normal))
    public static let status = CoreOperation(op: "status", method: .get, path: "/v1/status", auth: .signed(.normal))
    public static let devicesList = CoreOperation(op: "devices.list", method: .get, path: "/v1/devices", auth: .signed(.normal))
    public static let devicesRevoke = CoreOperation(
        op: "devices.revoke", method: .post, path: "/v1/devices/revoke", auth: .signed(.critical)
    )
    public static let wsOpen = CoreOperation(op: "ws.open", method: .get, path: "/v1/ws", auth: .signed(.normal))
    // Reads with parameters are POST, so the signed body hash covers the parameters.
    public static let dataGet = CoreOperation(op: "data.get", method: .post, path: "/v1/data", auth: .signed(.normal))
    public static let logList = CoreOperation(op: "log.list", method: .post, path: "/v1/log", auth: .signed(.normal))
    public static let quickList = CoreOperation(op: "quick.list", method: .get, path: "/v1/quick", auth: .signed(.normal))
    /// A message to the channel agent; its verifier re-checks this signature itself.
    public static let friendSend = CoreOperation(op: "friend.send", method: .post, path: "/v1/friend", auth: .signed(.normal))
    /// The owner's messages with their state and the agent's replies, changed after a cursor. A read
    /// with parameters, so POST: the signed body hash covers the cursor.
    public static let friendMessages = CoreOperation(
        op: "friend.messages", method: .post, path: "/v1/friend/messages", auth: .signed(.normal)
    )
    /// Open questions of the channel agent: text and the exact action, shown in full.
    public static let friendQuestions = CoreOperation(
        op: "friend.questions", method: .get, path: "/v1/friend/questions", auth: .signed(.normal)
    )
    /// The owner's decision. The key level follows the decision: allow needs the critical key
    /// (a fresh Face ID), deny the normal one; the core refuses the other way round.
    public static func friendDecide(_ decision: FriendDecision) -> CoreOperation {
        CoreOperation(op: "friend.decide", method: .post, path: "/v1/friend/decide", auth: .signed(decision.keyLevel))
    }
}
