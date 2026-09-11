#if os(macOS)
import AppKit
import PDFKit

/// Crops a document's pages to their content while it is read as a book, so
/// that every paper's spread has the same gutter and the same margins.
///
/// Papers set their margins differently — an ACM two-column page and an
/// arXiv preprint can differ by an inch a side — and in a spread those
/// margins met in the middle, so one paper opened with a canyon between its
/// pages and the next with a slit. The gutter should be the app's, not the
/// paper's. Each page is cropped to a box of one width for the whole
/// document, centred on that page's own text: a journal that shifts its text
/// block outward on odd pages and inward on even ones (PNAS does) keeps its
/// words in the same place on screen either way, and the margins come out
/// equal on both sides of every page. Only the crop box changes, only in
/// memory, and only while the book is open — page coordinates, and so every
/// mark and every anchor, are untouched.
///
/// The box is measured two ways and takes the wider. The text block comes
/// from the lines wide enough to be body text, which leaves out the stamp
/// arXiv runs up the margin and the "Downloaded from …" a journal prints
/// there. The ink comes from a small rendering of the page, columns of dark
/// pixels, which catches what the text misses — a figure set into the outer
/// margin, and every page of a scanned book, which has no text at all. The
/// width is the widest page's, with one landscape table not allowed to widen
/// every margin; the centre is each page's own. Pages are measured as they
/// are turned to, a few ahead, so a six-hundred-page book opens as fast as a
/// six-page paper.
@MainActor
final class BookTrim {
    struct Measure {
        /// The middle of the page's text, or of its ink when it has no text.
        var center: CGFloat
        /// How far the content reaches from that middle, the farther side.
        var halfWidth: CGFloat
        /// Text running up the margin, to be painted out: the crop would
        /// otherwise cut through its letters.
        var stamps: [CGRect]
        /// Guessed from the other pages rather than measured.
        var guessed = false
    }

    let document: PDFDocument
    /// How far the crop stays clear of the content, in page points.
    static let margin: CGFloat = 18

    private(set) var halfWidth: CGFloat = 0
    private var fallbackCenter: CGFloat = 0
    private var measures: [Int: Measure] = [:]
    private var original: [Int: CGRect] = [:]
    private(set) var isApplied = false

    /// The trim in force, for the overlays that paint out the stamps.
    private(set) static weak var active: BookTrim?

    init(document: PDFDocument) {
        self.document = document
    }

    /// Measures pages from across the document and crops every page.
    func apply() {
        guard !isApplied else { return }
        let count = document.pageCount
        guard count > 0 else { return }
        let sampleCount = min(count, 8)
        var sample = Set<Int>()
        for step in 0..<sampleCount {
            sample.insert(sampleCount == 1 ? 0 : step * (count - 1) / (sampleCount - 1))
        }
        for index in sample.sorted() { measure(index) }
        let measured = measures.values.filter { !$0.guessed }
        guard !measured.isEmpty else { return }
        // The widest page's reach, but no wider than a little over what
        // most pages reach: one landscape table must not widen every margin.
        let halves = measured.map(\.halfWidth).sorted()
        halfWidth = min(halves[halves.count - 1], halves[halves.count * 3 / 4] * 1.15)
        let centers = measured.map(\.center).sorted()
        fallbackCenter = centers[centers.count / 2]
        for index in 0..<count { crop(index) }
        isApplied = true
        Self.active = self
    }

    /// Measures pages about to be shown, and crops them on their own centre
    /// where they had been cropped on a guess. Whether any crop changed.
    @discardableResult
    func ensure(_ indices: [Int]) -> Bool {
        guard isApplied else { return false }
        var changed = false
        for index in indices where index >= 0 && index < document.pageCount && (measures[index]?.guessed ?? true) {
            let before = document.page(at: index)?.bounds(for: .cropBox)
            measure(index)
            if measures[index] == nil {
                measures[index] = Measure(center: fallbackCenter, halfWidth: halfWidth, stamps: [], guessed: true)
            }
            crop(index)
            if document.page(at: index)?.bounds(for: .cropBox) != before { changed = true }
        }
        return changed
    }

