import Foundation
import LocalAuthentication
import RHCrypto

/// Signs requests with the stored keys and owns the Face ID session (SPEC §4.1,
/// docs/decisions/0002): one context for `normal` while the app is active, reset after
/// `resetInterval` in the background; a fresh Face ID for every `critical` signature.
@MainActor
final class SigningSession: MessageSigner {
    static let defaultResetInterval: TimeInterval = 5 * 60

    let keys: StoredKeySet
    var resetInterval: TimeInterval
    private let faceID: any FaceIDAuthenticating
    private var sessionContext: LAContext?
    private var backgroundedAt: Date?

    init(keys: StoredKeySet, faceID: any FaceIDAuthenticating, resetInterval: TimeInterval = SigningSession.defaultResetInterval) {
        self.keys = keys
        self.faceID = faceID
        self.resetInterval = resetInterval
    }

    var isUnlocked: Bool { sessionContext != nil }

    /// Face ID when the app opens; later `normal` signatures reuse this context.
    func unlock() async throws(KeyError) {
        if sessionContext == nil {
            sessionContext = try await faceID.authenticate(reason: String(localized: "Unlock RemoteHands"))
        }
    }

    func lock() {
        sessionContext?.invalidate()
        sessionContext = nil
    }

    func didEnterBackground(at date: Date = .now) {
        backgroundedAt = date
    }

    func willEnterForeground(at date: Date = .now) {
        if let backgroundedAt, date.timeIntervalSince(backgroundedAt) >= resetInterval {
            lock()
        }
        backgroundedAt = nil
    }

    func signature(for message: Data, level: KeyLevel) async throws -> Data {
        switch level {
        case .normal:
            return try await signNormal(message)
        case .critical:
            let context = try await faceID.authenticate(reason: String(localized: "Confirm with Face ID"))
            defer { context.invalidate() }
            return try sign(message, role: .critical, context: context)
        }
    }

    private func signNormal(_ message: Data) async throws(KeyError) -> Data {
        try await unlock()
        do {
            return try sign(message, role: .normal, context: sessionContext)
        } catch {
            // A stale session context must not look like a lost key: ask Face ID once more
            // and only then report the key as unavailable.
            lock()
            try await unlock()
            return try sign(message, role: .normal, context: sessionContext)
        }
    }

    private func sign(_ message: Data, role: KeyRole, context: LAContext?) throws(KeyError) -> Data {
        let key = keys[role]
        let provider = try KeyProviders.provider(for: key)
        do {
            return try provider.signature(for: message, with: key, context: context)
        } catch {
            throw .keyUnavailable
        }
    }
}
