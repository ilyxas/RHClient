import CryptoKit
import Foundation

/// Same as RHCryptoTests/ContractsLocation.swift. The vendored copy of RHServer `contracts/` at the RHClient repository root.
enum ContractsLocation {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // RHAPITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // RHKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("contracts", isDirectory: true)

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(relativePath))
    }
}

func sha256Hex<D: DataProtocol>(_ data: D) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
