import CryptoKit
import Foundation
import RHCrypto

/// Same as RHCryptoTests/TestSigner.swift: software keys for tests.
struct TestSigner: MessageSigner {
    let normal: Data
    let critical: Data

    init(normal: Data, critical: Data) {
        self.normal = normal
        self.critical = critical
    }

    init() {
        self.init(
            normal: P256.Signing.PrivateKey().rawRepresentation,
            critical: P256.Signing.PrivateKey().rawRepresentation
        )
    }

    func privateKey(_ level: KeyLevel) throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: level == .normal ? normal : critical)
    }

    func signature(for message: Data, level: KeyLevel) async throws -> Data {
        try privateKey(level).signature(for: message).derRepresentation
    }
}
