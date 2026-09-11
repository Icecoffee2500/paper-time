import InkEngine
import LibraryStore
import PDFKit
import PDFReader
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The reading surface: the page, the drawing tools, and the small set of
/// actions that belong on top of a paper rather than in the library.
struct ReaderScreen: View {
    let library: LibraryModel
    let paper: LoadedPaper
    let configuration: ReaderConfiguration
    let link: ReaderLink

    @State private var session: DocumentSession?
    @State private var finder = DocumentFinder()
    @State private var selectionFrame: CGRect = .zero
    @State private var selection: PDFSelection?
    @State private var currentPageIndex = 0
    @State private var loadError: String?
    /// A selection the user is writing a note about, and what they have typed.
    @State private var noteSelection: PDFSelection?
    @State private var noteDraft = ""
    /// A short-lived confirmation, so an action that changes nothing on screen
    /// still says that it happened.
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
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
        .task(id: paper.id) { await load() }
        .onDisappear {
            // Only write; the session itself stays with the link until another
            // paper takes its place. A reader that is rebuilt — which SwiftUI
            // does freely — must find the session it had, or the inspector
            // spends the rest of the session saying "Opening the Paper".
            link.selection = nil
            Task { await saveAndClose() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding is the last reliable moment to write the file.
            if phase != .active {
                Task {
                    await library.flushReadingPositions()
                    await session?.flush()
                }
            }
        }
    }

