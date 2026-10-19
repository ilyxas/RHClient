import Foundation
import Security
import Synchronization

/// Small secrets the app keeps between launches: key references, pairing record.
protocol SecretStore: Sendable {
    func load(_ account: String) throws -> Data?
    func save(_ data: Data, as account: String) throws
    func delete(_ account: String) throws
}

struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// Generic-password items, this device only, readable while the device is unlocked.
/// Nothing here is a private key: Secure Enclave keys are stored as their encrypted
/// dataRepresentation, which only this device's Secure Enclave can use.
struct KeychainStore: SecretStore {
    let service: String

    init(service: String = "RemoteHands") {
        self.service = service
    }

    func load(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    func save(_ data: Data, as account: String) throws {
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var item = baseQuery(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// For tests and previews.
final class MemorySecretStore: SecretStore {
    private let items = Mutex<[String: Data]>([:])

    func load(_ account: String) throws -> Data? {
        items.withLock { $0[account] }
    }

    func save(_ data: Data, as account: String) throws {
        items.withLock { $0[account] = data }
    }

    func delete(_ account: String) throws {
        items.withLock { $0[account] = nil }
    }
}
