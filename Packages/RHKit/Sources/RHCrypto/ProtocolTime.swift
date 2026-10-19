import Foundation

/// Protocol timestamps: UTC, whole seconds, `YYYY-MM-DDTHH:MM:SSZ` (openapi Timestamp).
public enum ProtocolTime {
    public static func format(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: truncated(date))
        func padded(_ value: Int?, _ width: Int) -> String {
            let digits = String(value!)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(padded(parts.year, 4))-\(padded(parts.month, 2))-\(padded(parts.day, 2))"
            + "T\(padded(parts.hour, 2)):\(padded(parts.minute, 2)):\(padded(parts.second, 2))Z"
    }

    /// Only the exact spelling `format` produces; "2026-02-30T…" and the like are rejected.
    public static func parse(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 20 else { return nil }
        for (index, byte) in bytes.enumerated() {
            let expected: UInt8? = switch index {
            case 4, 7: UInt8(ascii: "-")
            case 10: UInt8(ascii: "T")
            case 13, 16: UInt8(ascii: ":")
            case 19: UInt8(ascii: "Z")
            default: nil
            }
            if let expected {
                guard byte == expected else { return nil }
            } else {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            }
        }
        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 * 10 + Int(bytes[$1] - UInt8(ascii: "0")) }
        }
        let parts = DateComponents(
            year: number(0..<4), month: number(5..<7), day: number(8..<10),
            hour: number(11..<13), minute: number(14..<16), second: number(17..<19)
        )
        guard let date = calendar.date(from: parts), format(date) == text else { return nil }
        return date
    }

    /// Drops the fraction of a second, as the protocol has no sub-second times.
    public static func truncated(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
