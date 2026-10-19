import RHAPI
import SwiftUI
import UIKit

/// Theme choice in the Home header (SPEC §8.1): like iOS by default, or fixed light / dark.
enum ThemePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "theme"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

/// Colours of design/DESIGN.md: one accent, system semantic colours, system fonts.
enum Palette {
    /// #C8F560 in the dark theme.
    static let accentDark: UInt32 = 0xC8F560
    /// The same hue, darker, for the light theme: 5.8:1 on white (WCAG AA needs 4.5:1).
    static let accentLight: UInt32 = 0x4D7000

    static let accent = Color(uiColor: UIColor { traits in
        UIColor(rgb: traits.userInterfaceStyle == .dark ? accentDark : accentLight)
    })

    /// Text on an accent fill: black on the light lime, white on the darker light-theme accent.
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })

    /// Online / ok. In the dark theme the accent, as in the concept; system green in light.
    static let ok = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(rgb: accentDark) : .systemGreen
    })

    static func color(for state: StatusValue.State) -> Color {
        switch state {
        case .ok: ok
        case .warn: .orange
        case .error: .red
        case .off, .other: .secondary
        }
    }

    /// WCAG 2 contrast ratio of two sRGB colours given as 0xRRGGBB.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((rgb >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1
        )
    }
}

/// Screen background: near black with a faint green glow behind the glass in the dark
/// theme, the system grouped background in the light one (DESIGN.md).
struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            ZStack {
                Color(red: 0.03, green: 0.04, blue: 0.035)
                RadialGradient(
                    colors: [Color(red: 0.12, green: 0.22, blue: 0.08).opacity(0.55), .clear],
                    center: .topLeading, startRadius: 20, endRadius: 520
                )
                RadialGradient(
                    colors: [Color(red: 0.06, green: 0.16, blue: 0.10).opacity(0.45), .clear],
                    center: .bottomTrailing, startRadius: 20, endRadius: 460
                )
            }
            .ignoresSafeArea()
        } else {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
        }
    }
}
