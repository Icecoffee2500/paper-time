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
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
        case .favorites: "Favorites"
        case .needsReview: "Needs Review"
        case let .collection(id):
            model.collections.collections.first { $0.id == id }?.name ?? "Collection"
        case let .tag(id):
            model.manifest.tags.first { $0.id == id }?.name ?? "Tag"
        }
    }
}

/// The reader, plus the bibliographic inspector and the actions that act on one
/// paper at a time.
struct PaperDetailColumn: View {
    let model: LibraryModel

    // A Mac window is wide enough to show the details permanently; an iPad is
    // not, so there the inspector opens on request.
    #if os(macOS)
    @State private var showsInspector = true
    #else
    @State private var showsInspector = false
    #endif
    @State private var showsExport = false
    @State private var showsMigration = false
    @State private var showsCitationStyles = false

    var body: some View {
        Group {
            if let paper = model.selectedPaper {
                ReaderScreen(library: model, paper: paper)
                    .id(paper.id)
            } else {
                ContentUnavailableView(
                    "No Paper Selected",
                    systemImage: "doc.text",
                    description: Text("Choose a paper to start reading.")
                )
            }
        }
        .inspector(isPresented: $showsInspector) {
            if model.selectedPaper != nil {
                PaperInspector(model: model)
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
            } else {
                ContentUnavailableView("Nothing Selected", systemImage: "sidebar.right")
            }
        }
        .toolbar {
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
            ToolbarItem {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Bibliographic Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide bibliographic details")
            }
        }
        .sheet(isPresented: $showsExport) {
            BibTeXExportView()
        }
        .sheet(isPresented: $showsMigration) {
            MigrationView(model: model)
        }
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
