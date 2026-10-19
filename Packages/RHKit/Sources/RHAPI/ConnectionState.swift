/// What the app shows about the link to the Mac (PLAN, stage 1).
public enum ConnectionState: Equatable, Sendable {
    /// Last signed call succeeded: "Connected · Secure session".
    case connected
    case unreachable
    /// The core refused a request for a reason that does not end the pairing (clock, nonce, …).
    case authError(code: String)
    /// Re-pair needed: device unknown or revoked, or the core's signature does not verify.
    case pairingLost

    /// State after a failed call; nil when the error says nothing about the connection.
    public init?(error: any Error) {
        guard let error = error as? CoreClientError else { return nil }
        switch error {
        case .rejected(let rejection) where rejection.code == .badRequest || rejection.code == .notFound:
            // The link is fine; this one request was wrong.
            return nil
        case .rejected(let rejection):
            self = rejection.losesPairing ? .pairingLost : .authError(code: rejection.rawCode)
        case .badServerSignature:
            self = .pairingLost
        case .unreachable:
            self = .unreachable
        case .unexpectedResponse(let status):
            self = .authError(code: "http_\(status)")
        }
    }
}
