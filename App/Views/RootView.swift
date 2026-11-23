import PaperCore
import InkEngine
import LibraryStore
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Chooses what the window shows: setup, the library, or an explanation of why
/// the library folder cannot be reached.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    #if os(macOS)
    private var wantsUpdateSheet: Bool {
        UpdateCenter.shared.showsSheet && !app.showsReleaseNotes && !app.showsFeedback
    }
    #endif

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                ProgressView(L("라이브러리를 여는 중", "Opening your library"))
                    .controlSize(.large)
                    .plainScreen()
            case .needsLibraryFolder:
                LibrarySetupView().plainScreen()
            case .ready:
                if let library = app.library {
                    LibraryWindow(model: library)
                } else {
                    LibrarySetupView().plainScreen()
                }
            case let .failed(message):
                LibraryUnavailableView(message: message).plainScreen()
            }
        }
        // Changing the interface's language changes every string below this
        // point, and none of them is a stored property SwiftUI can watch.
        // Rebuilding the tree once is the honest answer.
        .id(Language.Switch.shared.generation)
        // Every scroll view in the window, in one place: the indicator is an
        // environment value, so the whole tree inherits it.
        .scrollIndicators(.hidden)
        #if os(macOS)
        // Published from above the window's own content, so `LibraryWindow`
        // can read it: an `@Environment` property on a view resolves in that
        // view's own environment, not in the one it hands to its children.
        .measuringWindowToolbarBand()
        .translucentWindow()
        // Behind everything, and inside SwiftUI's own order so it stays there.
        .windowBackdrop()
        #endif
        .task {
            guard app.phase == .launching, app.beginLaunch() else { return }
            await app.restore()
            // After the library is up, not before: an introduction over an
            // empty window is an introduction to nothing.
            app.showReleaseNotesIfNew()
            #if os(macOS)
            UpdateCenter.shared.start {
                #if canImport(Sparkle)
                SparkleInstaller.make()
                #else
                nil
                #endif
            }
            FeedbackProbe.runIfAsked(app: app)
            PlansDemoProbe.runIfAsked()
            WindowProbe.runIfAsked(app: app)
            #endif
        }
        .sheet(isPresented: Bindable(app).showsFeedback) {
            FeedbackView()
        }
        #if os(macOS)
        // A new version: after the welcome for this one, never on top of it.
        // Read here, in the body, so SwiftUI watches it — a binding's getter
        // runs later, where nothing is being observed.
        .sheet(isPresented: Binding(
            get: { [wants = wantsUpdateSheet] in wants },
            set: { if !$0 { UpdateCenter.shared.showsSheet = false } }
        )) {
            UpdateSheet(center: .shared)
        }
        .overlay(alignment: .bottom) {
            if UpdateCenter.shared.showsBar {
                UpdateBar(center: .shared).padding(.bottom, 14)
            }
        }
        .animation(Motion.surface, value: UpdateCenter.shared.showsBar)
        #endif
        .sheet(isPresented: Bindable(app).showsReleaseNotes) {
            // A probe that opens this sheet to look at it must not put the
            // version down as seen — the person using this Mac has not seen
            // it yet, and would never be shown it.
            WhatsNewView(marksAsSeen: !Boot.isSet("PAPERTIME_WHATS_NEW"))
        }
        // Changing the folder is choosing a folder — the picker, not the
        // first-run screen. Nothing is forgotten until something is chosen.
        .fileImporter(isPresented: Bindable(app).isChoosingLibraryFolder, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            Task { await app.adopt(folderAt: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            // The folder is watched while the app runs, but a Mac that was
            // asleep or an iPhone that suspended the app will have missed
            // whatever arrived meanwhile. Coming back to the app is the
            // moment to look again.
            guard phase == .active, let library = app.library else { return }
            Task { await library.folderDidChange() }
        }
    }
}

/// The library window.
///
/// Every toolbar control is declared here, on the split view itself, rather
/// than on the individual columns. Per-column toolbars are what put dividers
/// between groups of buttons and made the order look accidental; one toolbar
/// gives one row, centred, in a deliberate order.
struct LibraryWindow: View {
    let model: LibraryModel
    @Environment(AppModel.self) private var app

    @Environment(\.windowToolbarBand) private var toolbarBand

    @State private var configuration = ReaderConfiguration()
    @State private var link = ReaderLink()
    /// Which of the inspector's tabs is showing. Owned here rather than by the
    /// column, because on a Mac the picker for it lives in the toolbar and the
    /// toolbar is declared here.
    @State private var inspectorTab = InspectorTab(
        rawValue: Boot.setting("PAPERTIME_INSPECTOR_TAB") ?? ""
    ) ?? .details
    /// How wide each pane was while it showed, so it can be held at that
    /// width on the way out rather than squeezed to nothing.
    @State private var heldWidths: [UUID: CGFloat] = [:]
    /// Where each pane is, for the watcher that tells which one a press
    /// landed in. A box, so writing it redraws nothing.
    @State private var paneFrames = PaneFrames()
    /// Whether the launch has settled — a selection it brings back is not
    /// somebody choosing a paper.
    @State private var panesSettled = false
    @Environment(\.undoManager) private var undoManager
    /// How much room the window has, so a column can be dragged as wide as
    /// there is room for rather than as wide as a number written here.
    @State private var windowWidth: CGFloat = 1200
    /// The paper a passage link opened, shown where the notes list was.
    @State private var slipBoxPaperID: UUID?
    /// The list pane opened only to hold a paper opened from a note or a
    /// project with no list pane open, and closed again on the way back.
    @State private var listLent = false
    @State private var isImportingPDFs = false
    @State private var showsExport = false
    @State private var showsMigration = false
    @State private var showsAddByAddress = false
    @State private var showsCitationStyles = false
    #if os(iOS)
    /// Settings on iOS: there is no Settings window, so a sheet from a gear.
    @State private var showsSettings = false
    #endif

