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
    }
}

/// The three-column layout used on Mac and iPad, collapsing to a stack on
/// iPhone. `NavigationSplitView` handles that collapse itself, which is why the
/// app does not branch on device idiom here.
struct LibraryWindow: View {
    let model: LibraryModel
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app

        NavigationSplitView(columnVisibility: $app.columnVisibility) {
            LibrarySidebar(model: model)
                .navigationTitle(model.manifest.displayName)
        } content: {
            PaperListView(model: model)
                .navigationTitle(scopeTitle)
                .toolbar { LibraryToolbarItems(model: model) }
        } detail: {
            // The inspector lives on the detail column rather than on the split
            // view itself. Attaching it to the whole view adds a fourth pane
            // beside three columns, which on an 11-inch iPad squeezes the
            // reader down to a sliver and duplicates the toolbar.
            PaperDetailColumn(model: model)
        }
    }

    private var scopeTitle: String {
        switch model.scope {
        case .all: "All Papers"
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

/// The reader, plus the inspector and the actions that act on one paper.
///
/// Every toolbar control for this column is declared here, in the order it
/// should appear: what you are doing to the page, then what you are doing with
/// the paper, then the panel toggle at the trailing edge. Spreading them across
/// nested views is what made the window look like a collection of unrelated
/// buttons.
struct PaperDetailColumn: View {
    let model: LibraryModel
    @Environment(AppModel.self) private var app

    @State private var configuration = ReaderConfiguration()
    @State private var link = ReaderLink()
    @State private var inspectorTab = InspectorTab.details
    @State private var showsExport = false
    @State private var showsMigration = false
    @State private var showsCitationStyles = false

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
                ReaderScreen(
                    library: model,
                    paper: paper,
                    configuration: configuration,
                    link: link
                )
                .id(paper.id)
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
        .toolbar { toolbarContent }
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
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeExportBibTeX)) { _ in
            showsExport = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .paperTimeCopyCitationKey)) { _ in
            copySelectedCitationKey()
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if model.selectedPaper != nil {
            VStack(spacing: 0) {
                Picker("Inspector", selection: $inspectorTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                switch inspectorTab {
                case .details:
                    PaperInspector(model: model)
                case .notes:
                    if let session = link.session {
                        MarkupListView(session: session)
                    } else {
                        ContentUnavailableView(
                            "Opening the Paper",
                            systemImage: "hourglass"
                        )
                    }
                }
            }
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "sidebar.right")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem {
            Button {
                configuration.mode = configuration.mode == .draw ? .read : .draw
                configuration.showsToolPicker = configuration.mode == .draw
            } label: {
                Label(
                    configuration.mode == .draw ? "Stop Drawing" : "Draw",
                    systemImage: "pencil.tip.crop.circle"
                )
                .symbolVariant(configuration.mode == .draw ? .fill : .none)
            }
            .disabled(model.selectedPaper == nil)
        }
        #endif

        ToolbarItem {
            Menu {
                Section("Highlight") {
                    ForEach(MarkupColor.allCases, id: \.self) { color in
                        Button(color.displayName) { addMarkup(.highlight, color: color) }
                    }
                }
                Button("Underline") { addMarkup(.underline, color: configuration.markupColor) }
                Button("Strikethrough") {
                    addMarkup(.strikethrough, color: configuration.markupColor)
                }
            } label: {
                Label("Mark Up", systemImage: "highlighter")
            }
            .disabled(!link.hasSelection)
            .help("Mark up the selected text")
        }

        ToolbarItem {
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
                #endif
            } label: {
                Label("View Options", systemImage: "textformat.size")
            }
            .disabled(model.selectedPaper == nil)
        }

        ToolbarItem {
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
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                app.showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector (Command-])")
        }
    }

    // MARK: - Actions

    private func addMarkup(_ kind: MarkupDescriptor.Kind, color: MarkupColor) {
        guard let session = link.session, let selection = link.selection else { return }
        session.addMarkup(for: selection, kind: kind, color: color)
        link.selection = nil
    }

    /// Copies the citation key so it can be pasted straight into a manuscript.
    private func copySelectedCitationKey() {
        guard let key = model.selectedPaper?.meta.bibKey, !key.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        #else
        UIPasteboard.general.string = key
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
