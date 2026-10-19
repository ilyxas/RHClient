import Testing
@testable import RHClient

struct AppTabTests {
    @Test func tabBarOrderMatchesSpec() {
        #expect(AppTab.allCases.map(\.title) == ["Home", "Chat", "Terminal", "Log", "Pages"])
    }
}