    @ViewBuilder
    private func reader(_ session: DocumentSession) -> some View {
        PDFReaderRepresentable(
            session: session,
            configuration: configuration,
            link: link,
            revision: session.revision,
            currentPageIndex: $currentPageIndex,
            onSelectionChange: { newSelection, frame in
                guard noteSelection == nil else { return }
                selection = newSelection
                selectionFrame = frame
                link.selection = newSelection
            },
            onNoteRequested: {
                guard let selection else { return }
                noteDraft = ""
                noteSelection = selection
            },
            onToast: { show(toast: $0) }
        )
        // Glass paper: multiplied against what is behind it, so the page's
        // white falls away to whatever the panel is showing and the ink stays
        // ink. Highlights multiply too, which is what a highlighter does.
        //
        // Only under the glass tint. Multiplied over a dark ground the text
        // would go with the paper, which is why the other tints keep their
        // own opaque background instead.
        // Under the status bar in the scrolling layouts, where the page
        // flowing on beneath the glass is the point; not in a book, where
        // the bar was sitting on the last lines of both pages.
        .ignoresSafeArea(edges: configuration.layout == .book ? [] : .bottom)
        .navigationTitle(paper.meta.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay(alignment: .topLeading) { touchSelectionControls(session) }
        .animation(.snappy(duration: 0.16), value: selectionFrame)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .liquidGlass(.floating)
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                    .shadow(radius: 8, y: 2)
                    .padding(.bottom, 56)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.22), value: toast)
        .overlay { pageTurnZones }
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
            library.recordReadingPosition(index, for: paper.id)
        }
    }

    @ViewBuilder
    private func statusBar(_ session: DocumentSession) -> some View {
        HStack(spacing: 12) {
            let count = max(session.document.pageCount, 1)
            if configuration.layout == .book {
                // Both pages of the spread, and how far through the paper
                // they are — the two things a bookmark tells you.
                let left = currentPageIndex - currentPageIndex % 2 + 1
                let right = min(left + 1, count)
                Text(left == right ? "Page \(left) of \(count)" : "Pages \(left)–\(right) of \(count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ProgressView(value: Double(right), total: Double(count))
                    .progressViewStyle(.linear)
                    .tint(.secondary.opacity(0.6))
                    .frame(width: 140)
            } else {
                Text("Page \(currentPageIndex + 1) of \(count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

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
        // A rectangle, not a capsule: the bar spans the panel and the panel's
        // own clip is what rounds the two corners it shares with it. `.bar`
        // was opaque, which left a white strip across the foot of the page.
        .liquidGlass(.floating, in: Rectangle())
    }

    /// The note editor on iPhone and iPad, where the markup actions themselves
    /// live in the system edit menu and only the editor needs a place to sit.
    @ViewBuilder
    private func touchSelectionControls(_ session: DocumentSession) -> some View {
        if !Self.usesFloatingMarkupBar, let noteSelection {
            NoteComposer(
                quotedText: noteSelection.string ?? "",
                text: $noteDraft,
                onCancel: { dismissSelectionControls() },
                onSave: {
                    let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { dismissSelectionControls(); return }
                    session.addNote(for: noteSelection, comment: trimmed)
                    dismissSelectionControls()
                    show(toast: "Note added")
                }
            )
            .frame(width: 300)
            .offset(anchoredTo: selectionFrame, width: 300)
            .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
        }
    }

    /// Whether markup controls float next to the selection.
    ///
    /// The Mac has no selection menu of its own, so the bar is the only place
    /// these actions can live. iPhone and iPad already put them in the system
    /// edit menu, right where the finger lifted; a second bar beside it would
    /// be the app talking over the platform.
    static var usesFloatingMarkupBar: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Invisible strips down the left and right edges that turn the page.
    ///
    /// A book turns by its edges. In the paged layouts this is the gesture
    /// people already make; in continuous scrolling it would fight the scroll,
    /// so it is not offered there.
    @ViewBuilder
    private var pageTurnZones: some View {
        // Only where there is no swipe: iPhone and iPad turn pages with a
        // finger already.
        #if os(macOS)
        // Book only: the spread leaves margins for the strips to sit in, while
        // a single page fills the window and the strips would swallow clicks
        // meant for the text.
        if configuration.layout == .book {
            HStack(spacing: 0) {
                PageTurnZone(edge: .leading) {
                    NotificationCenter.default.post(name: .paperTimePreviousPage, object: nil)
                }
                Spacer(minLength: 0)
                PageTurnZone(edge: .trailing) {
                    NotificationCenter.default.post(name: .paperTimeNextPage, object: nil)
                }
            }
            .allowsHitTesting(selection == nil && noteSelection == nil)
        }
        #endif
    }

    private func dismissSelectionControls() {
        selection = nil
        link.selection = nil
        selectionFrame = .zero
        noteSelection = nil
        noteDraft = ""
    }

    private func show(toast message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: - Actions

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func load() async {
        loadError = nil
        // A different paper: forget what belonged to the last one, but keep its
        // session in place until the new document is ready. Dropping it would
        // take the PDF view out of the view tree, and building another one is
        // most of what opening a paper costs.
        if session?.paper.id != paper.id {
            selection = nil
            selectionFrame = .zero
            noteSelection = nil
            currentPageIndex = paper.state.lastPageIndex
        }
        guard link.loadingPaperID != paper.id else { return }
        // Reuse the session this paper already has. Opening it a second time
        // would give the view one document and the saver another.
        if let existing = link.session(for: paper.id) {
            session = existing
            currentPageIndex = paper.state.lastPageIndex
            return
        }
        link.loadingPaperID = paper.id
        defer { if link.loadingPaperID == paper.id { link.loadingPaperID = nil } }
        do {
            let opened = try await DocumentSession.open(paper: paper, store: library.store)
            session = opened
            link.adopt(opened, for: paper.id)
            currentPageIndex = paper.state.lastPageIndex
            // Opening a paper records that it was opened, and nothing else.
            // Whether it counts as "reading" is the user's call, made with the
            // status button in the list.
            var state = paper.state
            state.lastOpenedAt = .now
            // Not awaited: writing "you opened this" is a file write plus a
            // reload of the whole list, and the reader has no reason to wait
            // for either before showing the page.
            Task { await library.update(state: state, for: paper.id) }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func saveAndClose() async {
        await library.flushReadingPositions()
        await session?.flush()
    }
}
