import Foundation
import LocalAuthentication

/// Asks for Face ID and returns the evaluated context that unlocks the keys.
@MainActor
protocol FaceIDAuthenticating {
    func authenticate(reason: String) async throws(KeyError) -> LAContext
}

/// Biometrics only: SPEC §4.1 has no fallback to the device passcode.
struct SystemFaceID: FaceIDAuthenticating {
    func authenticate(reason: String) async throws(KeyError) -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var canError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &canError) else {
            throw Self.keyError(canError)
        }
        let result: Result<Void, KeyError> = await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { @Sendable success, error in
                continuation.resume(returning: success ? .success(()) : .failure(Self.keyError(error)))
            }
        }
        try result.get()
        return context
    }

    nonisolated static func keyError(_ error: (any Error)?) -> KeyError {
        guard let error = error as? LAError else { return .biometryUnavailable }
        switch error.code {
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return .cancelled
        case .authenticationFailed:
            return .authenticationFailed
        default:
            return .biometryUnavailable
        }
    }
}
