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
    let configuration: ReaderConfiguration
    let link: ReaderLink

    @State private var session: DocumentSession?
    @State private var finder = DocumentFinder()
    @State private var currentPageIndex = 0
    @State private var loadError: String?
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
            link.session = nil
            link.selection = nil
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
            link: link,
            currentPageIndex: $currentPageIndex,
            onSelectionChange: { link.selection = $0 }
        )
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(paper.meta.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay(alignment: .topTrailing) {
            if link.isFinding {
                FindBar(
                    finder: finder,
                    document: session.document,
                    isPresented: Binding(
                        get: { link.isFinding },
                        set: { link.isFinding = $0 }
                    ),
                    onNavigate: { selection in
                        guard let selection else { return }
                        link.scrollRequest = selection
                    }
                )
                .padding(12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: link.isFinding)
        .safeAreaInset(edge: .bottom) { statusBar(session) }
        .onChange(of: currentPageIndex) { _, index in
            Task { await recordPosition(index) }
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

    private func load() async {
        loadError = nil
        do {
            let opened = try await DocumentSession.open(paper: paper, store: library.store)
            session = opened
            link.session = opened
            currentPageIndex = paper.state.lastPageIndex
            // Opening a paper records that it was opened, and nothing else.
            // Whether it counts as "reading" is the user's call, made with the
            // status button in the list.
            var state = paper.state
            state.lastOpenedAt = .now
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
