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
                        Text(L("라이브러리 폴더 고르기", "Choose a Library Folder"))
                            .font(.title.bold())
                        Text(
                            L(
                                """
                                Paper Time은 논문을 평범한 파일로 둔다. \
                                iCloud Drive, Google Drive, 아니면 어디든 폴더 하나를 고르고, \
                                다른 기기에서도 같은 폴더를 고르면 서로 맞춰진다.
                                """,
                                """
                                Paper Time keeps your papers as ordinary files. \
                                Pick a folder in iCloud Drive, Google Drive, or anywhere else, \
                                and choose the same folder on your other devices to keep them in step.
                                """
                            )
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    }

                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("권하는 폴더", "Suggested"))
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

                    Button(L("폴더 고르기…", "Choose Folder…")) { isChoosingFolder = true }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)

                    Text(L("논문은 그 폴더에 그대로 있다. 앱을 지워도 논문은 지워지지 않는다.", "Your papers stay in that folder. Deleting the app never deletes them."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #if os(iOS)
                    // Said before the picker spins forever: Google's Files
                    // provider on iOS lets a file be picked but not a folder,
                    // and the picker shows "Loading" for as long as you wait.
                    Text(L("아이폰과 아이패드에서는 iCloud Drive나 이 기기 안의 폴더를 고른다. Google Drive의 파일 제공자로는 여기서 폴더를 고를 수 없다 — 고르는 창이 '로드 중'에서 멈춘다 — 그래서 Google Drive 라이브러리는 맥에서 쓰고, 이 기기들에서는 같은 논문을 iCloud Drive에 둔다.",
                           "On iPhone and iPad, choose a folder in iCloud Drive or on this device. Google Drive's Files provider does not allow a folder to be chosen here — its picker loads without end — so a Google Drive library can be used from the Mac, and the same papers kept in iCloud Drive for these devices."))
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
