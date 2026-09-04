import SwiftUI

@main
struct PaperTimeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .commands { PaperTimeCommands(model: model) }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
        }
        #endif
    }
}
