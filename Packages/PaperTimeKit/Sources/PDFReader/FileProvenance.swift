import CryptoKit
import Foundation
import LibraryStore
import PaperCore

/// Where a paper's file stands in relation to the one that was imported.
///
/// The record keeps the SHA-256 of the file as it arrived (`importDigest`)
/// and its length then (`byteSize`), and neither is ever refreshed. Since
/// marks are appended rather than written over, those two numbers answer the
/// question exactly: a file whose digest still matches is the original; one
/// whose first `byteSize` bytes still hash to it is the original with marks
/// after it; one where neither holds was written out by something else —
/// PDFKit, Preview, another reader — and its text may not be what the author
/// set. Fonts and producer strings cannot tell these apart (most originals
/// already carry a Quartz producer); the digest can.
public enum FileProvenance: Equatable, Sendable {
    /// The file is the one that was imported, byte for byte.
    case pristine
    /// The imported bytes, followed by `tail` bytes of appended marks.
    case appended(tail: Int)
    /// Neither: another program wrote the file out again since import.
    case rewritten
    /// The record has no digest to compare against.
    case unknown

    /// Classifies file bytes against the record. One pass over the data:
    /// the hasher is copied at the record's length, so the prefix and the
    /// whole are digested together.
    public static func classify(_ data: Data, importDigest: String, byteSize: Int64) -> FileProvenance {
        let wanted = importDigest.lowercased()
        guard wanted.count == 64, wanted.allSatisfy(\.isHexDigit) else { return .unknown }
        let prefixLength = Int(clamping: byteSize)
        var hasher = SHA256()
        if prefixLength > 0, prefixLength < data.count {
            hasher.update(data: data.prefix(prefixLength))
            let atPrefix = hasher
            if hex(atPrefix.finalize()) == wanted { return .appended(tail: data.count - prefixLength) }
            hasher.update(data: data.suffix(from: prefixLength))
        } else {
            hasher.update(data: data)
        }
        return hex(hasher.finalize()) == wanted ? .pristine : .rewritten
    }

    /// The same, read from disk through the usual coordinated read.
    public static func classify(fileAt url: URL, meta: PaperMeta) throws -> FileProvenance {
        classify(try FileOperations.read(contentsOf: url), importDigest: meta.file.importDigest, byteSize: meta.file.byteSize)
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// For the probes: one word per case.
    public var name: String {
        switch self {
        case .pristine: "pristine"
        case let .appended(tail): "appended(+\(tail))"
        case .rewritten: "rewritten"
        case .unknown: "unknown"
        }
    }
}

/// A file's size and modification date — enough to say whether it is the
/// same file it was a moment ago without reading it.
public struct FileStamp: Equatable, Sendable {
    public var size: Int64
    public var modified: Date

    public init?(url: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let size = values.fileSize,
              let modified = values.contentModificationDate
        else { return nil }
        self.size = Int64(size)
        self.modified = modified
    }
}

/// The bytes a paper's marks are appended after: their length and digest.
///
/// Compaction folds every revision since the base into one, and for that it
/// has to know where the base ends. When the file is the original plus
/// appends, the record already says (`byteSize`, `importDigest`). When it is
/// not — a file PDFKit had rewritten before saves became incremental, or one
/// brought in from another reader — the session writes this down the first
/// time it appends anything, and the base is whatever the file was at that
/// moment. It lives as a sidecar in the record folder rather than as a field
/// in `meta.json`: the record's bytes are shared with the Windows and Linux
/// build byte for byte, and a key that build does not know would turn every
/// record it rewrote into a cloud conflict.
public struct PDFBase: Codable, Equatable, Sendable {
    public var length: Int
    public var digest: String

    public init(length: Int, digest: String) {
        self.length = length
        self.digest = digest
    }

    /// Whether `data` still begins with this base.
    public func fits(_ data: Data) -> Bool {
        guard length > 0, length <= data.count else { return false }
        return FileProvenance.hex(SHA256.hash(data: data.prefix(length))) == digest.lowercased()
    }

    /// The base for a file: the sidecar if one was written and still fits,
    /// otherwise the record's own numbers if those still fit. Nil when
    /// neither does — there is then no version of this file that is known
    /// to be all its own.
    public static func find(for data: Data, in folder: PaperFolder, meta: PaperMeta) -> PDFBase? {
        if let recorded = load(from: folder), recorded.fits(data) { return recorded }
        let fromRecord = PDFBase(length: Int(clamping: meta.file.byteSize), digest: meta.file.importDigest)
        return fromRecord.fits(data) ? fromRecord : nil
    }

    public static func load(from folder: PaperFolder) -> PDFBase? {
        try? FileOperations.decode(PDFBase.self, at: folder.pdfBaseURL)
    }

    public func save(to folder: PaperFolder) throws {
        try FileOperations.encodeAndWrite(self, to: folder.pdfBaseURL)
    }

    /// Writes `data` down as the base — unless a base is already recorded.
    /// Called just before the first append, with the file as it then is.
    public static func recordIfAbsent(_ data: Data, in folder: PaperFolder) {
        guard load(from: folder) == nil else { return }
        try? PDFBase(length: data.count, digest: FileProvenance.hex(SHA256.hash(data: data))).save(to: folder)
    }
}

public extension PaperFolder {
    /// `.papertime/papers/<id>/pdf/base.json`: see `PDFBase`.
    var pdfBaseURL: URL {
        url.appending(path: "pdf", directoryHint: .isDirectory).appending(path: "base.json")
    }
}
