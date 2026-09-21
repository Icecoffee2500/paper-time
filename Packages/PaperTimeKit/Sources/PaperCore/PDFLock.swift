import Foundation
import PDFKit

/// Why a PDF will not open.
///
/// A PDF can be encrypted in three ways, and only one of them is something a
/// reader can do anything about. The standard handler takes a password, and
/// every PDF library implements it. The other two hand the key to somebody
/// else: a certificate in the reader's own keychain, or a rights server at
/// the company that published the file. A file locked those ways is not
/// damaged and not ours to open — Acrobat opens it because Acrobat carries
/// the plug-in that asks the rights service for the key, and no amount of
/// work here substitutes for that.
///
/// Saying which of the three it is matters more than it sounds. A reader that
/// shows an empty page teaches somebody that the app is broken; one that says
/// "this is your company's protection, and Acrobat is the way in" ends the
/// question in a sentence.
public enum PDFLock: Equatable, Sendable {
    /// Opens with a password somebody can type.
    case password
    /// Held by a rights service or a certificate. The name is the handler as
    /// it is written in the file; the interface turns it into a sentence.
    case rights(String)

    /// The handlers worth naming, in the order they are looked for.
    public static let knownHandlers = [
        "MicrosoftIRMServices",
        "FoxitIRM",
        "Adobe.PubSec",
        "EBX_HANDLER",
    ]

    /// What the `/Encrypt` dictionary's handler is, read from the bytes.
    ///
    /// The handler's name is one of the few things in an encrypted PDF that
    /// cannot itself be encrypted — a reader has to know who to ask before it
    /// can ask — so it sits in the file as plain text, and looking for it
    /// beats parsing a document nothing here can parse yet.
    public static func rightsHandler(in data: Data) -> String? {
        knownHandlers.first { data.range(of: Data($0.utf8)) != nil }
    }

    /// What is wrong with a document, if anything.
    ///
    /// Three cases, and the third is the one that cost an afternoon. PDFKit
    /// does not refuse a file encrypted by a handler it has never heard of:
    /// it opens it, reports it as neither locked nor encrypted, and draws the
    /// cipher — coloured rules where the text was, and a title like
    /// "OìáCµC˘-Ü˘°" in the library. So a document that opened is not proof of
    /// anything. What settles it is a rights handler named in the file *and*
    /// not one readable character in the front of the document. A paper about
    /// rights management has these words in its prose and pages full of text,
    /// so it is never mistaken for one of these.
    public static func of(document: PDFDocument?, data: Data) -> PDFLock? {
        guard let document else { return rightsHandler(in: data).map(PDFLock.rights) }
        if document.isLocked {
            return rightsHandler(in: data).map(PDFLock.rights) ?? .password
        }
        guard let handler = rightsHandler(in: data), isUnreadable(document) else { return nil }
        return .rights(handler)
    }

    /// The same, for a document that came from a file: the bytes are read
    /// only if they are needed, and only the ends of the file.
    ///
    /// `/Encrypt` is pointed at from the trailer and written near it, so the
    /// ends find it. Reading a whole twenty-megabyte paper to learn that it
    /// is not encrypted is the kind of cost that turns an import into a wait.
    public static func of(document: PDFDocument?, fileAt url: URL?) -> PDFLock? {
        if let document, !document.isLocked, !isUnreadable(document) { return nil }
        return of(document: document, data: url.flatMap(ends(of:)) ?? Data())
    }

    /// Whether the front of the document holds no text at all.
    ///
    /// Three pages, because a paper can open on a plate or a cover sheet. A
    /// scanned paper has no text either, which is why this is never asked on
    /// its own — only about a file that names a rights handler.
    private static func isUnreadable(_ document: PDFDocument) -> Bool {
        guard document.pageCount > 0 else { return true }
        for index in 0..<min(3, document.pageCount) {
            let text = document.page(at: index)?.string ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        }
        return true
    }

    /// The first and last 256 KB, which is where a trailer lives.
    private static func ends(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let window = 256 * 1024
        let head = (try? handle.read(upToCount: window)) ?? Data()
        guard let size = try? handle.seekToEnd() else { return head }
        guard size > UInt64(window) else { return head }
        try? handle.seek(toOffset: size - UInt64(window))
        return head + ((try? handle.readToEnd()) ?? Data())
    }
}

/// Thrown when the file is fine and the door is shut.
///
/// Separate from `FileOperations.Failure` because the interface treats it
/// differently: a locked paper gets a field to type a password into, not a
/// "Try Again" button that will do exactly what it just did.
public struct Locked: LocalizedError, Equatable, Sendable {
    public let url: URL
    public let lock: PDFLock

    public init(url: URL, lock: PDFLock) {
        self.url = url
        self.lock = lock
    }

    public var errorDescription: String? {
        switch lock {
        case .password: "\(url.lastPathComponent) is locked with a password."
        case let .rights(handler): "\(url.lastPathComponent) is protected by \(handler)."
        }
    }
}
