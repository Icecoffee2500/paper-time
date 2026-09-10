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
        // Compact, because the toolbar's height is the gap between it and the
        // panels below: the roomy default left a band of empty ground there
        // that read as a mistake.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
        }
        #endif
    }
}
