import Foundation
import PaperCore

/// The on-disk shape of a Paper Time library.
///
/// ```
/// <library root>/
/// ├── Attention Is All You Need.pdf     ← your PDFs, under their own names
/// ├── 2403.18293v1.pdf
/// └── .papertime/                        ← everything the app adds, out of sight
///     ├── library.json
///     ├── collections.json
///     └── papers/
///         └── 4F3A1C08-…/
///             ├── meta.json
///             ├── state.json
///             └── ink/p0003.drawing
/// ```
///
/// The PDFs stay where a person would put them, under the names they already
/// had. That is possible because highlights and ink are written into the PDF
/// itself: the file alone carries everything you can see on the page, and the
/// sidecars hold only what the app adds on top — the bibliographic record,
/// reading state, and the pressure-accurate original of each drawing.
public enum LibraryLayout {
    /// Everything the app writes lives under this one hidden folder.
    public static let supportDirectoryName = ".papertime"
    public static let manifestFileName = "library.json"
    public static let collectionsFileName = "collections.json"
    public static let papersDirectoryName = "papers"
    public static let metadataFileName = "meta.json"
    public static let stateFileName = "state.json"
    /// The single note a paper used to have, kept only so an old library can
    /// be read and moved into the notes folder.
    public static let noteFileName = "note.md"
    public static let notesDirectoryName = "notes"
    /// The slip-box: every note in the library, in one folder, because a
    /// thought written while reading one paper is rarely only about it.
    public static func slipBoxURL(inLibrary root: URL) -> URL {
        supportDirectoryURL(inLibrary: root)
            .appending(path: notesDirectoryName, directoryHint: .isDirectory)
    }
    public static let inkDirectoryName = "ink"
    /// The shapes, arrows and text cards drawn on the pages, one small JSON
    /// file per page beside the ink.
    public static let sketchDirectoryName = "sketch"
    /// One small file per device with the marks it made — the fast path
    /// between devices, beside the PDF that is the slow, durable one.
    public static let marksDirectoryName = "marks"
    public static let trashDirectoryName = "Trash"

    public static func supportDirectoryURL(inLibrary root: URL) -> URL {
        root.appending(path: supportDirectoryName, directoryHint: .isDirectory)
    }

    public static func manifestURL(inLibrary root: URL) -> URL {
        supportDirectoryURL(inLibrary: root).appending(path: manifestFileName)
    }

    public static func collectionsURL(inLibrary root: URL) -> URL {
        supportDirectoryURL(inLibrary: root).appending(path: collectionsFileName)
    }

    /// Where the per-paper records live.
    public static func recordsDirectoryURL(inLibrary root: URL) -> URL {
        supportDirectoryURL(inLibrary: root)
            .appending(path: papersDirectoryName, directoryHint: .isDirectory)
    }

    public static func recordURL(forPaper id: UUID, inLibrary root: URL) -> URL {
        recordsDirectoryURL(inLibrary: root)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    public static func trashURL(inLibrary root: URL) -> URL {
        root.appending(path: trashDirectoryName, directoryHint: .isDirectory)
    }

    public static func inkFileName(pageIndex: Int) -> String {
        String(format: "p%04d.drawing", pageIndex)
    }

    public static func pageIndex(fromInkFileName name: String) -> Int? {
        guard name.hasPrefix("p"), name.hasSuffix(".drawing") else { return nil }
        return Int(name.dropFirst().dropLast(".drawing".count))
    }

    public static func sketchFileName(pageIndex: Int) -> String {
        String(format: "p%04d.json", pageIndex)
    }

    public static func pageIndex(fromSketchFileName name: String) -> Int? {
        guard name.hasPrefix("p"), name.hasSuffix(".json") else { return nil }
        return Int(name.dropFirst().dropLast(".json".count))
    }

    /// The name a newly imported PDF takes inside the library.
    ///
    /// The file keeps the name it arrived with. Only a collision forces a
    /// change, and then it gains a numeric suffix the way Finder does, so the
    /// name you recognise is still the name you see.
    public static func availableFileName(
        for originalName: String,
        inLibrary root: URL,
        fileManager: FileManager = .default
    ) -> String {
        let stem = (originalName as NSString).deletingPathExtension
        let ext = (originalName as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"

        var candidate = originalName
        var counter = 2
        while fileManager.fileExists(
            atPath: root.appending(path: candidate).path(percentEncoded: false)
        ) {
            candidate = "\(stem) \(counter)\(suffix)"
            counter += 1
        }
        return candidate
    }
}

/// One paper's record: the folder under `.papertime/papers/` that holds
/// everything about a paper except the PDF itself.
public struct PaperFolder: Hashable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var metadataURL: URL { url.appending(path: LibraryLayout.metadataFileName) }
    public var stateURL: URL { url.appending(path: LibraryLayout.stateFileName) }
    /// What the reader wrote about this paper: one Markdown file per note.
    public var notesDirectoryURL: URL {
        url.appending(path: LibraryLayout.notesDirectoryName, directoryHint: .isDirectory)
    }

    public func noteURL(id: UUID) -> URL {
        notesDirectoryURL.appending(path: "\(id.uuidString).md")
    }

    /// Where a library written before notes were a list kept its one note.
    public var legacyNoteURL: URL { url.appending(path: LibraryLayout.noteFileName) }
    public var inkDirectoryURL: URL {
        url.appending(path: LibraryLayout.inkDirectoryName, directoryHint: .isDirectory)
    }

    public func inkURL(pageIndex: Int) -> URL {
        inkDirectoryURL.appending(path: LibraryLayout.inkFileName(pageIndex: pageIndex))
    }

    public var sketchDirectoryURL: URL {
        url.appending(path: LibraryLayout.sketchDirectoryName, directoryHint: .isDirectory)
    }

    public func sketchURL(pageIndex: Int) -> URL {
        sketchDirectoryURL.appending(path: LibraryLayout.sketchFileName(pageIndex: pageIndex))
    }

    public var marksDirectoryURL: URL {
        url.appending(path: LibraryLayout.marksDirectoryName, directoryHint: .isDirectory)
    }

    public func marksURL(device: String) -> URL {
        marksDirectoryURL.appending(path: "\(device).json")
    }
}

/// Filesystem-safe name generation, still used for the record folders.
public enum Slug {
    public static func make(from raw: String, maxLength: Int) -> String {
        let folded = raw.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil
        )
        var result = ""
        var lastWasSeparator = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator, result.count < maxLength {
                result.append("-")
                lastWasSeparator = true
            }
            if result.count >= maxLength { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }
}
