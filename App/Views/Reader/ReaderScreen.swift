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
        .task { await load() }
        .onDisappear {
            link.session = nil
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
                // While a note is being written the selection it belongs to
                // must not be pulled out from under the editor.
                guard noteSelection == nil else { return }
                selection = newSelection
                selectionFrame = frame
                link.selection = newSelection
            },
            onNoteRequested: {
                guard let selection else { return }
                noteDraft = ""
                noteSelection = selection
            }
        )
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(paper.meta.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay(alignment: .topLeading) { selectionControls(session) }
        .animation(.snappy(duration: 0.16), value: selectionFrame)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: .capsule)
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

    /// The markup controls, and the note editor they turn into.
    ///
    /// Anchored to the text rather than parked in the toolbar: the action
    /// belongs where the user just dragged.
    @ViewBuilder
    private func selectionControls(_ session: DocumentSession) -> some View {
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
        } else if let selection, !selectionFrame.isEmpty, Self.usesFloatingMarkupBar {
            SelectionMarkupBar { kind, color in
                session.addMarkup(for: selection, kind: kind, color: color)
                dismissSelectionControls()
            } onNote: {
                noteDraft = ""
                noteSelection = selection
            } onCopy: {
                copy(selection.string ?? "")
                show(toast: "Copied")
                dismissSelectionControls()
            }
            .offset(anchoredTo: selectionFrame, width: 300)
            .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
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
        if configuration.layout != .continuous {
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

    private func saveAndClose() async {
        await library.flushReadingPositions()
        await session?.flush()
    }
}
