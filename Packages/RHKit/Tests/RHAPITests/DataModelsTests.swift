import Foundation
import RHCrypto
import Testing
@testable import RHAPI

struct DataModelsTests {
    @Test func decodesEveryDataShape() throws {
        let response = try JSONDecoder().decode(DataResponse.self, from: Data(FakeCore.dataExample.utf8))
        let values = response.values
        #expect(values[BuiltinData.cpu] == .active(.number(38.4, unit: "%"), at: "2026-10-19T12:00:00Z"))
        #expect(values[BuiltinData.diskFree]?.value?.number == 112_400_000_000)
        #expect(values[BuiltinData.status]?.value?.status == StatusValue(state: .ok, text: "rh-core 0.2.0"))
        #expect(values[BuiltinData.approvals]?.value?.rows == [])
        #expect(values["render.queue"] == .pending)
        #expect(values["render.night"] == .error("provider failed"))

        let activity = try #require(values[BuiltinData.activity]?.value?.rows)
        #expect(activity.first?.at == "2026-10-19T11:58:00Z")
        #expect(activity.first?.status == nil)

        let agents = try #require(values[BuiltinData.agents]?.value?.rows)
        #expect(agents.map(\.id) == ["Agent-Alpha", "RemoteHands"])
        #expect(agents[0].status == StatusValue(state: .ok, text: "monitoring"))
        #expect(agents[1].status?.state == .off)
        #expect(agents[1].at == nil)
    }

    @Test func decodesScalarTypes() throws {
        func decode(_ json: String) throws -> DataResult {
            try JSONDecoder().decode(DataResult.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"status":"active","type":"string","value":"idle","at":"2026-10-19T12:00:00Z"}"#).value == .string("idle"))
        #expect(try decode(#"{"status":"active","type":"bool","value":true,"at":"2026-10-19T12:00:00Z"}"#).value == .bool(true))
        #expect(try decode(#"{"status":"active","type":"text","value":"a\nb","at":"2026-10-19T12:00:00Z"}"#).value == .text("a\nb"))
        #expect(try decode(#"{"status":"active","type":"number","value":3,"at":"2026-10-19T12:00:00Z"}"#).value == .number(3, unit: nil))
        // A newer core may add states; they decode instead of failing.
        #expect(try decode(#"{"status":"active","type":"status","value":{"state":"busy"},"at":"2026-10-19T12:00:00Z"}"#).value
            == .status(StatusValue(state: .other("busy"))))
    }

    @Test func rejectsWrongShapes() {
        for json in [
            #"{"status":"active","type":"number","value":"38","at":"2026-10-19T12:00:00Z"}"#,
            #"{"status":"active","type":"rows","value":[{"id":"x"}],"at":"2026-10-19T12:00:00Z"}"#,
            #"{"status":"active","type":"number","value":1}"#,
            #"{"status":"error"}"#,
        ] {
            #expect(throws: (any Error).self, "\(json)") { try JSONDecoder().decode(DataResult.self, from: Data(json.utf8)) }
        }
    }

    @Test func newerShapesDoNotBreakTheBatch() throws {
        let json = #"""
        {"values":{"sys.cpu":{"status":"active","type":"number","value":1,"at":"2026-10-19T12:00:00Z"},
                   "x.chart":{"status":"active","type":"chart","value":[1,2],"at":"2026-10-19T12:00:00Z"},
                   "x.later":{"status":"stale","since":"2026-10-19T12:00:00Z"}},
         "server_time":"2026-10-19T12:00:00Z"}
        """#
        let values = try JSONDecoder().decode(DataResponse.self, from: Data(json.utf8)).values
        #expect(values["sys.cpu"]?.value?.number == 1)
        #expect(values["x.chart"] == .error("unsupported data type chart"))
        #expect(values["x.later"] == .error("unsupported data status stale"))

        let quick = try JSONDecoder().decode(QuickResponse.self, from: Data(#"{"items":[{"kind":"folder","id":"f","title":"F"}]}"#.utf8))
        #expect(quick.items.first?.kind == .other("folder"))
    }

    @Test func decodesLogPage() throws {
        let page = try JSONDecoder().decode(LogResponse.self, from: Data(FakeCore.logExample.utf8))
        #expect(page.next == "MjAyNjEwMTk6MTI")
        #expect(page.entries.map(\.kind) == [.error, .command])
        #expect(page.entries[0].op == "ping")
        #expect(page.entries[1].op == nil)
        #expect(page.entries[1].detail == "fingerprint 3f2a 9c0d 1e4b 5a6f")

        let last = try JSONDecoder().decode(LogResponse.self, from: Data(#"{"entries":[],"next":null}"#.utf8))
        #expect(last.next == nil)
        let future = #"{"entries":[{"id":"\#(String(repeating: "a", count: 64))","ts":"2026-10-19T12:00:00Z","kind":"audit","event":"x","title":"t"}],"next":null}"#
        #expect(try JSONDecoder().decode(LogResponse.self, from: Data(future.utf8)).entries.first?.kind == .other("audit"))
    }

    @Test func logRequestSendsOnlyWhatIsSet() throws {
        func json(_ request: LogRequest) throws -> [String: JSONValue] {
            let data = try JSONEncoder().encode(request)
            guard case .object(let members) = try JCS.parse(String(decoding: data, as: UTF8.self)) else { return [:] }
            return members
        }
        #expect(try json(LogRequest()) == ["filter": .string("all")])
        #expect(try json(LogRequest(filter: .errors, query: "", limit: 50)) == ["filter": .string("errors"), "limit": .integer(50)])
        #expect(try json(LogRequest(filter: .chat, query: "ping", before: "c", includeReads: true))
            == ["filter": .string("chat"), "query": .string("ping"), "before": .string("c"), "include_reads": .bool(true)])
    }

    @Test func homeAsksForEveryBuiltin() {
        #expect(Set(BuiltinData.home) == ["sys.cpu", "sys.memory", "sys.disk_free", "rh.status", "rh.approvals",
                                          "rh.questions", "rh.activity", "agents.status"])
        #expect(BuiltinData.home.count == Set(BuiltinData.home).count)
    }
}

struct MetricFormatTests {
    private let locale = Locale(identifier: "en_US_POSIX")

    @Test func percent() {
        #expect(MetricFormat.percent(38.4, locale: locale) == "38%")
        #expect(MetricFormat.percent(99.6, locale: locale) == "100%")
        #expect(MetricFormat.percent(-3, locale: locale) == "0%")
        #expect(MetricFormat.percent(140, locale: locale) == "100%")
    }

    @Test func bytes() {
        #expect(MetricFormat.bytes(112_400_000_000, locale: locale) == "112 GB")
        #expect(MetricFormat.bytes(9_540_000_000, locale: locale) == "9.5 GB")
        #expect(MetricFormat.bytes(9_960_000_000, locale: locale) == "10 GB")
        #expect(MetricFormat.bytes(512_000_000, locale: locale) == "512 MB")
        #expect(MetricFormat.bytes(1_260_000_000_000, locale: locale) == "1.3 TB")
        #expect(MetricFormat.bytes(999, locale: locale) == "999 bytes")
        #expect(MetricFormat.bytes(0, locale: locale) == "0 bytes")
    }

    @Test func numberByUnit() {
        #expect(MetricFormat.number(38.4, unit: "%", locale: locale) == "38%")
        #expect(MetricFormat.number(112_400_000_000, unit: "bytes", locale: locale) == "112 GB")
        #expect(MetricFormat.number(7, unit: "items", locale: locale) == "7 items")
        #expect(MetricFormat.number(2.25, unit: nil, locale: locale) == "2.2")
    }
}
