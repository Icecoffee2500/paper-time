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
        .task {
            guard app.phase == .launching else { return }
            await app.restore()
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

    @State private var configuration = ReaderConfiguration()
    @State private var link = ReaderLink()
    @State private var isImportingPDFs = false
    @State private var showsExport = false
    @State private var showsMigration = false
    @State private var showsCitationStyles = false

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
            .toolbar(id: "library") { toolbarContent }
            .toolbar(id: "inspector-toggle") { inspectorToolbarContent }
            .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
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
        return AnyView(
            NavigationSplitView(columnVisibility: $app.columnVisibility) {
                sidebarColumn
            } content: {
                listColumn
            } detail: {
                PaperDetailColumn(model: model, configuration: configuration, link: link)
            }
        )
        #endif
    }

    #if os(macOS)
    private var macColumns: some View {
        @Bindable var app = app

        return HStack(spacing: 0) {
            sidebarColumn
                .frame(width: app.isSidebarVisible ? app.settings.sidebarWidth : 0)
                .opacity(app.isSidebarVisible ? 1 : 0)
                .clipped()

            if app.isSidebarVisible {
                ColumnDivider(width: Bindable(app.settings).sidebarWidth, range: 200...360)
            }

            listColumn
                .frame(width: app.showsPaperList ? app.settings.paperListWidth : 0)
                .opacity(app.showsPaperList ? 1 : 0)
                .clipped()

            if app.showsPaperList {
                ColumnDivider(width: Bindable(app.settings).paperListWidth, range: 240...560)
            }

            PaperDetailColumn(model: model, configuration: configuration, link: link)
                .frame(maxWidth: .infinity)
        }
        .animation(.snappy(duration: 0.22), value: app.showsPaperList)
        .animation(.snappy(duration: 0.22), value: app.isSidebarVisible)
    }
    #endif

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            Text(model.displayName)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
            #endif
            LibrarySidebar(model: model)
        }
        #if os(macOS)
        .background(.ultraThinMaterial)
        #endif
    }

    private var windowBody: some View {
        @Bindable var app = app

        return splitView

        .overlay(alignment: .topLeading) { floatingList }
        .onChange(of: configuration.layout) { _, layout in
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
        .fileImporter(
            isPresented: $isImportingPDFs,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            Task { await model.importDocuments(at: urls) }
        }
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
            link.isFinding = true
        }
    }

    /// In focus mode the list is summoned over the page rather than pinned to
    /// a column, so a glance at the library costs nothing and leaves nothing
    /// behind.
    @ViewBuilder
    private var floatingList: some View {
        if app.isFocusMode {
            HStack(alignment: .top, spacing: 0) {
                if app.showsFloatingList {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(scopeTitle)
                                .font(.headline)
                            Spacer()
                            Button {
                                app.toggleFloatingList()
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .buttonStyle(.plain)
                            .help("Hide papers (Command-L)")
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        Divider()
                        PaperListView(model: model)
                    }
                        .frame(width: 320)
                        .frame(maxHeight: 620)
                        .background(.regularMaterial, in: .rect(cornerRadius: 16, style: .continuous))
                        .shadow(radius: 18, y: 6)
                        .padding(.leading, 16)
                        .padding(.top, 16)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .onChange(of: model.selectedPaperID) { _, _ in
                            app.toggleFloatingList()
                        }
                } else {
                    Button {
                        app.toggleFloatingList()
                    } label: {
                        Label("Papers", systemImage: "sidebar.leading")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: .capsule)
                            .overlay(
                                Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                            )
                            .shadow(radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Show papers (Command-L)")
                    .padding(.leading, 12)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
    }

    @ViewBuilder
    private var listColumn: some View {
        #if os(macOS)
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
        #else
        PaperListView(model: model)
            .navigationTitle(scopeTitle)
            .toolbar(id: "library") { toolbarContent }
        #endif
    }

    // MARK: - Toolbar

    /// The Mac centres its toolbar with `.principal`; iOS allows only one
    /// principal item, so there the controls sit in the trailing group.
    private var barPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .principal
        #else
        .topBarTrailing
        #endif
    }

    @ToolbarContentBuilder
    private var toolbarContent: some CustomizableToolbarContent {
        // One group rather than one item each: separate toolbar items are what
        // drew the little vertical rules between the buttons.
        ToolbarItem(id: "actions", placement: barPlacement) {
            HStack(spacing: 2) {
                Button {
                    isImportingPDFs = true
                } label: {
                    Label("Add PDFs", systemImage: "plus")
                }
                .help("Add PDFs to the library (Command-O)")

                Button {
                    app.showsSearchPalette = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Search everything (Command-K)")

                sortMenu
                viewMenu
                shareMenu
            }
            .toolbarButtons()
        }
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
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort the list")
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
            #if os(iOS)
            Toggle("Draw with Finger", isOn: $configuration.fingerDrawing)
            Toggle(
                "Draw",
                isOn: Binding(
                    get: { configuration.mode == .draw },
                    set: { on in
                        configuration.mode = on ? .draw : .read
                        configuration.showsToolPicker = on
                    }
                )
            )
            #endif
            Divider()
            Toggle(
                "Focus on the Paper",
                isOn: Binding(get: { app.isFocusMode }, set: { app.setFocusMode($0) })
            )
            .keyboardShortcut("f", modifiers: [.command, .control])
        } label: {
            Label("View Options", systemImage: "textformat.size")
        }
        .help("Page layout and tint")
        .disabled(model.selectedPaper == nil)
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
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .help("Export and import")
    }

    @ToolbarContentBuilder
    private var inspectorToolbarContent: some CustomizableToolbarContent {
        ToolbarItem(id: "inspector", placement: .primaryAction) {
            Button {
                app.toggleInspector()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .toolbarButtons()
            .help("Show or hide the inspector (Command-])")
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
        }
    }
}

/// The reader and the inspector.
struct PaperDetailColumn: View {
    let model: LibraryModel
    let configuration: ReaderConfiguration
    let link: ReaderLink
    @Environment(AppModel.self) private var app

    @State private var inspectorTab = InspectorTab.details

    enum InspectorTab: String, CaseIterable, Identifiable {
        case details, notes
        var id: String { rawValue }
        var label: String {
            switch self {
            case .details: "Details"
            case .notes: "Notes"
            }
        }
    }

    var body: some View {
        @Bindable var app = app

        Group {
            if let paper = model.selectedPaper {
                // Deliberately not `.id(paper.id)`: giving each paper its own
                // identity threw away the PDF view and built another one for
                // every selection, and creating a `PDFView` is most of what
                // opening a paper used to cost. The reader reloads itself when
                // the paper changes instead.
                ReaderScreen(
                    library: model,
                    paper: paper,
                    configuration: configuration,
                    link: link
                )
            } else {
                ContentUnavailableView(
                    "No Paper Selected",
                    systemImage: "doc.text",
                    description: Text("Choose a paper to start reading.")
                )
            }
        }
        .inspector(isPresented: $app.showsInspector) {
            inspector
                .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        // Everything is pinned to the top and told to fill the column. Without
        // it SwiftUI centres the whole stack, which left the tab picker
        // floating halfway down an empty inspector.
        VStack(spacing: 0) {
            if model.selectedPaper != nil {
                Picker("Inspector", selection: $inspectorTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 8)

                Divider()

                switch inspectorTab {
                case .details:
                    PaperInspector(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                case .notes:
                    if let session = link.session {
                        MarkupListView(session: session, link: link)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        ContentUnavailableView("Opening the Paper", systemImage: "hourglass")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            Button("Choose a Different Folder…") {
                app.forgetLibrary()
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
        buttonStyle(.accessoryBar)
            .menuStyle(.borderlessButton)
            .labelStyle(.iconOnly)
        #else
        labelStyle(.iconOnly)
        #endif
    }
}


#if os(macOS)
/// The line between two columns, which can be dragged to resize the one to its
/// left. The split view used to provide this; owning it is the price of columns
/// that can actually be hidden and brought back.
private struct ColumnDivider: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Divider()
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 10)
                    .contentShape(.rect)
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                width = min(
                                    max(start + value.translation.width, range.lowerBound),
                                    range.upperBound
                                )
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
#endif
