import Foundation
import RHAPI

/// What the phone keeps about the Mac it is paired with (Keychain, SPEC §4.2).
struct PairingRecord: Codable, Equatable, Sendable {
    static let account = "pairing"

    let coreURL: URL
    let coreKeyX963: Data
    let deviceID: String
    let macName: String
    /// OpenSSH host key lines from the pair response, for the terminal (stage 6).
    let sshHostKeys: [String]

    var endpoint: CoreEndpoint {
        CoreEndpoint(baseURL: coreURL, coreKeyX963: coreKeyX963, deviceID: deviceID)
    }

    static func load(from store: any SecretStore) throws -> PairingRecord? {
        try store.load(account).map { try JSONDecoder().decode(PairingRecord.self, from: $0) }
    }

    func save(to store: any SecretStore) throws {
        try store.save(JSONEncoder().encode(self), as: Self.account)
    }
}
