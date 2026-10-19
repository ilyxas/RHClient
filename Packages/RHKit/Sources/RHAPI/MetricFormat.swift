import Foundation

/// Text for the Home metrics. The core sends raw numbers and a unit (data.get);
/// rounding and wording are the client's (SPEC §8.2: "112 GB free", not "112 GB").
public enum MetricFormat {
    /// "38%" for a value in 0…100.
    public static func percent(_ value: Double, locale: Locale = .current) -> String {
        let clamped = min(max(value, 0), 100)
        return (clamped / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "112 GB", "9.5 GB", "512 MB": decimal units like Finder, one decimal below 10.
    public static func bytes(_ value: Double, locale: Locale = .current) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var amount = max(value, 0)
        var index = 0
        while amount >= 1000, index < units.count - 1 {
            amount /= 1000
            index += 1
        }
        if index == 0 {
            return "\(Int(amount)) \(units[0])"
        }
        // Round first so 9.96 GB reads "10 GB", not "10.0 GB".
        let digits = (amount * 10).rounded() / 10 < 10 ? 1 : 0
        let number = amount.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        return "\(number) \(units[index])"
    }

    /// Text for a number value with its unit from data.get: "38%", "112 GB", "7 items".
    public static func number(_ value: Double, unit: String?, locale: Locale = .current) -> String {
        switch unit {
        case "%": percent(value, locale: locale)
        case "bytes": bytes(value, locale: locale)
        case let unit?: "\(value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) \(unit)"
        case nil: value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        }
    }
}
