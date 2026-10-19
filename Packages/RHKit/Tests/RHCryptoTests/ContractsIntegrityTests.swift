import Foundation
import Testing

/// The vendored contracts/ must match RHServer byte for byte (decided by the owner):
/// every file is listed in MANIFEST.sha256 with its hash, nothing is missing or extra,
/// and the manifest itself matches the root hash recorded in UPSTREAM at sync time.
/// scripts/check-contracts.sh additionally compares against RHServer at that commit.
struct ContractsIntegrityTests {
    private static let localOnly: Set<String> = ["MANIFEST.sha256", "UPSTREAM"]

    @Test func filesMatchManifest() throws {
        let manifest = try String(decoding: ContractsLocation.data("MANIFEST.sha256"), as: UTF8.self)
        var expected: [String: String] = [:]
        var order: [String] = []
        for line in manifest.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1)
            try #require(parts.count == 2 && parts[1].hasPrefix(" "), "malformed manifest line: \(line)")
            let path = String(parts[1].dropFirst())
            expected[path] = String(parts[0])
            order.append(path)
        }
        #expect(order == order.sorted(), "MANIFEST.sha256 is not sorted by path")

        var actual: [String: String] = [:]
        let root = ContractsLocation.directory.standardizedFileURL.path + "/"
        let enumerator = try #require(FileManager.default.enumerator(
            at: ContractsLocation.directory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  url.lastPathComponent != ".DS_Store" else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(root.count))
            guard !Self.localOnly.contains(path) else { continue }
            actual[path] = sha256Hex(try Data(contentsOf: url))
        }

        #expect(Set(actual.keys).subtracting(expected.keys).sorted() == [], "files not in MANIFEST.sha256")
        #expect(Set(expected.keys).subtracting(actual.keys).sorted() == [], "files missing from contracts/")
        for (path, hash) in expected where actual[path] != nil {
            #expect(actual[path] == hash, "\(path): sha256 differs from MANIFEST.sha256")
        }
    }

    @Test func manifestMatchesUpstreamRootHash() throws {
        let upstream = try String(decoding: ContractsLocation.data("UPSTREAM"), as: UTF8.self)
        let fields = Dictionary(uniqueKeysWithValues: upstream
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let pair = line.split(separator: "=", maxSplits: 1)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            })
        let recorded = try #require(fields["manifest_sha256"], "UPSTREAM has no manifest_sha256")
        #expect(fields["rhserver_commit"]?.count == 40, "UPSTREAM has no full rhserver_commit")
        #expect(sha256Hex(try ContractsLocation.data("MANIFEST.sha256")) == recorded)
    }
}
