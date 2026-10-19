import CryptoKit
import Foundation
import Testing

/// docs/decisions/0001-secure-enclave-in-simulator.md: pins what the simulator does.
/// If this fails on a new Xcode, update the decision record.
struct SecureEnclaveAvailabilityTests {
    @Test func simulatorSecureEnclaveSignsAndVerifies() throws {
        #if targetEnvironment(simulator)
        #expect(SecureEnclave.isAvailable)
        let key = try SecureEnclave.P256.Signing.PrivateKey()
        let message = Data("rh-secure-enclave-probe".utf8)
        let signature = try key.signature(for: message)
        #expect(key.publicKey.isValidSignature(signature, for: message))
        #endif
    }
}
