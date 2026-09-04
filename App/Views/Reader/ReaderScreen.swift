import InkEngine
import LibraryStore
import PDFKit
import PDFReader
import SwiftUI

/// The reading surface: the page, the drawing tools, and the small set of
/// actions that belong on top of a paper rather than in the library.
struct ReaderScreen: View {
    let library: LibraryModel
    let paper: LoadedPaper

    @State private var session: DocumentSession?
    @State private var configuration = ReaderConfiguration()
    @State private var currentPageIndex = 0
    @State private var selection: PDFSelection?
    @State private var loadError: String?
    @State private var showsMarkupList = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let session {
                reader(session)
            } else if let loadError {
                ContentUnavailableView {
                    Label("Can't Open This Paper", systemImage: "doc.questionmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ProgressView("Opening \(paper.meta.displayTitle)")
                    .controlSize(.large)
            }
        }
        .task { await load() }
        .onDisappear {
            Task { await saveAndClose() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding is the last reliable moment to write the file.
            if phase != .active { Task { await session?.flush() } }
        }
    }

    @ViewBuilder
    private func reader(_ session: DocumentSession) -> some View {
        PDFReaderRepresentable(
            session: session,
            configuration: configuration,
            currentPageIndex: $currentPageIndex,
            onSelectionChange: { selection = $0 }
        )
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(paper.meta.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar(session) }
        .safeAreaInset(edge: .bottom) { statusBar(session) }
        .inspector(isPresented: $showsMarkupList) {
            MarkupListView(session: session)
                .inspectorColumnWidth(min: 260, ideal: 320)
        }
        .onChange(of: currentPageIndex) { _, index in
            Task { await recordPosition(index) }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ session: DocumentSession) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Mode", selection: Binding(
                get: { configuration.mode },
                set: { newValue in
                    configuration.mode = newValue
                    configuration.showsToolPicker = newValue == .draw
                }
            )) {
                ForEach(ReaderConfiguration.Mode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            #if os(macOS)
            // PencilKit has no canvas on the Mac, so the drawing mode would be
            // a control that does nothing.
            .hidden()
            #endif
        }

        ToolbarItem {
            Menu {
                if selection != nil {
                    Section("Selected Text") {
                        ForEach(MarkupColor.allCases, id: \.self) { color in
                            Button {
                                addMarkup(.highlight, color: color, session: session)
                            } label: {
                                Label("Highlight \(color.displayName)", systemImage: "highlighter")
                            }
                        }
                        Button {
                            addMarkup(.underline, color: configuration.markupColor, session: session)
                        } label: {
                            Label("Underline", systemImage: "underline")
                        }
                        Button {
                            addMarkup(
                                .strikethrough,
                                color: configuration.markupColor,
                                session: session
                            )
                        } label: {
                            Label("Strikethrough", systemImage: "strikethrough")
                        }
                    }
                }
                Section {
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
                    Toggle("Draw with Finger", isOn: $configuration.fingerDrawing)
                }
                Section {
                    Button {
                        showsMarkupList.toggle()
                    } label: {
                        Label("Notes & Highlights", systemImage: "list.bullet.rectangle")
                    }
                }
            } label: {
                Label("Reader Options", systemImage: "textformat.size")
            }
        }
    }

    @ViewBuilder
    private func statusBar(_ session: DocumentSession) -> some View {
        HStack(spacing: 12) {
            Text("Page \(currentPageIndex + 1) of \(max(session.document.pageCount, 1))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            switch session.saveState {
            case .idle:
                EmptyView()
            case .pending:
                Label("Unsaved changes", systemImage: "circle.dotted")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .saving:
                ProgressView().controlSize(.small)
            case .mergedExternalChanges:
                Label("Merged changes from another device", systemImage: "arrow.triangle.merge")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            if session.hasForeignInk {
                Label("Contains ink from another app", systemImage: "hand.draw")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .help(
                        """
                        This PDF already had freehand ink when it was imported. \
                        Drawing here will replace it.
                        """
                    )
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Actions

    private func addMarkup(
        _ kind: MarkupDescriptor.Kind,
        color: MarkupColor,
        session: DocumentSession
    ) {
        guard let selection else { return }
        session.addMarkup(for: selection, kind: kind, color: color)
        self.selection = nil
    }

    private func load() async {
        loadError = nil
        do {
            session = try await DocumentSession.open(paper: paper, store: library.store)
            currentPageIndex = paper.state.lastPageIndex
            var state = paper.state
            state.lastOpenedAt = .now
            if state.readingStatus == .unread { state.readingStatus = .reading }
            await library.update(state: state, for: paper.id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func recordPosition(_ index: Int) async {
        var state = paper.state
        state.lastPageIndex = index
        state.lastOpenedAt = .now
        await library.update(state: state, for: paper.id)
    }

    private func saveAndClose() async {
        await session?.flush()
    }
}
