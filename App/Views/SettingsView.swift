import Bibliography
import LibraryStore
import SwiftUI

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
    @FocusState private var searchIsFocused: Bool
    /// Which log lines are showing what they mean.
    @State private var openEntries: Set<String> = []

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
            List(Pane.allCases, selection: $pane) { page in
                Label(page.rawValue, systemImage: page.symbol).tag(page)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 172)
            .padding(.top, 8)

            // No rule between them. The sidebar's own faint ground is what
            // separates the two columns — the same way nothing else in this
            // app is divided by a drawn line.
            settingsForm
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
        .frame(width: 760, height: 540)
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
            case .about: aboutSection
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

        Section {
            // The whole capsule takes the click, not just the letters. A
            // plain text field is exactly as big as its text, so an empty one
            // had almost nothing to hit — the field worked and could not be
            // reached, which is the same as not working.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField(
                    "",
                    text: $shortcutQuery,
                    prompt: Text("Search by name or key").foregroundStyle(.tertiary)
                )
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($searchIsFocused)
                if !shortcutQuery.isEmpty {
                    Button {
                        shortcutQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
            .contentShape(Capsule())
            .onTapGesture { searchIsFocused = true }
            if matchingActions.isEmpty {
                Text("Nothing is on that key, and nothing is called that.")
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

    // MARK: - Log

    /// What each version brought, newest first.
    private var logSection: some View {
        ForEach(ReleaseNotes.releases) { release in
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(release.added) { item in
                        entry(item, symbol: "plus", tint: .green)
                    }
                    ForEach(release.fixed) { item in
                        entry(item, symbol: "wrench.adjustable", tint: .orange)
                    }
                }
            } header: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(release.version).font(.headline)
                    Text(release.date.value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(release.note.value)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
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
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
