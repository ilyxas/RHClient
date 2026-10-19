import Foundation

// Stage 2 bodies of contracts/api/openapi.yaml: data.get, log.list, quick.list.
// Enums the core may extend later decode unknown values instead of failing, so a
// newer core never breaks Home or Log.

// MARK: - data.get

/// Built-in data sources of the core (SPEC §5.4).
public enum BuiltinData {
    public static let cpu = "sys.cpu"
    public static let memory = "sys.memory"
    public static let diskFree = "sys.disk_free"
    public static let status = "rh.status"
    public static let approvals = "rh.approvals"
    public static let questions = "rh.questions"
    public static let activity = "rh.activity"
    public static let agents = "agents.status"

    /// Everything Home shows, in one data.get call.
    public static let home = [cpu, memory, diskFree, status, approvals, questions, activity, agents]
}

public struct DataRequest: Encodable, Sendable {
    /// 1–32 distinct data_id.
    public let ids: [String]

    public init(ids: [String]) {
        self.ids = ids
    }
}

public struct DataResponse: Decodable, Equatable, Sendable {
    /// Keys are exactly the requested ids.
    public let values: [String: DataResult]
    public let serverTime: String

    enum CodingKeys: String, CodingKey {
        case values
        case serverTime = "server_time"
    }
}

/// One value of data.get: read now, not registered yet, or failed this time.
public enum DataResult: Decodable, Equatable, Sendable {
    /// `at`: when the core read the value (Timestamp).
    case active(DataValue, at: String)
    /// Not built in and not registered (yet). Not an error (SPEC §7.5).
    case pending
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case status, type, value, unit, at, message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "active":
            let value: DataValue
            switch try container.decode(String.self, forKey: .type) {
            case "number":
                value = .number(try container.decode(Double.self, forKey: .value), unit: try container.decodeIfPresent(String.self, forKey: .unit))
            case "string": value = .string(try container.decode(String.self, forKey: .value))
            case "bool": value = .bool(try container.decode(Bool.self, forKey: .value))
            case "status": value = .status(try container.decode(StatusValue.self, forKey: .value))
            case "rows": value = .rows(try container.decode([Row].self, forKey: .value))
            case "text": value = .text(try container.decode(String.self, forKey: .value))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown data type \(other)")
            }
            self = .active(value, at: try container.decode(String.self, forKey: .at))
        case "pending":
            self = .pending
        case "error":
            self = .error(try container.decode(String.self, forKey: .message))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "unknown data status \(other)")
        }
    }

    public var value: DataValue? {
        if case .active(let value, _) = self { return value }
        return nil
    }
}

/// A value of one of the SPEC §7.3 types.
public enum DataValue: Equatable, Sendable {
    case number(Double, unit: String?)
    case string(String)
    case bool(Bool)
    case status(StatusValue)
    case rows([Row])
    case text(String)

    public var number: Double? {
        if case .number(let value, _) = self { return value }
        return nil
    }

    public var rows: [Row]? {
        if case .rows(let rows) = self { return rows }
        return nil
    }

    public var status: StatusValue? {
        if case .status(let status) = self { return status }
        return nil
    }
}

/// Value of type status (SPEC §7.3); also the status of a row.
public struct StatusValue: Codable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case ok, warn, error, off
        /// A state this client does not know yet; shown like `off`.
        case other(String)

        init(raw: String) {
            switch raw {
            case "ok": self = .ok
            case "warn": self = .warn
            case "error": self = .error
            case "off": self = .off
            default: self = .other(raw)
            }
        }

        var raw: String {
            switch self {
            case .ok: "ok"
            case .warn: "warn"
            case .error: "error"
            case .off: "off"
            case .other(let raw): raw
            }
        }
    }

    public let state: State
    public let text: String?

    public init(state: State, text: String? = nil) {
        self.state = state
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case state, text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = State(raw: try container.decode(String.self, forKey: .state))
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state.raw, forKey: .state)
        try container.encodeIfPresent(text, forKey: .text)
    }
}

/// One element of a value of type rows (SPEC §7.3, plus the optional `at` the owner added).
public struct Row: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let status: StatusValue?
    /// When the row's event happened (Timestamp), if it has one.
    public let at: String?

    public init(id: String, title: String, subtitle: String? = nil, status: StatusValue? = nil, at: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.at = at
    }
}

// MARK: - log.list

public enum LogFilter: String, Codable, CaseIterable, Sendable {
    case all, commands, approvals, chat, errors
}

public struct LogRequest: Encodable, Equatable, Sendable {
    public var filter: LogFilter
    /// Case-insensitive substring; nil or empty for no search.
    public var query: String?
    /// `next` of the previous page; nil for the newest page.
    public var before: String?
    /// 1–200; the core's default is 50.
    public var limit: Int?
    /// Accepted read requests too (kind system). The Log tab leaves this off.
    public var includeReads: Bool?

    public init(filter: LogFilter = .all, query: String? = nil, before: String? = nil, limit: Int? = nil, includeReads: Bool? = nil) {
        self.filter = filter
        self.query = query
        self.before = before
        self.limit = limit
        self.includeReads = includeReads
    }

    enum CodingKeys: String, CodingKey {
        case filter, query, before, limit
        case includeReads = "include_reads"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filter, forKey: .filter)
        if let query, !query.isEmpty { try container.encode(query, forKey: .query) }
        try container.encodeIfPresent(before, forKey: .before)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encodeIfPresent(includeReads, forKey: .includeReads)
    }
}

public struct LogResponse: Decodable, Equatable, Sendable {
    /// Newest first.
    public let entries: [LogEntry]
    /// Cursor for the next (older) page; nil when there is none.
    public let next: String?
}

public struct LogEntry: Decodable, Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case command, approval, chat, error, system
        case other(String)

        init(raw: String) {
            switch raw {
            case "command": self = .command
            case "approval": self = .approval
            case "chat": self = .chat
            case "error": self = .error
            case "system": self = .system
            default: self = .other(raw)
            }
        }
    }

    /// sha256 hex of the journal line.
    public let id: String
    public let ts: String
    public let kind: Kind
    /// Journal event, e.g. request, pairing, device.revoked.
    public let event: String
    /// One line, English, ready to show.
    public let title: String
    public let detail: String?
    public let device: String?
    public let op: String?

    enum CodingKeys: String, CodingKey {
        case id, ts, kind, event, title, detail, device, op
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ts = try container.decode(String.self, forKey: .ts)
        kind = Kind(raw: try container.decode(String.self, forKey: .kind))
        event = try container.decode(String.self, forKey: .event)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        device = try container.decodeIfPresent(String.self, forKey: .device)
        op = try container.decodeIfPresent(String.self, forKey: .op)
    }
}

// MARK: - quick.list

public struct QuickResponse: Decodable, Equatable, Sendable {
    public let items: [QuickItem]
}

/// A pinned page or action on Home (SPEC §8.2). Always empty until stage 5.
public struct QuickItem: Decodable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Decodable, Sendable {
        case page, action
    }

    public let kind: Kind
    /// Page id or action_id.
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let icon: String?
}
