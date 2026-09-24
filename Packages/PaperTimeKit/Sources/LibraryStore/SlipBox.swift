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

    /// The folder, when the reader chose one. Held so its security scope
    /// outlives this call — a sandboxed app reaches a folder somebody picked
    /// only while something is still holding the scope open.
    private nonisolated let place: LibraryLocation?

    public init(directory: URL) {
        self.directory = directory
        self.place = nil
    }

    /// A folder the reader picked, so the loose notes can live where they
    /// choose — in a cloud folder, say, where they follow them between
    /// machines.
    public init(at place: LibraryLocation) {
        self.directory = place.url
        self.place = place
    }

    /// Whether this is a folder somebody chose, rather than the app's own.
    public nonisolated var isChosen: Bool { place != nil }

    /// Whether the folder is there to be written to.
    ///
    /// Only a chosen folder can be away — an unplugged disk, a cloud drive
    /// that was signed out of — and one that has been moved to the Trash is
    /// away as well: a bookmark follows its folder there, and notes written
    /// into the Trash are notes on their way out.
    public nonisolated var isReachable: Bool {
        guard isChosen else { return true }
        var isDirectory: ObjCBool = false
        let path = directory.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        return !directory.pathComponents.contains(".Trash")
    }

    /// Thrown instead of writing into a chosen folder that is not there.
    public struct Unreachable: Error, Sendable {
        public let folder: URL
    }

    /// Where the app keeps them on this machine, until told otherwise.
    public static func inApplicationSupport(named name: String = "Notes") -> LooseNotes {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return LooseNotes(directory: base.appending(path: name, directoryHint: .isDirectory))
    }

    /// Takes the notes with it.
    ///
    /// Choosing a new folder for notes that are about no paper has to move
    /// them, or they are simply gone from the reader's point of view — the box
    /// is the notes. Every `.md` is copied across and then removed here; a name
    /// already taken in the new folder is left alone and kept here, because the
    /// one thing that must not happen is writing over a note.
    ///
    /// Unless what is there is this very file, byte for byte. That is the
    /// reader who copied the folder into the cloud by hand before choosing
    /// the copy, and a note that is already where it is going has moved: left
    /// here as well, every one of them would have been reported as stuck and
    /// kept in the app's folder for good.
    public func move(into other: LooseNotes) -> (moved: Int, kept: Int) {
        let manager = FileManager.default
        guard directory.standardizedFileURL != other.directory.standardizedFileURL else { return (0, 0) }
        let here = (try? FileOperations.visibleContents(of: directory, keys: [])) ?? []
        let notes = here.filter { $0.pathExtension == "md" }
        // Nothing to carry, nothing to ask of the other folder — which may be
        // in a cloud drive, where even "is it there" is a round trip.
        guard !notes.isEmpty else { return (0, 0) }
        // A folder somebody chose is never made here. Made again where it
        // used to be — a disk that is not plugged in, a drive signed out of —
        // it is a second, empty folder of the same name, and the notes moved
        // into it are notes the real one never sees.
        guard other.isReachable else { return (0, notes.count) }
        try? FileOperations.ensureDirectory(at: other.directory)
        var moved = 0
        var kept = 0
        for file in notes {
            let landing = other.directory.appending(path: file.lastPathComponent)
            if manager.fileExists(atPath: landing.path(percentEncoded: false)) {
                if manager.contentsEqual(
                    atPath: file.path(percentEncoded: false),
                    andPath: landing.path(percentEncoded: false)
                ) {
                    try? manager.removeItem(at: file)
                    moved += 1
                } else {
                    kept += 1
                }
                continue
            }
            do {
                try manager.copyItem(at: file, to: landing)
                try? manager.removeItem(at: file)
                moved += 1
            } catch {
                kept += 1
            }
        }
        return (moved, kept)
    }

    /// The names of the notes here, without reading any of them.
    public func noteIDs() -> [String] {
        ((try? FileOperations.visibleContents(of: directory, keys: [])) ?? [])
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
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
        // Before anything else, the empty note included: writing makes the
        // folders on the way, and a chosen folder made again is the second,
        // empty folder `move(into:)` refuses to make.
        guard isReachable else { throw Unreachable(folder: directory) }
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
