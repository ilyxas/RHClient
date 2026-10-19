import SwiftUI

/// Tabs of the main tab bar, in the order fixed by SPEC §8.1.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home, chat, terminal, log, pages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .chat: "Chat"
        case .terminal: "Terminal"
        case .log: "Log"
        case .pages: "Pages"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .chat: "bubble.left.and.bubble.right"
        case .terminal: "terminal"
        case .log: "list.bullet.rectangle"
        case .pages: "square.grid.2x2"
        }
    }
}

struct RootTabView: View {
    @State private var selection: AppTab = .home

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    PlaceholderScreen(tab: tab)
                }
            }
        }
    }
}

/// Stand-in for screens that arrive in later stages.
private struct PlaceholderScreen: View {
    let tab: AppTab

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                tab.title,
                systemImage: tab.systemImage,
                description: Text("Coming in a later stage.")
            )
            .navigationTitle(tab.title)
        }
    }
}

#Preview {
    RootTabView()
}
