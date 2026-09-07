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
            readingSection(settings: settings)
            aboutSection
        }
        .formStyle(.grouped)
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

    // MARK: - Reading

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
            Text("Papers are stored as ordinary files in the folder you chose — nothing lives only inside this app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return "—"
        }
        return "Version \(version)"
    }
}
