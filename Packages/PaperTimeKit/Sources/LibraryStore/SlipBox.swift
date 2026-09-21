import Foundation
import PaperCore

/// Somewhere notes are kept.
///
/// There are two kinds of place. A library folder keeps the notes about its
/// own papers, beside them, so the folder is whole wherever it goes. And the
/// app keeps the notes that are about no paper at all — a loose thought, a
/// map, a draft — because those belong to the person rather than to any one
/// folder, and a folder is a thing you connect and disconnect.
public protocol SlipBox: Sendable {
    /// Which box this is. Boxes are told apart by it, so a note goes back to
    /// the one it came from.
    nonisolated var boxID: URL { get }

    func loadNotes() async -> [Zettel]
    func saveNote(_ note: Zettel) async throws
    func deleteNote(_ id: String) async throws
}

/// The app's own box: the notes that are about no paper.
///
/// A plain folder of Markdown in Application Support — the same file shape as
/// the notes beside the papers, so one can be dragged into the other and
/// nothing is lost. It does not travel between machines the way a library
/// folder in a cloud drive does; that is the price of not living in a folder
/// you might disconnect.
public actor LooseNotes: SlipBox {
    public nonisolated let directory: URL
    public nonisolated var boxID: URL { directory }

    public init(directory: URL) {
        self.directory = directory
    }

    /// Where the app keeps them on this machine.
    public static func inApplicationSupport(named name: String = "Notes") -> LooseNotes {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return LooseNotes(directory: base.appending(path: name, directoryHint: .isDirectory))
    }

    public func loadNotes() -> [Zettel] {
        let urls = (try? FileOperations.visibleContents(
            of: directory, keys: [.contentModificationDateKey]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return ZettelFile.note(
                    from: text,
                    id: url.deletingPathExtension().lastPathComponent,
                    modified: modified
                )
            }
            .sorted { $0.modified > $1.modified }
    }

    public func saveNote(_ note: Zettel) throws {
        let url = noteURL(note.id)
        if note.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileOperations.write(Data(ZettelFile.text(of: note).utf8), to: url)
    }

    public func deleteNote(_ id: String) throws {
        let url = noteURL(id)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public nonisolated func noteURL(_ id: String) -> URL {
        directory.appending(path: "\(id).md")
    }
}

extension LibraryStore: SlipBox {
    public nonisolated var boxID: URL { root }
}
