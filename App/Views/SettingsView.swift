import Bibliography
import LibraryStore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Per-device preferences plus the one library-lifecycle action (changing the
/// folder) that has no other home.
///
/// On macOS this is the content of the Settings scene; on iOS/iPadOS it is
/// pushed from wherever the app puts a Settings entry, so it supplies its own
/// navigation chrome there.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var showsChangeFolderConfirmation = false
    @State private var showsReleaseNotes = false
    @State private var showsFeatureLog = false
    #if os(macOS)
    @State private var pane: Pane = .library
    #endif
    /// What the shortcuts page is being searched for.
    @State private var shortcutQuery = ""
    /// Set when the query was pressed rather than typed.
    ///
    /// A typed "⌘k" should still find ⇧⌘K — you are casting about. A pressed
    /// ⌘K should not: you pressed exactly those keys and want to know what
    /// they do, and offering the neighbouring combination answers a question
    /// nobody asked.
    @State private var capturedKey: Shortcut?
    @FocusState private var searchIsFocused: Bool
    /// Which log lines are showing what they mean.
    @State private var openEntries: Set<String> = []
    /// Which versions are unfolded. The newest one is, to begin with; the
    /// rest fold away as they accumulate.
    @State private var openReleases: Set<String> = Set(ReleaseNotes.releases.prefix(1).map(\.version))

    /// The pages of Settings.
    ///
    /// One scroll of everything had grown long enough that reaching the
    /// shortcuts meant remembering they were at the bottom of it. People
    /// arrive at Settings already knowing roughly what they came for, and a
    /// list of names is what that knowledge is for.
    enum Pane: String, CaseIterable, Identifiable {
        case library = "Library"
        case metadata = "Metadata"
        case bibtex = "BibTeX"
        case reading = "Reading"
        case shortcuts = "Shortcuts"
        case log = "Log"
        case about = "About"

        var id: String { rawValue }

        /// The name a reader sees. The raw value is the identifier and stays
        /// as it is.
        var title: String {
            switch self {
            case .library: L("라이브러리", "Library")
            case .metadata: L("서지", "Metadata")
            case .bibtex: "BibTeX"
            case .reading: L("읽기", "Reading")
            case .shortcuts: L("단축키", "Shortcuts")
            case .log: L("기록", "Log")
            case .about: L("정보", "About")
            }
        }

        var symbol: String {
            switch self {
            case .library: "folder"
            case .metadata: "text.book.closed"
            case .bibtex: "text.quote"
            case .reading: "doc.text"
            case .shortcuts: "keyboard"
            case .log: "list.bullet.rectangle"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        #if os(iOS)
        // The pages as rows to step into, not one scroll of everything.
        //
        // The Mac keeps the same seven pages in a sidebar beside the page it
        // is showing. A phone has no room for a sidebar and an iPad in a
        // sheet has little more, so the seven become seven rows opened one at
        // a time — the same pages, the same names, the same symbols, in the
        // shape these devices use for settings everywhere else. The stack is
        // the presenter's: this used to make one of its own inside the
        // sheet's, and two stacks cannot agree on whose bar is whose.
        List {
            Section {
                ForEach(Self.pages) { page in
                    NavigationLink(value: page) {
                        LabeledContent {
                            Text(summary(for: page))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } label: {
                            Label(page.title, systemImage: page.symbol)
                        }
                    }
                }
            } footer: {
                Text(L(
                    "논문은 내가 고른 폴더에 평범한 파일로 있어요. 이 앱 안에만 있는 건 하나도 없어요.",
                    "Papers are ordinary files in the folder you chose. Nothing lives only inside Paper Time."
                ))
            }
        }
        .navigationTitle(L("설정", "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Pane.self) { settingsPage($0) }
        #else
        // Two columns and a line, rather than a split view. A split view
        // gives the sidebar its own floating surface and a button to collapse
        // it — and this sidebar is the only way to reach five of the six
        // pages, so collapsing it is not something anyone should be offered.
        HStack(spacing: 0) {
            // Rows of our own rather than a `List`. A sidebar list paints
            // its selection with the accent colour only while the list itself
            // has keyboard focus, and on the Shortcuts page focus belongs to
            // the search field the moment you arrive — so the one page that
            // needed the field also lost its blue, and the selection went
            // grey. Which page you are on is not a fact about where the
            // keyboard is pointing.
            VStack(alignment: .leading, spacing: 2) {
                // The window's title, here rather than centred over the page:
                // the panel reaches the top of the window now, and a title
                // drawn across it would have sat on the page.
                Text(L("설정", "Settings"))
                    .font(.headline)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)

                ForEach(Pane.allCases) { page in
                    let isCurrent = pane == page
                    Button {
                        pane = page
                    } label: {
                        Label {
                            Text(page.title)
                        } icon: {
                            Image(systemName: page.symbol)
                                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The chosen page is the one lifted off the ground —
                        // a white card with a soft edge — rather than the one
                        // painted blue. The blue said "selected in a list";
                        // this says "the page you are on".
                        .background(
                            RoundedRectangle(cornerRadius: Corner.row + 2, style: .continuous)
                                .fill(isCurrent ? AnyShapeStyle(.background) : AnyShapeStyle(.clear))
                                .shadow(color: .black.opacity(isCurrent ? 0.08 : 0), radius: 3, y: 1)
                        )
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: 176)
            .padding(.top, 10)

            VStack(spacing: 0) {
                // Above the page rather than in it, so it stays put while the
                // keys scroll — and so the Form stops right-aligning it.
                if pane == .shortcuts { shortcutSearchBar }

                if pane == .about {
                    AboutView()
                } else {
                    settingsForm
                }
            }
            .frame(maxWidth: .infinity)
            // The page as a panel: rounded, lifted, and clear of the edges
            // on three sides, with the sidebar sitting on the ground beside
            // it. The same arrangement as the library window — and the one
            // Aside uses, which is where the idea came from. The clip is also
            // what keeps a scrolled page from drawing up behind the title.
            .columnPanel()
            .padding([.top, .trailing, .bottom], Column.margin)
            // Up to the top edge, past where the title was — the whole height
            // of the window, the way Aside's page sits.
            .ignoresSafeArea(edges: .top)
        }
        // The panes are not the same size. Everything but 정보 is a form, and
        // 760×540 is generous for a form; 정보 is a demonstration at full size
        // with its words underneath, and 540 cut the top off it — the card
        // began above the window. macOS's own Settings takes the size of the
        // pane it is showing, and so does this one.
        .frame(
            width: pane == .about ? 900 : 760,
            height: pane == .about ? 780 : 540
        )
        .animation(Motion.surface, value: pane == .about)
        .background { Column.ground }
        .sheet(isPresented: $showsReleaseNotes) {
            WhatsNewView(marksAsSeen: false)
        }
        .sheet(isPresented: $showsFeatureLog) {
            VStack(spacing: 0) {
                FeatureLogView()
                Button(ReleaseNotes.string("완료", "Done")) { showsFeatureLog = false }
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 16)
            }
        }
        .translucentWindow()
        .plainTitlebar()
        .centeredOnOpen()
        .thinScrollers()
        // Escape closes it. Settings is a place you step into and back out
        // of, and reaching for ⌘W or the mouse to leave a window you opened
        // with a key is a change of hands for no reason. With something typed
        // in the shortcut search the first Escape empties that instead, the
        // way a search field behaves everywhere else.
        .background {
            Button("", action: escape)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
        #endif
    }

#if os(iOS)
    /// The pages this device has.
    ///
    /// A phone has no keys to remap and no keyboard to read them off, so the
    /// shortcuts page is not offered there. The iPad, which may well have a
    /// keyboard attached, gets them to read.
    static var pages: [Pane] {
        Pane.allCases.filter { page in
            page != .shortcuts || UIDevice.current.userInterfaceIdiom != .phone
        }
    }

    /// What a row says about its page without being opened — the folder's
    /// name, the layout in use — the way Settings says "Wi-Fi · name".
    private func summary(for page: Pane) -> String {
        switch page {
        case .library:
            app.library?.location.url.lastPathComponent ?? L("연결 안 됨", "Not Connected")
        case .metadata:
            app.settings.resolvesMetadataOnImport ? L("들여올 때", "On Import") : L("끔", "Off")
        case .bibtex:
            BibTeXExportOptions.PreprintStyle(rawValue: app.settings.preferredPreprintStyle)?.displayName ?? ""
        case .reading:
            ReaderConfiguration.PageLayout(rawValue: app.settings.readerPageMode)?.label ?? ""
        case .log:
            ReleaseNotes.releases.first?.version ?? ""
        case .about:
            appVersion
        case .shortcuts:
            ""
        }
    }

    /// One page of settings, pushed from the list.
    @ViewBuilder
    private func settingsPage(_ page: Pane) -> some View {
        let settings = app.settings
        Group {
            switch page {
            case .library:
                Form {
                    librarySection
                    languageSection
                }
                    .confirmationDialog(
                        L("라이브러리 폴더를 바꿀까요?", "Change Library Folder?"),
                        isPresented: $showsChangeFolderConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(L("폴더 바꾸기", "Change Folder"), role: .destructive) { app.forgetLibrary() }
                        Button(L("취소", "Cancel"), role: .cancel) {}
                    } message: {
                        Text(L(
                            "아무것도 지우지 않아요. 논문은 있던 자리에 그대로 있어요. 이 기기에서 폴더만 다시 고르면 돼요.",
                            "This deletes nothing. The papers stay where they are. This device asks for the folder again."
                        ))
                    }
            case .metadata:
                Form { metadataSection(settings: settings) }
            case .bibtex:
                Form { bibTeXSection(settings: settings) }
            case .reading:
                Form {
                    readingSection(settings: settings)
                    listSection(settings: settings)
                }
            case .shortcuts:
                Form { keysSection }
            case .log:
                Form { logSection }
            case .about:
                AboutView()
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The keys, to read rather than to change.
    ///
    /// Remapping belongs where the keyboard is the main instrument; on an
    /// iPad the keyboard is a guest, and what a guest needs is the list of
    /// what the keys already do. Changing them is on the Mac, and what is
    /// changed there travels in the same settings.
    @ViewBuilder
    private var keysSection: some View {
        ForEach(ShortcutAction.Group.allCases) { group in
            let actions = ShortcutAction.allCases.filter { $0.group == group }
            if !actions.isEmpty {
                Section(group.rawValue) {
                    ForEach(actions) { action in
                        LabeledContent(action.title) {
                            Text(app.shortcut(for: action).display)
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
#endif

#if os(macOS)
    private var settingsForm: some View {
        let settings = app.settings
        return Form {
            switch pane {
            case .library:
                librarySection
                // With no library open there are no notes to point anywhere.
                if app.library != nil { looseNotesSection }
                languageSection
            case .metadata: metadataSection(settings: settings)
            case .bibtex: bibTeXSection(settings: settings)
            case .reading:
                listSection(settings: settings)
                readingSection(settings: settings)
                writingSection(settings: settings)
            case .shortcuts: shortcutsSection
            case .log: logSection
            case .about: EmptyView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog(
            L("라이브러리 폴더를 바꿀까요?", "Change Library Folder?"),
            isPresented: $showsChangeFolderConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("폴더 바꾸기", "Change Folder"), role: .destructive) {
                app.forgetLibrary()
            }
            Button(L("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(L(
                "아무것도 지우지 않아요. 논문은 있던 자리에 그대로 있어요. 이 기기에서 폴더만 다시 고르면 돼요.",
                "This deletes nothing. The papers stay where they are. This device asks for the folder again."
            ))
        }
    }
#endif

    // MARK: - Library
    /// A section's name, where it is not already the name of the page.
    ///
    /// The Mac shows these pages side by side with a list and no title over
    /// them, so each section says what it is. On iOS the navigation bar has
    /// just said it, and saying it twice, one line apart, is the kind of
    /// thing that makes a settings screen look unfinished.
    @ViewBuilder
    private func pageHeader(_ title: String) -> some View {
        #if os(macOS)
        Text(title)
        #endif
    }


    private var librarySection: some View {
        Section {
            // The folder's name in the row and its path underneath the
            // section, not the other way round. A row is one line long, and
            // the path is four: wrapped into a row it left a hole the height
            // of the card on the phone and the iPad, and it was unreadable
            // in either place. Down here it can take the width it needs.
            LabeledContent(L("폴더", "Folder")) {
                Text(app.library?.location.url.lastPathComponent ?? L("연결 안 됨", "Not Connected"))
                    .foregroundStyle(.secondary)
            }
            if let provider = app.library?.location.provider {
                // The icon and the name side by side rather than a `Label`:
                // a Label handed to a form row's value side was given the
                // whole column and grew a card's worth of empty space under
                // itself on the phone and the iPad.
                LabeledContent(L("동기화", "Synced Via")) {
                    HStack(spacing: 6) {
                        Image(systemName: provider.symbolName)
                        Text(provider.displayName)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L("\(provider.displayName)로 동기화", "Synced via \(provider.displayName)"))
                }
            }
            Button(L("라이브러리 폴더 바꾸기…", "Change Library Folder…")) {
                app.chooseLibraryFolder()
            }
        } header: {
            pageHeader(L("라이브러리", "Library"))
        } footer: {
            VStack(alignment: .leading, spacing: 10) {
                if let path = app.library?.location.url.path(percentEncoded: false) {
                    Text(path)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L(
                    "라이브러리를 옮길 때는 폴더를 통째로 옮겨주세요. 안에 숨어 있는 .papertime 폴더까지요. 서지와 노트, 잉크, 읽던 자리가 거기 있어요. PDF만 복사하면 새 라이브러리가 시작되고, 노트는 따라오지 않아요.",
                    "Move the whole folder, including the hidden .papertime inside it. That folder holds the records, notes, ink and reading progress. Copying only the PDFs starts a fresh library and leaves the notes behind."
                ))
            }
        }
    }

    #if os(macOS)
    // MARK: - Notes about no paper

    /// Where the notes that belong to no paper are kept, and the way to move
    /// them somewhere else.
    ///
    /// A section of its own under the library's rather than a row inside it:
    /// the library's folder is where the papers are, and a note about a paper
    /// lives beside it. This is the other folder — the one for the notes no
    /// library folder can hold, because they belong to none of them. The Mac
    /// only: this is where a folder can be handed to the app with a panel.
    private var looseNotesSection: some View {
        let notes = app.library?.notes
        let place = app.notesFolder
        let where_ = looseNotesLocation(notes: notes, place: place)
        return Section {
            LabeledContent(L("폴더", "Folder")) {
                HStack(spacing: 6) {
                    if isAway(place, notes) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    Text(where_.name)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            // The same pair the library's folder shows — which service carries
            // it, if any — because that is the reason to choose a folder at
            // all: so these notes go where the rest of your notes go.
            if let provider = where_.provider {
                LabeledContent(L("동기화", "Synced Via")) {
                    HStack(spacing: 6) {
                        Image(systemName: provider.symbolName)
                        Text(provider.displayName)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L("\(provider.displayName)로 동기화", "Synced via \(provider.displayName)"))
                }
            }
            HStack {
                Button(L("폴더 고르기…", "Choose Folder…")) { app.chooseNotesFolder() }
                if place != .app {
                    Button(L("앱 폴더로 되돌리기", "Move Back to My Mac")) {
                        Task { await app.keepNotesInAppFolder() }
                    }
                }
                if isAway(place, notes) {
                    Button(L("다시 연결", "Reconnect")) {
                        Task { await app.reconnectNotesFolder() }
                    }
                }
                Spacer()
                if let url = where_.url {
                    // With the chosen folder away the folder it opens is the
                    // app's own, not the one the row names, and the button
                    // says so.
                    if isAway(place, notes) {
                        Button(L("앱 폴더 보기", "Show Notes on My Mac")) { reveal(url) }
                    } else {
                        Button(L("Finder에서 보기", "Show in Finder")) { reveal(url) }
                    }
                }
            }
        } header: {
            pageHeader(L("논문 없는 노트", "Notes Without a Paper"))
        } footer: {
            VStack(alignment: .leading, spacing: 10) {
                // The path of the folder the row names — the chosen one even
                // while it is away, since that is the one to go and look for.
                if let path = where_.hint ?? where_.url?.path(percentEncoded: false) {
                    Text(path)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let status = looseNotesStatus(notes: notes, place: place) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(status)
                            .fixedSize(horizontal: false, vertical: true)
                        if let move = app.lastNotesMove, move.kept > 0 {
                            Button(L("남은 노트 보기", "Show Notes Left Behind")) { reveal(move.keptIn) }
                                .buttonStyle(.link)
                        }
                    }
                }
                Text(L(
                    "논문에 대한 노트는 그 논문이 있는 폴더에 있어요. 여기에는 어느 논문에도 딸리지 않은 노트만 있어요. iCloud Drive 같은 클라우드 폴더를 고르면 다른 맥에서도 보여요.",
                    "Notes about a paper stay in that paper's folder. This folder holds the rest. Choose one in iCloud Drive to see them on your other Macs."
                ))
            }
        }
    }

    /// What the row names: the folder, the service that carries it, and
    /// where it is.
    private func looseNotesLocation(
        notes: NotesModel?, place: AppModel.NotesFolder
    ) -> (name: String, provider: CloudProvider?, url: URL?, hint: String?) {
        switch place {
        case .app:
            // The app's own folder is on this Mac and goes nowhere, which is
            // what the name says; a "This Device" row under it would say it
            // twice.
            return (L("앱 폴더", "On My Mac"), nil, notes?.looseBox, nil)
        case .chosen:
            guard let notes else { return ("", nil, nil, nil) }
            let url = notes.looseBox
            // Gone while the app was open: what is being written now goes to
            // the app's own folder, and that is the one worth opening.
            if notes.chosenFolderWentAway {
                return (url.lastPathComponent, CloudProvider.detect(at: url), notes.appFolderURL, url.path(percentEncoded: false))
            }
            return (url.lastPathComponent, CloudProvider.detect(at: url), url, nil)
        case let .away(hint):
            let name = hint.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("고른 폴더", "Chosen Folder")
            let provider = hint.map { CloudProvider.detect(at: URL(fileURLWithPath: $0)) }
            // The folder that is actually taking the notes for now is the
            // app's own, and that is the one worth opening.
            return (name, provider, notes?.looseBox, hint)
        }
    }

    private func isAway(_ place: AppModel.NotesFolder, _ notes: NotesModel?) -> Bool {
        if case .away = place { return true }
        return notes?.chosenFolderWentAway == true
    }

    /// One line under the row: why the notes are not where they were put, or
    /// what the last move did. Nothing when there is nothing to say.
    private func looseNotesStatus(notes: NotesModel?, place: AppModel.NotesFolder) -> String? {
        if let refusal = app.notesNotice { return refusal }
        var lines: [String] = []
        if case .away = place {
            lines.append(L(
                "고른 폴더에 닿을 수 없어요. 그동안 쓰는 노트는 앱 폴더에 둬요. 폴더가 돌아오면 그리로 옮겨요.",
                "Paper Time can't reach the folder you chose. New notes stay on this Mac until it's back, then move there."
            ))
        } else if notes?.chosenFolderWentAway == true {
            lines.append(L(
                "고른 폴더에 닿지 못해서 노트를 앱 폴더에 두고 있어요. 폴더가 돌아오면 그리로 옮겨요.",
                "Paper Time can't reach the folder you chose anymore. Notes stay on this Mac until it's back, then move there."
            ))
        }
        if let move = app.lastNotesMove {
            lines.append(Self.describe(move, appFolder: notes?.appFolderURL, box: notes?.looseBox))
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// What a move did, counted. `box` is where the notes about no paper are
    /// now — the folder the move went into.
    static func describe(_ move: AppModel.NotesMove, appFolder: URL?, box: URL?) -> String {
        let n = move.moved
        let k = move.kept
        let notesEN = n == 1 ? "1 note" : "\(n) notes"
        var sentences: [String] = []
        switch move.occasion {
        case .chose where n == 0 && k == 0:
            sentences.append(L("옮길 노트가 없었어요. 새 노트부터 여기에 둬요.", "No notes to move. New ones go here."))
        case .wentBack where n == 0 && k == 0:
            sentences.append(L("옮길 노트가 없었어요.", "No notes to move."))
        case .chose:
            sentences.append(L("노트 \(n)개를 옮겼어요.", "Moved \(notesEN)."))
        case .wentBack:
            sentences.append(L("노트 \(n)개를 앱 폴더로 옮겼어요.", "Moved \(notesEN) back to this Mac."))
        case .cameBack where n > 0:
            sentences.append(L(
                "폴더에 닿지 못하는 동안 쓴 노트 \(n)개를 옮겼어요.",
                "Moved \(notesEN) written while the folder was away."
            ))
        case .cameBack:
            // Nothing new came across; the only thing worth a line is what is
            // still waiting, below. "Moved 0 notes" would be a line about
            // nothing.
            break
        }
        if k > 0 {
            func isAppFolder(_ url: URL?) -> Bool {
                guard let url, let appFolder else { return false }
                return url.standardizedFileURL == appFolder.standardizedFileURL
            }
            // Both folders by name: "the new folder" and "there" leave the
            // reader working out which of two folders is meant.
            let stayedKO = isAppFolder(move.keptIn) ? "앱 폴더" : "«\(move.keptIn.lastPathComponent)»"
            let stayedEN = isAppFolder(move.keptIn) ? "on this Mac" : "in \(move.keptIn.lastPathComponent)"
            let intoKO = isAppFolder(box) ? "앱 폴더" : "«\(box?.lastPathComponent ?? "")»"
            let intoEN = isAppFolder(box) ? "this Mac" : (box?.lastPathComponent ?? "")
            // Standing alone it has to say what it is counting; after "moved
            // 12 notes" the count is enough.
            let alone = sentences.isEmpty
            let whatKO = alone ? "노트 \(k)개는" : "\(k)개는"
            let whatEN = alone ? (k == 1 ? "1 note" : "\(k) notes") : "\(k)"
            sentences.append(L(
                "\(whatKO) \(intoKO)에 같은 이름의 노트가 이미 있어서 \(stayedKO)에 그대로 뒀어요.",
                k == 1
                    ? "\(whatEN) stayed \(stayedEN) because \(intoEN) already has a note with that name."
                    : "\(whatEN) stayed \(stayedEN) because \(intoEN) already has notes with those names."
            ))
        }
        return sentences.joined(separator: " ")
    }

    private func reveal(_ url: URL) {
        // The app's own folder is made the first time a note is written, and
        // a Finder window on a folder that is not there shows nothing at all.
        // Only that one: a chosen folder that is not there is away, and
        // making it again is the one thing never done to it.
        if let own = app.library?.notes.appFolderURL,
           own.standardizedFileURL == url.standardizedFileURL {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif

    // MARK: - Language

    /// The interface follows the system unless a reader says otherwise. A
    /// Korean system gets Korean; everything else gets English. The override
    /// is here because "my system is Korean but I want the English words" is
    /// a real preference among people who read English papers all day.
    private var languageSection: some View {
        Section {
            Picker(L("말", "Language"), selection: Binding(
                get: { Language.choice },
                set: { Language.choice = $0 }
            )) {
                ForEach(Language.Choice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
        } header: {
            pageHeader(L("말", "Language"))
        } footer: {
            Text(L(
                "고르지 않으면 시스템을 따라가요. 시스템이 한국어면 한국어로, 아니면 영어로 보여요.",
                "Paper Time follows the system: Korean when the system is Korean, English otherwise."
            ))
        }
    }

    // MARK: - Metadata

    private func metadataSection(settings: AppSettings) -> some View {
        Section {
            Toggle(L("들여올 때 서지 채우기", "Resolve Metadata on Import"), isOn: Bindable(settings).resolvesMetadataOnImport)
            // Its own row rather than a value beside a label: the message is
            // a sentence, and a sentence in the value column of a form row is
            // either squeezed into a corner or given the whole card to fall
            // down — the same trap the library's provider fell into.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("정보", "Information"))
                Text(app.library?.onDeviceModelMessage ?? L("쓸 수 있는지는 라이브러리를 열어야 알 수 있어요.", "Open a library to see whether it's available."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)

            // On iOS a field given a prompt loses its title, so the row
            // read "optional" and nothing else. The name goes beside it, the
            // way every other row on the page is named.
            #if os(iOS)
            LabeledContent(L("연락 이메일", "Contact Email")) {
                TextField(L("선택 사항", "optional"), text: Bindable(settings).metadataContactEmail)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
            }
            #else
            TextField(
                L("연락 이메일", "Contact Email"),
                text: Bindable(settings).metadataContactEmail,
                prompt: Text(L("선택 사항", "optional"))
            )
            .autocorrectionDisabled()
            #endif
        } header: {
            pageHeader(L("서지", "Metadata"))
        } footer: {
            Text(L(
                """
                Crossref와 OpenAlex는 연락처를 밝힌 요청에 더 빨리 답해줘요. \
                비워 둬도 돼요. 대신 논문 여러 편을 한꺼번에 채울 때 느려요. \
                주소는 이 두 곳에만 보내요.
                """,
                """
                Crossref and OpenAlex answer faster when a request carries a \
                contact address. This can stay empty; lookups slow down when \
                many papers resolve at once. Paper Time sends the address to \
                those two services and nowhere else.
                """
            ))
        }
    }

    // MARK: - BibTeX

    private func bibTeXSection(settings: AppSettings) -> some View {
        Section {
            Picker(L("프리프린트 양식", "Preprint Style"), selection: Bindable(settings).preferredPreprintStyle) {
                ForEach(BibTeXExportOptions.PreprintStyle.allCases, id: \.rawValue) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            Toggle(L("제목 대소문자 지키기", "Protect Case in Titles"), isOn: Bindable(settings).protectsCase)
            Toggle(L("확인 안 된 항목도 내보내기", "Include Unverified Records in Export"), isOn: Bindable(settings).includesUnverifiedInExport)
        } header: {
            pageHeader("BibTeX")
        }
    }

    // MARK: - The list

    /// Which fields appear under a title in the paper list.
    ///
    /// Order follows the order they are switched on, so the reader chooses
    /// both what is shown and what comes first.
    private func listSection(settings: AppSettings) -> some View {
        let chosen = SubtitleField.parse(settings.listSubtitleFields)
        return Section {
            ForEach(SubtitleField.allCases) { field in
                Toggle(
                    field.displayName,
                    isOn: Binding(
                        get: { chosen.contains(field) },
                        set: { isOn in
                            var updated = chosen.filter { $0 != field }
                            if isOn { updated.append(field) }
                            settings.listSubtitleFields = SubtitleField.encode(updated)
                        }
                    )
                )
            }
        } header: {
            Text(L("제목 아래에", "Under the Title"))
        } footer: {
            Text(chosen.map(\.displayName).joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Reading

    /// Which key does what.
    ///
    /// Every command the app has, not the handful somebody remembered to make
    /// configurable. Habits come from whatever the reader used before this, so
    /// the defaults are a starting point rather than a rule. A key belongs to
    /// one command: giving it to a second takes it from the first, which is
    /// then left with no shortcut until it is given one.
    @ViewBuilder
    private var shortcutsSection: some View {
        #if os(macOS)
        @Bindable var app = app

        if matchingActions.isEmpty {
            Section {
                Text(capturedKey == nil
                     ? ReleaseNotes.string("그런 키도, 그런 이름도 없어요.", "Nothing is on that key, and nothing is called that.")
                     : ReleaseNotes.string("\(shortcutQuery)에는 아무것도 없어요.", "Nothing is on \(shortcutQuery)."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(ShortcutAction.Group.allCases) { group in
            let actions = matchingActions.filter { $0.group == group }
            if !actions.isEmpty {
                Section {
                    // One card, rows separated by air. A line under every row
                    // is a list of twenty-five hairlines, which is what made
                    // this page look like a form to be filled in rather than
                    // a set of keys to be read.
                    VStack(spacing: 2) {
                        ForEach(actions) { action in
                            HStack {
                                Text(action.title)
                                Spacer(minLength: 12)
                                if action.isFixed {
                                    // The system's, and not ours to move.
                                    Text(action.fallback.display)
                                        .font(.body.monospaced())
                                        .foregroundStyle(.secondary)
                                        .help(L("macOS가 정한 것", "Set by macOS"))
                                } else {
                                    ShortcutRecorder(
                                        shortcut: app.shortcut(for: action),
                                        isUnset: !app.hasShortcut(action)
                                    ) { app.setShortcut($0, for: action) }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                } header: {
                    Text(group.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }

        if shortcutQuery.isEmpty {
            Section {
                HStack {
                    Spacer()
                    Button(L("기본값으로 복원", "Restore Defaults")) { app.resetShortcuts() }
                        .disabled(app.paneShortcuts.isEmpty)
                }
            }
        }
        #endif
    }

    /// What Escape does: empty the search if there is anything in it, and
    /// otherwise leave.
    ///
    /// Reached two ways, because Escape arrives two ways. With the search
    /// field focused the key never gets past the field editor, so the
    /// catcher in the field calls this; everywhere else on the page the
    /// hidden cancel button does.
    private func escape() {
        #if os(macOS)
        if !shortcutQuery.isEmpty {
            shortcutQuery = ""
            capturedKey = nil
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
        #endif
    }

    /// The commands a search matches, by name or by key.
    ///
    /// Both, because you arrive at this page from one of two directions: you
    /// know what the thing is called and want to know its key, or a key did
    /// something you did not expect and you want to know what owns it. The
    /// second is the one that is usually impossible.
    ///
    /// The key is matched as it is drawn (⌘F) and as it is spoken (cmd, shift,
    /// option, control) — nobody types ⌘ into a search field.
    private var matchingActions: [ShortcutAction] {
        if let capturedKey {
            return ShortcutAction.allCases.filter {
                app.shortcut(for: $0).display == capturedKey.display
            }
        }
        let query = shortcutQuery
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !query.isEmpty else { return ShortcutAction.allCases }
        return ShortcutAction.allCases.filter { action in
            haystack(for: action).contains(query)
        }
    }

    private func haystack(for action: ShortcutAction) -> String {
        let shortcut = app.shortcut(for: action)
        var words = [action.title, action.group.rawValue, shortcut.display]
        if shortcut.modifiers.contains(.command) { words += ["cmd", "command", "⌘"] }
        if shortcut.modifiers.contains(.shift) { words += ["shift", "⇧"] }
        if shortcut.modifiers.contains(.option) { words += ["opt", "option", "alt", "⌥"] }
        if shortcut.modifiers.contains(.control) { words += ["ctrl", "control", "⌃"] }
        return words.joined(separator: " ").lowercased()
    }

    private func readingSection(settings: AppSettings) -> some View {
        // Driven by the reader's own cases rather than a hand-written copy of
        // them. The copy had drifted: it offered "None" and "Dim" where the
        // page's own menu says "Paper White" and "Dimmed", and it had never
        // heard of Glass — so a tint chosen on the page had no name here and
        // one chosen here was called something else there.
        Section {
            Picker(L("쪽 배치", "Page Layout"), selection: Bindable(settings).readerPageMode) {
                ForEach(ReaderConfiguration.PageLayout.allCases) { layout in
                    Label(layout.label, systemImage: layout.symbolName).tag(layout.rawValue)
                }
            }
            Picker(L("쪽 색조", "Page Tint"), selection: Bindable(settings).readerTint) {
                ForEach(ReaderConfiguration.PageTint.allCases) { tint in
                    Text(tint.label).tag(tint.rawValue)
                }
            }
        } header: {
            pageHeader(L("읽기", "Reading"))
        } footer: {
            Text(L(
                "논문을 열었을 때의 모양이에요. 쪽 위의 AA 메뉴는 지금 읽는 논문만 바꿔요. 이 설정은 그대로예요.",
                "How a paper looks when it opens. The AA menu on the page changes only the paper you are reading, not this setting."
            ))
        }
    }

    // MARK: - Writing

    #if os(macOS)
    /// Latex Suite in the note and in the text cards on the page — the two
    /// places on the Mac where LaTeX is typed, so one switch for both. The
    /// line under it is the feature in one example, because a name with
    /// "shortcuts" in it says nothing about what will happen to the keys; the
    /// line under that is the credit the snippets' licence asks for. Only on
    /// the Mac: that is where the text views are that do it.
    private func writingSection(settings: AppSettings) -> some View {
        Section {
            Toggle(L("LaTeX 단축 입력", "LaTeX Shortcuts"), isOn: Bindable(settings).latexShortcuts)
        } header: {
            pageHeader(L("쓰기", "Writing"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                // Read as Markdown, so the trigger is set as code.
                let help = L(
                    "`//`를 치면 분수가 되는 것처럼, 짧게 친 말을 LaTeX로 바꿔요.",
                    "Expands short triggers into LaTeX as you type, like // into a fraction."
                )
                Text((try? AttributedString(markdown: help)) ?? AttributedString(help))
                Text(L(
                    "기본 스니펫과 동작은 artisticat1의 Latex Suite(MIT 라이선스)에서 가져왔어요.",
                    "Snippets and behavior from Latex Suite by artisticat1, under the MIT License."
                ))
                .foregroundStyle(.tertiary)
            }
        }
    }
    #endif

    /// The shortcut search, sitting above the page.
    ///
    /// It used to be a row of the Form, and a macOS Form right-aligns the
    /// value side of a row: what you typed appeared hard against the clear
    /// button while the placeholder still sat at the left, because they were
    /// two different views being aligned two different ways. Out here it is
    /// just a field.
    ///
    /// While the field has focus it also *catches* key combinations instead of
    /// letting them run, which is the only way to ask "what is on ⌘K?" from
    /// inside a window where ⌘K does something. ⌘Q and ⌘W are let through on
    /// purpose — a field you cannot leave would be a worse bargain than an
    /// unanswerable question.
    @ViewBuilder
    private var shortcutSearchBar: some View {
        #if os(macOS)
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)

            ZStack(alignment: .leading) {
                if shortcutQuery.isEmpty {
                    Text(ReleaseNotes.string("이름으로, 또는 키를 눌러서", "Search by name, or press the keys"))
                        .font(.body.weight(.light))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $shortcutQuery)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !shortcutQuery.isEmpty {
                Button {
                    shortcutQuery = ""
                    capturedKey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Image(systemName: "keyboard")
                .foregroundStyle(searchIsFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .help(ReleaseNotes.string(
                    "칸을 누른 다음 키 조합을 누르면, 그 키를 쓰는 기능이 나와요.",
                    "Click the field, then press a combination to find what owns it."
                ))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .contentShape(Capsule())
        // Simultaneous, not `onTapGesture`: a plain tap gesture over the
        // capsule consumes the click before the field under it sees it, so
        // the one place you would click to type was the one place that did
        // not focus. This adds the padding around the field to its target
        // without taking the field's own click away.
        .simultaneousGesture(TapGesture().onEnded { searchIsFocused = true })
        .background(
            KeyCatcher(
                isRecording: Binding(get: { searchIsFocused }, set: { searchIsFocused = $0 }),
                capturesAnything: true,
                onEscape: escape
            ) { key, modifiers in
                let pressed = Shortcut(key, modifiers)
                shortcutQuery = pressed.display
                capturedKey = pressed
            }
            .allowsHitTesting(false)
        )
        // Editing the text by hand puts it back to an ordinary search.
        .onChange(of: shortcutQuery) { _, now in
            if now != capturedKey?.display { capturedKey = nil }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        // Focused on arrival, because focus is what arms the key-catching.
        // Somebody who opens this page to find out what ⌘K does should be
        // able to press ⌘K, not click first and then press.
        //
        // A tick late, deliberately: asked for during `onAppear` the field is
        // not yet in the window's responder chain, and the request went
        // nowhere — which is most of why pressing keys at this page appeared
        // to do nothing.
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            searchIsFocused = true
        }
        #endif
    }

    // MARK: - Log

    /// What each version brought, newest first.
    private var logSection: some View {
        Group {
            Section {
                HStack(spacing: 16) {
                    legend("plus", .green, ReleaseNotes.string("더한 것", "Added"))
                    legend("minus", .secondary, ReleaseNotes.string("뺀 것", "Removed"))
                    legend("wrench.adjustable", .orange, ReleaseNotes.string("고친 것", "Fixed"))
                    Spacer(minLength: 8)
                    Text(ReleaseNotes.string("버전과 항목은 눌러서 펼쳐요", "Versions and entries open when clicked"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(ReleaseNotes.releases) { release in
                let isOpen = openReleases.contains(release.version)
                Section {
                    if isOpen {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(release.added) { item in
                                entry(item, symbol: "plus", tint: .green)
                            }
                            ForEach(release.removed) { item in
                                entry(item, symbol: "minus", tint: .secondary)
                            }
                            ForEach(release.fixed) { item in
                                entry(item, symbol: "wrench.adjustable", tint: .orange)
                            }
                        }
                    }
                } header: {
                    // The version number is the handle. With one release that
                    // is a formality; with ten it is the only way the page
                    // stays a page.
                    Button {
                        withAnimation(Motion.move) {
                            if isOpen { openReleases.remove(release.version) }
                            else { openReleases.insert(release.version) }
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(release.version).font(.headline)
                            Text(release.date.value)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.subheadline)
                                .foregroundStyle(.quaternary)
                            counts(release)
                            Spacer(minLength: 8)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } footer: {
                    if isOpen {
                        Text(release.note.value)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// One symbol and what it means, said once at the top instead of
    /// twelve times down the side.
    private func legend(_ symbol: String, _ tint: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// What a folded version is hiding, so it can be skipped without opening.
    ///
    /// The same three symbols as the legend, rather than the words: a symbol
    /// read once at the top of the page is read for the rest of it, and three
    /// short pairs scan where three phrases have to be parsed. Nought is shown
    /// too — that a version fixed nothing is worth knowing, and a missing
    /// column would only be counted for.
    private func counts(_ release: ReleaseNotes.Release) -> some View {
        HStack(spacing: 11) {
            count("plus", .green, release.added.count)
            count("minus", .secondary, release.removed.count)
            count("wrench.adjustable", .orange, release.fixed.count)
        }
    }

    private func count(_ symbol: String, _ tint: Color, _ number: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(number == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(tint))
                .frame(width: 12)
            Text(ReleaseNotes.string("\(number)개", "\(number)"))
                .font(.subheadline)
                .foregroundStyle(number == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tertiary))
        }
    }

    /// A line of the log: the keyword, and the sentence it is hiding.
    ///
    /// Folded by default. Twelve open paragraphs is a page nobody scans, and
    /// scanning is the whole reason someone opens a changelog.
    private func entry(
        _ item: ReleaseNotes.Entry, symbol: String, tint: Color
    ) -> some View {
        let isOpen = openEntries.contains(item.id)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(Motion.move) {
                    if isOpen { openEntries.remove(item.id) } else { openEntries.insert(item.id) }
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 12)
                    Text(item.title.value)
                        .fontWeight(item.featured ? .bold : .medium)
                        .foregroundStyle(item.featured ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    if let action = item.action {
                        KeyCap(action: action)
                    }
                    if item.featured {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .help(ReleaseNotes.string("이 버전의 핵심 기능", "This version's headline"))
                    }
                    // Where it landed: one chip a device, when it is not just the Mac.
                    if item.devices != [.mac] {
                        ForEach(item.devices) { device in
                            Label(device.label, systemImage: device.symbol)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary.opacity(0.6)))
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isOpen {
                Text(item.detail.value)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
                    .padding(.bottom, item.demo == nil ? 4 : 0)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                if let demo = item.demo {
                    LogDemoView(demo: demo)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - About

    /// The two pages, as sheets on Settings rather than windows of their own:
    /// this is where someone goes when they are looking for how something
    /// works, so it is where the answer should be.
    private var appVersion: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return "—"
        }
        return L("버전 \(version)", "Version \(version)")
    }
}
