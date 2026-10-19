import SwiftUI

@main
struct RHClientApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    model.load()
                    await model.becameActive()
                }
        }
    }
}
