import Foundation
import RHAPI

/// A message this phone has not got accepted by the Mac yet: no network, a refusal, or still on
/// its way. Kept so Retry works after a restart; a retry sends the same id, and the core answers
/// with the first message instead of creating a second one.
struct OutgoingMessage: Identifiable, Codable, Equatable {
    /// The phone's message id (`FriendSendRequest.id`).
    let id: String
    let text: String
    let kind: MessageKind
    /// The message this one follows up ("make it a task"), if any.
    let re: String?
    let createdAt: Date
    /// Why it was not accepted; nil while it is being sent.
    var failure: String?
}

/// What the Chat tab shows when the Mac cannot be reached: the last messages the core gave us, the
/// cursor to ask for what changed since, the unsent ones, and the last reply the owner has seen.
/// The core is the source of truth; this file is only so the tab is not blank offline.
struct ChatCache: Codable, Equatable {
    var messages: [FriendMessage] = []
    var cursor: Int = 0
    var outgoing: [OutgoingMessage] = []
    var lastSeenReplySeq: Int = 0

    static func url(deviceID: String, in directory: URL? = nil) -> URL {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteHands", isDirectory: true)
        return base.appendingPathComponent("chat-\(deviceID).json")
    }

    static func load(from url: URL) -> ChatCache {
        guard let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(ChatCache.self, from: data) else {
            return ChatCache()
        }
        return cache
    }

    func save(to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            // A cache that cannot be written is a cache: the next load comes from the core.
        }
    }

    /// Replies the owner has not seen yet, across every message.
    var unreadReplies: Int {
        messages.reduce(0) { count, message in
            count + message.replies.filter { $0.seq > lastSeenReplySeq }.count
        }
    }

    /// The newest reply there is, to mark everything seen.
    var newestReplySeq: Int {
        messages.flatMap(\.replies).map(\.seq).max() ?? 0
    }

    /// Merge a page from the core: a message changed since replaces its earlier copy; the list
    /// stays oldest first by the time the Mac accepted it.
    mutating func merge(_ page: FriendMessagesResponse) {
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in page.messages {
            byID[message.id] = message
        }
        messages = byID.values.sorted { ($0.acceptedAt, $0.seq) < ($1.acceptedAt, $1.seq) }
        cursor = max(cursor, page.next)
    }
}
