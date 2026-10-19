import CryptoKit
import Foundation
import LocalAuthentication
import RHCrypto
import Testing
@testable import RHClient

/// Face ID stand-in: counts prompts and can fail like the system does.
@MainActor
final class FakeFaceID: FaceIDAuthenticating {
    var prompts = 0
    var failure: KeyError?

    func authenticate(reason: String) async throws(KeyError) -> LAContext {
        prompts += 1
        await Task.yield()  // like the real prompt, let other callers run meanwhile
        if let failure { throw failure }
        return LAContext()
    }
}

private func isValid(_ signature: Data, _ message: Data, _ key: StoredKey) throws -> Bool {
    let publicKey = try #require(ECDSA.publicKey(x963: key.publicKeyX963))
    return ECDSA.isValid(signatureDER: signature, message: message, publicKey: publicKey)
}

struct KeyProviderTests {
    @Test func softwareKeysSign() throws {
        let keys = try StoredKeySet.make(with: SoftwareKeyProvider())
        let message = Data("ping".utf8)
        for role in KeyRole.allCases {
            let signature = try SoftwareKeyProvider().signature(for: message, with: keys[role], context: nil)
            #expect(try isValid(signature, message, keys[role]), "\(role)")
        }
        #expect(Set(KeyRole.allCases.map { keys[$0].publicKeyX963 }).count == 3)
    }

    /// The real Secure Enclave path without biometry (the simulator has no Face ID enrolled):
    /// create, store the reference, load it back, sign, verify.
    @Test func secureEnclaveKeySurvivesStoreAndSigns() throws {
        try #require(SecureEnclave.isAvailable)
        let provider = SecureEnclaveKeyProvider(accessFlags: [.privateKeyUsage])
        let store = MemorySecretStore()
        try StoredKeySet.make(with: provider).save(to: store)
        let keys = try #require(try StoredKeySet.load(from: store))
        let message = Data("status".utf8)
        let signature = try provider.signature(for: message, with: keys.critical, context: nil)
        #expect(try isValid(signature, message, keys.critical))
        #expect(throws: KeyError.keyUnavailable) {
            try provider.signature(for: message, with: StoredKey(kind: .secureEnclave, material: Data([1, 2, 3]), publicKeyX963: Data()), context: nil)
        }
    }

    @Test func deviceKeysMatchStoredPublicKeys() throws {
        let keys = try StoredKeySet.make(with: SoftwareKeyProvider())
        #expect(keys.deviceKeys.normal == keys.normal.publicKeyX963)
        #expect(keys.deviceKeys.deviceID == DeviceKeys.deviceID(normalKey: keys.normal.publicKeyX963))
    }

    @Test func keychainRoundTrip() throws {
        let store = KeychainStore(service: "RemoteHands.tests.\(UUID().uuidString)")
        #expect(try store.load("a") == nil)
        try store.save(Data([1]), as: "a")
        try store.save(Data([2]), as: "a")
        #expect(try store.load("a") == Data([2]))
        try store.delete("a")
        #expect(try store.load("a") == nil)
        try store.delete("a")
    }
}

@MainActor
struct SigningSessionTests {
    private func session(_ faceID: FakeFaceID) throws -> SigningSession {
        SigningSession(keys: try StoredKeySet.make(with: SoftwareKeyProvider()), faceID: faceID)
    }

    @Test func normalReusesOneFaceID() async throws {
        let faceID = FakeFaceID()
        let session = try session(faceID)
        let message = Data("ping".utf8)
        let first = try await session.signature(for: message, level: .normal)
        _ = try await session.signature(for: message, level: .normal)
        #expect(faceID.prompts == 1)
        #expect(try isValid(first, message, session.keys.normal))
    }

    @Test func concurrentCallsShareOneFaceID() async throws {
        let faceID = FakeFaceID()
        let session = try session(faceID)
        async let first = session.signature(for: Data("a".utf8), level: .normal)
        async let second = session.signature(for: Data("b".utf8), level: .normal)
        _ = try await (first, second)
        #expect(faceID.prompts == 1)
    }

    @Test func criticalAsksEveryTime() async throws {
        let faceID = FakeFaceID()
        let session = try session(faceID)
        try await session.unlock()
        let message = Data("revoke".utf8)
        let signature = try await session.signature(for: message, level: .critical)
        _ = try await session.signature(for: message, level: .critical)
        #expect(faceID.prompts == 3)
        #expect(try isValid(signature, message, session.keys.critical))
        #expect(try !isValid(signature, message, session.keys.normal))
    }

    @Test func backgroundResetsAfterInterval() async throws {
        let faceID = FakeFaceID()
        let session = try session(faceID)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try await session.unlock()

        session.didEnterBackground(at: start)
        session.willEnterForeground(at: start.addingTimeInterval(SigningSession.defaultResetInterval - 1))
        #expect(session.isUnlocked)

        session.didEnterBackground(at: start)
        session.willEnterForeground(at: start.addingTimeInterval(SigningSession.defaultResetInterval))
        #expect(!session.isUnlocked)
        _ = try await session.signature(for: Data(), level: .normal)
        #expect(faceID.prompts == 2)
    }

    @Test func cancelledFaceIDIsNotPairingLost() async throws {
        let faceID = FakeFaceID()
        faceID.failure = .cancelled
        let session = try session(faceID)
        await #expect(throws: KeyError.cancelled) {
            try await session.signature(for: Data(), level: .normal)
        }
        await #expect(throws: KeyError.cancelled) {
            try await session.signature(for: Data(), level: .critical)
        }
    }

    /// Face ID passes but the key cannot sign: after one retry with a new Face ID it is Pairing lost.
    @Test func brokenKeyIsUnavailable() async throws {
        let faceID = FakeFaceID()
        let dead = StoredKey(kind: .software, material: Data([0]), publicKeyX963: Data())
        let session = SigningSession(keys: StoredKeySet(normal: dead, critical: dead, ssh: dead), faceID: faceID)
        await #expect(throws: KeyError.keyUnavailable) {
            try await session.signature(for: Data(), level: .normal)
        }
        #expect(faceID.prompts == 2)
    }

    @Test func faceIDErrorsMapToKeyErrors() {
        #expect(SystemFaceID.keyError(LAError(.userCancel)) == .cancelled)
        #expect(SystemFaceID.keyError(LAError(.systemCancel)) == .cancelled)
        #expect(SystemFaceID.keyError(LAError(.authenticationFailed)) == .authenticationFailed)
        #expect(SystemFaceID.keyError(LAError(.biometryNotEnrolled)) == .biometryUnavailable)
        #expect(SystemFaceID.keyError(LAError(.biometryLockout)) == .biometryUnavailable)
        #expect(SystemFaceID.keyError(nil) == .biometryUnavailable)
    }
}
