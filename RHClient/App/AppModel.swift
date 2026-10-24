import Foundation
import Observation
import RHAPI
import RHCrypto

/// App state: keys, pairing, the signed link to the core, Home data (stage 2), the chat with the
/// channel agent (friend slice 3).
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
    /// Questions of the channel agent waiting for a decision (friend.questions), oldest first.
    private(set) var questions: [FriendQuestion] = []
    /// The owner's messages with their state and the agent's replies, from the core
    /// (friend.messages), oldest first; the last copy is cached on disk for an offline start.
    private(set) var chat = ChatCache()
    /// Where the chat cache lives; nil in tests that keep it in memory.
    var chatCacheURL: URL?
    /// What the agents.status row of the channel agent says: "working", "idle", "stopped", …;
    /// nil when the team has no row for it or Home data is not loaded yet.
    var agentState: String? {
        guard let agent = channel?.agent, let rows = homeData[BuiltinData.agents]?.value?.rows else { return nil }
        return rows.first { $0.id == agent }?.status?.text
    }
    /// The agent on the channel, from the last status; nil until the first one. Messages and
    /// decisions are addressed to it and every name on the Chat tab is its title.
    var channel: Channel? { status?.channel }
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
        if let record {
            chatCacheURL = chatCacheURL ?? ChatCache.url(deviceID: record.deviceID)
            chat = ChatCache.load(from: chatCacheURL!)
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

    /// Status, Home data, Quick Access and the agent's questions in parallel. Each part keeps its
    /// last value when its own call fails, so one broken source does not blank the screen.
    func refresh() async {
        guard let client else { return }
        async let status = Self.attempt { try await client.status() }
        async let data = Self.attempt { try await client.data(ids: BuiltinData.home) }
        async let quick = Self.attempt { try await client.quick() }
        async let asked = Self.attempt { try await client.friendQuestions() }
        async let talked = Self.attempt { try await Self.allMessages(client) }
        let results = await (status, data, quick, asked, talked)
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
        switch results.3 {
        case .success(let value): questions = value.questions
        case .failure(let error): failure = failure ?? error
        }
        switch results.4 {
        case .success(let pages):
            // Everything the core has: a cursor from before a core reset would hide the rest.
            var fresh = ChatCache(outgoing: chat.outgoing, lastSeenReplySeq: chat.lastSeenReplySeq)
            for page in pages { fresh.merge(page) }
            chat = fresh
            saveChat()
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

    /// Every page of friend.messages from the start (the core is the source of truth).
    private nonisolated static func allMessages(_ client: CoreClient, pageLimit: Int = 20) async throws -> [FriendMessagesResponse] {
        var pages: [FriendMessagesResponse] = []
        var since = 0
        for _ in 0..<pageLimit {
            let page = try await client.friendMessages(FriendMessagesRequest(since: since, limit: 200))
            pages.append(page)
            since = page.next
            if !page.more { break }
        }
        return pages
    }

    /// What changed since the last page: the Chat tab polls this while it is on screen. Quiet on
    /// failure (the connection state says why); nothing is sent before the first status.
    func pollMessages() async {
        guard let client, channel != nil else { return }
        do {
            var page = try await client.friendMessages(FriendMessagesRequest(since: chat.cursor, limit: 200))
            chat.merge(page)
            while page.more {
                page = try await client.friendMessages(FriendMessagesRequest(since: chat.cursor, limit: 200))
                chat.merge(page)
            }
            saveChat()
            connected()
        } catch {
            handle(error)
        }
    }

    /// A signed message to the channel agent (friend.send). It stays in `chat.outgoing` until the
    /// Mac accepts it (then it is in `chat.messages` as accepted); a failure keeps it there with
    /// the reason, for Retry. Nothing is sent before a status has named the agent.
    @discardableResult
    func send(_ text: String, kind: MessageKind = .question, re: String? = nil) async -> FriendSendResponse? {
        let item = OutgoingMessage(id: UUID().uuidString, text: text, kind: kind, re: re, createdAt: .now, failure: nil)
        chat.outgoing.append(item)
        saveChat()
        return await deliver(item)
    }

    /// Send an unsent message again, with the same id: the core answers with the first message if
    /// the earlier attempt did reach it.
    @discardableResult
    func retry(_ item: OutgoingMessage) async -> FriendSendResponse? {
        guard let index = chat.outgoing.firstIndex(where: { $0.id == item.id }) else { return nil }
        chat.outgoing[index].failure = nil
        return await deliver(chat.outgoing[index])
    }

    /// "Make it a task": the agent may work on what it was asked as a question.
    @discardableResult
    func makeTask(_ message: FriendMessage) async -> FriendSendResponse? {
        await send(String(localized: "Go ahead, make it a task."), kind: .task, re: message.id)
    }

    /// The same text once more, as a new message (after a rejection or a stopped agent).
    @discardableResult
    func sendAgain(_ message: FriendMessage) async -> FriendSendResponse? {
        await send(message.text, kind: message.kind, re: message.re)
    }

    private func deliver(_ item: OutgoingMessage) async -> FriendSendResponse? {
        func fail(_ reason: String) -> FriendSendResponse? {
            if let index = chat.outgoing.firstIndex(where: { $0.id == item.id }) {
                chat.outgoing[index].failure = reason
            }
            saveChat()
            return nil
        }
        guard let client else { return fail(String(localized: "Not paired")) }
        notice = nil  // a failure below must not show the reason of an earlier one
        guard let channel else {
            return fail(String(localized: "The Mac has not said which agent is on the channel yet."))
        }
        do {
            let request = FriendSendRequest(id: item.id, text: item.text, to: channel.agent, kind: item.kind == .question ? nil : item.kind, re: item.re)
            let answer = try await client.sendToFriend(request)
            connected()
            chat.outgoing.removeAll { $0.id == item.id }
            if !chat.messages.contains(where: { $0.id == answer.id }) {
                // Shown at once; the next poll brings the core's copy (same id) with its state.
                chat.messages.append(
                    FriendMessage(
                        id: answer.id, seq: 0, messageID: item.id, device: record?.deviceID ?? "", agent: channel.agent,
                        kind: item.kind, re: item.re, text: item.text, acceptedAt: answer.acceptedAt, state: .accepted
                    )
                )
            }
            saveChat()
            await pollMessages()
            return answer
        } catch {
            handle(error)
            return fail(notice ?? connection?.title ?? String(localized: "Not sent"))
        }
    }

    /// Forget an unsent message.
    func discard(_ item: OutgoingMessage) {
        chat.outgoing.removeAll { $0.id == item.id }
        saveChat()
    }

    /// The owner has the Chat tab in front: every reply so far counts as seen.
    func markChatSeen() {
        let newest = chat.newestReplySeq
        guard newest > chat.lastSeenReplySeq else { return }
        chat.lastSeenReplySeq = newest
        saveChat()
    }

    private func saveChat() {
        if let chatCacheURL { chat.save(to: chatCacheURL) }
    }

    /// Only the agent's open questions; nil when the call failed.
    func loadQuestions() async -> [FriendQuestion]? {
        guard let client else { return nil }
        do {
            questions = try await client.friendQuestions().questions
            connected()
            return questions
        } catch {
            handle(error)
            return nil
        }
    }

    /// Decide one question of the agent. Allow asks Face ID (critical key); deny does not. The
    /// question leaves the list once the core accepted the decision; nil when it did not
    /// (the reason is in `connection` or `notice`).
    func decide(_ question: FriendQuestion, _ decision: FriendDecision) async -> FriendDecideResponse? {
        guard let client else { return nil }
        notice = nil
        guard let channel else {
            notice = String(localized: "The Mac has not said which agent is on the channel yet.")
            return nil
        }
        do {
            let answer = try await client.decide(
                FriendDecideRequest(question: question, decision: decision, to: channel.agent)
            )
            questions.removeAll { $0.id == question.id }
            connected()
            return answer
        } catch {
            handle(error)
            if case CoreClientError.rejected(let rejection) = error, rejection.code == .badRequest {
                // Answered from another device, withdrawn, or changed: this question is gone.
                questions.removeAll { $0.id == question.id }
            }
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
        questions = []
        chat = ChatCache()
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
        questions = []
        chatCacheURL = ChatCache.url(deviceID: record.deviceID)
        chat = ChatCache()
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
