import Foundation
import PaperCore
import PDFKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A passage of the open paper that a note quotes: the way back from the
/// page to the quotation.
///
/// ⌘L puts a passage into a note with a link to the page; this is the same
/// link read the other way. Nothing is stored for it — the notes are read
/// (`QuotedPassages`) — so it is exactly as current as they are.
struct QuoteLink: Hashable {
    var noteID: String
    /// The note's name, for the rule's tooltip.
    var noteTitle: String
    var modified: Date
    var passage: QuotedPassage

    var pageIndex: Int { passage.anchor.pageIndex }
    var rect: CGRect { passage.anchor.rect }

    /// Every passage of a paper that the notes quote, the newest note's
    /// last — so where two notes quote one passage, the newer is on top.
    @MainActor
    static func of(paper: UUID, in notes: NotesModel) -> [QuoteLink] {
        notes.notes
            .flatMap { note in
                QuotedPassages.passages(in: note, of: paper).map {
                    QuoteLink(noteID: note.id, noteTitle: note.displayTitle, modified: note.modified, passage: $0)
                }
            }
            .sorted { $0.modified < $1.modified }
    }
}

/// A paper's quote links, with the paper they were read for — so a reader
/// that has moved on to another paper does not draw the last one's.
struct QuoteLinks: Equatable {
    var paperID: UUID?
    var links: [QuoteLink] = []
}

/// Reads a paper's quote links off the notes, and again whenever they
/// change. While a note is typed into they change with every key, so this
/// waits for the typing to pause, and hands on only an answer that differs.
struct QuoteLinkWatcher: View {
    let notes: NotesModel
    let paperID: UUID
    @Binding var links: QuoteLinks

    var body: some View {
        Color.clear
            .task(id: "\(paperID)|\(notes.revision)") {
                if links.paperID == paperID { try? await Task.sleep(for: .milliseconds(300)) }
                guard !Task.isCancelled else { return }
                let fresh = QuoteLinks(paperID: paperID, links: QuoteLink.of(paper: paperID, in: notes))
                if fresh != links { links = fresh }
            }
    }
}

#if os(macOS)
/// The rule beside a quoted passage, in page space: the note's quotation
/// rule (`NoteQuoteBar`), standing in the margin of the column the passage
/// is set in, so the two read as one quotation seen from either side.
struct QuoteBar: Equatable {
    var link: QuoteLink
    /// The rule itself.
    var rect: CGRect
    /// What a click takes: the rule and a little either side of it.
    var target: CGRect

    static let width: CGFloat = 2
    /// Between the rule and the words of the column.
    static let gap: CGFloat = 4

    /// The rules for a page's passages. A rule stands left of the column,
    /// not left of the passage: a passage that starts in the middle of a
    /// line put it between two words. PDFKit's line knows where its column
    /// begins — it keeps the two columns of a paper apart.
    static func bars(for links: [QuoteLink], on page: PDFPage) -> [QuoteBar] {
        let box = page.bounds(for: .cropBox)
        return links.compactMap { link in
            let passage = link.rect
            guard passage.isFinite, passage.width > 0, passage.height > 0, passage.intersects(box) else { return nil }
            var left = passage.minX
            let reach = min(passage.height / 2, 6)
            for y in [passage.maxY - reach, passage.minY + reach] {
                let point = CGPoint(x: passage.minX + 1, y: y)
                guard let line = page.selectionForLine(at: point)?.bounds(for: page), line.isFinite,
                      line.height > 0, line.minY - 1 <= y, y <= line.maxY + 1,
                      line.minX <= passage.minX + 1, line.maxX >= passage.minX,
                      // A line that reaches across to the other column is
                      // not one this rule can stand beside.
                      passage.minX - line.minX < box.width / 2
                else { continue }
                left = min(left, line.minX)
            }
            let x = max(box.minX + 1, left - gap - width)
            let rect = CGRect(x: x, y: passage.minY + 1, width: width, height: max(passage.height - 2, width))
            return QuoteBar(link: link, rect: rect, target: rect.insetBy(dx: -5, dy: -1))
        }
    }
}

/// The rules beside this page's quoted passages, over the page.
///
/// Composited plainly rather than multiplied like the marks: the rule is
/// the accent, and multiplied it would darken into whatever is under it.
final class QuoteLinkOverlayView: NSView, NSViewToolTipOwner {
    private weak var page: PDFPage?
    private let bars: () -> [QuoteBar]
    private let hovered: () -> QuoteBar?

    nonisolated(unsafe) private static var byPage: [ObjectIdentifier: Weak] = [:]
    private struct Weak { weak var view: QuoteLinkOverlayView? }

    init(page: PDFPage, bars: @escaping () -> [QuoteBar], hovered: @escaping () -> QuoteBar?) {
        self.page = page
        self.bars = bars
        self.hovered = hovered
        super.init(frame: .zero)
        Self.byPage[ObjectIdentifier(page)] = Weak(view: self)
    }

    required init?(coder: NSCoder) { nil }

    static func refresh(_ page: PDFPage) {
        guard let view = byPage[ObjectIdentifier(page)]?.view else { return }
        view.needsDisplay = true
        view.placeToolTips()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        placeToolTips()
    }

    /// From the page's space into this view's, which covers the page's
    /// crop box — the box PDFKit shows.
    private func viewRect(_ rect: CGRect) -> CGRect? {
        guard let page else { return nil }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0, bounds.width > 0 else { return nil }
        let sx = bounds.width / box.width, sy = bounds.height / box.height
        return CGRect(x: (rect.minX - box.minX) * sx, y: (rect.minY - box.minY) * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }

    override func draw(_ dirtyRect: NSRect) {
        let hover = hovered()
        for bar in bars() {
            let lit = hover?.link == bar.link && hover?.rect == bar.rect
            // A shade wider and the full accent under the pointer, the way
            // a mark deepens.
            let drawn = lit ? bar.rect.insetBy(dx: -0.5, dy: 0) : bar.rect
            guard let rect = viewRect(drawn) else { continue }
            let color = lit ? NSColor.controlAccentColor.withAlphaComponent(0.9) : NoteQuoteBar.bar(anchored: true)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2).fill()
        }
    }

    /// Each rule says whose it is when the pointer rests on it.
    private func placeToolTips() {
        removeAllToolTips()
        for bar in bars() {
            guard let rect = viewRect(bar.target) else { continue }
            addToolTip(rect, owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let bar = bars().last(where: { viewRect($0.target)?.contains(point) == true }) else { return "" }
        let title = bar.link.noteTitle
        return title.isEmpty ? L("노트에서 보기", "Show in Note") : L("노트에서 보기 · \(title)", "Show in Note · \(title)")
    }
}
#endif
