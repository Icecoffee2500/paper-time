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
        // Every note, the ones filed in an area (a folder under this one)
        // with the area: it goes to the same folder there.
        let notes = Self.markdown(under: directory, area: "")
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
        for (file, area) in notes {
            let folder = area.isEmpty ? other.directory : other.directory.appending(path: area, directoryHint: .isDirectory)
            try? FileOperations.ensureDirectory(at: folder)
            let landing = folder.appending(path: file.lastPathComponent)
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
        // The areas carried over, empty ones too; the ones left here empty
        // go — a folder of nothing is not a place the reader made twice.
        for area in Self.folders(under: directory, area: "") {
            try? FileOperations.ensureDirectory(at: other.directory.appending(path: area, directoryHint: .isDirectory))
        }
        for area in Self.folders(under: directory, area: "").reversed() {
            let folder = directory.appending(path: area, directoryHint: .isDirectory)
            if (try? FileOperations.visibleContents(of: folder, keys: []))?.isEmpty == true {
                try? manager.removeItem(at: folder)
            }
        }
        // The notes' pictures go with them: the hidden folder beside the
        // notes, each file by its own name — names are never reused, so one
        // already there is that picture.
        let pictures = directory.appending(path: ".assets", directoryHint: .isDirectory)
        if let files = try? manager.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil), !files.isEmpty {
            let landing = other.directory.appending(path: ".assets", directoryHint: .isDirectory)
            try? FileOperations.ensureDirectory(at: landing)
            for file in files {
                let there = landing.appending(path: file.lastPathComponent)
                if manager.fileExists(atPath: there.path(percentEncoded: false)) || (try? manager.copyItem(at: file, to: there)) != nil {
                    try? manager.removeItem(at: file)
                }
            }
        }
        return (moved, kept)
    }

    // MARK: - Areas

    /// How deep areas go: a folder in a folder in a folder is as far as
    /// anybody files thoughts, and a walk with no floor is a walk that can
    /// be led round a symbolic link for ever.
    static let deepest = 6

    /// Every Markdown file under a folder, with the area it is filed in.
    static func markdown(under folder: URL, area: String, depth: Int = 0) -> [(url: URL, area: String)] {
        let here = (try? FileOperations.visibleContents(of: folder, keys: [.isDirectoryKey])) ?? []
        var found: [(url: URL, area: String)] = []
        for url in here {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                guard depth < deepest else { continue }
                let inner = area.isEmpty ? url.lastPathComponent : area + "/" + url.lastPathComponent
                found += markdown(under: url, area: inner, depth: depth + 1)
            } else if url.pathExtension == "md" {
                found.append((url, area))
            }
        }
        return found
    }

    /// Every folder under a folder, as areas, parents before their children.
    static func folders(under folder: URL, area: String, depth: Int = 0) -> [String] {
        guard depth < deepest else { return [] }
        let here = (try? FileOperations.visibleContents(of: folder, keys: [.isDirectoryKey])) ?? []
        var found: [String] = []
        for url in here where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let inner = area.isEmpty ? url.lastPathComponent : area + "/" + url.lastPathComponent
            found.append(inner)
            found += folders(under: url, area: inner, depth: depth + 1)
        }
        return found
    }

    /// The areas of knowledge: every folder under the box, in Finder's order.
    public func areas() -> [String] {
        Self.folders(under: directory, area: "").sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Whether a name can be an area's — one folder's name, not a path.
    public nonisolated static func isAreaName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix(".") && !trimmed.contains("/") && !trimmed.contains(":")
    }

    /// Makes an area — `inside` another one, or at the top.
    public func createArea(named name: String, inside parent: String = "") throws -> String {
        guard isReachable else { throw Unreachable(folder: directory) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAreaName(trimmed) else { throw CocoaError(.fileWriteInvalidFileName) }
        let area = parent.isEmpty ? trimmed : parent + "/" + trimmed
        let folder = directory.appending(path: area, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileOperations.ensureDirectory(at: folder)
        return area
    }

    /// Renames an area's folder. Its notes go with it; nothing is rewritten.
    public func renameArea(_ area: String, to name: String) throws -> String {
        guard isReachable else { throw Unreachable(folder: directory) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAreaName(trimmed) else { throw CocoaError(.fileWriteInvalidFileName) }
        let parent = area.split(separator: "/").dropLast().joined(separator: "/")
        let renamed = parent.isEmpty ? trimmed : parent + "/" + trimmed
        guard renamed != area else { return area }
        let from = directory.appending(path: area, directoryHint: .isDirectory)
        let to = directory.appending(path: renamed, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: to.path(percentEncoded: false)) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: from, to: to)
        for (id, was) in areaOf where was == area || was.hasPrefix(area + "/") {
            areaOf[id] = renamed + was.dropFirst(area.count)
        }
        return renamed
    }

    /// Takes an area away. Its notes are not: they go up to the area it was
    /// in (or to no area), and only then is the folder removed — and only if
    /// nothing else is left in it, since what else is there is not ours.
    public func removeArea(_ area: String) throws -> Int {
        guard isReachable else { throw Unreachable(folder: directory) }
        let folder = directory.appending(path: area, directoryHint: .isDirectory)
        let parent = area.split(separator: "/").dropLast().joined(separator: "/")
        let landing = parent.isEmpty ? directory : directory.appending(path: parent, directoryHint: .isDirectory)
        var moved = 0
        for (file, _) in Self.markdown(under: folder, area: area) {
            let target = landing.appending(path: file.lastPathComponent)
            // A note of the same name already there: the identifier is the
            // name, so two of them is two notes — this one keeps its folder.
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) { continue }
            try FileManager.default.moveItem(at: file, to: target)
            areaOf[file.deletingPathExtension().lastPathComponent] = parent
            moved += 1
        }
        let left = Self.markdown(under: folder, area: area)
        if left.isEmpty {
            // Empty folders under it go with it; other files keep it.
            let others = Self.files(under: folder).filter { $0.pathExtension != "md" }
            if others.isEmpty { try? FileManager.default.removeItem(at: folder) }
        }
        return moved
    }

    static func files(under folder: URL, depth: Int = 0) -> [URL] {
        guard depth < deepest else { return [] }
        let here = (try? FileOperations.visibleContents(of: folder, keys: [.isDirectoryKey])) ?? []
        return here.flatMap { url -> [URL] in
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return files(under: url, depth: depth + 1)
            }
            return [url]
        }
    }

    /// Which area each note was read from or written to, by identifier — so
    /// a note written again goes to its own folder, and a note moved to
    /// another area leaves the old one.
    private var areaOf: [String: String] = [:]

    /// The names of the notes here, without reading any of them.
    public func noteIDs() -> [String] {
        Self.markdown(under: directory, area: "")
            .map { $0.url.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public func loadNotes() -> [Zettel] {
        var areas: [String: String] = [:]
        let notes = Self.markdown(under: directory, area: "").compactMap { url, area -> Zettel? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            var note = ZettelFile.note(
                from: text,
                id: url.deletingPathExtension().lastPathComponent,
                modified: modified
            )
            note.area = area
            areas[note.id] = area
            return note
        }
        areaOf = areas
        return notes.sorted { $0.modified > $1.modified }
    }

    public func saveNote(_ note: Zettel) throws {
        // Before anything else, the empty note included: writing makes the
        // folders on the way, and a chosen folder made again is the second,
        // empty folder `move(into:)` refuses to make.
        guard isReachable else { throw Unreachable(folder: directory) }
        let url = noteURL(note.id, area: note.area)
        let was = areaOf[note.id]
        if note.isEmpty {
            try? FileManager.default.removeItem(at: url)
            if let was, was != note.area { try? FileManager.default.removeItem(at: noteURL(note.id, area: was)) }
            areaOf[note.id] = nil
            return
        }
        try FileOperations.write(Data(ZettelFile.text(of: note).utf8), to: url)
        // Filed somewhere else now: the copy in the old folder goes, once the
        // new one is written.
        if let was, was != note.area {
            try? FileManager.default.removeItem(at: noteURL(note.id, area: was))
        }
        areaOf[note.id] = note.area
    }

    public func deleteNote(_ id: String) throws {
        let url = noteURL(id, area: areaOf[id] ?? "")
        areaOf[id] = nil
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public nonisolated func noteURL(_ id: String, area: String = "") -> URL {
        let folder = area.isEmpty ? directory : directory.appending(path: area, directoryHint: .isDirectory)
        return folder.appending(path: "\(id).md")
    }
}

extension LibraryStore: SlipBox {
    public nonisolated var boxID: URL { root }
}
