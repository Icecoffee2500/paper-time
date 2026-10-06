import Foundation
import InkEngine
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
    /// The note's name, for the tooltip.
    var noteTitle: String
    var modified: Date
    var passage: QuotedPassage
    /// The quotation as the note writes it — the words the page's text is
    /// searched for, to tint the passage and nothing round it.
    var quotation: String

    var pageIndex: Int { passage.anchor.pageIndex }
    var rect: CGRect { passage.anchor.rect }

    /// Every passage of a paper that the notes quote, the newest note's
    /// last — so where two notes quote one passage, the newer is on top.
    @MainActor
    static func of(paper: UUID, in notes: NotesModel) -> [QuoteLink] {
        notes.notes
            .flatMap { note in
                let body = note.body as NSString
                return QuotedPassages.passages(in: note, of: paper).map {
                    let quote = NSMaxRange($0.quote) <= body.length ? body.substring(with: $0.quote) : ""
                    return QuoteLink(noteID: note.id, noteTitle: note.displayTitle, modified: note.modified, passage: $0, quotation: quote)
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

/// How much of the accent a quoted passage's wash takes on its page, at
/// rest and under the pointer: enough to find the passage at a glance, and
/// little enough that a highlight under it keeps its own colour. Portable's
/// `QUOTE_WASH` and `--quote-wash` are the same two.
enum QuoteWashShare {
    static let rest: CGFloat = 0.18
    static let lit: CGFloat = 0.3
}

#if os(macOS)
/// A quoted passage on its page, tinted: the words ⌘L put into a note,
/// in a pale wash of the accent.
///
/// It was a rule in the margin first — the note's quotation rule, seen from
/// the page's side — and a rule beside a column says nothing about where in
/// the column the quotation starts: beside a slide's line it read as the
/// whole line quoted when only its last words were. Tinted, the passage is
/// exactly what was quoted, in the shape a highlight has, so it reads as a
/// mark that leads somewhere.
struct QuoteWash: Equatable {
    var link: QuoteLink
    /// The passage's lines in page space, fitted to their letters the way a
    /// highlight's are — or, where its box holds no words at all (a scan),
    /// the box.
    var lines: [CGRect]

    /// Whether a point on the page is on the passage.
    func contains(_ point: CGPoint) -> Bool {
        lines.contains { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// How round the lines' ends are: a highlight's (`RoundedMarks`).
    static func radius(of line: CGRect) -> CGFloat { min(line.height * 0.3, 3.5) }

    /// The accent, most of the way to white — multiplied onto the page like
    /// a mark, so the letters keep their black. Deeper under the pointer.
    static func fill(lit: Bool) -> CGColor {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let share = lit ? QuoteWashShare.lit : QuoteWashShare.rest
        func mixed(_ part: CGFloat) -> CGFloat { 1 - share + share * part }
        return CGColor(srgbRed: mixed(accent.redComponent), green: mixed(accent.greenComponent),
                       blue: mixed(accent.blueComponent), alpha: 1)
    }

    /// The washes for a page's passages, worked out together: their lines
    /// are fitted to the letters off one rendering of the page.
    static func washes(for links: [QuoteLink], on page: PDFPage) -> [QuoteWash] {
        let box = page.bounds(for: .cropBox)
        let shown = links.filter {
            $0.rect.isFinite && $0.rect.width > 0 && $0.rect.height > 0 && $0.rect.intersects(box)
        }
        let passages = shown.map { passage(of: $0, on: page) }
        var fitted = TextMarkupWriter.fittedLines(of: passages.compactMap { $0 }, on: page).makeIterator()
        return zip(shown, passages).map { link, passage in
            let region = link.rect
            // Never outside the box the passage was quoted from.
            let within = region.insetBy(dx: -2, dy: -2)
            let lines = (passage == nil ? [] : fitted.next() ?? []).compactMap { line -> CGRect? in
                let kept = line.intersection(within)
                return kept.isNull || kept.width < 0.5 || kept.height < 0.5 ? nil : kept
            }
            return QuoteWash(link: link, lines: lines.isEmpty ? [region] : lines)
        }
    }

    /// The quoted words as a selection: the text the passage's box holds,
    /// narrowed to where the quotation's words are in it. A box round two
    /// lines of a column runs from margin to margin, and a passage that
    /// starts in the middle of a line would otherwise be tinted from the
    /// margin. Where the words are not found — a formula the lasso caught
    /// and the note holds as LaTeX the page's text cannot be matched to —
    /// the lines the box was drawn round: fitted to their letters, they
    /// stay off the next line, which PDFKit's box round a displayed
    /// formula reaches into. Nil when the box holds no text.
    static func passage(of link: QuoteLink, on page: PDFPage) -> PDFSelection? {
        let region = link.rect
        guard let rough = page.selection(for: region), let string = page.string as NSString? else { return nil }
        // The lines the box was drawn round: their middles inside it. A
        // neighbour's descenders can reach into it.
        var ranges: [NSRange] = []
        for line in rough.selectionsByLine() {
            let bounds = line.bounds(for: page)
            guard bounds.isFinite, !bounds.isNull, bounds.height > 0,
                  bounds.midY >= region.minY - 1, bounds.midY <= region.maxY + 1
            else { continue }
            for index in 0..<line.numberOfTextRanges(on: page) {
                let range = line.range(at: index, on: page)
                guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= string.length else { continue }
                ranges.append(range)
            }
        }
        guard !ranges.isEmpty else { return nil }
        ranges.sort { $0.location < $1.location }
        var text = ""
        var length = 0
        var pieces: [(offset: Int, range: NSRange)] = []
        for range in ranges {
            pieces.append((length, range))
            let words = string.substring(with: range) + "\n"
            text += words
            length += (words as NSString).length
        }
        let span = QuotedPassages.span(of: link.quotation, in: text) ?? 0..<length
        // From the text back to the page: within a line, one for one; on the
        // break after it, the line's end.
        func onPage(_ offset: Int) -> Int {
            var answer = pieces[0].range.location
            for piece in pieces where piece.offset <= offset {
                answer = piece.range.location + min(offset - piece.offset, piece.range.length)
            }
            return answer
        }
        let start = onPage(span.lowerBound), end = onPage(span.upperBound)
        guard end > start else { return nil }
        return page.selection(for: NSRange(location: start, length: end - start))
    }
}

/// The washes over this page's quoted passages.
///
/// Multiplied onto the page like the marks: pale as it is, a wash laid on
/// plainly would grey the letters under it. Each wash is filled in one go,
/// so where its lines touch the colour does not double, and where two notes
/// quote one passage the newer covers the older instead of deepening it.
final class QuoteLinkOverlayView: NSView, NSViewToolTipOwner {
    private weak var page: PDFPage?
    private let washes: () -> [QuoteWash]
    private let hovered: () -> QuoteWash?

    nonisolated(unsafe) private static var byPage: [ObjectIdentifier: Weak] = [:]
    private struct Weak { weak var view: QuoteLinkOverlayView? }

    init(page: PDFPage, washes: @escaping () -> [QuoteWash], hovered: @escaping () -> QuoteWash?) {
        self.page = page
        self.washes = washes
        self.hovered = hovered
        super.init(frame: .zero)
        wantsLayer = true
        layer?.compositingFilter = "multiplyBlendMode"
        layer?.isOpaque = false
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
        guard let page, let context = NSGraphicsContext.current?.cgContext else { return }
        let all = washes()
        guard !all.isEmpty else { return }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return }
        let hover = hovered()
        context.saveGState()
        context.scaleBy(x: bounds.width / box.width, y: bounds.height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        // The one under the pointer last, over any other on its words.
        for wash in all.filter({ $0 != hover }) + all.filter({ $0 == hover }) {
            let path = CGMutablePath()
            for line in wash.lines {
                let radius = QuoteWash.radius(of: line)
                path.addRoundedRect(in: line, cornerWidth: radius, cornerHeight: radius)
            }
            context.addPath(path)
            context.setFillColor(QuoteWash.fill(lit: wash == hover))
            context.fillPath()
        }
        context.restoreGState()
    }

    /// Each passage says whose it is when the pointer rests on it.
    private func placeToolTips() {
        removeAllToolTips()
        for wash in washes() {
            for line in wash.lines {
                guard let rect = viewRect(line) else { continue }
                addToolTip(rect, owner: self, userData: nil)
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let wash = washes().last(where: { wash in wash.lines.contains { viewRect($0)?.contains(point) == true } })
        else { return "" }
        let title = wash.link.noteTitle
        return title.isEmpty ? L("노트에서 보기", "Show in Note") : L("노트에서 보기 · \(title)", "Show in Note · \(title)")
    }
}
#endif
