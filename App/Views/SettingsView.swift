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
        NavigationStack {
            settingsForm
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
        }
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
                ForEach(Pane.allCases) { page in
                    Button {
                        pane = page
                    } label: {
                        Label(page.rawValue, systemImage: page.symbol)
                            .foregroundStyle(pane == page ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: Corner.row, style: .continuous)
                                    .fill(pane == page ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: 172)
            .padding(.top, 14)

            // One hairline, and only here. Two columns of the same shade need
            // something to say where one stops; the rule that had to go was
            // the one across the top, which divided nothing. Fainter than a
            // `Divider`, which at this length reads as a drawn border.
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)

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
            // Stops the page drawing up behind the traffic lights. A scroll
            // view near the top of a full-height window extends itself into
            // the titlebar and insets its content instead, which is right
            // until something is scrolled: then the paragraph that has gone
            // past the top is still drawn, over the title. Covering it is not
            // on — a material laid over the ground blurs the same desktop
            // twice and comes out milky white — so the column keeps its
            // drawing inside itself.
            .clipped()
            .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
        }
        .frame(width: 760, height: 540)
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

    private var settingsForm: some View {
        let settings = app.settings
        return Form {
            #if os(macOS)
            switch pane {
            case .library: librarySection
            case .metadata: metadataSection(settings: settings)
            case .bibtex: bibTeXSection(settings: settings)
            case .reading:
                listSection(settings: settings)
                readingSection(settings: settings)
            case .shortcuts: shortcutsSection
            case .log: logSection
            case .about: EmptyView()
            }
            #else
            librarySection
            metadataSection(settings: settings)
            bibTeXSection(settings: settings)
            listSection(settings: settings)
            readingSection(settings: settings)
            shortcutsSection
            aboutSection
            #endif
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog(
            "Change Library Folder?",
            isPresented: $showsChangeFolderConfirmation,
            titleVisibility: .visible
        ) {
            Button("Change Folder", role: .destructive) {
                app.forgetLibrary()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This doesn't delete anything. Your papers stay exactly where they are — you'll just choose a folder again, on this device."
            )
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        Section("Library") {
            LabeledContent("Folder") {
                Text(app.library?.location.url.path(percentEncoded: false) ?? "Not Connected")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if let provider = app.library?.location.provider {
                LabeledContent("Synced Via") {
                    Label(provider.displayName, systemImage: provider.symbolName)
                        .accessibilityLabel("Synced via \(provider.displayName)")
                }
            }
            Button("Change Library Folder…") {
                showsChangeFolderConfirmation = true
            }
        }
    }

    // MARK: - Metadata

    private func metadataSection(settings: AppSettings) -> some View {
        Section {
            Toggle("Resolve Metadata on Import", isOn: Bindable(settings).resolvesMetadataOnImport)
            LabeledContent("On-Device Extraction") {
                Label {
                    Text(app.library?.onDeviceModelMessage ?? "Open a library to check availability.")
                } icon: {
                    Image(systemName: "info.circle")
                        .accessibilityLabel("Information")
                }
            }

            TextField(
                "Contact Email",
                text: Bindable(settings).metadataContactEmail,
                prompt: Text("optional")
            )
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            #endif
            .autocorrectionDisabled()
        } header: {
            Text("Metadata")
        } footer: {
            Text(
                """
                Crossref and OpenAlex give faster, more reliable service to \
                requests that identify a contact address. Leaving this empty \
                still works; lookups are just slower when many papers resolve \
                at once. Your address is sent only to those services.
                """
            )
        }
    }

    // MARK: - BibTeX

    private func bibTeXSection(settings: AppSettings) -> some View {
        Section("BibTeX") {
            Picker("Preprint Style", selection: Bindable(settings).preferredPreprintStyle) {
                ForEach(BibTeXExportOptions.PreprintStyle.allCases, id: \.rawValue) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            Toggle("Protect Case in Titles", isOn: Bindable(settings).protectsCase)
            Toggle("Include Unverified Records in Export", isOn: Bindable(settings).includesUnverifiedInExport)
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
            Text("Under the Title")
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
                     ? ReleaseNotes.string("그런 키도, 그런 이름도 없다.", "Nothing is on that key, and nothing is called that.")
                     : ReleaseNotes.string("\(shortcutQuery)에는 아무것도 없다.", "Nothing is on \(shortcutQuery)."))
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
                                        .help("Set by macOS")
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
                    Button("Restore Defaults") { app.resetShortcuts() }
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
        Section("Reading") {
            Picker("Page Layout", selection: Bindable(settings).readerPageMode) {
                Text("Continuous").tag("continuous")
                Text("Single Page").tag("singlePage")
                Text("Book").tag("book")
            }
            Picker("Page Tint", selection: Bindable(settings).readerTint) {
                Text("None").tag("none")
                Text("Sepia").tag("sepia")
                Text("Dim").tag("dim")
            }
        }
    }

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
                    "칸을 누른 다음 키 조합을 누르면, 그 키를 가진 기능이 나온다.",
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
                    Text(ReleaseNotes.string("버전과 항목은 눌러서 펼친다", "Versions and entries open when clicked"))
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
                        withAnimation(.snappy(duration: 0.22)) {
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
                withAnimation(.snappy(duration: 0.2)) {
                    if isOpen { openEntries.remove(item.id) } else { openEntries.insert(item.id) }
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 12)
                    Text(item.title.value)
                        .fontWeight(.medium)
                    if let action = item.action {
                        KeyCap(action: action)
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

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Paper Time", value: appVersion)
            Button(ReleaseNotes.string("Paper Time 소개 다시 보기…", "What's New in Paper Time…")) { showsReleaseNotes = true }
            Button(ReleaseNotes.string("모든 기능과 단축키…", "All Features and Keys…")) { showsFeatureLog = true }
            Text("Papers are stored as ordinary files in the folder you chose — nothing lives only inside this app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// The two pages, as sheets on Settings rather than windows of their own:
    /// this is where someone goes when they are looking for how something
    /// works, so it is where the answer should be.
    private var appVersion: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return "—"
        }
        return "Version \(version)"
    }
}
