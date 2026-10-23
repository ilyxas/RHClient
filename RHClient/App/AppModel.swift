import Foundation
import Observation
import RHAPI
import RHCrypto

/// App state: keys, pairing, the signed link to the core, Home data (stage 2).
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case unpaired
        case paired
        /// Keys unusable, device unknown or revoked, or the core key does not match: Re-pair.
        case pairingLost
    }

    enum PairingProgress: Equatable {
        case creatingKeys
        /// The request is waiting for y/n in the Mac terminal; the same fingerprint is shown there.
        case waitingForMac(fingerprint: String)
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var record: PairingRecord?
    private(set) var connection: ConnectionState?
    private(set) var status: StatusResponse?
    /// Home data sources (``BuiltinData/home``) from the last refresh; empty until the first one.
    private(set) var homeData: [String: DataResult] = [:]
    /// Quick Access on Home; always empty until stage 5.
    private(set) var quickItems: [QuickItem] = []
    private(set) var pairingProgress: PairingProgress?
    /// A failure worth a line on screen that does not change the phase (Face ID cancelled, …).
    private(set) var notice: String?

    let allowLocalHTTP: Bool
    private let store: any SecretStore
    private let faceID: any FaceIDAuthenticating
    private let transport: any HTTPTransport
    private var session: SigningSession?

    init(
        store: any SecretStore = KeychainStore(), faceID: any FaceIDAuthenticating = SystemFaceID(),
        transport: any HTTPTransport = URLSessionTransport(), allowLocalHTTP: Bool = AppModel.isDebugBuild
    ) {
        self.store = store
        self.faceID = faceID
        self.transport = transport
        self.allowLocalHTTP = allowLocalHTTP
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static let resetIntervalKey = "faceIDResetInterval"

    /// Settings → Face ID: how long the app may stay in the background before Face ID is asked again.
    var resetInterval: TimeInterval = UserDefaults.standard.object(forKey: AppModel.resetIntervalKey) as? TimeInterval
        ?? SigningSession.defaultResetInterval {
        didSet {
            UserDefaults.standard.set(resetInterval, forKey: Self.resetIntervalKey)
            session?.resetInterval = resetInterval
        }
    }

    private var client: CoreClient? {
        guard let record, let session else { return nil }
        return CoreClient(endpoint: record.endpoint, signer: session, transport: transport)
    }

    // MARK: - Lifecycle

    func load() {
        do {
            record = try PairingRecord.load(from: store)
            let keys = try StoredKeySet.load(from: store)
            session = keys.map { SigningSession(keys: $0, faceID: faceID, resetInterval: resetInterval) }
        } catch {
            notice = String(localized: "Keychain error: \(String(describing: error))")
        }
        switch (record, session) {
        case (nil, _): phase = .unpaired
        case (_?, nil): lose()
        case (_?, _?): phase = .paired
        }
        #if DEBUG
        // A launch argument is for a phone that starts unpaired; a later Re-pair must not
        // pick it up silently.
        if record != nil { launchPairingUsed = true }
        #endif
    }

    /// App became active: Face ID for the session if needed, then a fresh status.
    func becameActive() async {
        session?.willEnterForeground()
        guard phase == .paired else { return }
        await refresh()
    }

    func enteredBackground() {
        session?.didEnterBackground()
    }

    // MARK: - Signed calls

    /// Status, Home data and Quick Access in parallel. Each part keeps its last value when
    /// its own call fails, so one broken source does not blank the screen.
    func refresh() async {
        guard let client else { return }
        async let status = Self.attempt { try await client.status() }
        async let data = Self.attempt { try await client.data(ids: BuiltinData.home) }
        async let quick = Self.attempt { try await client.quick() }
        let results = await (status, data, quick)
        var failure: (any Error)?
        switch results.0 {
        case .success(let value): self.status = value
        case .failure(let error): failure = error
        }
        switch results.1 {
        case .success(let value): homeData = value.values
        case .failure(let error): failure = failure ?? error
        }
        switch results.2 {
        case .success(let value): quickItems = value.items
        case .failure(let error): failure = failure ?? error
        }
        if let failure {
            handle(failure)
        } else {
            connected()
        }
    }

    /// One page of the Log feed; nil when the call failed (the reason is in `connection` or `notice`).
    func log(_ request: LogRequest) async -> LogResponse? {
        guard let client else { return nil }
        do {
            let page = try await client.log(request)
            connected()
            return page
        } catch {
            handle(error)
            return nil
        }
    }

    private nonisolated static func attempt<T: Sendable>(_ call: @Sendable () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await call())
        } catch {
            return .failure(error)
        }
    }

    func ping() async {
        guard let client else { return }
        do {
            _ = try await client.ping()
            connected()
        } catch {
            handle(error)
        }
    }

    func devices() async -> [DevicesResponse.Device]? {
        guard let client else { return nil }
        do {
            let devices = try await client.devices().devices
            connected()
            return devices
        } catch {
            handle(error)
            return nil
        }
    }

    /// A signed message to the Friend session; nil when it was not accepted (the reason is in
    /// `connection` or `notice`).
    func sendToFriend(_ text: String) async -> FriendSendResponse? {
        guard let client else { return nil }
        notice = nil  // a failure below must not show the reason of an earlier one
        do {
            let answer = try await client.sendToFriend(FriendSendRequest(text: text))
            connected()
            return answer
        } catch {
            handle(error)
            return nil
        }
    }

    /// Critical key: Face ID every time. Revoking this phone ends in Pairing lost on the next call.
    func revoke(_ deviceID: String) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.revoke(deviceID: deviceID)
            connected()
            if deviceID == record?.deviceID { lose() }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    private func connected() {
        connection = .connected
        notice = nil
    }

    private func handle(_ error: any Error) {
        if let keyError = error as? KeyError {
            switch keyError {
            case .keyUnavailable: lose()
            case .cancelled: notice = String(localized: "Face ID cancelled.")
            case .authenticationFailed: notice = String(localized: "Face ID did not recognise you.")
            case .biometryUnavailable: notice = String(localized: "Face ID is not available. Check Settings → Face ID & Passcode.")
            case .unsupportedDevice: notice = String(localized: "This device has no Secure Enclave.")
            }
            return
        }
        guard let state = ConnectionState(error: error) else {
            if case CoreClientError.rejected(let rejection) = error {
                notice = rejection.message
            } else {
                notice = String(describing: error)
            }
            return
        }
        connection = state
        if state == .pairingLost { lose() }
    }

    private func lose() {
        phase = .pairingLost
        connection = .pairingLost
        status = nil
        homeData = [:]
        quickItems = []
    }

    #if DEBUG
    /// One ecdsa.json vector signed by this phone's normal key: a ping object for this device.
    func exportTestSignature() async -> String? {
        guard let record, let session else { return nil }
        let object = SignedObject(
            device: record.deviceID, key: .normal, nonce: Base64.encode(Data(repeating: 0, count: 32)),
            op: CoreOperation.ping.op, body: Data("{}".utf8), now: .now
        )
        let message = Data(object.canonicalBytes)
        do {
            let signature = try await session.signature(for: message, level: .normal)
            let vector: [String: Any] = [
                "name": session.keys.normal.kind == .secureEnclave ? "secure-enclave-device" : "software-key",
                "pub_x963_b64": Base64.encode(session.keys.normal.publicKeyX963),
                "message_b64": Base64.encode(message),
                "sig_der_b64": Base64.encode(signature),
                "valid": true,
            ]
            let data = try JSONSerialization.data(withJSONObject: vector, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        } catch {
            handle(error)
            return nil
        }
    }
    #endif

    #if DEBUG
    private var launchPairingUsed = false

    /// `-RHPairing <string>` (Debug): used once per launch, so a later Re-pair does not reuse a spent code.
    func takeLaunchPairing() -> String? {
        guard !launchPairingUsed else { return nil }
        launchPairingUsed = true
        return UserDefaults.standard.string(forKey: "RHPairing")
    }
    #endif

    // MARK: - Pairing

    func parsePairing(_ text: String) throws(PairingString.ParseError) -> PairingString {
        try PairingString(parsing: text.trimmingCharacters(in: .whitespacesAndNewlines), allowLocalHTTP: allowLocalHTTP)
    }

    /// New keys, a pair request signed by normal and critical, then y/n on the Mac (SPEC §4.2).
    /// A Re-pair sends `replaces` with the old device id so the Mac revokes it in the same step.
    @discardableResult
    func pair(_ pairing: PairingString, deviceName: String) async -> Bool {
        pairingProgress = .creatingKeys
        let keys: StoredKeySet
        do {
            keys = try StoredKeySet.make(with: KeyProviders.forNewKeys())
        } catch {
            pairingProgress = .failed(String(localized: "Could not create keys: \(String(describing: error))"))
            return false
        }
        let signer = SigningSession(keys: keys, faceID: faceID, resetInterval: resetInterval)
        let name = String(deviceName.prefix(64)).isEmpty ? "iPhone" : String(deviceName.prefix(64))
        let replaces = record?.deviceID
        var lostConnection = false

        while true {
            pairingProgress = .waitingForMac(fingerprint: keys.deviceKeys.fingerprint)
            do {
                let paired = try await CoreClient.pair(
                    pairing, name: name, keys: keys.deviceKeys, replaces: replaces, signer: signer, transport: transport
                )
                return finishPairing(pairing, keys: keys, signer: signer, macName: paired.macName, sshHostKeys: paired.sshHostKeys)
            } catch _ where Task.isCancelled {
                pairingProgress = nil
                return false
            } catch CoreClientError.unreachable(_) where !pairing.isExpired(now: .now) {
                // The core withdraws the request when the phone drops; the code stays valid,
                // so the same string and the same keys are sent again.
                lostConnection = true
                try? await Task.sleep(for: .seconds(2))
            } catch CoreClientError.rejected(let rejection)
                where lostConnection && (rejection.code == .pairRejected || rejection.code == .badPairCode) {
                // "y" may have landed just as the connection dropped: then these keys are registered.
                if await isRegistered(pairing, keys: keys, signer: signer) { return true }
                pairingProgress = .failed(Self.message(for: rejection))
                return false
            } catch {
                pairingProgress = .failed(Self.pairingMessage(error))
                return false
            }
        }
    }

    func cancelPairing() {
        pairingProgress = nil
    }

    private func isRegistered(_ pairing: PairingString, keys: StoredKeySet, signer: SigningSession) async -> Bool {
        let endpoint = CoreEndpoint(baseURL: pairing.url, coreKeyX963: pairing.coreKeyX963, deviceID: keys.deviceKeys.deviceID)
        let client = CoreClient(endpoint: endpoint, signer: signer, transport: transport)
        guard let status = try? await client.status() else { return false }
        return finishPairing(pairing, keys: keys, signer: signer, macName: status.macName, sshHostKeys: [])
    }

    private func finishPairing(
        _ pairing: PairingString, keys: StoredKeySet, signer: SigningSession, macName: String, sshHostKeys: [String]
    ) -> Bool {
        let record = PairingRecord(
            coreURL: pairing.url, coreKeyX963: pairing.coreKeyX963, deviceID: keys.deviceKeys.deviceID,
            macName: macName, sshHostKeys: sshHostKeys
        )
        do {
            try keys.save(to: store)
            try record.save(to: store)
        } catch {
            pairingProgress = .failed(String(localized: "Paired, but the keys could not be saved: \(String(describing: error))"))
            return false
        }
        self.record = record
        session = signer
        pairingProgress = nil
        phase = .paired
        status = nil
        homeData = [:]
        quickItems = []
        connection = nil
        Task { await refresh() }
        return true
    }

    private static func pairingMessage(_ error: any Error) -> String {
        switch error {
        case CoreClientError.rejected(let rejection):
            return message(for: rejection)
        case CoreClientError.unreachable(_):
            return String(localized: "The pairing code expired before the Mac answered. Run rhcore pair again.")
        case CoreClientError.badServerSignature:
            return String(localized: "The answer was not signed by the Mac from the QR code.")
        case KeyError.cancelled:
            return String(localized: "Face ID cancelled.")
        default:
            return String(describing: error)
        }
    }

    private static func message(for rejection: CoreError) -> String {
        switch rejection.code {
        case .badPairCode: String(localized: "The pairing code is wrong, used or expired. Run rhcore pair again.")
        case .pairRejected: String(localized: "Pairing was declined on the Mac.")
        case .peerMismatch: String(localized: "The request came from another Tailscale device than expected.")
        default: rejection.message
        }
    }
}

extension ConnectionState {
    var title: String {
        switch self {
        case .connected: String(localized: "Connected · Secure session")
        case .unreachable: String(localized: "Unreachable")
        case .authError: String(localized: "Auth error")
        case .pairingLost: String(localized: "Pairing lost")
        }
    }
}
