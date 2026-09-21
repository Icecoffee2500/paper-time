#if os(macOS)
import AppKit
import SwiftUI

/// Files and folders handed to the app by the desktop.
///
/// Dropping a folder on the app's icon, or on its window, is the shortest
/// path there is to "read the papers in here" — shorter than a first-run
/// screen, and the one people try first. It matters most for a folder the
/// app cannot reach on its own: a Google Drive or Dropbox folder lives under
/// `~/Library/CloudStorage`, which a sandboxed app may not look inside until
/// somebody hands it over. Dropping it *is* handing it over — Launch Services
/// grants the app the same access the open panel would, so the folder opens
/// and keeps opening on later launches, from the bookmark stored for it.
///
/// A PDF dropped the same way is imported into the library that is open.
final class OpenWithFinder: NSObject, NSApplicationDelegate {
    /// Set once the model exists. Weak: the delegate outlives nothing, and a
    /// strong reference here would be the app's second owner of its model.
    @MainActor static weak var model: AppModel?

    /// What arrived before the model did. The first drop on a cold app opens
    /// the delegate before the window, and dropping the reason the app
    /// launched would be a strange thing to do.
    @MainActor private static var waiting: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            guard let model = Self.model else {
                Self.waiting.append(contentsOf: urls)
                return
            }
            Task { await Self.take(urls, into: model) }
        }
    }

    /// Called by the window once the model is alive.
    @MainActor static func flush(into model: AppModel) {
        self.model = model
        let pending = waiting
        waiting = []
        guard !pending.isEmpty else { return }
        Task { await take(pending, into: model) }
    }

    @MainActor private static func take(_ urls: [URL], into model: AppModel) async {
        var folders: [URL] = []
        var documents: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { folders.append(url) } else { documents.append(url) }
        }
        // One folder is a library; the papers in it come with it.
        if let folder = folders.first {
            await model.adopt(folderAt: folder)
        }
        guard !documents.isEmpty, let library = model.library else { return }
        _ = await library.importDocuments(at: documents)
    }
}
#endif
