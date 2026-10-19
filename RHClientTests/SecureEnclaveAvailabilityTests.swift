import CryptoKit
import Testing

/// docs/decisions/0001-secure-enclave-in-simulator.md: pins what the simulator reports.
/// If this fails on a new Xcode, update the decision record.
struct SecureEnclaveAvailabilityTests {
    @Test func simulatorHasNoSecureEnclave() {
        #if targetEnvironment(simulator)
        #expect(!SecureEnclave.isAvailable)
        #endif
    }
}
