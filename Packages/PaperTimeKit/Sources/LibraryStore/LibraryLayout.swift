import Foundation
import PaperCore

/// The on-disk shape of a Paper Time library.
///
/// ```
/// <library root>/
/// ├── library.json
/// ├── collections.json
/// └── papers/
///     └── 4F3A1C08-attention-is-all-you-need/
///         ├── attention-is-all-you-need.pdf
///         ├── meta.json
///         ├── state.json
///         └── ink/
///             └── p0003.drawing
/// ```
///
/// The folder name is fixed when the paper is imported and is never changed
/// afterwards, even when better metadata arrives. Renaming a folder reads as
/// delete-plus-create to most sync engines, which risks losing annotations for
/// a purely cosmetic gain; the display name comes from `meta.json` instead.
public enum LibraryLayout {
    public static let manifestFileName = "library.json"
    public static let collectionsFileName = "collections.json"
    public static let papersDirectoryName = "papers"
    public static let metadataFileName = "meta.json"
    public static let stateFileName = "state.json"
    public static let inkDirectoryName = "ink"
    /// Per-device scratch space. Never synced content the app depends on.
    public static let supportDirectoryName = ".papertime"

    public static func manifestURL(inLibrary root: URL) -> URL {
        root.appending(path: manifestFileName)
    }

    public static func collectionsURL(inLibrary root: URL) -> URL {
        root.appending(path: collectionsFileName)
    }

    public static func papersDirectoryURL(inLibrary root: URL) -> URL {
        root.appending(path: papersDirectoryName, directoryHint: .isDirectory)
    }

    public static func inkFileName(pageIndex: Int) -> String {
        String(format: "p%04d.drawing", pageIndex)
    }

    public static func pageIndex(fromInkFileName name: String) -> Int? {
        guard name.hasPrefix("p"), name.hasSuffix(".drawing") else { return nil }
        let digits = name.dropFirst().dropLast(".drawing".count)
        return Int(digits)
    }

    /// Builds the immutable folder name for a newly imported paper.
    public static func folderName(id: UUID, originalFileName: String) -> String {
        let prefix = id.uuidString.prefix(8)
        let stem = (originalFileName as NSString).deletingPathExtension
        let slug = Slug.make(from: stem, maxLength: 60)
        return slug.isEmpty ? String(prefix) : "\(prefix)-\(slug)"
    }

    /// Builds the PDF's file name inside its folder.
    ///
    /// A readable name matters because the user will meet this file in Finder,
    /// the Files app, and any other PDF app they open it with.
    public static func pdfFileName(originalFileName: String) -> String {
        let stem = (originalFileName as NSString).deletingPathExtension
        let slug = Slug.make(from: stem, maxLength: 80)
        return slug.isEmpty ? "paper.pdf" : "\(slug).pdf"
    }
}

/// Filesystem-safe name generation.
public enum Slug {
    /// Lowercases, strips accents, and replaces every run of non-alphanumerics
    /// with a single hyphen. Keeps the result short enough that the full path
    /// stays well inside the limits of every sync provider we support.
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

/// A single paper's folder, with the paths that live inside it.
public struct PaperFolder: Hashable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var metadataURL: URL { url.appending(path: LibraryLayout.metadataFileName) }
    public var stateURL: URL { url.appending(path: LibraryLayout.stateFileName) }
    public var inkDirectoryURL: URL {
        url.appending(path: LibraryLayout.inkDirectoryName, directoryHint: .isDirectory)
    }

    public func inkURL(pageIndex: Int) -> URL {
        inkDirectoryURL.appending(path: LibraryLayout.inkFileName(pageIndex: pageIndex))
    }

    public func documentURL(fileName: String) -> URL {
        url.appending(path: fileName)
    }

    /// Finds the PDF without trusting `meta.json`, used when the metadata file
    /// is missing or unreadable.
    public func discoverDocumentURL() -> URL? {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents?.first { $0.pathExtension.lowercased() == "pdf" }
    }
}