    var body: some View {
        decorated
            // `--papertime-dark=1` looks at the window in the dark appearance
            // without changing the Mac's; `--papertime-split=1` puts the
            // first two papers side by side — both for checking without a
            // hand on the machine.
            .preferredColorScheme(Boot.isSet("PAPERTIME_DARK") ? .dark : nil)
            #if os(macOS)
            // The brush in a note's head: the inspector, on its Tools.
            .onChange(of: NoteFormatCenter.shared.panelRequests) { _, _ in
                if !app.showsInspector { app.setInspectorFloats(app.inspectorFloats) }
                inspectorTab = .tool
            }
            #endif
            .task {
                // `--papertime-toolbar-shot=<png in the container>`: the bar
                // over a selection in a note, drawn light and dark — its
                // layout; the glass itself needs a window to be glass.
                // `--papertime-format-shot=<png in the container>`: the
                // note's format panel, drawn light and dark with no window.
                if let path = Boot.setting("PAPERTIME_FORMAT_SHOT") {
                    var state = NoteFormat.State()
                    state.isEditing = true
                    state.paragraph = .subheading
                    state.style.bold = true
                    state.style.color = "#d62e54"
                    state.size = 18
                    state.alignment = .left
                    NoteFormatCenter.shared.preview(state)
                    for scheme in [ColorScheme.light, .dark] {
                        let renderer = ImageRenderer(content:
                            NoteFormatPanel().controls
                                .frame(width: 244, height: 430, alignment: .top)
                                .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
                                .environment(\.colorScheme, scheme)
                        )
                        renderer.scale = 2
                        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                            let file = path.replacingOccurrences(of: ".png", with: scheme == .dark ? "-dark.png" : ".png")
                            try? png.write(to: URL(fileURLWithPath: file))
                            FileHandle.standardError.write(Data("format shot: wrote \(file)\n".utf8))
                        }
                    }
                }
                if let path = Boot.setting("PAPERTIME_TOOLBAR_SHOT") {
                    FileHandle.standardError.write(Data("toolbar panel: \(SelectionToolbar.describePanel())\n".utf8))
                    // Both bars in a window of their own off every screen,
                    // displayed once: which views AppKit draws with vibrancy
                    // (the blending that washes a saturated colour toward the
                    // backdrop), by their `allowsVibrancy` and the compositing
                    // filter it puts on their layers.
                    let stage = WindowProbe.ownWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: .borderless)
                    stage.isOpaque = false
                    stage.backgroundColor = .clear
                    let noteBar = SelectionToolbar.SelectionBarView(rootView: SelectionToolbar.Bar(choose: { _ in }))
                    noteBar.frame = NSRect(x: 20, y: 70, width: 250, height: 32)
                    let pageBar = MarkupBarView(onMark: { _, _ in }, onNote: {}, onCopy: {}, onUltraCopy: {})
                    pageBar.frame = NSRect(x: 20, y: 10, width: 320, height: 44)
                    stage.contentView?.addSubview(noteBar)
                    stage.contentView?.addSubview(pageBar)
                    stage.orderFrontRegardless()
                    stage.contentView?.layoutSubtreeIfNeeded()
                    stage.displayIfNeeded()
                    try? await Task.sleep(for: .milliseconds(300))
                    func walk(_ view: NSView, _ depth: Int) {
                        let filter = (view.layer?.compositingFilter as? CIFilter)?.name ?? (view.layer?.compositingFilter).map { String(describing: $0) } ?? "-"
                        FileHandle.standardError.write(Data("vibrancy: \(String(repeating: "  ", count: depth))\(type(of: view)) allowsVibrancy=\(view.allowsVibrancy) filter=\(filter) layer=\(view.layer.map { String(describing: type(of: $0)) } ?? "none")\n".utf8))
                        for child in view.subviews { walk(child, depth + 1) }
                    }
                    if let root = stage.contentView { walk(root, 0) }
                    stage.orderOut(nil)
                    for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                        let renderer = ImageRenderer(content: SelectionToolbar.Bar(choose: { _ in })
                            .padding(24)
                            .background(scheme == .dark ? Color(white: 0.12) : Color.white)
                            .environment(\.colorScheme, scheme))
                        renderer.scale = 2
                        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                            let file = path.replacingOccurrences(of: ".png", with: "-\(name).png")
                            try? png.write(to: URL(fileURLWithPath: file))
                            FileHandle.standardError.write(Data("toolbar shot: \(file) \(Int(image.size.width))×\(Int(image.size.height))\n".utf8))
                        }
                    }
                }
                // `--papertime-contents=1` opens the contents over the page,
                // which is where the page grid lives.
                if Boot.isSet("PAPERTIME_CONTENTS") {
                    try? await Task.sleep(for: .seconds(3))
                    app.toggleFloatingList()
                }
                if Boot.isSet("PAPERTIME_OPEN_PAPERS") {
                    try? await Task.sleep(for: .seconds(2))
                    if let first = model.visiblePapers.first { model.keepOpen(first.id) }
                    app.toggleOpenPapers()
                }
                guard let split = Boot.setting("PAPERTIME_SPLIT") else { return }
                try? await Task.sleep(for: .seconds(2))
                let papers = model.visiblePapers
                // `--papertime-split=same`: the first paper beside itself —
                // two panes of one paper, each a reader of its own.
                if split == "same", let first = papers.first {
                    model.selectedPaperID = first.id
                    app.dock(first.id, at: .right, in: model)
                } else {
                    guard papers.count >= 2 else { return }
                    model.selectedPaperID = papers[0].id
                    app.dock(papers[1].id, at: .right, in: model)
                }
                try? await Task.sleep(for: .seconds(1))
                let panes = (app.split?.panes ?? []).map { "\($0.id.uuidString.prefix(4)):\(model.paper($0.paper)?.meta.displayTitle ?? "?")" }
                FileHandle.standardError.write(Data("split: \(panes) focused \(app.focusedPaneID?.uuidString.prefix(4) ?? "none") selected \(model.selectedPaper?.meta.displayTitle ?? "none")\n".utf8))
            }
            // A quoted passage was clicked on the page: its note opens
            // where notes are showing, at the quotation.
            .onChange(of: model.notes.passageRequest) { _, request in
                guard let request else { return }
                Task { @MainActor in await openQuotation(request) }
            }
    }

    /// Opens a quotation asked for from its page. In the slip-box the note
    /// takes the open note's place beside the paper; otherwise the inspector
    /// comes forward on Notes with it. A pane beside another becomes the one
    /// being read with the same click, and the inspector follows its paper —
    /// clearing the open note as it does — so the note is opened once that
    /// has settled.
    @MainActor
    private func openQuotation(_ request: NotesModel.PassageRequest) async {
        defer { if model.notes.passageRequest == request { model.notes.passageRequest = nil } }
        guard model.notes.note(request.noteID) != nil else { return }
        if model.scope.isSlipBox {
            model.notes.openNoteID = request.noteID
        } else {
            for _ in 0..<20 where model.selectedPaperID != request.paperID {
                try? await Task.sleep(for: .milliseconds(25))
            }
            await Task.yield()
            app.showsInspector = true
            inspectorTab = .note
            link.openNoteID = request.noteID
        }
        model.notes.revealPassage = request.url
        if Boot.isSet("PAPERTIME_QUOTE_LINK") {
            let place = model.scope.isSlipBox ? "the slip-box" : "the inspector on \(inspectorTab)"
            FileHandle.standardError.write(Data("quote link: opened \(request.noteID) in \(place)\n".utf8))
        }
    }

    /// The Mac hangs the toolbar off the split view itself, which is what makes
    /// it one centred row with no dividers between column groups. iOS has no
    /// such toolbar on a split view, so there it belongs to the list column's
    /// navigation bar.
    @ViewBuilder
    private var decorated: some View {
        #if os(macOS)
        if #available(macOS 26, *) {
            windowBody
                // One toolbar with a flexible spacer in it, rather than two.
                // Without the title holding them apart the two groups packed
                // against the leading edge together; the spacer is what macOS 26
                // gives you to say "these belong at the other end".
                .toolbar(id: "library") {
                    toolbarContent.sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible)
                    trailingToolbarContent.sharedBackgroundVisibility(.hidden)
                    inspectorToolbarContent.sharedBackgroundVisibility(.hidden)
                }
                // Hidden, so the toolbar has no colour of its own: the window's
                // ground runs straight up through it and there is no edge left
                // where the two used to meet. The controls carry their own glass.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            // Sonoma and Sequoia: no glass to hide and no ToolbarSpacer. A
            // Spacer in an item of its own is what a flexible space was
            // before there was a name for it, and the toolbar's ground is
            // hidden the older way.
            windowBody
                .toolbar(id: "library") {
                    toolbarContent
                    ToolbarItem(id: "space", placement: .automatic) { Spacer() }
                    trailingToolbarContent
                    inspectorToolbarContent
                }
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        #else
        windowBody
        #endif
    }

    private var splitView: some View {
        @Bindable var app = app

        // Both columns are ours.
        //
        // `NavigationSplitView` cannot express "hide the middle column": there
        // is no such visibility case, and collapsing it by width is one-way.
        // Rebuilding the view tree does work, but it tears down the PDF view
        // every time, which is what made the shortcut crawl. And on a
        // two-column split view the visibility binding is inert — SwiftUI's own
        // Hide Sidebar command cannot move it either. Owning the widths means
        // both shortcuts work, both animate, both give the width back, and the
        // reader never moves.
        #if os(macOS)
        // The plans' sheets hang here, on something that outlives the menus
        // and buttons that ask for them (`PlanRequest`).
        return AnyView(macColumns.modifier(PlanPresentations(model: model)))
        #else
        // iPhone and iPad keep the system split view: it is what gives them
        // the sliding sidebar, the back button and the compact layout.
        // Two columns, not three: the screen has no room for a shelf of
        // scopes beside the list and the page. The scopes come as a panel
        // over the window (`scopePanel`), the inspector floats in from the
        // right, and the system's own toggle hides and shows the list.
        return AnyView(
            NavigationSplitView(columnVisibility: $app.columnVisibility, preferredCompactColumn: $app.compactColumn) {
                listColumn
                    // Wide enough for the row of buttons above it: at 340 the sixth
                    // pushed the shelves button off the leading edge.
                    .navigationSplitViewColumnWidth(min: 340, ideal: 380, max: 640)
            } detail: {
                // The same three details the Mac has: the note, the graph,
                // the paper.
                switch model.scope {
                case .notes, .knowledge:
                    SlipBoxDetail(model: model, link: link) { paperID in
                        withAnimation(Motion.move) { slipBoxPaperID = paperID }
                    }
                case .graph:
                    PaperGraphView(model: model, graph: model.graph)
                default:
                    PaperDetailColumn(
                        model: model, configuration: configuration,
                        link: link, inspectorTab: $inspectorTab
                    )
                }
            }
            .background { scopePanel }
            .sheet(isPresented: $showsSettings) {
                NavigationStack {
                    SettingsView()
                        .environment(app)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L("완료", "Done")) { showsSettings = false }
                            }
                        }
                }
            }
        )
        #endif
    }

    #if os(iOS)
    /// The library's shelves — scopes, collections, tags, authors — as a
    /// panel in the middle of the window, the way Spotlight comes: a form
    /// sheet, which the system centres, dims the ground behind and lets a
    /// tap outside dismiss. Pick a shelf and it goes.
    private var scopePanel: some View {
        @Bindable var app = app
        return Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: $app.showsScopePanel) {
                NavigationStack {
                    LibrarySidebar(model: model)
                        .navigationTitle(L("라이브러리", "Library"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    app.showsScopePanel = false
                                    showsSettings = true
                                } label: {
                                    Label(L("설정", "Settings"), systemImage: "gearshape")
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L("완료", "Done")) { app.showsScopePanel = false }
                            }
                        }
                }
                .presentationSizing(.form)
                .presentationBackground(.regularMaterial)
            }
    }
    #endif

    #if os(macOS)
    // MARK: - The panes (`Workspace.swift`)

    /// The panes showing: the window's own, less the list while a plan's
    /// calendar stands where the list and the page were.
    private var shownPanes: [ContentPane] {
        var shown = app.displayedPanes
        if model.showsBoard, shown.contains(where: { $0.content == .page }) {
            shown.removeAll { $0.content == .list }
        }
        return shown
    }

    /// Every pane the row holds: those showing, then those held out of sight
    /// at no width — the list and the page always among them, so the reader
    /// and the table are never torn down to be hidden. Building a `PDFView`
    /// is most of what opening a paper costs, and tearing it down and back
    /// up is what made the toggles crawl.
    private func rowPanes(_ shown: [ContentPane]) -> [ContentPane] {
        var row = shown
        for pane in app.panes where !row.contains(where: { $0.id == pane.id }) { row.append(pane) }
        if !row.contains(where: { $0.id == ContentPane.listID }) { row.append(.list) }
        if !row.contains(where: { $0.id == ContentPane.pageID }) { row.append(.page) }
        return row
    }

    private var dockedInspectorShown: Bool { app.showsInspector && !app.inspectorFloats && !app.isFocusMode }
    private var floatingInspectorShown: Bool { app.showsInspector && app.inspectorFloats && !app.isFocusMode }

    /// The inspector's width as laid out: what it was given, held to what
    /// leaves the panes a page's floor — in a window too narrow for both,
    /// the inspector gives way rather than the window growing past the
    /// screen.
    private var inspectorShownWidth: CGFloat {
        var others = Pane.pageFloor + (showsPlusColumn ? PlusColumn.width + Column.gap : 0)
        if app.isSidebarVisible { others += app.sidebarWidth + Column.gap }
        return min(app.inspectorWidth, max(240, windowWidth - others - Column.gap))
    }

    /// Whether the «+» column stands: not in focus, and not when the row
    /// is full — it could only say «칸은 네 개까지예요» (2026-11-19, «이미 4개
    /// 다 차면 저 "+"를 없애면 되잖아»).
    private var showsPlusColumn: Bool {
        !app.isFocusMode && shownPanes.count < AppModel.mostPanes
    }

    /// The room the content panes share, the gaps between them included.
    private var paneRoom: CGFloat {
        var room = windowWidth
        if app.isSidebarVisible { room -= app.sidebarWidth + Column.gap }
        if showsPlusColumn { room -= PlusColumn.width + Column.gap }
        if dockedInspectorShown { room -= inspectorShownWidth + Column.gap }
        return max(room, 0)
    }

    /// What a pane would like, before the room has its say.
    private func wantedWidth(_ pane: ContentPane) -> CGFloat {
        switch pane.content {
        // The list's width is the table's while it holds the table, the
        // list's otherwise — kept apart so the notes keep their own.
        case .list: model.boardInListColumn ? app.tableWidth : app.paperListWidth
        case .page: pane.width ?? 600
        case let .shelf(key): pane.width ?? Self.defaultWidth(forShelf: key)
        case .note: pane.width ?? 360
        }
    }

    private static func defaultWidth(forShelf key: String) -> CGFloat {
        switch LibraryModel.Scope(paneKey: key) {
        case .notes, .knowledge: 320
        case .projects(nil): 300
        case .projects: 620
        default: 560
        }
    }

    /// The width a pane is not squeezed below while anything else can give.
    private static let paneLeast: CGFloat = 200

    private struct PaneLayout {
        /// Every showing pane's width but the filler's.
        var widths: [UUID: CGFloat]
        /// The pane that takes what is left: the page, else the list, else
        /// the last.
        var filler: UUID?
        /// How far the table may go before the page loses its reading width.
        var tableCap: CGFloat?
        /// How much wider the panes could be before the filler reaches its floor.
        var slack: CGFloat
    }

    /// The widths, worked out from the room there is.
    ///
    /// What each pane was given, until the filler would go under its floor —
    /// then they give way together, and have their widths back when the room
    /// comes back. The table yields first, so the page keeps a reading width
    /// (2026-11-16: with the inspector open, the table took the room and left
    /// the paper 270 points). And nothing is ever laid out wider than the
    /// room: widths that added up past the window made SwiftUI widen the
    /// window past the screen, and a zoom then fought it until AppKit gave up.
    private func layout(_ shown: [ContentPane]) -> PaneLayout {
        let filler = (shown.first { $0.content == .page } ?? shown.first { $0.content == .list } ?? shown.last)?.id
        let fillerIsPage = shown.first { $0.id == filler }?.content == .page
        let room = paneRoom - Column.gap * CGFloat(max(shown.count - 1, 0))
        var widths: [UUID: CGFloat] = [:]
        for pane in shown where pane.id != filler { widths[pane.id] = wantedWidth(pane) }
        var tableCap: CGFloat?
        if let list = shown.first(where: { $0.content == .list }), list.id != filler, model.boardInListColumn, fillerIsPage {
            let others = widths.filter { $0.key != list.id }.values.reduce(0, +)
            let cap = max(room - Pane.readingFloor - others, Pane.tableLeast)
            tableCap = cap
            widths[list.id] = min(widths[list.id] ?? 0, cap)
        }
        let floor: CGFloat = fillerIsPage ? Pane.pageFloor : Self.paneLeast
        var available = max(room - floor, 0)
        let slack = max(available - widths.values.reduce(0, +), 0)
        if widths.values.reduce(0, +) > available {
            // Too little room: the panes give way toward a width that still
            // shows a column of titles; then the page gives way down to the
            // same; and only then does everybody shrink together. A pane
            // squeezed evenly to nothing is no pane — the list came out
            // seventy points wide beside a page that kept all of its floor.
            let least = widths.mapValues { min($0, Self.paneLeast) }
            if least.values.reduce(0, +) > available {
                available = max(room - min(floor, Self.paneLeast), 0)
            }
            let spare = widths.values.reduce(0, +) - least.values.reduce(0, +)
            let over = widths.values.reduce(0, +) - available
            if over <= spare, spare > 0 {
                for (id, width) in widths {
                    let give = (width - least[id]!) / spare * over
                    widths[id] = (width - give).rounded(.down)
                }
            } else {
                let total = least.values.reduce(0, +)
                let factor = total > 0 ? available / total : 0
                for (id, width) in least { widths[id] = (width * factor).rounded(.down) }
            }
        }
        return PaneLayout(widths: widths, filler: filler, tableCap: tableCap, slack: slack)
    }

    /// The gap before a pane, which resizes the pane beside it that has a
    /// width of its own — the one on the left, unless that is the filler.
    @ViewBuilder
    private func divider(before index: Int, in shown: [ContentPane], layout: PaneLayout) -> some View {
        let left = shown[index - 1], right = shown[index]
        let resized = left.id == layout.filler ? right : left
        let current = layout.widths[resized.id] ?? wantedWidth(resized)
        // The table's floor is higher than the list's, and a narrow window
        // can leave less room than that: the top of the range is held at or
        // above its floor, or `400...300` traps.
        let floor: CGFloat = resized.content == .list ? (model.boardInListColumn ? Pane.tableLeast : 240) : 200
        let top: CGFloat = {
            let room = current + layout.slack
            if resized.content == .list, let cap = layout.tableCap { return min(room, cap) }
            return room
        }()
        ColumnDivider(
            width: widthBinding(resized, shown: current),
            range: Double(floor)...Double(max(floor, top)),
            resizes: left.id == layout.filler ? .trailing : .leading
        )
    }

    private func widthBinding(_ pane: ContentPane, shown: CGFloat) -> Binding<Double> {
        switch pane.content {
        case .list:
            model.boardInListColumn
                ? Binding(get: { Double(shown) }, set: { app.tableWidth = $0 })
                : Binding(get: { Double(shown) }, set: { app.paperListWidth = $0 })
        default:
            Binding(get: { Double(shown) }, set: { app.setPaneWidth(pane.id, $0) })
        }
    }

    /// What a pane's head says and does.
    private func head(for pane: ContentPane) -> PaneHead {
        let title = app.title(of: pane, model: model)
        return PaneHead(
            id: pane.id,
            title: title,
            symbol: app.symbol(of: pane, model: model),
            canClose: app.panes.count > 1 && !app.isFocusMode,
            close: { [app, undoManager] in app.closePane(pane.id, title: title, undo: undoManager) },
            choose: { [app, model] in app.show($0, inPane: pane.id, model: model) }
        )
    }

    /// One pane in the row: its gap, its content, its panel — or, held out
    /// of sight, the same at no width.
    @ViewBuilder
    private func paneSlot(_ pane: ContentPane, shown: [ContentPane], layout: PaneLayout) -> some View {
        let index = shown.firstIndex { $0.id == pane.id }
        let displayed = index != nil
        let isFiller = displayed && pane.id == layout.filler
        let fixed = layout.widths[pane.id] ?? wantedWidth(pane)
        // Held at the width it had, and revealed — for the reason the lists
        // always were: a column closing by width drags its content's width
        // with it, and a `PDFView` with no width draws nothing, which for a
        // frame was a pane of glass the colour of paper. That was the white
        // flash.
        let held = heldWidths[pane.id] ?? fixed
        HStack(spacing: 0) {
            if let index, index > 0 { divider(before: index, in: shown, layout: layout) }
            paneBody(pane)
                .environment(\.paneHead, head(for: pane))
                // Content that will not go narrower is cut at its far edge,
                // so the start of every row is what stays. The filler is held
                // at its width while the panes move (`heldFillerWidth`).
                .frame(width: isFiller ? app.heldFillerWidth : (displayed ? fixed : held), alignment: .leading)
                .frame(width: isFiller ? nil : (displayed ? fixed : 0), alignment: .leading)
                // The filler takes the room it is given and never more: what
                // it would like is not counted towards the window's minimum.
                // The others are rigid — a pane that could be squeezed was
                // squeezed, the row splitting what was left evenly.
                .frame(minWidth: isFiller ? 0 : nil, maxWidth: isFiller ? .infinity : nil, alignment: .leading)
                .modifier(PaneDropZones(paneID: pane.id, enabled: displayed, model: model))
                .columnPanel()
                .opacity(displayed ? 1 : 0)
                .clipped()
                .allowsHitTesting(displayed)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    // Only while it shows: reading it back while it is held
                    // would be reading our own answer.
                    paneFrames.frames[pane.id] = displayed ? frame : nil
                    // The filler's width for the next motion to hold — read
                    // only while nothing is moving.
                    if isFiller, displayed, app.heldFillerWidth == nil, frame.width > 1 { app.fillerWidth = frame.width }
                    // Not while the panes move: this is state, and written on
                    // every frame of the motion it laid the whole window out
                    // again on every frame (`movingPanes`).
                    if displayed, app.heldFillerWidth == nil, frame.width > 1,
                       abs((heldWidths[pane.id] ?? 0) - frame.width) > 0.5 {
                        heldWidths[pane.id] = frame.width
                    }
                }
        }
        .frame(minWidth: isFiller ? 0 : nil, maxWidth: isFiller ? .infinity : nil, alignment: .leading)
        .transition(.opacity)
    }

    @ViewBuilder
    private func paneBody(_ pane: ContentPane) -> some View {
        switch pane.content {
        case .list:
            listColumn
        case .page:
            pageColumn
        case let .shelf(key):
            PinnedShelf(model: model, link: link, paneID: pane.id, key: key) { id in
                openFromPinned(id, pane: pane.id)
            }
        case let .note(id):
            NotePane(model: model, link: link, paneID: pane.id, noteID: id)
        }
    }

    /// The page pane: the paper, or the note, the project, the graph — what
    /// the sidebar's place puts there, or what a pinned pane did.
    @ViewBuilder
    private var pageColumn: some View {
        switch app.pageShowing(model: model) {
        case let .project(id):
            VStack(spacing: 0) {
                PaneHeadBar(symbol: "flag", title: app.title(of: .page, model: model))
                ProjectPage(model: model, openPaper: openInListPane, pinnedID: id)
            }
        case .note:
            VStack(spacing: 0) {
                PaneHeadBar(symbol: "note.text", title: app.title(of: .page, model: model))
                SlipBoxDetail(model: model, link: link) { paperID in openInListPane(paperID) }
            }
        case .graph:
            VStack(spacing: 0) {
                PaneHeadBar(symbol: "point.3.connected.trianglepath.dotted", title: L("그래프", "Graph"))
                PaperGraphView(model: model, graph: model.graph)
            }
        case .paper:
            // The page, with the board where a plan's calendar takes it.
            PaperDetailColumn(
                model: model, configuration: configuration,
                link: link, inspectorTab: $inspectorTab
            )
        }
    }

    /// A paper pressed in a pinned pane: on the page — one comes in to the
    /// pane's right when none is open — and the page shows the paper even
    /// where the sidebar's place would put a note there.
    private func openFromPinned(_ id: UUID, pane: UUID) {
        model.selection = [id]
        model.keepOpen(id)
        app.showOnPage(.paper, model: model)
        app.ensurePagePane(after: pane)
    }

    /// The inspector, standing at the right of the panes.
    private var dockedInspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button {
                    app.setInspectorFloats(true)
                } label: {
                    Label(L("띄우기", "Float"), systemImage: "macwindow.on.rectangle")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pressable(cornerRadius: 11)
                .help(L("창 위에 띄워서 보기 — 칸을 넓게 써요", "Float over the window, and give the panes the room"))
                PaneCloseButton { app.hideInspector() }
                    .help(L("정보 패널 숨기기", "Hide the Inspector"))
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            // Not drawn while it is closed or floating: held in the row at
            // no width, it was still laid out — its form measured whole —
            // every time the paper changed, for nobody (`--papertime-perf`).
            if dockedInspectorShown {
                InspectorView(model: model, configuration: configuration, link: link, inspectorTab: $inspectorTab)
            } else {
                Color.clear
            }
        }
    }

    private var macColumns: some View {
        @Bindable var app = app
        let shown = shownPanes
        let layout = layout(shown)

        return HStack(spacing: 0) {
            // Two frames, and the inner one never moves. A column closing by
            // width drags its content's width with it, and the content here is
            // a `List` — an `NSTableView` that re-lays out every row on every
            // frame of the animation. Held at its own width inside a frame
            // that animates, the list is revealed rather than resized, and
            // lays out once.
            // On the ground, not on a panel — the way the Settings window's
            // sidebar sits beside its page. The list of places is chrome;
            // the panels are for the things you read.
            sidebarColumn
                .frame(width: app.sidebarWidth)
                .frame(width: app.isSidebarVisible ? app.sidebarWidth : 0, alignment: .leading)
                .clipShape(Column.shape)
                .opacity(app.isSidebarVisible ? 1 : 0)
                .clipped()

            if app.isSidebarVisible {
                ColumnDivider(width: $app.sidebarWidth, range: 200...max(200, app.sidebarWidth + Double(layout.slack)))
            }

            // The content panes, one to four, and the ones held out of sight.
            ForEach(rowPanes(shown)) { pane in
                paneSlot(pane, shown: shown, layout: layout)
            }

            // At the end of the row while there is room for another pane: a
            // pane closed is never a pane lost.
            if showsPlusColumn {
                Color.clear.frame(width: Column.gap)
                PlusColumn(model: model)
                    .transition(.opacity)
            }

            if dockedInspectorShown {
                ColumnDivider(
                    width: $app.inspectorWidth,
                    range: 280...max(280, Double(inspectorShownWidth + layout.slack)),
                    resizes: .trailing
                )
            }
            // Closed by width, so it slides rather than blinking in and out —
            // and revealed rather than squeezed: narrowing the column narrowed
            // the form inside it, which re-wrapped every label on every frame.
            dockedInspector
                .frame(width: inspectorShownWidth)
                .frame(width: dockedInspectorShown ? inspectorShownWidth : 0, alignment: .trailing)
                .columnPanel()
                .opacity(dockedInspectorShown ? 1 : 0)
                .clipped()
                .allowsHitTesting(dockedInspectorShown)
        }
        // The width the window offers, not the width the columns ask for:
        // measured on a frame that takes the offer, so a column that asks
        // for too much cannot feed its own answer back in as room.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        // Rounded, and that is the point: a drag on the window's edge reports
        // a new width sixty times a second, and every one of them was a
        // change of state that rebuilt the whole column stack. Rounded down:
        // the columns are laid out against it, and rounding up promised them
        // room the window does not have.
        .onGeometryChange(for: CGFloat.self) { ($0.size.width / 24).rounded(.down) * 24 } action: {
            windowWidth = $0
        }
        // The inspector, floating: over the panes, which have its room back —
        // so with four panes it is still one press away.
        .overlay(alignment: .topLeading) {
            if floatingInspectorShown {
                GeometryReader { proxy in
                    FloatingInspector(container: proxy.size, inspectorTab: $inspectorTab, hasPaper: model.selectedPaper != nil) {
                        InspectorView(model: model, configuration: configuration, link: link, inspectorTab: $inspectorTab)
                    }
                }
                .transition(.opacity)
            }
        }
        // The panels float clear of the window's edges and of the toolbar, so
        // every boundary in the window is a curve and a gap rather than a
        // straight line drawn where two flat backgrounds happen to meet.
        .padding(.horizontal, Column.margin)
        .padding(.bottom, Column.margin)
        // Nothing between the controls and the panels but the gap they
        // already keep from each other; the band's own slack is the margin.
        .padding(.top, max(toolbarBand - Column.underToolbar, 0))
        .background { Column.ground }
        // A pane closed, or a fifth refused.
        .overlay(alignment: .bottom) { PaneNoticeCapsule() }
        // Which pane a press lands in — a paper chosen with no page open
        // opens one to that pane's right.
        .background(PanePressWatcher(frames: paneFrames) { [app] id in app.lastPressedPane = id })
        // What the window may shrink to, said once, here — not the sum of
        // whatever the columns happen to hold (`Pane.windowFloor`).
        .frame(minWidth: Pane.windowFloor.width, minHeight: Pane.windowFloor.height)
        .task {
            // A selection the launch brings back is not somebody choosing.
            try? await Task.sleep(for: .seconds(1.5))
            panesSettled = true
        }
        .onChange(of: model.scope) { _, scope in
            if listLent {
                app.returnLentListPane()
                listLent = false
            }
            // The page goes back to what the sidebar's place puts there.
            app.pageShows = nil
            // A project chosen shows its page.
            if panesSettled, case .projects(_?) = scope { app.ensurePagePane(after: app.lastPressedPane) }
        }
        .onChange(of: model.selectedPaperID) { old, new in
            // Side by side, the paper chosen goes to the pane in focus.
            app.followSelection(new, model: model)
            guard panesSettled, let new, new != old else { return }
            let from = app.lastPressedPane
            // Pressed in a pinned shelf of papers: the page shows the paper,
            // even where the sidebar's place would put a note there.
            if let from, let key = app.pane(from)?.shelfKey,
               LibraryModel.Scope(paneKey: key)?.holdsPapers == true {
                app.showOnPage(.paper, model: model)
            }
            app.ensurePagePane(after: from)
        }
        .onChange(of: model.notes.openNoteID) { old, new in
            guard panesSettled, new != nil, new != old else { return }
            // A note pressed in the list of notes: the page goes back to
            // notes, if a pinned pane had put a paper there.
            if model.scope.isSlipBox, app.lastPressedPane == ContentPane.listID { app.pageShows = nil }
            guard app.pageShowing(model: model) == .note else { return }
            app.ensurePagePane(after: app.lastPressedPane)
        }
        .onChange(of: slipBoxPaperID) { _, paper in
            guard paper == nil, listLent else { return }
            listLent = false
            app.returnLentListPane()
        }
        // No `.animation(value:)` here. The toggles already declare the motion
        // with `withAnimation`, and declaring it a second time with a
        // different duration meant every pane change was interpolated twice —
        // 0.22 against 0.25, on the same widths, which is what the stutter
        // was. The transaction the model opens is the one animation now.
    }
    #endif

    /// A paper opened from a note, with the way back to the notes above it.
    private func slipBoxPaper(_ paper: LoadedPaper) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(Motion.move) { slipBoxPaperID = nil }
                } label: {
                    Label(model.scope.paneKey?.hasPrefix("project") == true ? L("프로젝트", "Project") : L("노트", "Notes"), systemImage: "chevron.left")
                        .font(.subheadline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                Spacer(minLength: 8)

                Text(paper.meta.csl.fullTitle ?? paper.meta.displayTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                #if os(macOS)
                PaneHeadControls()
                #endif
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            ReaderScreen(
                library: model, paper: paper,
                configuration: configuration, link: link
            )
        }
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No title. The folder's name was a headline over a list whose
            // first section header already says "Library"; it is beside that
            // header now, small, and the list starts where the title was.
            LibrarySidebar(model: model)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsSettings = true
                } label: {
                    Label(L("설정", "Settings"), systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsView()
                    .environment(app)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L("완료", "Done")) { showsSettings = false }
                        }
                    }
            }
        }
        #endif
    }

    private var windowBody: some View {
        @Bindable var app = app

        return splitView
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            app.reassertFocusMode()
        }
        .onChange(of: configuration.layout, initial: true) { _, layout in
            app.settings.readerPageMode = layout.rawValue
            // A spread wants the whole window. Choosing Book is the clearest
            // statement a reader can make that they are here to read, so the
            // columns step aside and the list becomes something summoned.
            app.setFocusMode(layout == .book)
        }
        .searchPalette(model: model, link: link, isPresented: $app.showsSearchPalette) { action in
            perform(action)
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeToggleFocus)) { _ in
            app.toggleFocusMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeLayoutContinuous)) { _ in
            configuration.layout = .continuous
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeLayoutSinglePage)) { _ in
            configuration.layout = .singlePage
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeLayoutBook)) { _ in
            configuration.layout = .book
        }
        #if os(macOS)
        .fileImporter(
            isPresented: $isImportingPDFs,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            Task { await model.importDocuments(at: urls) }
        }
        #endif
        .sheet(isPresented: $showsExport) { BibTeXExportView() }
        .sheet(isPresented: $showsMigration) { MigrationView(model: model) }
        .sheet(isPresented: $showsAddByAddress) { AddByAddressSheet(model: model) { showsAddByAddress = false } }
        .modifier(RestoreAlerts(model: model))
        .sheet(isPresented: $showsCitationStyles) {
            if let paper = model.selectedPaper {
                NavigationStack {
                    CitationStyleView(item: paper.meta.csl)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L("완료", "Done")) { showsCitationStyles = false }
                            }
                        }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeBackToPreviousPaper)) { _ in
            model.goBack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeForwardToNextPaper)) { _ in
            model.goForward()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeAddPapers)) { _ in
            chooseDocumentsToAdd()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeAddByAddress)) { _ in
            showsAddByAddress = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeExportBibTeX)) { _ in
            showsExport = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeSyncNow)) { _ in
            syncNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeCopyCitationKey)) { _ in
            copySelectedCitationKey()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeFindInDocument)) { _ in
            // The find bar lives over the page, so there has to be a page.
            if !app.showsReader { app.toggleReader() }
            if app.isFocusMode || model.selectedPaper != nil { link.isFinding = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeNewNote)) { _ in
            openNewNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeNextPaper)) { _ in
            step(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimePreviousPaper)) { _ in
            step(by: -1)
        }
    }

    /// Moves the selection along the list the reader is looking at.
    private func step(by offset: Int) {
        let papers = model.visiblePapers
        guard !papers.isEmpty else { return }
        guard let current = model.selectedPaperID,
              let index = papers.firstIndex(where: { $0.id == current })
        else {
            model.selectedPaperID = papers.first?.id
            return
        }
        let next = index + offset
        guard papers.indices.contains(next) else { return }
        model.selectedPaperID = papers[next].id
    }

    /// The list column, whatever the shelf is showing.
    ///
    /// The bar belongs to the column, not to the papers: hung on the paper
    /// list alone, walking into the slip-box took the button that opens the
    /// shelves with it, and there was no way back out of the notes.
    private var listColumn: some View {
        shelfColumn
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(id: "library") { toolbarContent.sharedBackgroundVisibility(.hidden) }
            // The importer sits on the column whose button asks for it: hung
            // on the split view's root it never came up on the iPad.
            .fileImporter(
                isPresented: $isImportingPDFs,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true
            ) { result in
                guard case let .success(urls) = result else { return }
                Task { await model.importDocuments(at: urls) }
            }
        #endif
    }

    @ViewBuilder
    private var shelfColumn: some View {
        switch model.scope {
        #if os(macOS)
        case .projects:
            if let id = slipBoxPaperID, let paper = model.paper(id) {
                slipBoxPaper(paper)
            } else {
                ProjectList(model: model)
            }
        #endif
        case .notes, .knowledge:
            // Following a passage out of a note puts the paper where the list
            // of notes was. The note stays open beside it — which is the
            // whole point of following the link — so the paper takes the only
            // other column there is, and a way back sits on top of it.
            if let id = slipBoxPaperID, let paper = model.paper(id) {
                slipBoxPaper(paper)
            } else {
                SlipBoxList(model: model)
            }
        case .graph: GraphSidePanel(model: model, graph: model.graph)
        default:
            #if os(macOS)
            if model.boardInListColumn {
                PlanBoard(model: model)
            } else {
                paperListColumn
            }
            #else
            paperListColumn
            #endif
        }
    }

    private var paperListColumn: some View {
        // The shelf's name stands at the top of the column on every device.
        // In the iPad's navigation bar it was squeezed between our own
        // buttons and the system's toggle until one clipped letter of it was
        // left standing in the corner.
        VStack(spacing: 0) {
            #if os(macOS)
            // The same head every left column wears: a tile, a name, a line.
            ShelfHeader(symbol: ShelfTitle.symbol(of: model.scope), title: scopeTitle,
                        subtitle: L("논문 \(model.visiblePapers.count)편", PlanText.papers(model.visiblePapers.count))) {
                if Legacy.paperList, LibraryModel.shelfKey(model.scope) != nil {
                    ShelfViewSwitch(
                        view: Binding(get: { model.shelfView(for: model.scope) },
                                      set: { model.setShelfView($0, for: model.scope) }),
                        choices: { if case .plan = model.scope { [.list, .table, .calendar] } else { [.list, .table] } }(),
                        compact: true
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)
            #else
            HStack {
                Text(scopeTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            #endif
            PaperListView(model: model, link: link)
        }
    }

    // MARK: - Toolbar

    /// The Mac centres its toolbar with `.principal`; iOS allows only one
    /// principal item, so there the controls sit in the trailing group.
    private var barPlacement: ToolbarItemPlacement {
        #if os(macOS)
        // Leading, after the title. Centred, the cluster sat at no edge and
        // belonged to neither side of the window.
        .navigation
        #else
        .topBarTrailing
        #endif
    }

    #if os(macOS)
    /// The trailing group: search, the plus, the three panes, and the menu.
    @ToolbarContentBuilder
    private var trailingToolbarContent: some CustomizableToolbarContent {
        ToolbarItem(id: "trailing", placement: .automatic) {
            HStack(spacing: 6) {
                Button {
                    app.showsSearchPalette = true
                } label: {
                    Label(L("전부 찾기", "Search Everything"), systemImage: "magnifyingglass").toolbarIcon()
                }
                .help(L("논문·노트·지도·초안에서 찾기 (Command-K)", "Search papers, notes, maps and drafts (Command-K)"))
                .toolbarHover()
                Button(action: chooseDocumentsToAdd) {
                    Label(L("PDF 더하기", "Add PDFs"), systemImage: "plus").toolbarIcon()
                }
                .help(L("라이브러리에 PDF 더하기 (Command-O)", "Add PDFs to the library (Command-O)"))
                .toolbarHover()
                Divider().frame(height: 14).padding(.horizontal, 4)
                paneButton(.reader, symbol: "text.page", on: app.showsReader && !app.isFocusMode) { app.toggleReader() }
                paneButton(.inspector, symbol: app.inspectorFloats ? "macwindow.on.rectangle" : "sidebar.right", on: app.showsInspector) { app.toggleInspector() }
                    // Its other way, a right-click away: docked or floating.
                    .contextMenu {
                        Button(L("옆에 붙여 보기", "Show Docked"), systemImage: "sidebar.right") { app.showInspector(floating: false) }
                        Button(L("띄워 보기", "Show Floating"), systemImage: "macwindow.on.rectangle") { app.showInspector(floating: true) }
                    }
                Divider().frame(height: 14).padding(.horizontal, 4)
                Menu {
                    Button(action: syncNow) { Label(L("지금 맞추기", "Sync Now"), systemImage: "arrow.clockwise") }
                        .disabled(model.isScanning)
                    Divider()
                    Picker(L("정렬 기준", "Sort By"), selection: sortOrderBinding) {
                        ForEach(LibraryModel.SortOrder.allCases) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                    Toggle(L("오름차순", "Ascending"), isOn: sortAscendingBinding)
                    Divider()
                    Picker(L("쪽 배치", "Page Layout"), selection: $configuration.layout) {
                        ForEach(ReaderConfiguration.PageLayout.allCases) { layout in
                            Label(layout.label, systemImage: layout.symbolName).tag(layout)
                        }
                    }
                    Picker(L("쪽 색조", "Page Tint"), selection: $configuration.tint) {
                        ForEach(ReaderConfiguration.PageTint.allCases) { tint in
                            Text(tint.label).tag(tint)
                        }
                    }
                    // Asked once when a paper arrives, and changed here on
                    // the day the wrong button was pressed.
                    if let paper = model.selectedPaper {
                        Divider()
                        Picker(L("종류", "Kind"), selection: kindBinding(for: paper)) {
                            ForEach(ShelfKind.allCases, id: \.self) { kind in
                                Label(kind.answer, systemImage: kind.symbolName).tag(kind)
                            }
                        }
                        // Only when another program has written the file
                        // out again: the text under the marks may then not
                        // be the author's, and the file that was imported is
                        // the way back.
                        if model.provenance(of: paper) == .rewritten {
                            Button {
                                model.chooseOriginal(for: paper.id)
                            } label: {
                                Label(L("원본 글자 되살리기…", "Restore Original Text…"), systemImage: "arrow.uturn.backward.circle")
                            }
                        }
                    }
                    Divider()
                    shareMenu
                } label: {
                    Label(L("더 보기", "More"), systemImage: "ellipsis").toolbarIcon()
                }
                .help(L("맞추기·정렬·쪽 배치·공유", "Sync, sort, page layout, share"))
                .toolbarHover()
            }
            .toolbarButtons()
        }
    }
    #endif

    @ToolbarContentBuilder
    private var toolbarContent: some CustomizableToolbarContent {
        // One group rather than one item each: separate toolbar items are what
        // drew the little vertical rules between the buttons.
        #if os(macOS)
        // Two quiet groups, the way Aside and Claude Code lay a bar out: at
        // the leading edge the sidebar and the way back and forward, and at
        // the trailing edge the three panes, the search, the plus, and one
        // menu for everything done rarely. Eleven icons in a row read as a
        // control panel; a paper is not a control panel.
        ToolbarItem(id: "leading", placement: .navigation) {
            HStack(spacing: 6) {
                paneButton(.sidebar, symbol: "sidebar.left", on: app.isSidebarVisible) { app.toggleSidebar() }
                paneButton(.paperList, symbol: "list.bullet.rectangle.portrait", on: app.showsPaperList) { app.togglePaperList() }
                Divider().frame(height: 14).padding(.horizontal, 4)
                // Back and forward through the papers opened, like a
                // browser's; grey when there is nowhere to go.
                Button { NotificationCenter.default.post(name: .paperTimeGoBack, object: nil) } label: {
                    Label(L("뒤로", "Back"), systemImage: "chevron.left").toolbarIcon()
                }
                .disabled(!(model.canGoBack || link.canGoBackInDocument))
                .help(L("왔던 논문으로 돌아가기 (\(app.shortcut(for: .back).display))", "Back to the paper you came from (\(app.shortcut(for: .back).display))"))
                .toolbarHover()
                Button { NotificationCenter.default.post(name: .paperTimeGoForward, object: nil) } label: {
                    Label(L("앞으로", "Forward"), systemImage: "chevron.right").toolbarIcon()
                }
                .disabled(!(model.canGoForward || link.canGoForwardInDocument))
                .help(L("다시 앞으로 (\(app.shortcut(for: .forward).display))", "Forward again (\(app.shortcut(for: .forward).display))"))
                .toolbarHover()
            }
            .toolbarButtons()
        }
        #else
        ToolbarItem(id: "actions", placement: barPlacement) {
            HStack(spacing: 4) {
                #if os(iOS)
                // The shelves, first: the leading edge belongs to the split
                // view's own toggle, which sat over anything put beside it.
                Button {
                    withAnimation(AppModel.paneMotion) { app.showsScopePanel.toggle() }
                } label: {
                    Label(L("라이브러리", "Library"), systemImage: "square.grid.2x2").toolbarIcon()
                }
                .help(L("라이브러리 목록: 분류·컬렉션·태그", "The library's shelves: scopes, collections, tags"))
                .keyboardShortcut("1", modifiers: [.command, .control])
                .toolbarHover()
                #endif
                Button {
                    isImportingPDFs = true
                } label: {
                    Label(L("PDF 더하기", "Add PDFs"), systemImage: "plus").toolbarIcon()
                }
                .help(L("라이브러리에 PDF 더하기 (Command-O)", "Add PDFs to the library (Command-O)"))
                .toolbarHover()

                // Not a plain magnifier: the reader's bar has one of those
                // for finding a word in the paper, and two magnifiers in one
                // window are a coin toss. This one looks through everything
                // and offers before it is asked, which is what the sparkle
                // is for.
                Button {
                    app.showsSearchPalette = true
                } label: {
                    Label(L("전부 찾기", "Search Everything"), systemImage: "rectangle.and.text.magnifyingglass").toolbarIcon()
                }
                .help(L("논문·노트·지도·초안에서 찾기 (Command-K)", "Search papers, notes, maps and drafts (Command-K)"))
                .toolbarHover()

                // Marks and ink travel in small files that iCloud brings when
                // it is ready — usually seconds. This asks for them now.
                Button(action: syncNow) {
                    Label(L("지금 맞추기", "Sync Now"), systemImage: "arrow.clockwise").toolbarIcon()
                }
                .help(L("다른 기기가 쓴 것을 가져오기 (Command-R)", "Fetch what the other devices have written (Command-R)"))
                // On the Mac the same key is on the Library menu, and two
                // owners of one key is one too many.
                #if os(iOS)
                .keyboardShortcut("r", modifiers: .command)
                #endif
                .disabled(model.isScanning)
                .toolbarHover()

                sortMenu
                // On the iPad the page's options sit on the page's own bar;
                // here they only crowded the column into an overflow menu.
                shareMenu
            }
            .toolbarButtons()
        }
        #endif
    }

    /// The four panes, behind one button.
    ///
    /// There used to be one button, for the inspector, at the far end of the
    /// toolbar — from when only the two sidebars could be hidden. Four in a
    /// row said the same thing four times and took the room of six controls.
    /// One menu, with a tick beside each pane that is showing, says it once.
    /// The four panes, one button each, where the one menu used to be:
    /// each shows and hides its own pane and stays put — a button that
    /// closes a pane and goes with it cannot open it again.
    private var paneMenu: some View {
        HStack(spacing: 2) {
            paneButton(.sidebar, symbol: "sidebar.left", on: app.isSidebarVisible) { app.toggleSidebar() }
            paneButton(.paperList, symbol: "list.bullet.rectangle", on: app.showsPaperList) { app.togglePaperList() }
            paneButton(.reader, symbol: "doc.text", on: app.showsReader && !app.isFocusMode) { app.toggleReader() }
            paneButton(.inspector, symbol: "sidebar.trailing", on: app.showsInspector) { app.toggleInspector() }
        }
    }

    /// ⌘N: on the paper chosen, a literature note; with none — or in 지식 —
    /// a note of one's own, in the area shown.
    private func openNewNote() {
        if case let .knowledge(area) = model.scope {
            model.notes.openNoteID = model.notes.create(paperID: nil, area: area ?? "").id
        } else if let paperID = model.selectedPaperID {
            model.scope = .notes
            model.notes.openNoteID = model.notes.create(paperID: paperID).id
        } else {
            model.scope = .knowledge(nil)
            model.notes.openNoteID = model.notes.create(paperID: nil).id
        }
    }

    #if os(macOS)
    /// A paper pressed in a project or followed out of a note.
    ///
    /// In the slip-box the paper stands where the list stands, beside the
    /// note or the project it came from — a list pane is lent for it when
    /// none is open. Elsewhere it is the page's.
    private func openInListPane(_ id: UUID) {
        if model.scope.isSlipBox {
            withAnimation(Motion.move) {
                if !app.showsPaperList, app.lendListPane() { listLent = true }
                if app.showsPaperList {
                    slipBoxPaperID = id
                } else {
                    model.selection = [id]
                    app.showOnPage(.paper, model: model)
                }
            }
        } else {
            model.selectedPaperID = id
            model.keepOpen(id)
            app.showOnPage(.paper, model: model)
            app.ensurePagePane(after: nil)
        }
    }
    #endif

    private func paneButton(_ pane: ShortcutAction, symbol: String, on: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Label(pane.title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .toolbarIcon()
        }
        // On: the accent. Off: the quiet grey of the other icons. No square
        // behind the ones that are on — three squares side by side ran into
        // one another and read as a single block.
        .tint(on ? Color.accentColor : Color.secondary)
        .help(L("\(pane.title) \(on ? "숨기기" : "보이기") (\(app.shortcut(for: pane).display))", "\(on ? "Hide" : "Show") the \(pane.title.lowercased()) (\(app.shortcut(for: pane).display))"))
        .toolbarHover()
    }

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            Picker(L("정렬 기준", "Sort By"), selection: sortOrderBinding) {
                ForEach(LibraryModel.SortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
            Divider()
            Toggle(L("오름차순", "Ascending"), isOn: sortAscendingBinding)
        } label: {
            Label(L("정렬", "Sort"), systemImage: "arrow.up.arrow.down").toolbarIcon()
        }
        .help(L("목록 정렬", "Sort the list"))
        .toolbarHover()
    }

    @ViewBuilder
    private var viewMenu: some View {
        Menu {
                Picker(L("쪽 배치", "Page Layout"), selection: $configuration.layout) {
                    ForEach(ReaderConfiguration.PageLayout.allCases) { layout in
                        Label(layout.label, systemImage: layout.symbolName).tag(layout)
                    }
                }
                Picker(L("쪽 색조", "Page Tint"), selection: $configuration.tint) {
                    ForEach(ReaderConfiguration.PageTint.allCases) { tint in
                        Text(tint.label).tag(tint)
                    }
                }
                .onChange(of: configuration.tint) { _, tint in
                    app.settings.readerTint = tint.rawValue
                }
            #if os(macOS)
                // A colour well cannot live in a menu; the system's colour
                // panel can, and the page follows it as it is dragged.
                if configuration.tint == .custom {
                    Button(L("바탕색 고르기…", "Choose Ground Color…")) {
                        GroundColorPanel.shared.show(hex: app.settings.readerTintColor)
                    }
                }
            #endif
            #if os(iOS)
            Toggle(L("손가락으로 그리기", "Draw with Finger"), isOn: $configuration.fingerDrawing)
            #endif
        } label: {
            Label(L("보기 방식", "View Options"), systemImage: "textformat.size").toolbarIcon()
        }
        .help(L("쪽 배치와 색조", "Page layout and tint"))
        .disabled(model.selectedPaper == nil)
        .toolbarHover()
    }

    @ViewBuilder
    private var shareMenu: some View {
        Menu {
                Button {
                    showsExport = true
                } label: {
                    Label(L("BibTeX 내보내기…", "Export BibTeX…"), systemImage: "square.and.arrow.up")
                }
                Button {
                    showsCitationStyles = true
                } label: {
                    Label(L("인용 스타일…", "Citation Styles…"), systemImage: "text.quote")
                }
                .disabled(model.selectedPaper == nil)
                Divider()
            Button {
                showsMigration = true
            } label: {
                Label(
                    L("기존 라이브러리 들여오기…", "Import Existing Library…"),
                    systemImage: "square.and.arrow.down.on.square"
                )
            }
        } label: {
            Label(L("공유", "Share"), systemImage: "square.and.arrow.up").toolbarIcon()
        }
        .help(L("내보내기와 들여오기", "Export and import"))
        .toolbarHover()
    }

    @ToolbarContentBuilder
    private var inspectorToolbarContent: some CustomizableToolbarContent {
        // The inspector's tabs belong up here rather than at the top of the
        // column: the column is laid out from the very top of the window, so a
        // picker pinned to it sits behind the toolbar instead of below it —
        // which read as the buttons having been taken away. A segmented picker
        // is also what a Mac uses for this, where the column had a bespoke one.
        ToolbarItem(id: "inspector-tab", placement: .primaryAction) {
            // Docked; floating, the picker is in the panel's own head.
            if app.showsInspector, !app.inspectorFloats, model.selectedPaper != nil {
                Picker(L("정보 패널", "Inspector"), selection: $inspectorTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(L("정보 패널에 보일 것", "What the inspector shows"))
            }
        }

    }

    // MARK: - Actions

    /// Asks for PDFs to add. On the Mac this is AppKit's own open panel: the
    /// SwiftUI importer, presented from the toolbar, opened once and never
    /// again, and a plus that does nothing is worse than no plus.
    private func chooseDocumentsToAdd() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("라이브러리에 더할 PDF를 골라주세요", "Choose PDFs to add to the library")
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            Task { await model.importDocuments(at: urls) }
        }
        #else
        isImportingPDFs = true
        #endif
    }

    private var sortOrderBinding: Binding<LibraryModel.SortOrder> {
        Binding(get: { model.sortOrder }, set: { model.sortOrder = $0 })
    }

    private var sortAscendingBinding: Binding<Bool> {
        Binding(get: { model.sortAscending }, set: { model.sortAscending = $0 })
    }


    private func perform(_ action: SearchResult.Action) {
        switch action {
        case .addPDFs: isImportingPDFs = true
        case .addByAddress: showsAddByAddress = true
        case .exportBibTeX: showsExport = true
        case .resolveMetadata: Task { await model.resolveAllPending() }
        case .refresh: syncNow()
        case .importLibrary: showsMigration = true
        case .settings:
            #if os(macOS)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            #endif
        }
    }

    /// Asks iCloud for what it has not brought and re-reads the folder, and
    /// tells the open paper to look at its own files again.
    private func syncNow() {
        Task {
            await model.pullFromCloud()
            await link.session?.reloadFromDisk()
        }
    }

    private func copySelectedCitationKey() {
        guard let key = model.selectedPaper?.meta.bibKey, !key.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        #else
        UIPasteboard.general.string = key
        #endif
    }

    private func kindBinding(for paper: LoadedPaper) -> Binding<ShelfKind> {
        Binding(
            get: { paper.meta.shelfKind },
            set: { kind in Task { await model.setKind(kind, for: paper.id) } }
        )
    }

    private var scopeTitle: String {
        switch model.scope {
        case .all: L("모두", "All")
        case .papers: L("논문", "Papers")
        case .books: L("책", "Books")
        case .documents: L("문서", "Documents")
        case let .folder(root): root.lastPathComponent
        case .open: L("열린 문서", "Open Documents")
        case .notes: L("문헌 노트", "Literature Notes")
        case let .knowledge(area): KnowledgeArea.title(area)
        case let .projects(id): id.flatMap { model.project($0)?.name } ?? L("프로젝트", "Projects")
        case .graph: L("그래프", "Graph")
        case .searchResults: L("찾은 것", "Search Results")
        case .unread: L("안 읽음", "Unread")
        case .reading: L("읽는 중", "Reading")
        case .read: L("읽음", "Read")
        case .favorites: L("즐겨찾기", "Favorites")
        case .needsReview: L("살펴볼 것", "Needs Review")
        case let .collection(id):
            model.collections.collections.first { $0.id == id }?.name ?? L("컬렉션", "Collection")
        case let .tag(id):
            model.manifest.tags.first { $0.id == id }?.name ?? L("태그", "Tag")
        case let .author(key):
            model.authorRanking.first { $0.key == key }?.name ?? L("저자", "Author")
        case let .plan(id): model.plan(id)?.name ?? L("계획", "Plan")
        case .thisWeek: L("이번 주", "This Week")
        }
    }
}

/// What the inspector is showing. "Notes" used to mean the list of marks,
/// which is not what a note is; the two are separate now and say so.
enum InspectorTab: String, CaseIterable, Identifiable {
    case details, marks, note, tool
    var id: String { rawValue }
    /// In English whatever the system speaks: these four are the column's
    /// headings, short and set apart, and the owner wanted them read as
    /// labels rather than sentences.
    var label: String {
        switch self {
        case .details: "Info"
        case .marks: "Marks"
        case .note: "Notes"
        case .tool: "Tools"
        }
    }
}

/// The reader and the inspector.
struct PaperDetailColumn: View {
    let model: LibraryModel
    let configuration: ReaderConfiguration
    let link: ReaderLink
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var inspectorTab: InspectorTab
    /// What the inspector was showing before the pen came out, so putting the
    /// pen away can give it back.
    @State private var tabBeforeDrawing: InspectorTab?
    /// The room the page and the inspector share.
    @State private var columnWidth: CGFloat = 800
    /// Where a paper being dragged over the page would land, while it is.
    /// Where a dragged paper would land on the page (`DockTarget`).
    @State private var dockTarget: DockTarget?
    @State private var pageSize: CGSize = .zero

    /// The handle the inspector reads: the window's own, which the pane in
    /// focus holds when papers are side by side.
    private var activeLink: ReaderLink { link }
    /// How wide the inspector was when a drag on its grip began.
    @State private var gripStart: CGFloat?

    var body: some View {
        columns
        // The paper's contents, floating over the page. Centred on the
        // column, which in a book spread puts it in the gutter between the
        // two pages where there are no words to cover.
        .overlay { contents }

        .animation(Motion.move, value: app.showsFloatingList)
        // A passage of another paper, followed from a note here: that paper
        // opens, and its reader takes the request from there.
        .onChange(of: link.anchorRequest) { _, request in
            guard let request, let paperID = request.paperID, model.selectedPaperID != paperID,
                  model.paper(paperID) != nil else { return }
            model.selection = [paperID]
        }
        // Clicking a mark on the page opens the list it lives in.
        .onChange(of: link.revealedMarkID) { _, id in
            guard id != nil else { return }
            app.showsInspector = true
            inspectorTab = .marks
        }
        // Taking the pencil out brings the tool inspector forward, the way
        // Figma's panel is about whatever is being drawn — and putting it away
        // gives the panel back. It used to only go one way, so a lecture spent
        // in the Notes tab ended on Tools the first time a pen was picked up,
        // and stayed there.
        .onChange(of: configuration.mode) { _, mode in
            if mode == .draw {
                if inspectorTab != .tool { tabBeforeDrawing = inspectorTab }
                app.showsInspector = true
                inspectorTab = .tool
            } else {
                // Only if Tools is still what is showing. Somebody who chose
                // another tab with the pen in hand meant it.
                if inspectorTab == .tool, let back = tabBeforeDrawing { inspectorTab = back }
                tabBeforeDrawing = nil
            }
        }
        // Command-L: the passage goes to the note, and the note comes forward.
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeLinkToNote)) { _ in
            // The lasso's catch first — read off the picture when it has to
            // be, which takes a moment.
            if link.lasso != nil {
                Task { @MainActor in
                    guard let anchor = await link.lassoAnchor() else {
                        link.toastRequest = L("사각형 안에서 읽을 글이 없어요.", "Nothing to read inside the rectangle.")
                        return
                    }
                    app.showsInspector = true
                    inspectorTab = .note
                    link.pendingNoteAnchor = anchor
                }
                return
            }
            guard let anchor = link.selectionAnchor() else { return }
            app.showsInspector = true
            inspectorTab = .note
            link.pendingNoteAnchor = anchor
        }
    }

    /// The paper's table of contents, over the page.
    ///
    /// On the Mac it floats in the middle of the column, which in a spread is
    /// the gutter between the two pages, and a click anywhere else puts it
    /// away. A touch screen gets the same list along the foot of the paper,
    /// where a thumb is, and the whole page above it is the way out — there
    /// is no Escape key to fall back on, so the way out has to be the obvious
    /// one: touch the paper.
    @ViewBuilder
    private var contents: some View {
        if app.showsFloatingList, model.selectedPaper != nil {
            if contentsPlacement == .gutter {
                ContentsPopup(link: link) { app.toggleFloatingList() }
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else {
                ZStack(alignment: .bottom) {
                    #if !os(macOS)
                    // Not a dimming: the paper stays readable while the list
                    // is up, because the point of the list is to find your
                    // way about the paper. It is here to catch the touch that
                    // dismisses. The Mac has no such layer — a click there
                    // goes to the page and puts the list away on its way.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { app.toggleFloatingList() }
                    #endif
                    ContentsPopup(link: link, placement: .footer) { app.toggleFloatingList() }
                        .padding(.horizontal, 12)
                        // Clear of the bar that counts the pages: the list
                        // floats over the paper, not over the reader's own
                        // furniture.
                        .padding(.bottom, ReaderScreen.statusBarClearance + 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // Told to fill the reader and sit at the bottom of it. On iOS
                // the layer that catches the dismissing touch fills the stack
                // and the alignment has something to work against; the Mac has
                // no such layer, so the stack shrank to the panel and the
                // overlay put that in the middle of the page — which is how a
                // footer ended up floating over the words it was avoiding.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    /// Asks iCloud for what it has not brought yet, and tells the open paper
    /// to look at its own files again.
    private func syncNow() {
        Task {
            await model.pullFromCloud()
            await link.session?.reloadFromDisk()
        }
    }

    /// Where the contents goes.
    ///
    /// Only a spread has a gutter to stand in. A scrolling page and a single
    /// page fill the column, so a column of headings down the middle of them
    /// covers the words it is meant to help you find — there it lies along the
    /// foot instead, where it covers the least and the headings get the width.
    private var contentsPlacement: ContentsPopup.Placement {
        #if os(macOS)
        configuration.layout == .book ? .gutter : .footer
        #else
        // A touch screen keeps it along the foot even in a book: the spread
        // fills the screen edge to edge there, and the gutter it leaves is a
        // seam rather than a margin.
        .footer
        #endif
    }

    /// The page and the inspector, side by side.
    ///
    /// Hand-rolled on the Mac rather than left to `.inspector`, which brought
    /// its own column background — square-cornered, and drawn where nothing
    /// outside it could round it off. Owning the column is what the sidebar
    /// and the list already do, and it makes the inspector a panel like them.
    private var columns: some View {
        @Bindable var app = app

        #if os(macOS)
        // The board stands where the page was; the page stays in the tree
        // underneath, unseen, so going back to it is instant. The inspector
        // is the window's now, docked or floating (`Workspace.swift`), and
        // the panel is the pane's.
        return ZStack {
            page
                .opacity(model.showsBoard ? 0 : 1)
                .allowsHitTesting(!model.showsBoard)
            if model.showsBoard {
                PlanBoard(model: model)
                    .transition(.opacity)
            }
        }
        // The page takes what is left and no more: a reader that would like
        // more is cut at its own edge.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        #else
        // The inspector floats in from the right, over the page, and goes
        // the same way: the screen is too narrow to give it a column, and a
        // sheet took the page away while the notes were being read.
        return page.overlay(alignment: .trailing) {
            if app.showsInspector {
                HStack(spacing: 0) {
                    // A grip, on an iPad. Writing a note beside a paper is
                    // the reason the panel is there, and 360 points is a
                    // column two words wide — which is fine for a list of
                    // marks and no way to write in.
                    if horizontalSizeClass == .regular { grip }
                    InspectorView(model: model, configuration: configuration, link: link, inspectorTab: $inspectorTab)
                }
                    .frame(width: horizontalSizeClass == .regular ? app.inspectorWidth : 360)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Corner.panel - 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Corner.panel - 4, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                    .padding(10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(AppModel.paneMotion, value: app.showsInspector)
        .onGeometryChange(for: CGFloat.self) { ($0.size.width / 24).rounded() * 24 } action: {
            columnWidth = $0
        }
        #endif
    }

    #if !os(macOS)
    /// The handle down the inspector's leading edge, and the drag that
    /// widens it. Touch has no pointer to change shape over a gap, so the
    /// thing to pull has to be something you can see.
    private var grip: some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 4, height: 44)
            .padding(.horizontal, 7)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        // From where the drag began, not from where the
                        // panel is now: a translation applied to the width it
                        // has already been given compounds, and the panel
                        // runs away across the screen.
                        let start = gripStart ?? app.inspectorWidth
                        gripStart = start
                        let widest = max(320, columnWidth - Pane.pageFloor)
                        app.inspectorWidth =
                            min(max(start - value.translation.width, 320), widest)
                    }
                    .onEnded { _ in gripStart = nil }
            )
    }
    #endif

    private var page: some View {
        pageBody
            // The space the side-by-side panes report their frames in, and the
            // drop reads its location in.
            .coordinateSpace(.named(DockDropDelegate.space))
            // A paper dragged here from the list, or from another pane's title,
            // is put where it was dropped: a half of the page area, or a
            // quarter of it — the way a window tiles when dragged to an edge.
            .overlay { DockZoneOverlay(target: dockTarget, frames: app.splitPaneFrames) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { pageSize = $0 }
            // The open papers, the way the contents come: a key brings the
            // list up over the page, a choice or Escape puts it away.
            .overlay {
                if app.showsOpenPapers {
                    OpenPapersPopup(model: model) { app.toggleOpenPapers() }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            // ⌘W closes the pane in focus while there are several; the last
            // one left hands the key back to the window.
            .background(ClosePaneShortcut {
                guard let split = app.split, split.panes.count > 1,
                      let pane = app.focusedPane(in: split, model: model) else { return false }
                app.closePane(pane, model: model)
                return true
            }.frame(width: 0, height: 0))
            .onDrop(of: [.paperTimePaper], delegate: DockDropDelegate(
                size: { pageSize },
                arrangement: { app.split },
                frames: { app.splitPaneFrames },
                target: $dockTarget,
                drop: { transfer, zone in app.dock(transfer.id, at: zone, in: model, movingPane: transfer.pane) },
                open: { transfer, pane in app.open(transfer.id, inPane: pane, moving: transfer.pane, model: model) }
            ))
            // The zone stays lit only while a drag is really going on. A
            // drag let go outside the window, or cancelled with Escape, never
            // sends `dropExited`, and the half of the page stayed blue.
            .onChange(of: dockTarget != nil) { _, lit in
                guard lit else { return }
                Task { @MainActor in
                    while dockTarget != nil {
                        try? await Task.sleep(for: .milliseconds(250))
                        if NSEvent.pressedMouseButtons == 0 { dockTarget = nil }
                    }
                }
            }
            .onChange(of: app.split) { _, _ in dockTarget = nil }
            // Clicking into the paper is using it: it stays on the open shelf.
            .onAppear { armKeepOpen() }
            .onChange(of: app.split) { _, split in if split == nil { armKeepOpen() } }
    }

    private func armKeepOpen() {
        link.activated = { if let id = model.selectedPaperID { model.keepOpen(id) } }
    }

    private var pageBody: some View {
        Group {
            if let split = app.split {
                VStack(spacing: 0) {
                    #if os(macOS)
                    // The pane's own head over the papers side by side, each
                    // of which keeps its strip.
                    PaneHeadBar(symbol: "rectangle.split.2x1",
                                title: L("논문 \(split.panes.count)편 나란히", "\(split.panes.count) Papers Side by Side"))
                    #endif
                    SplitReaderView(model: model, configuration: configuration, link: link, arrangement: split)
                }
            } else if let paper = model.selectedPaper {
                // Deliberately not `.id(paper.id)`: giving each paper its own
                // identity threw away the PDF view and built another one for
                // every selection, and creating a `PDFView` is most of what
                // opening a paper used to cost. The reader reloads itself when
                // the paper changes instead.
                VStack(spacing: 0) {
                    // The paper's name, where the list has "All Papers" and
                    // the slip-box has "Notes". The page keeps its place; the
                    // strip is what the panel gained by reaching higher. On
                    // iOS the navigation bar already says it.
                    #if os(macOS)
                    HStack {
                        Text(paper.meta.displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // The title is the pane's handle.
                            .paneDragHandle()
                        Spacer(minLength: 0)
                        // The pencil, at the end of the paper's own strip:
                        // the paper is drawn on, and the tool that does it
                        // should be on the paper's row, not two menus deep.
                        Button {
                            configuration.mode = configuration.mode == .draw ? .read : .draw
                        } label: {
                            Label(L("그리기", "Draw"), systemImage: configuration.mode == .draw ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                                .labelStyle(.iconOnly)
                                .toolbarIcon()
                        }
                        .buttonStyle(.borderless)
                        .tint(configuration.mode == .draw ? Color.accentColor : .primary)
                        .toolbarHover()
                        .help(L("쪽에 그리기 (\(app.shortcut(for: .draw).display))", "Draw on the page (\(app.shortcut(for: .draw).display))"))
                        // The lasso beside the pencil: lit while it is out,
                        // so the mode shows somewhere the eye already goes.
                        Button {
                            configuration.mode = configuration.mode == .lasso ? .read : .lasso
                        } label: {
                            Label(L("수식 올가미", "Formula Lasso"), systemImage: "lasso")
                                .labelStyle(.iconOnly)
                                .toolbarIcon()
                        }
                        .buttonStyle(.borderless)
                        .tint(configuration.mode == .lasso ? Color.accentColor : .primary)
                        .toolbarHover()
                        .help(L("수식 올가미 (\(app.shortcut(for: .lasso).display))", "Formula lasso (\(app.shortcut(for: .lasso).display))"))
                        // The pane's ⌄ and ×, at the end of the paper's strip.
                        PaneHeadControls()
                            .padding(.leading, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    #endif

                    ReaderScreen(
                        library: model,
                        paper: paper,
                        configuration: configuration,
                        link: link
                    )
                }
                // The menu's "Draw on the Page", and its key.
                .onReceive(NotificationCenter.default.publisher(for: .paperTimeToggleDraw)) { _ in
                    configuration.mode = configuration.mode == .draw ? .read : .draw
                }
                // The formula lasso, and its key.
                .onReceive(NotificationCenter.default.publisher(for: .paperTimeToggleLasso)) { _ in
                    configuration.mode = configuration.mode == .lasso ? .read : .lasso
                }
                #if os(iOS)
                // The tools, in a strip under the title while the pencil is
                // out — where a notebook keeps them. The same strip on the
                // iPad and the phone; only its width differs.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if configuration.mode == .draw {
                        MarkingToolbar(configuration: configuration)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(Motion.move, value: configuration.mode)
                .toolbar {
                    // The pencil, first in the reader's own bar: the paper is
                    // written on, and the tool that does it should not be two
                    // menus deep. On the phone a finger holds it.
                    // Flat, like the Mac's: the glass pills the system draws
                    // behind toolbar groups made the two bars read as two apps.
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        // The table of contents, one button, wherever the
                        // reader is — not a line inside the AA menu.
                        Button {
                            app.toggleFloatingList()
                        } label: {
                            Label(L("차례", "Table of Contents"), systemImage: "list.bullet.indent")
                        }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                        .help(L("차례", "Table of contents"))
                        // Its key is the menu command's, so it is not pressed
                        // twice for one press.
                        Button {
                            configuration.mode = configuration.mode == .draw ? .read : .draw
                        } label: {
                            Label(L("그리기", "Draw"), systemImage: configuration.mode == .draw ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                        }
                        .help(L("연필로 쪽에 쓰기", "Write on the page with the pencil"))
                    }
                    .sharedBackgroundVisibility(.hidden)
                    // On a phone the reader is a screen of its own, so the
                    // page's options and the search come along with it.
                    // On a phone the reader is a screen of its own; on the iPad
                    // with the list stepped aside (a book, or focus) it is the
                    // only bar there is. Either way the page's options, the
                    // search and the way back come along with it.
                    ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Picker(L("쪽 배치", "Page Layout"), selection: Bindable(configuration).layout) {
                                    ForEach(ReaderConfiguration.PageLayout.allCases) { layout in
                                        Label(layout.label, systemImage: layout.symbolName).tag(layout)
                                    }
                                }
                                Picker(L("쪽 색조", "Page Tint"), selection: Bindable(configuration).tint) {
                                    ForEach(ReaderConfiguration.PageTint.allCases) { tint in
                                        Text(tint.label).tag(tint)
                                    }
                                }
                                Button {
                                    app.toggleFloatingList()
                                } label: {
                                    Label(L("차례", "Table of Contents"), systemImage: "list.bullet.indent")
                                }
                                Divider()
                                // The whole library, from inside a paper —
                                // the other kind of looking, and the rarer
                                // one, so it is a line in the menu and the
                                // bar keeps the one about this paper.
                                Button {
                                    app.showsSearchPalette = true
                                } label: {
                                    Label(L("전부 찾기", "Search Everything"), systemImage: "rectangle.and.text.magnifyingglass")
                                }
                                // Also here: with the list stepped aside for
                                // a book, the bar it lives on is gone.
                                Button(action: syncNow) {
                                    Label(L("지금 맞추기", "Sync Now"), systemImage: "arrow.clockwise")
                                }
                                .disabled(model.isScanning)
                            } label: {
                                Label(L("보기 방식", "View Options"), systemImage: "textformat.size")
                            }
                        }
                        .sharedBackgroundVisibility(.hidden)
                    // Finding a word in the paper being read. The magnifier
                    // in the reader's own bar means this paper; the one in
                    // the list's bar means the library. Both were the
                    // library, and there was no way to search a paper at all.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            link.isFinding = true
                        } label: {
                            Label(L("이 논문에서 찾기", "Find in Paper"), systemImage: "magnifyingglass")
                        }
                        .keyboardShortcut("f", modifiers: .command)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    // The marks and the notes, floating in from the right.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            app.toggleInspector()
                        } label: {
                            Label(L("표시와 노트", "Marks and Notes"), systemImage: app.showsInspector ? "sidebar.trailing" : "sidebar.trailing")
                                .symbolVariant(app.showsInspector ? .fill : .none)
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                #endif
            } else {
                VStack(spacing: 0) {
                    #if os(macOS)
                    PaneHeadBar(symbol: "text.page", title: ShortcutAction.reader.title)
                    #endif
                    ContentUnavailableView(
                        L("고른 논문이 없어요", "No Paper Selected"),
                        systemImage: "doc.text",
                        description: Text(L("읽을 논문을 하나 골라보세요.", "Choose a paper to start reading."))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

}

/// What the inspector shows: the paper in focus, in one of four tabs —
/// docked at the window's right, floating over it, or (iOS) over the page.
struct InspectorView: View {
    let model: LibraryModel
    let configuration: ReaderConfiguration
    let link: ReaderLink
    @Binding var inspectorTab: InspectorTab

    var body: some View {
        // Everything is pinned to the top and told to fill the column. Without
        // it SwiftUI centres the whole stack, which left the contents floating
        // halfway down an empty inspector.
        VStack(spacing: 0) {
            if model.selectedPaper != nil {
                #if !os(macOS)
                CapsulePicker(
                    options: InspectorTab.allCases.map { ($0, $0.label) },
                    selection: $inspectorTab
                )
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 8)

                Divider()
                #endif

                switch inspectorTab {
                case .details:
                    PaperInspector(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                case .marks:
                    if let session = link.session {
                        MarkupListView(session: session, link: link)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        ContentUnavailableView(L("논문을 여는 중", "Opening the Paper"), systemImage: "hourglass")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .note:
                    if let paper = model.selectedPaper {
                        PaperNotesView(model: model, paperID: paper.id, link: link)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                case .tool:
                    #if os(macOS)
                    // One place for the tools of whatever is being worked
                    // on: a note's format while a note has the keyboard,
                    // and what is drawn on the page, as numbers — Figma's
                    // design panel — otherwise.
                    if NoteFormatCenter.shared.isFront {
                        NoteFormatPanel()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        SketchInspector(configuration: configuration, docked: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    #else
                    ContentUnavailableView(L("맥에서 그릴 때 써요", "For drawing on the Mac"), systemImage: "pencil.tip")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #endif
                }
            } else {
                #if os(macOS)
                // No paper, and a note being written: its format.
                if NoteFormatCenter.shared.isFront {
                    NoteFormatPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ContentUnavailableView(L("고른 것이 없어요", "Nothing Selected"), systemImage: "sidebar.right")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                #else
                ContentUnavailableView(L("고른 것이 없어요", "Nothing Selected"), systemImage: "sidebar.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.isInsideInspector, true)
        #if os(macOS)
        // The pen picked up after the note took the keyboard: the Tools
        // are the drawing's until the note is written in again.
        .onChange(of: configuration.mode) { _, mode in
            if mode == .draw { NoteFormatCenter.shared.yielded() }
        }
        #endif
    }

}

/// Shown when the chosen folder is missing — usually a cloud drive that has not
/// mounted yet, which is a wait-and-retry situation rather than an error.
struct LibraryUnavailableView: View {
    @Environment(AppModel.self) private var app
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(L("라이브러리 폴더를 열 수 없어요", "Library Folder Unavailable"), systemImage: "externaldrive.badge.questionmark")
        } description: {
            Text(message)
        } actions: {
            Button(L("다시 시도", "Try Again")) {
                Task { await app.restore() }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)

            Button(L("다른 폴더 고르기…", "Choose a Different Folder…")) {
                app.chooseLibraryFolder()
            }
        }
    }
}


extension View {
    /// The toolbar's own button look: no bezel, no separators, icon only.
    ///
    /// `.accessoryBar` is the Mac's flat toolbar style; iOS toolbars are
    /// already flat and do not have it.
    @ViewBuilder
    func toolbarButtons() -> some View {
        #if os(macOS)
        // Borderless and unadorned. A chevron on three of the five made the
        // row ragged, and the glass capsules made five separate pills out of
        // what is one group of actions.
        buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
        #else
        labelStyle(.iconOnly)
        #endif
    }

    /// One size for every icon in the toolbar, so the row is a row — and a
    /// faint square under the pointer, the way the segmented picker at the
    /// other end of the toolbar already answers a hover. Borderless buttons
    /// answered with nothing, and a row of icons that does not react does
    /// not look like a row of buttons.
    func toolbarIcon() -> some View {
        font(.system(size: 13.5, weight: .regular))
            .frame(width: 22, height: 22)
            .contentShape(.rect)
    }

    /// The hover square, on the control itself. On a `Menu` the label never
    /// hears the pointer — the menu button takes it — so the modifier goes
    /// on the menu, and on a `Button` for the same reason.
    func toolbarHover() -> some View {
        modifier(ToolbarHover())
    }
}

private struct ToolbarHover: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Corner.control - 2, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.09 : 0))
                    .padding(-3)
            )
            .animation(Motion.tap, value: isHovering)
            .onHover { isHovering = $0 }
    }
}


/// What the page keeps for itself, whatever else is open.
///
/// The one number left in the column widths. Everything else — how wide the
/// shelves, the list, the inspector may be dragged — is worked out from the
/// window, because a limit written down here is a guess about somebody
/// else's screen: reading beside a note means giving the note half of it,
/// and half of a large screen is not the 520 points this used to allow.
/// Outside the Mac-only `Column` because the iPad's inspector is dragged
/// against the same floor.
enum Pane {
    static let pageFloor: CGFloat = 300
    /// The width a page keeps while something beside it can give way: a
    /// column of a two-column paper at a size you can read. The table yields
    /// before the page goes under it (2026-11-16: with the inspector open,
    /// the table took the room and left the paper 270 points).
    static let readingFloor: CGFloat = 520
    /// How far the table yields for it — a title with room to be read. Its
    /// authors, year and venue fold under the title long before this.
    static let tableLeast: CGFloat = 300
    /// The window's own floor. The columns are held at widths, and widths
    /// that add up past the window made SwiftUI widen the window past the
    /// screen — and a zoom then fought it until AppKit gave up its layout
    /// pass and the app quit (2026-11-16, «update constraints count»). The
    /// columns now never ask for more than the window has; this is what the
    /// window may shrink to.
    static let windowFloor = CGSize(width: 720, height: 420)
}

#if os(macOS)
/// How the window's columns sit in it.
///
/// The window has rounded corners, and every surface inside it is a rung on
/// the `Corner` ladder — so the columns are rounded panels too, laid on one
/// ground with a gap between them. What was there before was flat backgrounds
/// butted against each other: the boundaries came out as straight lines ruled
/// across a rounded window, which is the one shape the rest of the app never
/// uses.
enum Column {
    /// How far the panels stay clear of the window's edges, and of each other.
    static let margin: CGFloat = 8
    /// The gap between two panels. Also the strip that resizes them: wide
    /// enough for a pointer, which a hairline never was.
    static let gap: CGFloat = 10

    /// How much of the toolbar's height the panels are allowed to reclaim.
    ///
    /// The band AppKit reports is the toolbar plus the room it leaves under
    /// its own controls, and that room is more than a gap: measured against
    /// it, the panels sat a good inch below the buttons. This is empirical —
    /// there is no API for where the controls stop, only for where the band
    /// does.
    static let underToolbar: CGFloat = 52

    /// What shows between and around the panels, and up through the toolbar,
    /// which has no colour of its own.
    ///
    /// Translucent, and that is the whole trick: glass is only glass when
    /// something varied shows through it, and inside a window the only thing
    /// behind is the desktop. A flat colour here made the panels read as white
    /// cards — the material lets the wallpaper up through the window, through
    /// the ground, and through the panels on top of it.
    ///
    /// The white over it is there because a dark wallpaper otherwise drags the
    /// whole window down with it, and this is an app for reading in.
    /// In the dark the white would have to go the other way: a pale ground
    /// under panes that are darker than it reads as fog, not as depth.
    static var ground: some View { Ground() }

    private struct Ground: View {
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(scheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.28))
                .ignoresSafeArea()
        }
    }

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Corner.panel, style: .continuous)
    }
}

extension View {
    /// Draws the view as one of the window's floating panels.
    /// A screen that is not the reader.
    ///
    /// The library window is deliberately translucent — its panels float on a
    /// blurred desktop and there is no background of the app's own between
    /// them. Every other screen has no panels at all, so on the same window it
    /// was a page of text on nothing: the first-run screen could not be seen.
    /// These get the background a normal Mac window has.
    func plainScreen() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.windowBackground)
    }

    func columnPanel() -> some View {
        clipShape(Column.shape)
            .liquidGlass(.pane, in: Column.shape)
    }
}

/// The gap between two columns, which can be dragged to resize the one to its
/// left. The split view used to provide this; owning it is the price of columns
/// that can actually be hidden and brought back.
private struct ColumnDivider: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    /// Which side of the gap the column being resized is on.
    ///
    /// The sidebar and the list are to the *left* of their divider, so
    /// dragging right makes them wider. The inspector is to the right of its
    /// own, so the same drag has to make it narrower — without this it grew
    /// when the pointer went the other way, which is the one thing a divider
    /// must never do.
    var resizes: HorizontalEdge = .leading
    @State private var startWidth: Double?

    var body: some View {
        // No line. The panels either side of it have rounded edges and the
        // ground shows through between them, which separates them better than
        // a hairline ruled across a window with rounded corners ever did. What
        // is left is the strip a pointer can actually hit — a bare `Divider`
        // is one point across, which is not something anyone can be asked to
        // grab.
        Color.clear
            .frame(width: Column.gap)
            .contentShape(.rect)
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        let travel = resizes == .leading
                            ? value.translation.width
                            : -value.translation.width
                        width = min(
                            max(start + travel, range.lowerBound),
                            range.upperBound
                        )
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}
#endif

