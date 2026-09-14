import LibraryStore
import SwiftUI
import UniformTypeIdentifiers

/// First-run setup: pick the folder that holds the library.
///
/// This replaces an account. The folder can live in iCloud Drive, Google Drive,
/// or anywhere else the Files app can reach; pointing a second device at the
/// same folder is what "syncing" means here.
struct LibrarySetupView: View {
    @Environment(AppModel.self) private var app
    @State private var isChoosingFolder = false
    @State private var suggestions: [FolderSuggestion] = []

    struct FolderSuggestion: Identifiable {
        let id = UUID()
        let url: URL
        let provider: CloudProvider
        var name: String { url.lastPathComponent }
    }

    var body: some View {
        // Centred when it fits, scrollable when Dynamic Type makes it taller
        // than the window — the behaviour every first-run screen in the system
        // apps has.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("Choose a Library Folder")
                            .font(.title.bold())
                        Text(
                            """
                            Paper Time keeps your papers as ordinary files. \
                            Pick a folder in iCloud Drive, Google Drive, or anywhere else, \
                            and choose the same folder on your other devices to keep them in step.
                            """
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    }

                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Suggested")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(suggestions) { suggestion in
                                Button {
                                    Task { await app.adopt(folderAt: suggestion.url) }
                                } label: {
                                    Label {
                                        VStack(alignment: .leading) {
                                            Text(suggestion.name)
                                            Text(suggestion.provider.displayName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: suggestion.provider.symbolName)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                            }
                        }
                        .frame(maxWidth: 460, alignment: .leading)
                    }

                    Button("Choose Folder…") { isChoosingFolder = true }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)

                    Text("Your papers stay in that folder. Deleting the app never deletes them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #if os(iOS)
                    // Said before the picker spins forever: Google's Files
                    // provider on iOS lets a file be picked but not a folder,
                    // and the picker shows "Loading" for as long as you wait.
                    Text("On iPhone and iPad, choose a folder in iCloud Drive or on this device. Google Drive's Files provider does not allow a folder to be chosen here — its picker loads without end — so a Google Drive library can be used from the Mac, and the same papers kept in iCloud Drive for these devices.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    #endif
                }
                .padding(40)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { await app.adopt(folderAt: url) }
        }
        .task { suggestions = Self.findSuggestions() }
    }

    /// Offers folders the user already syncs, so the common case is one tap.
    /// Only locations this process can already see are listed; anything else
    /// has to come through the picker so the app is granted access to it.
    static func findSuggestions() -> [FolderSuggestion] {
        var found: [FolderSuggestion] = []
        let manager = FileManager.default

        let iCloud = manager.url(forUbiquityContainerIdentifier: nil)?
            .appending(path: "Documents", directoryHint: .isDirectory)
        if let iCloud, manager.fileExists(atPath: iCloud.path(percentEncoded: false)) {
            found.append(FolderSuggestion(url: iCloud, provider: .iCloudDrive))
        }

        #if os(macOS)
        let cloudStorage = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let contents = (try? manager.contentsOfDirectory(
            at: cloudStorage,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents {
            let provider = CloudProvider.detect(at: url)
            guard provider != .local, provider != .unknown else { continue }
            found.append(FolderSuggestion(url: url, provider: provider))
        }
        #endif
        return found
    }
}
