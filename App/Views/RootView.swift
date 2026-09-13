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

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                ProgressView("Opening your library")
                    .controlSize(.large)
            case .needsLibraryFolder:
                LibrarySetupView()
            case .ready:
                if let library = app.library {
                    LibraryWindow(model: library)
                } else {
                    LibrarySetupView()
                }
            case let .failed(message):
                LibraryUnavailableView(message: message)
            }
        }
        // Every scroll view in the window, in one place: the indicator is an
        // environment value, so the whole tree inherits it.
        .scrollIndicators(.hidden)
        #if os(macOS)
        // Published from above the window's own content, so `LibraryWindow`
        // can read it: an `@Environment` property on a view resolves in that
        // view's own environment, not in the one it hands to its children.
        .measuringWindowToolbarBand()
        .translucentWindow()
        #endif
        .task {
            guard app.phase == .launching else { return }
            await app.restore()
            // After the library is up, not before: an introduction over an
            // empty window is an introduction to nothing.
            app.showReleaseNotesIfNew()
        }
        .sheet(isPresented: Bindable(app).showsReleaseNotes) {
            WhatsNewView()
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
    @State private var inspectorTab = InspectorTab.details
    /// How wide the paper was while it was open, so it can be held at that
    /// width on the way out rather than squeezed to nothing.
    @State private var readerWidth: CGFloat = 600
    /// The paper a passage link opened, shown where the notes list was.
    @State private var slipBoxPaperID: UUID?
    @State private var isImportingPDFs = false
    @State private var showsExport = false
    @State private var showsMigration = false
    @State private var showsCitationStyles = false
    #if os(iOS)
    /// Settings on iOS: there is no Settings window, so a sheet from a gear.
    @State private var showsSettings = false
    #endif

    var body: some View {
        decorated
    }

    /// The Mac hangs the toolbar off the split view itself, which is what makes
    /// it one centred row with no dividers between column groups. iOS has no
    /// such toolbar on a split view, so there it belongs to the list column's
    /// navigation bar.
    @ViewBuilder
    private var decorated: some View {
        #if os(macOS)
        windowBody
            // One toolbar with a flexible spacer in it, rather than two.
            // Without the title holding them apart the two groups packed
            // against the leading edge together; the spacer is what macOS 26
            // gives you to say "these belong at the other end".
            .toolbar(id: "library") {
                toolbarContent.sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
                inspectorToolbarContent.sharedBackgroundVisibility(.hidden)
            }
            // Hidden, so the toolbar has no colour of its own: the window's
            // ground runs straight up through it and there is no edge left
            // where the two used to meet. The controls carry their own glass.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
        return AnyView(macColumns)
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
                    .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
            } detail: {
                // The same three details the Mac has: the note, the graph,
                // the paper.
                switch model.scope {
                case .notes:
                    SlipBoxDetail(model: model, link: link) { paperID in
                        withAnimation(.snappy(duration: 0.25)) { slipBoxPaperID = paperID }
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
                                Button("Done") { showsSettings = false }
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
                        .navigationTitle("Library")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    app.showsScopePanel = false
                                    showsSettings = true
                                } label: {
                                    Label("Settings", systemImage: "gearshape")
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { app.showsScopePanel = false }
                            }
                        }
                }
                .presentationSizing(.form)
                .presentationBackground(.regularMaterial)
            }
    }
    #endif

    #if os(macOS)
    private var macColumns: some View {
        @Bindable var app = app

        return HStack(spacing: 0) {
            // Two frames, and the inner one never moves. A column closing by
            // width drags its content's width with it, and the content here is
            // a `List` — an `NSTableView` that re-lays out every row on every
            // frame of the animation. Held at its own width inside a frame
            // that animates, the list is revealed rather than resized, and
            // lays out once.
            // On the ground, not on a panel — the way the Settings window's
            // sidebar sits beside its page. The list of places is chrome;
            // the panels are for the things you read. Kept rounded so the
            // reveal still comes in as a shape, and clipped for the same
            // reason as before.
            sidebarColumn
                .frame(width: app.sidebarWidth)
                .frame(width: app.isSidebarVisible ? app.sidebarWidth : 0, alignment: .leading)
                .clipShape(Column.shape)
                .opacity(app.isSidebarVisible ? 1 : 0)
                .clipped()

            if app.isSidebarVisible {
                ColumnDivider(width: $app.sidebarWidth, range: 200...360)
            }

            // With the paper closed the list is the only thing left to look
            // at, so it takes the room rather than leaving the window half
            // empty. Its own width comes back when the paper does.
            let listFills = app.showsPaperList && !app.showsReader
            let listWidth: CGFloat? = if !app.showsPaperList {
                0
            } else if listFills {
                nil
            } else {
                app.paperListWidth
            }
            // The same, except when the list is the only thing left, where it
            // is meant to take the room and so has to be laid out for it.
            listColumn
                .frame(width: listFills ? nil : app.paperListWidth)
                .frame(width: listWidth, alignment: .leading)
                .frame(maxWidth: listFills ? .infinity : nil)
                .columnPanel()
                .opacity(app.showsPaperList ? 1 : 0)
                .clipped()

            // Nothing to drag against when there is no paper beside it.
            if app.showsPaperList, app.showsReader {
                ColumnDivider(width: $app.paperListWidth, range: 240...560)
            }

            Group {
                switch model.scope {
                case .notes:
                    SlipBoxDetail(model: model, link: link) { paperID in
                        withAnimation(.snappy(duration: 0.25)) { slipBoxPaperID = paperID }
                    }
                    .columnPanel()
                case .graph:
                    PaperGraphView(model: model, graph: model.graph).columnPanel()
                default:
                    // Panels its own two halves: the page and the inspector are
                    // each a panel, with the ground between them.
                    PaperDetailColumn(
                        model: model, configuration: configuration,
                        link: link, inspectorTab: $inspectorTab
                    )
                }
            }
            // Held at the width it had, and revealed, for the same reason
            // the lists are. Collapsing the column to nothing handed the page
            // a width of zero, and a `PDFView` with no width draws nothing —
            // so for a frame the panel was there with nothing in it, which is
            // a pane of glass the colour of paper. That was the white flash.
            .frame(width: app.showsReader ? nil : readerWidth, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                // Only while it is open: reading it back while it is being
                // held would be reading our own answer.
                if app.showsReader, width > 0 { readerWidth = width }
            }
            // Closed by width rather than by taking it out of the tree: the
            // reader is expensive to build, and tearing the PDF view down and
            // back up is what made the other column toggles crawl.
            .frame(maxWidth: app.showsReader ? .infinity : 0, alignment: .leading)
            .opacity(app.showsReader ? 1 : 0)
            .clipped()
        }
        // The panels float clear of the window's edges and of the toolbar, so
        // every boundary in the window is a curve and a gap rather than a
        // straight line drawn where two flat backgrounds happen to meet. The
        // gap between two of them is the drag strip that resizes them.
        .padding(.horizontal, Column.margin)
        .padding(.bottom, Column.margin)
        // Nothing between the controls and the panels but the gap they
        // already keep from each other; the band's own slack is the margin.
        .padding(.top, max(toolbarBand - Column.underToolbar, 0))
        .background { Column.ground }
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
                    withAnimation(.snappy(duration: 0.25)) { slipBoxPaperID = nil }
                } label: {
                    Label("Notes", systemImage: "chevron.left")
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
                    Label("Settings", systemImage: "gearshape")
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
                            Button("Done") { showsSettings = false }
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
        .searchPalette(model: model, isPresented: $app.showsSearchPalette) { action in
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
        .sheet(isPresented: $showsCitationStyles) {
            if let paper = model.selectedPaper {
                NavigationStack {
                    CitationStyleView(item: paper.meta.csl)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showsCitationStyles = false }
                            }
                        }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeAddPapers)) { _ in
            isImportingPDFs = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeExportBibTeX)) { _ in
            showsExport = true
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
            model.scope = .notes
            model.notes.openNoteID = model.notes.create(paperID: model.selectedPaperID).id
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

    @ViewBuilder
    private var listColumn: some View {
        switch model.scope {
        case .notes:
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
        default: paperListColumn
        }
    }

    private var paperListColumn: some View {
        // The shelf's name stands at the top of the column on every device.
        // In the iPad's navigation bar it was squeezed between our own
        // buttons and the system's toggle until one clipped letter of it was
        // left standing in the corner.
        VStack(spacing: 0) {
            HStack {
                Text(scopeTitle)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            PaperListView(model: model)
        }
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(id: "library") { toolbarContent }
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

    @ToolbarContentBuilder
    private var toolbarContent: some CustomizableToolbarContent {
        // One group rather than one item each: separate toolbar items are what
        // drew the little vertical rules between the buttons.
        ToolbarItem(id: "actions", placement: barPlacement) {
            HStack(spacing: 4) {
                #if os(iOS)
                // The shelves, first: the leading edge belongs to the split
                // view's own toggle, which sat over anything put beside it.
                Button {
                    withAnimation(AppModel.paneMotion) { app.showsScopePanel.toggle() }
                } label: {
                    Label("Library", systemImage: "square.grid.2x2").toolbarIcon()
                }
                .help("The library's shelves: scopes, collections, tags")
                .keyboardShortcut("1", modifiers: [.command, .control])
                .toolbarHover()
                #endif
                Button {
                    isImportingPDFs = true
                } label: {
                    Label("Add PDFs", systemImage: "plus").toolbarIcon()
                }
                .help("Add PDFs to the library (Command-O)")
                .toolbarHover()

                Button {
                    app.showsSearchPalette = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass").toolbarIcon()
                }
                .help("Search everything (Command-K)")
                .toolbarHover()

                sortMenu
                // On the iPad the page's options sit on the page's own bar;
                // here they only crowded the column into an overflow menu.
                #if os(macOS)
                viewMenu
                #endif
                shareMenu
                #if os(macOS)
                paneMenu
                #endif
            }
            .toolbarButtons()
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// The four panes, behind one button.
    ///
    /// There used to be one button, for the inspector, at the far end of the
    /// toolbar — from when only the two sidebars could be hidden. Four in a
    /// row said the same thing four times and took the room of six controls.
    /// One menu, with a tick beside each pane that is showing, says it once.
    private var paneMenu: some View {
        Menu {
            Toggle("Sidebar", isOn: Binding(
                get: { app.isSidebarVisible }, set: { _ in app.toggleSidebar() }
            ))
            Toggle("Paper List", isOn: Binding(
                get: { app.showsPaperList }, set: { _ in app.togglePaperList() }
            ))
            Toggle("Paper", isOn: Binding(
                get: { app.showsReader && !app.isFocusMode }, set: { _ in app.toggleReader() }
            ))
            Toggle("Inspector", isOn: Binding(
                get: { app.showsInspector }, set: { _ in app.toggleInspector() }
            ))
            Divider()
            Toggle("Focus on the Paper", isOn: Binding(
                get: { app.isFocusMode }, set: { app.setFocusMode($0) }
            ))
        } label: {
            Label("Panes", systemImage: "rectangle.split.3x1").toolbarIcon()
        }
        .help("Which panes are showing")
        .toolbarHover()
    }

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: sortOrderBinding) {
                ForEach(LibraryModel.SortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
            Divider()
            Toggle("Ascending", isOn: sortAscendingBinding)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down").toolbarIcon()
        }
        .help("Sort the list")
        .toolbarHover()
    }

    @ViewBuilder
    private var viewMenu: some View {
        Menu {
                Picker("Page Layout", selection: $configuration.layout) {
                    ForEach(ReaderConfiguration.PageLayout.allCases) { layout in
                        Label(layout.label, systemImage: layout.symbolName).tag(layout)
                    }
                }
                Picker("Page Tint", selection: $configuration.tint) {
                    ForEach(ReaderConfiguration.PageTint.allCases) { tint in
                        Text(tint.label).tag(tint)
                    }
                }
                .onChange(of: configuration.tint) { _, tint in
                    app.settings.readerTint = tint.rawValue
                }
            #if os(iOS)
            Toggle("Draw with Finger", isOn: $configuration.fingerDrawing)
            #endif
        } label: {
            Label("View Options", systemImage: "textformat.size").toolbarIcon()
        }
        .help("Page layout and tint")
        .disabled(model.selectedPaper == nil)
        .toolbarHover()
    }

    @ViewBuilder
    private var shareMenu: some View {
        Menu {
                Button {
                    showsExport = true
                } label: {
                    Label("Export BibTeX…", systemImage: "square.and.arrow.up")
                }
                Button {
                    showsCitationStyles = true
                } label: {
                    Label("Citation Styles…", systemImage: "text.quote")
                }
                .disabled(model.selectedPaper == nil)
                Divider()
            Button {
                showsMigration = true
            } label: {
                Label(
                    "Import Existing Library…",
                    systemImage: "square.and.arrow.down.on.square"
                )
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up").toolbarIcon()
        }
        .help("Export and import")
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
            if app.showsInspector, model.selectedPaper != nil {
                Picker("Inspector", selection: $inspectorTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("What the inspector shows")
            }
        }

    }

    // MARK: - Actions

    private var sortOrderBinding: Binding<LibraryModel.SortOrder> {
        Binding(get: { model.sortOrder }, set: { model.sortOrder = $0 })
    }

    private var sortAscendingBinding: Binding<Bool> {
        Binding(get: { model.sortAscending }, set: { model.sortAscending = $0 })
    }


    private func perform(_ action: SearchResult.Action) {
        switch action {
        case .addPDFs: isImportingPDFs = true
        case .exportBibTeX: showsExport = true
        case .resolveMetadata: Task { await model.resolveAllPending() }
        case .refresh: Task { await model.refresh() }
        case .importLibrary: showsMigration = true
        case .settings:
            #if os(macOS)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            #endif
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

    private var scopeTitle: String {
        switch model.scope {
        case .all: "All Papers"
        case .notes: "Notes"
        case .graph: "Graph"
        case .searchResults: "Search Results"
        case .unread: "Unread"
        case .reading: "Reading"
        case .read: "Read"
        case .favorites: "Favorites"
        case .needsReview: "Needs Review"
        case let .collection(id):
            model.collections.collections.first { $0.id == id }?.name ?? "Collection"
        case let .tag(id):
            model.manifest.tags.first { $0.id == id }?.name ?? "Tag"
        case let .author(key):
            model.authorRanking.first { $0.key == key }?.name ?? "Author"
        }
    }
}

/// What the inspector is showing. "Notes" used to mean the list of marks,
/// which is not what a note is; the two are separate now and say so.
enum InspectorTab: String, CaseIterable, Identifiable {
    case details, marks, note
    var id: String { rawValue }
    var label: String {
        switch self {
        case .details: "Details"
        case .marks: "Marks"
        case .note: "Note"
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

    var body: some View {
        columns
        // The paper's contents, floating over the page. Centred on the
        // column, which in a book spread puts it in the gutter between the
        // two pages where there are no words to cover.
        .overlay { contents }
        .animation(.snappy(duration: 0.22), value: app.showsFloatingList)
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
        // Command-L: the passage goes to the note, and the note comes forward.
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeLinkToNote)) { _ in
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
            #if os(macOS)
            ContentsPopup(link: link) { app.toggleFloatingList() }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            #else
            ZStack(alignment: .bottom) {
                // Not a dimming: the paper stays readable while the list is
                // up, because the point of the list is to find your way about
                // the paper. It is here to catch the touch that dismisses.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { app.toggleFloatingList() }
                ContentsPopup(link: link, placement: .footer) { app.toggleFloatingList() }
                    .padding(.horizontal, 12)
                    // Clear of the bar that counts the pages: the list floats
                    // over the paper, not over the reader's own furniture.
                    .padding(.bottom, ReaderScreen.statusBarClearance + 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            #endif
        }
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
        return HStack(spacing: 0) {
            page.columnPanel()

            // Nothing to drag against when the inspector is closed.
            if app.showsInspector {
                ColumnDivider(width: $app.inspectorWidth, range: 280...520, resizes: .trailing)
            }

            // Closed by width, the same as the other columns, so it slides
            // rather than blinking in and out — and revealed rather than
            // squeezed, for the same reason the lists are. Narrowing the
            // column narrowed the form inside it, which re-wrapped every
            // label on every frame: the paper's title went from two lines to
            // three and back on the way past.
            inspector
                .frame(width: app.inspectorWidth)
                .frame(
                    width: app.showsInspector ? app.inspectorWidth : 0,
                    alignment: .trailing
                )
                .columnPanel()
                .opacity(app.showsInspector ? 1 : 0)
                .clipped()
        }
        // Likewise: `toggleInspector` opens the transaction.
        #else
        // The inspector floats in from the right, over the page, and goes
        // the same way: the screen is too narrow to give it a column, and a
        // sheet took the page away while the notes were being read.
        return page.overlay(alignment: .trailing) {
            if app.showsInspector {
                inspector
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                    .padding(10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(AppModel.paneMotion, value: app.showsInspector)
        #endif
    }

    private var page: some View {
        Group {
            if let paper = model.selectedPaper {
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
                        Spacer(minLength: 0)
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
                .animation(.snappy(duration: 0.22), value: configuration.mode)
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
                            Label("Table of Contents", systemImage: "list.bullet.indent")
                        }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                        .help("Table of contents")
                        Button {
                            configuration.mode = configuration.mode == .draw ? .read : .draw
                        } label: {
                            Label("Draw", systemImage: configuration.mode == .draw ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                        }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                        .help("Write on the page with the pencil")
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
                                Picker("Page Layout", selection: Bindable(configuration).layout) {
                                    ForEach(ReaderConfiguration.PageLayout.allCases) { layout in
                                        Label(layout.label, systemImage: layout.symbolName).tag(layout)
                                    }
                                }
                                Picker("Page Tint", selection: Bindable(configuration).tint) {
                                    ForEach(ReaderConfiguration.PageTint.allCases) { tint in
                                        Text(tint.label).tag(tint)
                                    }
                                }
                                Button {
                                    app.toggleFloatingList()
                                } label: {
                                    Label("Table of Contents", systemImage: "list.bullet.indent")
                                }
                                Divider()
                                // The whole library, from inside a paper —
                                // the other kind of looking, and the rarer
                                // one, so it is a line in the menu and the
                                // bar keeps the one about this paper.
                                Button {
                                    app.showsSearchPalette = true
                                } label: {
                                    Label("Search the Library", systemImage: "magnifyingglass.circle")
                                }
                            } label: {
                                Label("View Options", systemImage: "textformat.size")
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
                            Label("Find in Paper", systemImage: "magnifyingglass")
                        }
                        .keyboardShortcut("f", modifiers: .command)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    // The marks and the notes, floating in from the right.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            app.toggleInspector()
                        } label: {
                            Label("Marks and Notes", systemImage: app.showsInspector ? "sidebar.trailing" : "sidebar.trailing")
                                .symbolVariant(app.showsInspector ? .fill : .none)
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                #endif
            } else {
                ContentUnavailableView(
                    "No Paper Selected",
                    systemImage: "doc.text",
                    description: Text("Choose a paper to start reading.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
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
                        ContentUnavailableView("Opening the Paper", systemImage: "hourglass")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .note:
                    if let paper = model.selectedPaper {
                        PaperNotesView(model: model, paperID: paper.id, link: link)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            } else {
                ContentUnavailableView("Nothing Selected", systemImage: "sidebar.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Shown when the chosen folder is missing — usually a cloud drive that has not
/// mounted yet, which is a wait-and-retry situation rather than an error.
struct LibraryUnavailableView: View {
    @Environment(AppModel.self) private var app
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Library Folder Unavailable", systemImage: "externaldrive.badge.questionmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await app.restore() }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)

            Button("Choose a Different Folder…") {
                app.isChoosingLibraryFolder = true
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
        font(.system(size: 14, weight: .medium))
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.09 : 0))
                    .padding(-3)
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
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
    @ViewBuilder
    static var ground: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.white.opacity(0.28))
            .ignoresSafeArea()
    }

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Corner.panel, style: .continuous)
    }
}

extension View {
    /// Draws the view as one of the window's floating panels.
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
