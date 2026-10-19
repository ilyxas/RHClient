import Foundation
import Testing
@testable import RHCrypto

struct ProtocolTimeTests {
    @Test func roundTrip() throws {
        let date = try #require(ProtocolTime.parse("2026-10-19T12:00:07Z"))
        #expect(date.timeIntervalSince1970 == 1_792_411_207)
        #expect(ProtocolTime.format(date) == "2026-10-19T12:00:07Z")
        #expect(ProtocolTime.format(date.addingTimeInterval(0.999)) == "2026-10-19T12:00:07Z")
    }

    @Test(arguments: [
        "2026-10-19T12:00:07", "2026-10-19T12:00:07z", "2026-10-19 12:00:07Z", "2026-10-19T12:00:07.5Z",
        "2026-10-19T12:00:07+00:00", "2026-02-30T12:00:00Z", "2026-10-19T24:00:00Z", "２026-10-19T12:00:07Z", "",
    ])
    func rejects(_ text: String) {
        #expect(ProtocolTime.parse(text) == nil)
    }
}
