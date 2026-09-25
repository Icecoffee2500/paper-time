import SwiftUI

@main
struct PaperTimeApp: App {
    @State private var model: AppModel
    #if os(macOS)
    /// Files and folders the desktop hands over — a folder dropped on the
    /// icon becomes the library, which is the one way into a Google Drive or
    /// Dropbox folder that needs no open panel.
    @NSApplicationDelegateAdaptor(OpenWithFinder.self) private var opener
    #endif

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        #if os(macOS)
        // Held for a probe whose launch restores no window: see
        // `WindowProbe.openIfNoneWasRestored`.
        WindowProbe.model = model
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
        // Types a few Latex Suite keystrokes in memory, prints them and quits.
        if Boot.isSet("PAPERTIME_LATEX_SUITE") {
            LatexSuiteProbe.run()
        }
        // Types Latex Suite's fixtures into a note and a text card in a window
        // of its own, off every display, and quits. Started from here, not
        // from the window's `.task` below: in a run launched hidden that task
        // was never reached — its "window on screen" mark never printed —
        // and a probe hung on it waits for nothing.
        LatexSuiteTypingProbe.runIfAsked()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    #if os(macOS)
                    OpenWithFinder.flush(into: model)
                    #endif
                    Trace.mark("window on screen")
                    Hitches.watch()
                    // Movement follows the system's own setting for it.
                    Motion.watch()
                    // Set now, cleared on a clean quit. Finding it still set
                    // next launch is how the app knows it died.
                    model.noteLaunch()
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
        // A paper in a window of its own: what a paper dragged out of the
        // open list becomes, the way a tab dragged out of a browser does.
        WindowGroup(id: "paper", for: UUID.self) { $paperID in
            PaperWindow(paperID: paperID)
                .environment(model)
        }
        .defaultSize(width: 760, height: 920)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))

        Settings {
            SettingsView()
                .environment(model)
        }
        #endif
    }
}
