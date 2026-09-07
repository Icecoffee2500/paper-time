import PDFKit
import PDFReader
import SwiftUI

/// A handle the detail column holds on whatever paper is open.
///
/// The reader owns its document session, but the toolbar lives one level up so
/// that every control in the window can be declared in one place and appear in
/// a deliberate order. This carries the two things those controls need — the
/// open session and the current text selection — without moving the reader's
/// own state out of it.
@MainActor
@Observable
final class ReaderLink {
    var session: DocumentSession?
    /// Which paper the open session belongs to.
    ///
    /// The reader is rebuilt whenever SwiftUI feels like it, and opening the
    /// same paper twice would leave two documents in play: one shown by the
    /// PDF view, one saved by the session. Marks made on the first would be
    /// written from the second, which is to say lost. Keeping the session here,
    /// keyed by paper, means a paper is opened exactly once.
    private(set) var sessionPaperID: UUID?
    /// The paper currently being opened, so two readers built for the same
    /// selection do not both read the file.
    var loadingPaperID: UUID?

    func session(for paperID: UUID) -> DocumentSession? {
        sessionPaperID == paperID ? session : nil
    }

    /// Takes over as the open paper, writing out whatever was open before.
    func adopt(_ session: DocumentSession, for paperID: UUID) {
        if let previous = self.session, previous !== session {
            Task { await previous.flush() }
        }
        self.session = session
        self.sessionPaperID = paperID
    }
    var selection: PDFSelection?
    /// Whether the in-document find bar is showing.
    var isFinding = false
    /// A selection the reader should scroll to and highlight. Cleared by the
    /// reader once it has acted on it.
    var scrollRequest: PDFSelection?
    /// A place in the document the reader should reveal: a mark chosen in the
    /// notes list. Cleared once the reader has scrolled there.
    var anchorRequest: Anchor?

    /// Somewhere on a page, in page coordinates.
    struct Anchor: Equatable {
        var pageIndex: Int
        var rect: CGRect
    }

    var hasSelection: Bool { selection?.string?.isEmpty == false }

    init() {}
}