    /// Puts every page's crop box back.
    func restore() {
        for (index, box) in original {
            document.page(at: index)?.setBounds(box, for: .cropBox)
        }
        original = [:]
        isApplied = false
        if Self.active === self { Self.active = nil }
    }

    /// The stamps to paint out on a page, in page space.
    func stamps(on page: PDFPage) -> [CGRect] {
        guard isApplied else { return [] }
        let index = document.index(for: page)
        guard index != NSNotFound else { return [] }
        return measures[index]?.stamps ?? []
    }

    private func crop(_ index: Int) {
        guard let page = document.page(at: index), page.rotation % 180 == 0 else { return }
        let box = original[index] ?? page.bounds(for: .cropBox)
        original[index] = box
        let center = measures[index]?.center ?? fallbackCenter
        let half = halfWidth + Self.margin
        let left = max(box.minX, center - half), right = min(box.maxX, center + half)
        guard right - left > 40 else { return }
        page.setBounds(CGRect(x: left, y: box.minY, width: right - left, height: box.height), for: .cropBox)
    }

    private func measure(_ index: Int) {
        guard let page = document.page(at: index), let found = Self.measure(page) else { return }
        measures[index] = found
    }

    // MARK: - Measuring a page

    static func measure(_ page: PDFPage) -> Measure? {
        let media = page.bounds(for: .mediaBox)
        guard media.width > 0, media.height > 0 else { return nil }

        // The text block, from the lines wide enough to be lines of a
        // column. A line taller than it is wide runs up the page; the long
        // ones are stamps in the margin, the short ones the axis labels of
        // a figure, which belong to the figure.
        var textMin = CGFloat.greatestFiniteMagnitude, textMax = -CGFloat.greatestFiniteMagnitude
        var wide = 0
        var stamps: [CGRect] = []
        if let text = page.selection(for: media) {
            for line in text.selectionsByLine() {
                let bounds = line.bounds(for: page)
                if bounds.height >= bounds.width {
                    if bounds.height >= media.height * 0.2, bounds.width <= media.width * 0.05 { stamps.append(bounds) }
                    continue
                }
                guard bounds.width > media.width * 0.2 else { continue }
                textMin = min(textMin, bounds.minX)
                textMax = max(textMax, bounds.maxX)
                wide += 1
            }
        }
        let hasText = wide >= 5 && textMax - textMin > media.width * 0.3
        if hasText { stamps = stamps.filter { $0.maxX < textMin || $0.minX > textMax } }

        let ink = inkExtent(of: page, in: media, excluding: stamps)
        let center: CGFloat
        if hasText {
            center = (textMin + textMax) / 2
        } else if let ink {
            center = (ink.reach.lowerBound + ink.reach.upperBound) / 2
        } else {
            return nil
        }
        var half = hasText ? (textMax - textMin) / 2 : 0
        if let ink { half = max(half, center - ink.reach.lowerBound, ink.reach.upperBound - center) }
        guard half > media.width * 0.1 else { return nil }
        // Ink left out of the reach — a journal's black section tab at the
        // page's edge — is painted out too, or the crop would show a sliver
        // of it.
        if let ink {
            stamps += ink.junk.filter { $0.maxX <= ink.reach.lowerBound || $0.minX >= ink.reach.upperBound }
        }
        return Measure(center: center, halfWidth: half, stamps: stamps)
    }

    private struct Ink {
        var reach: ClosedRange<CGFloat>
        /// Ink outside the reach: thin, or thin and at the edge.
        var junk: [CGRect]
    }

