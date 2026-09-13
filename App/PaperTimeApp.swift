import SwiftUI

@main
struct PaperTimeApp: App {
    @State private var model = AppModel()

    init() {
        #if os(macOS)
        // Draws every feature demo to a file and quits, for checking them
        // without a window: `PAPERTIME_RENDER_DEMOS=/some/dir`.
        if let directory = ProcessInfo.processInfo.environment["PAPERTIME_RENDER_DEMOS"] {
            DemoRenderer.render(into: directory)
        }
        #endif
    }

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
