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

    var body: some View {
        #if os(iOS)
        NavigationStack {
            settingsForm
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
        }
        #else
        settingsForm
        #endif
    }

    private var settingsForm: some View {
        let settings = app.settings
        return Form {
            librarySection
            metadataSection(settings: settings)
            bibTeXSection(settings: settings)
            listSection(settings: settings)
            readingSection(settings: settings)
            shortcutsSection
            aboutSection
        }
        .formStyle(.grouped)
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
        ForEach(ShortcutAction.Group.allCases) { group in
            Section(group == .library ? "Keyboard Shortcuts — \(group.rawValue)" : group.rawValue) {
                ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                    LabeledContent(action.title) {
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
                }
                if group == .app {
                    HStack {
                        Spacer()
                        Button("Restore Defaults") { app.resetShortcuts() }
                            .disabled(app.paneShortcuts.isEmpty)
                    }
                }
            }
        }
        #endif
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