    /// How far across the page the ink reaches, from a small rendering: the
    /// columns with dark pixels in them, in runs, with the thin isolated
    /// ones — a speck, a scanner's edge — left out. Drawn at two fifths of
    /// the size and read with a lenient threshold, because a hairline
    /// stroke shrunk that far is a light grey, not a black.
    private static func inkExtent(of page: PDFPage, in media: CGRect, excluding stamps: [CGRect]) -> Ink? {
        let scale: CGFloat = 0.4
        let width = Int(media.width * scale), height = Int(media.height * scale)
        guard width > 8, height > 8,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -media.minX, y: -media.minY)
        page.draw(with: .mediaBox, to: context)
        context.setFillColor(gray: 1, alpha: 1)
        for stamp in stamps { context.fill(stamp.insetBy(dx: -2, dy: -2)) }
        context.restoreGState()
        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)

        // Dark columns make the reach; anything not white, read leniently,
        // makes the junk outside it — a journal's grey section tab is too
        // light to count as ink and would otherwise show as a sliver at the
        // crop's edge.
        var dark = [Int](repeating: 0, count: width), faint = [Int](repeating: 0, count: width)
        for y in 2..<(height - 2) {
            let row = y * width
            for x in 0..<width {
                let value = pixels[row + x]
                if value < 190 { dark[x] += 1 }
                if value < 235 { faint[x] += 1 }
            }
        }
        let threshold = max(2, height / 150)
        func runs(of columns: [Int]) -> [(start: Int, end: Int)] {
            var found: [(start: Int, end: Int)] = []
            var x = 0
            while x < width {
                guard columns[x] >= threshold else { x += 1; continue }
                var end = x
                while end + 1 < width, columns[end + 1] >= threshold { end += 1 }
                found.append((x, end))
                x = end + 1
            }
            // Runs a small gap apart are one thing — a figure and its axis
            // labels.
            let gap = max(2, Int(CGFloat(width) * 0.025))
            var merged: [(start: Int, end: Int)] = []
            for run in found {
                if let last = merged.last, run.start - last.end <= gap {
                    merged[merged.count - 1].end = run.end
                } else {
                    merged.append(run)
                }
            }
            return merged
        }
        // A thin run on its own, or a thin one at the very edge, is nothing.
        let thin = max(2, Int(CGFloat(width) * 0.03))
        let edge = max(1, Int(CGFloat(width) * 0.02))
        let kept = runs(of: dark).filter { run in
            let span = run.end - run.start + 1
            return span >= thin && (!(run.start <= edge || run.end >= width - 1 - edge) || span >= width * 15 / 100)
        }
        guard let first = kept.first, let last = kept.last else { return nil }
        // Where on the page the junk's ink is, so only that is painted out.
        let junk: [CGRect] = runs(of: faint).filter { $0.end < first.start || $0.start > last.end }.compactMap { run in
            var top = 0, bottom = height
            for y in 0..<height {
                let row = y * width
                if (run.start...run.end).contains(where: { pixels[row + $0] < 235 }) { top = max(top, y + 1); bottom = min(bottom, y) }
            }
            guard top > bottom else { return nil }
            // Rows run down the bitmap; the page's y runs up it.
            return CGRect(
                x: media.minX + CGFloat(run.start) / scale - 1.5, y: media.minY + CGFloat(height - top) / scale - 1.5,
                width: CGFloat(run.end - run.start + 1) / scale + 3, height: CGFloat(top - bottom) / scale + 3
            )
        }
        return Ink(reach: (media.minX + CGFloat(first.start) / scale)...(media.minX + CGFloat(last.end + 1) / scale), junk: junk)
    }
}

/// Paints out the text that runs up a page's margin while the book's crop
/// would otherwise cut through it — the arXiv stamp, a journal's download
/// notice — in the paper's own white, so that under the dimmed tint it is
/// inverted along with the paper and stays invisible.
final class MarginMaskView: NSView {
    private weak var page: PDFPage?

    init(page: PDFPage) {
        self.page = page
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let page, let trim = BookTrim.active, trim.document === page.document,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0 else { return }
        let scale = bounds.width / box.width
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for stamp in trim.stamps(on: page) {
            let rect = stamp.insetBy(dx: -3, dy: -3)
            context.fill(CGRect(
                x: (rect.minX - box.minX) * scale, y: (rect.minY - box.minY) * scale,
                width: rect.width * scale, height: rect.height * scale
            ))
        }
    }
}
#endif
