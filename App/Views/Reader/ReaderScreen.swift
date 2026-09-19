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
        // What the tinted page is multiplied against, or sits on: sepia
        // paper under Sepia, a dark ground under Dimmed. Glass and Paper
        // White have the panel.
        .background {
            switch configuration.tint {
            case .sepia: Color(red: 0.96, green: 0.93, blue: 0.86)
            case .dim: Color(white: 0.13)
            default: Color.clear
            }
        }
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
        #if os(macOS)
        // The pencil's tools, floating over the top of the page while it
        // is out, and the style of what it draws down the left — where
        // Excalidraw keeps them, and for the same reason: they are about
        // the page, so they sit on it.
        .overlay(alignment: .top) {
            if configuration.mode == .draw {
                SketchToolbar(configuration: configuration)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) {
            if configuration.mode == .draw {
                // Scrolls when the window is shorter than the panel — the
                // text tool's panel is a tall one — instead of running off
                // the bottom with its last controls cut away.
                ScrollView(.vertical, showsIndicators: false) {
                    SketchStylePanel(configuration: configuration)
                        .padding(.leading, 12)
                        .padding(.top, 60)
                        .padding(.bottom, Self.statusBarClearance + 12)
                        .padding(.trailing, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .fixedSize(horizontal: true, vertical: false)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: configuration.mode)
        .onChange(of: configuration.mode) { _, mode in
            // Whatever was selected as text has no place while drawing.
            if mode == .draw { dismissSelectionControls() }
        }
        #endif
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
        .onChange(of: currentPageIndex, initial: true) { _, index in
            library.recordReadingPosition(index, for: paper.id)
            link.currentPageIndex = index
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
        #if os(macOS)
        // A rectangle, not a capsule: the bar spans the panel and the panel's
        // own clip is what rounds the two corners it shares with it. `.bar`
        // was opaque, which left a white strip across the foot of the page.
        .liquidGlass(.floating, in: Rectangle())
        #else
        // The floating glass overran the column's edges on the iPad; a flat
        // material the width of the column is what the Mac's bar looks like.
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        #endif
    }

    /// The note editor on iPhone and iPad, where the markup actions themselves
    /// live in the system edit menu and only the editor needs a place to sit.
    @ViewBuilder
    private func touchSelectionControls(_ session: DocumentSession) -> some View {
        #if os(iOS)
        // The Mac's bar, on the iPad and the phone: the colours as colours,
        // beside the selection, rather than their names in the edit menu.
        // Below the words, where the system's own menu is not.
        if noteSelection == nil, let selection, selection.string?.isEmpty == false {
            SelectionMarkupBar(
                onMark: { kind, color in
                    session.addMarkup(for: selection, kind: kind, color: color)
                    dismissSelectionControls()
                },
                onNote: {
                    noteDraft = ""
                    noteSelection = selection
                },
                onCopy: {
                    UIPasteboard.general.string = selection.string
                    dismissSelectionControls()
                    show(toast: "Copied")
                }
            )
            .offset(anchoredTo: selectionFrame, width: 260, below: true)
            .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
        }
        if let noteSelection {
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
        #endif
    }

    /// How much room the bar that counts the pages takes at the foot of the
    /// reader, for anything floating that has to stay clear of it.
    static let statusBarClearance: CGFloat = 44

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
        true
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
            Trace.mark("opening \(paper.meta.displayTitle.prefix(30))")
            let opened = try await Trace.time("open the paper") {
                try await DocumentSession.open(paper: paper, store: library.store)
            }
            Trace.mark("opened \(paper.meta.displayTitle.prefix(30))")
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
