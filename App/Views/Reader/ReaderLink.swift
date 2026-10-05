import PDFKit
import PDFReader
import PaperCore
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
            Task { await previous.close() }
        }
        self.session = session
        self.sessionPaperID = paperID
    }
    var selection: PDFSelection?
    /// The formula lasso's catch: a page and a rectangle on it (PDFKit page
    /// coordinates), standing in for the selection while the lasso is out.
    /// `needsOCR` when the rectangle holds no glyphs and the formula is read
    /// off the picture — which takes a second or two, so ⌘L goes through
    /// `lassoAnchor()` rather than `selectionAnchor()`.
    var lasso: (pageIndex: Int, rect: CGRect, needsOCR: Bool)?
    /// Told what a picture's reading has said so far while it reads, and nil
    /// when it is done — the lasso's banner shows it. Set by the reader.
    @ObservationIgnored var onPictureReading: (@MainActor (String?) -> Void)?
    /// Whether the in-document find bar is showing.
    var isFinding = false
    /// A selection the reader should scroll to and highlight. Cleared by the
    /// reader once it has acted on it.
    var scrollRequest: PDFSelection?
    /// A place in the document the reader should reveal: a mark chosen in the
    /// notes list, or a link followed out of a note. Cleared once the reader
    /// has scrolled there.
    var anchorRequest: Anchor?
    /// A place in the document chosen from its table of contents. Cleared
    /// once the reader has gone there.
    var destinationRequest: PDFDestination?
    /// How wide the space between the two pages of a spread is on screen,
    /// while a book is open. Nought otherwise.
    var bookGutter: CGFloat = 0
    /// The page under the reader's eyes, so the slip-box can read along.
    var currentPageIndex = 0
    /// A mark just clicked on the page, so the marks list can show which one.
    var revealedMarkID: UUID?
    /// A passage waiting to be dropped into the note at the cursor.
    var pendingNoteAnchor: NoteAnchor?
    /// The note open in the Notes tab of the inspector.
    ///
    /// Here rather than inside `PaperNotesView`, because the inspector picks
    /// its content with a `switch` and each tab is a branch of its own — so
    /// leaving the Notes tab takes that view out of the tree and SwiftUI
    /// throws its state away. Picking up the pen moves the tab to Tools on its
    /// own, and a note being written during a lecture went back to the list
    /// every time a line was highlighted. This outlives the tab, and there is
    /// one per pane, which is what papers side by side need.
    var openNoteID: String?
    /// Called when the reader this handle belongs to is clicked in — so,
    /// with several papers side by side, the one under the hand becomes the
    /// one the inspector is about.
    @ObservationIgnored var activated: (() -> Void)?

    /// Somewhere on a page, in page coordinates — of this paper, or of the
    /// one named.
    struct Anchor: Equatable {
        var pageIndex: Int
        var rect: CGRect
        var paperID: UUID? = nil
    }

    var hasSelection: Bool { selection?.string?.isEmpty == false }
    /// Whether the PDF view has a place to go back or forward to inside the
    /// paper — a link that was followed. Kept here so the toolbar can grey
    /// its arrows without a hand on the view.
    var canGoBackInDocument = false
    var canGoForwardInDocument = false

    /// The place the current selection points at, ready to be written into a
    /// note. Nil when nothing is selected.
    ///
    /// The words are read the way UltraCopy reads them, not the way PDFKit
    /// hands them over: a line of mathematics quoted into a note used to
    /// arrive as the prose a PDF makes of its symbols — "L(θ) = i λ 2 F i (θ
    /// i − θ ∗ A,i ) 2" — which is not what was on the page and cannot be set
    /// as what was on the page. Now it arrives as `$…$`, and the note draws
    /// the formula.
    ///
    /// And with the shape of the page: the section it came under is a
    /// heading, the equation keeps its own line and its number, the bold
    /// lead-in of a paragraph is still bold, and paragraphs are paragraphs.
    /// The lasso's catch as a note's anchor — read off the page's glyphs,
    /// or, when the rectangle holds none, off its picture (`FormulaOCR`).
    /// Nil when nothing is caught or nothing could be read.
    func lassoAnchor() async -> NoteAnchor? {
        guard let lasso, let session, let page = session.document.page(at: lasso.pageIndex) else { return nil }
        var quoted = MathReader.structured(on: page, rect: lasso.rect).joined(separator: "\n")
        if lasso.needsOCR || quoted.isEmpty {
            #if os(macOS) && canImport(OnnxRuntimeBindings)
            let reading = onPictureReading
            reading?("")
            defer { reading?(nil) }
            let overlay = PictureReading.overlay(of: session, page: lasso.pageIndex)
            guard let read = try? await PictureReading.read(page: page, rect: lasso.rect, overlay: overlay, partial: { text in
                Task { @MainActor in reading?(text) }
            }) else { return nil }
            quoted = read.text
            toastRequest = PictureReading.toast(after: read, copied: false)
            #else
            return nil
            #endif
        } else if let left = MathReader.leftOutSentence() {
            toastRequest = left
        }
        guard !quoted.isEmpty else { return nil }
        return NoteAnchor(pageIndex: lasso.pageIndex, rect: lasso.rect, quotedText: quoted, paperID: sessionPaperID)
    }

    func selectionAnchor() -> NoteAnchor? {
        guard let selection, let session,
              let page = selection.pages.first,
              selection.string?.isEmpty == false
        else { return nil }
        let index = session.document.index(for: page)
        guard index != NSNotFound else { return nil }
        let quoted = MathReader.structured(from: selection).joined(separator: "\n")
        if let left = MathReader.leftOutSentence() { toastRequest = left }
        return NoteAnchor(
            pageIndex: index,
            rect: selection.bounds(for: page),
            quotedText: quoted,
            paperID: sessionPaperID
        )
    }

    /// A line for the reader to say over the page, once — set by something
    /// that is not a view, and cleared by the view that says it.
    var toastRequest: String?

    init() {}
}
