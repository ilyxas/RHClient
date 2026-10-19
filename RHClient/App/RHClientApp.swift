import SwiftUI

@main
struct RHClientApp: App {
    @State private var model = AppModel()
    @AppStorage(ThemePreference.storageKey) private var theme: ThemePreference = .system

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(theme.colorScheme)
                .task {
                    model.load()
                    await model.becameActive()
                }
        }
    }
}
