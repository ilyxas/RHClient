import SwiftUI
import Testing
@testable import RHClient

struct ThemeTests {
    @Test func lightAccentIsReadable() {
        // DESIGN.md: a darker accent for the light theme, contrast at least 4.5:1.
        #expect(Palette.contrast(Palette.accentLight, 0xFFFFFF) >= 4.5)
        #expect(Palette.contrast(Palette.accentLight, 0xF2F2F7) >= 4.5)  // systemGroupedBackground
    }

    @Test func darkAccentIsReadable() {
        #expect(Palette.accentDark == 0xC8F560)
        #expect(Palette.contrast(Palette.accentDark, 0x000000) >= 4.5)
        #expect(Palette.contrast(Palette.accentDark, 0x1C1C1E) >= 4.5)  // dark secondary background
    }

    @Test func contrastFormula() {
        #expect(abs(Palette.contrast(0x000000, 0xFFFFFF) - 21) < 0.001)
        #expect(Palette.contrast(0x777777, 0x777777) == 1)
    }

    @Test func themeChoices() {
        #expect(ThemePreference.allCases == [.system, .light, .dark])
        #expect(ThemePreference.system.colorScheme == nil)
        #expect(ThemePreference.light.colorScheme == .light)
        #expect(ThemePreference.dark.colorScheme == .dark)
    }
}
