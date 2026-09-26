import PaperCore
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
    /// The door, when the file is fine and shut: a password to type, or a
    /// rights service that will not hand this app the key.
    @State private var lock: PDFLock?
    @State private var password = ""
    @State private var passwordFailed = false
    /// A selection the user is writing a note about, and what they have typed.
    @State private var noteSelection: PDFSelection?
    @State private var noteDraft = ""
    /// A short-lived confirmation, so an action that changes nothing on screen
    /// still says that it happened.
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    /// The custom tint's ground as Settings and the colour panel store it —
    /// a view's `@AppStorage` hears the defaults change, where a model
    /// object would need an observer of its own.
    @AppStorage(ReaderConfiguration.customTintKey) private var customTintHex = ReaderConfiguration.TintColor.night.hex

    var body: some View {
        Group {
            if let session {
                reader(session)
            } else if let lock {
                locked(lock)
            } else if let loadError {
                ContentUnavailableView {
                    Label(L("이 논문을 열지 못했어요", "Can't Open This Paper"), systemImage: "doc.questionmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button(L("다시 시도", "Try Again")) { Task { await load() } }
                }
            } else {
                ProgressView(L("\(paper.meta.displayTitle) 여는 중", "Opening \(paper.meta.displayTitle)"))
                    .controlSize(.large)
            }
        }
        .task(id: paper.id) { await load() }
        // Side by side, the handle a pane holds changes as focus moves; the
        // open session goes with it, so the inspector reads this paper.
        .onChange(of: ObjectIdentifier(link)) { _, _ in
            if let session, link.session(for: paper.id) == nil { link.adopt(session, for: paper.id) }
        }
        .onDisappear {
            // Only write; the session itself stays with the link until another
            // paper takes its place. A reader that is rebuilt — which SwiftUI
            // does freely — must find the session it had, or the inspector
            // spends the rest of the session saying "Opening the Paper".
            link.selection = nil
            Task { await saveAndClose() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding is the last reliable moment to write the file —
            // and, the file written, to fold a long history back into one
            // update (`DocumentSession.close`).
            if phase != .active {
                Task {
                    await library.flushReadingPositions()
                    await session?.close()
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
        // What the tinted page is multiplied or screened onto: sepia paper
        // under Sepia, the dark ground under Dimmed, the chosen colour under
        // Custom. Glass and Paper White have the panel.
        .background {
            if let ground = configuration.groundColor {
                ground.color
            } else {
                Color.clear
            }
        }
        // The tint's behaviour depends on the appearance; the reader is
        // where the appearance is known.
        .onAppear { configuration.isDarkAppearance = colorScheme == .dark }
        .onChange(of: colorScheme) { _, scheme in configuration.isDarkAppearance = scheme == .dark }
        .onChange(of: customTintHex, initial: true) { _, hex in configuration.adoptCustomTint(hex: hex) }
        #if os(macOS)
        // Choosing a colour is the next thing anyone does after choosing
        // Custom Color, so the panel comes with it.
        .onChange(of: configuration.tint) { old, new in
            if new == .custom, old != .custom { GroundColorPanel.shared.show(hex: customTintHex) }
        }
        #endif
        // Under the status bar in the scrolling layouts, where the page
        // flowing on beneath the glass is the point; not in a book, where
        // the bar was sitting on the last lines of both pages.
        .ignoresSafeArea(edges: configuration.layout == .book ? [] : .bottom)
        .navigationTitle(paper.meta.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay(alignment: .topLeading) { touchSelectionControls(session) }
        .animation(Motion.tap, value: selectionFrame)
        #if os(macOS)
        // The pencil's tools, floating over the top of the page while it
        // is out. The inspector for what is drawn is the window's own
        // inspector column, under its Tool tab.
        .overlay(alignment: .top) {
            if configuration.mode == .draw {
                SketchToolbar(configuration: configuration)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.move, value: configuration.mode)
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
        .animation(Motion.move, value: toast)
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
        .animation(Motion.move, value: link.isFinding)
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
                Text(left == right ? L("\(count)쪽 중 \(left)쪽", "Page \(left) of \(count)") : L("\(count)쪽 중 \(left)–\(right)쪽", "Pages \(left)–\(right) of \(count)"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ProgressView(value: Double(right), total: Double(count))
                    .progressViewStyle(.linear)
                    .tint(.secondary.opacity(0.6))
                    .frame(width: 140)
            } else {
                Text(L("\(count)쪽 중 \(currentPageIndex + 1)쪽", "Page \(currentPageIndex + 1) of \(count)"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            switch session.saveState {
            case .idle:
                EmptyView()
            case .pending:
                Label(L("저장 전", "Unsaved changes"), systemImage: "circle.dotted")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .saving:
                ProgressView().controlSize(.small)
            case .mergedExternalChanges:
                Label(L("다른 기기의 변경을 합쳤어요", "Merged changes from another device"), systemImage: "arrow.triangle.merge")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case let .keptInApp(reason):
                // Not a warning: nothing was lost. The marks are on screen,
                // in the journal and the sidecars; only this file said no.
                Label(L("표시는 Paper Time에 있어요", "Marks stay in Paper Time"), systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(Self.keptExplanation(reason))
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            if session.hasForeignInk {
                Label(L("다른 앱의 잉크가 있어요", "Contains ink from another app"), systemImage: "hand.draw")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .help(
                        L(
                            "이 PDF에는 들여올 때부터 손으로 그린 잉크가 있었어요. 여기서 그리면 그 위에 덮어써요.",
                            """
                            This PDF already had freehand ink when it arrived. \
                            Drawing here replaces it.
                            """
                        )
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

    /// Why a file would not take the marks, in words: that they are safe,
    /// that the file is as it was, and what about the file stopped it.
    static func keptExplanation(_ reason: DocumentSession.KeptReason) -> String {
        switch reason {
        case .locked:
            L(
                "이 PDF는 잠겨 있어서 표시를 파일에 넣지 않았어요. 표시는 Paper Time에 그대로 있어요.",
                "This PDF is locked, so the marks stay in Paper Time. The file is unchanged."
            )
        case .forbidden:
            L(
                "이 PDF는 주석을 허락하지 않아요. 파일은 그대로 두고, 표시는 Paper Time에 두었어요.",
                "This PDF doesn't allow annotations. The marks stay in Paper Time, and the file is unchanged."
            )
        case .unusual:
            L(
                "이 PDF는 짜임이 흔하지 않아서, 표시를 넣으면 파일이 상할 수 있어요. 파일은 그대로 두고, 표시는 Paper Time에 두었어요.",
                "This PDF is built in an unusual way, and writing into it could damage it. The marks stay in Paper Time, and the file is unchanged."
            )
        case .unconfirmed:
            L(
                "표시를 넣고 다시 읽어 보니 맞지 않았어요. 파일은 그대로 두고, 표시는 Paper Time에 두었어요.",
                "The marks didn't read back as written. They stay in Paper Time, and the file is unchanged."
            )
        }
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
                    show(toast: L("복사했어요", "Copied"))
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
                    show(toast: L("노트를 더했어요", "Note added"))
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

    private func load(password: String? = nil) async {
        loadError = nil
        if password == nil { lock = nil }
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
                try await DocumentSession.open(paper: paper, store: library.store, password: password)
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
        } catch let shut as Locked {
            // A wrong password is not a failure to report; it is the same
            // door, and the field stays where the hand already is.
            passwordFailed = password != nil && shut.lock == .password
            lock = shut.lock
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// What a locked paper shows instead of a blank page.
    ///
    /// Two different sentences, because they ask for two different things. A
    /// password is something the reader has; a rights service is something
    /// only their company's own reader can satisfy, and saying so saves them
    /// looking for a setting that does not exist.
    @ViewBuilder
    private func locked(_ lock: PDFLock) -> some View {
        switch lock {
        case .password:
            ContentUnavailableView {
                Label(L("암호가 걸린 논문이에요", "This Paper Is Locked"), systemImage: "lock.doc")
            } description: {
                VStack(spacing: 10) {
                    Text(passwordFailed
                        ? L("암호가 맞지 않아요. 다시 넣어주세요.", "That password didn't work. Try again.")
                        : L("암호를 넣으면 열어요. 어디에도 저장하지 않아요.",
                            "Type the password and it opens. It is not stored anywhere."))
                    SecureField(L("암호", "Password"), text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .onSubmit { Task { await load(password: password) } }
                }
            } actions: {
                Button(L("열기", "Open")) { Task { await load(password: password) } }
                    .disabled(password.isEmpty)
            }
        case let .rights(handler):
            ContentUnavailableView {
                Label(L("회사가 보호한 논문이에요", "This Paper Is Protected"), systemImage: "lock.shield")
            } description: {
                Text(L("""
                    \(Self.serviceName(handler))가 잠근 파일이라 Paper Time은 못 열어요. \
                    파일이 깨진 건 아니에요 — 여는 열쇠를 회사 권한 서버가 들고 있고, \
                    그 서버에 물어볼 수 있는 앱은 Acrobat처럼 회사가 허락한 것뿐이에요.
                    """, """
                    \(Self.serviceName(handler)) locked this file, so Paper Time can't open it. \
                    The file is not damaged — the key lives on your company's rights server, \
                    and only a reader your company allows, such as Acrobat, can ask for it.
                    """))
            } actions: {
                Button(L("Finder에서 보기", "Show in Finder")) {
                    #if os(macOS)
                    NSWorkspace.shared.activateFileViewerSelecting([paper.documentURL])
                    #endif
                }
            }
        }
    }

    /// The handler as it is written in the file, said the way a person would.
    private static func serviceName(_ handler: String) -> String {
        switch handler {
        case "MicrosoftIRMServices": L("Microsoft Purview(회사 IRM)", "Microsoft Purview")
        case "FoxitIRM": "Foxit IRM"
        case "Adobe.PubSec": L("인증서 보안", "Certificate security")
        case "EBX_HANDLER": "Adobe DRM"
        default: handler
        }
    }

    private func saveAndClose() async {
        await library.flushReadingPositions()
        await session?.close()
    }
}
