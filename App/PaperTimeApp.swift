import SwiftUI

@main
struct PaperTimeApp: App {
    @State private var model = AppModel()

    init() {
        #if os(macOS)
        // Draws every feature demo to a file and quits, for checking them
        // without a window: `PAPERTIME_RENDER_DEMOS=/some/dir`.
        if let directory = Boot.setting("PAPERTIME_RENDER_DEMOS") {
            DemoRenderer.render(into: directory)
        }
        // Prints how a note's Markdown is set, run by run, and quits:
        // `PAPERTIME_DUMP_NOTE="$(cat note.md)"`. A note is rendered in a text
        // view inside three panes, which is a slow place to find out that a
        // quotation came out looking like a link.
        // The ruler, before anything else can be measured with it.
        Trace.begin()
        Trace.mark("app starting")
        if let markdown = Boot.setting("PAPERTIME_DUMP_NOTE") {
            NoteMarkdown.dump(markdown)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    Trace.mark("window on screen")
                    Hitches.watch()
                }
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
