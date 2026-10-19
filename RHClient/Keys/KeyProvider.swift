import CryptoKit
import Foundation
import LocalAuthentication
import RHCrypto

/// One of the phone's three keys (SPEC §4.1).
enum KeyRole: String, CaseIterable, Codable, Sendable {
    case normal
    case critical
    case ssh
}

/// A private key as the app stores it. For Secure Enclave `material` is the encrypted
/// dataRepresentation; for the Debug software provider it is the raw scalar.
struct StoredKey: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case secureEnclave
        case software
    }

    let kind: Kind
    let material: Data
    let publicKeyX963: Data
}

struct StoredKeySet: Codable, Equatable, Sendable {
    let normal: StoredKey
    let critical: StoredKey
    let ssh: StoredKey

    subscript(role: KeyRole) -> StoredKey {
        switch role {
        case .normal: normal
        case .critical: critical
        case .ssh: ssh
        }
    }

    var deviceKeys: DeviceKeys {
        DeviceKeys(normal: normal.publicKeyX963, critical: critical.publicKeyX963, ssh: ssh.publicKeyX963)
    }
}

extension StoredKeySet {
    static let account = "device-keys"

    /// Three new keys from one provider.
    static func make(with provider: any KeyProvider) throws -> StoredKeySet {
        StoredKeySet(normal: try provider.makeKey(), critical: try provider.makeKey(), ssh: try provider.makeKey())
    }

    static func load(from store: any SecretStore) throws -> StoredKeySet? {
        try store.load(account).map { try JSONDecoder().decode(StoredKeySet.self, from: $0) }
    }

    func save(to store: any SecretStore) throws {
        try store.save(JSONEncoder().encode(self), as: Self.account)
    }
}

/// Why a signature did not happen (docs/decisions/0002).
enum KeyError: Error, Equatable, Sendable {
    /// Face ID was cancelled by the user or the system: nothing is wrong with the keys.
    case cancelled
    /// Face ID did not recognise the user.
    case authenticationFailed
    /// No Face ID enrolled, locked out, or no passcode: the keys cannot be used right now.
    case biometryUnavailable
    /// Face ID passed but the key could not sign (biometry changed, key missing): Pairing lost.
    case keyUnavailable
    /// No Secure Enclave and no software fallback (Release on unsupported hardware).
    case unsupportedDevice
}

/// Creates keys and signs with them. Face ID is not asked here: the caller passes an
/// already evaluated LAContext (docs/decisions/0002).
protocol KeyProvider: Sendable {
    var kind: StoredKey.Kind { get }
    func makeKey() throws -> StoredKey
    /// DER ECDSA P-256 / SHA-256 signature over `message`.
    func signature(for message: Data, with key: StoredKey, context: LAContext?) throws -> Data
}

struct SecureEnclaveKeyProvider: KeyProvider {
    /// SPEC §4.1: no passcode fallback; the key dies with the enrolled biometry.
    static let defaultAccessFlags: SecAccessControlCreateFlags = [.privateKeyUsage, .biometryCurrentSet]

    /// Tests in the simulator use `.privateKeyUsage` alone, since no Face ID is enrolled there.
    var accessFlags = Self.defaultAccessFlags

    var kind: StoredKey.Kind { .secureEnclave }

    func makeKey() throws -> StoredKey {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, accessFlags, &error
        ) else { throw error!.takeRetainedValue() as Error }
        let key = try SecureEnclave.P256.Signing.PrivateKey(
            compactRepresentable: false, accessControl: access, authenticationContext: nil
        )
        return StoredKey(kind: .secureEnclave, material: key.dataRepresentation, publicKeyX963: key.publicKey.x963Representation)
    }

    func signature(for message: Data, with key: StoredKey, context: LAContext?) throws -> Data {
        guard key.kind == .secureEnclave else { throw KeyError.keyUnavailable }
        do {
            let privateKey = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: key.material, authenticationContext: context
            )
            return try privateKey.signature(for: message).derRepresentation
        } catch {
            throw KeyError.keyUnavailable
        }
    }
}

#if DEBUG
/// Debug only, for machines without a Secure Enclave (docs/decisions/0001).
struct SoftwareKeyProvider: KeyProvider {
    var kind: StoredKey.Kind { .software }

    func makeKey() throws -> StoredKey {
        let key = P256.Signing.PrivateKey()
        return StoredKey(kind: .software, material: key.rawRepresentation, publicKeyX963: key.publicKey.x963Representation)
    }

    func signature(for message: Data, with key: StoredKey, context: LAContext?) throws -> Data {
        guard key.kind == .software,
              let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: key.material),
              let signature = try? privateKey.signature(for: message)
        else { throw KeyError.keyUnavailable }
        return signature.derRepresentation
    }
}
#endif

enum KeyProviders {
    /// The provider for new keys on this device, chosen at run time (docs/decisions/0001).
    static func forNewKeys() throws(KeyError) -> any KeyProvider {
        #if DEBUG && targetEnvironment(simulator)
        // The simulator's Secure Enclave refuses keys bound to biometry (LAError -1020,
        // "not supported on iOS Simulator"). Face ID itself still runs before every signature.
        return SoftwareKeyProvider()
        #else
        if SecureEnclave.isAvailable { return SecureEnclaveKeyProvider() }
        #if DEBUG
        return SoftwareKeyProvider()
        #else
        throw .unsupportedDevice
        #endif
        #endif
    }

    /// The provider that can sign with an existing key.
    static func provider(for key: StoredKey) throws(KeyError) -> any KeyProvider {
        switch key.kind {
        case .secureEnclave:
            return SecureEnclaveKeyProvider()
        case .software:
            #if DEBUG
            return SoftwareKeyProvider()
            #else
            throw .keyUnavailable
            #endif
        }
    }
}
