import InkEngine
import PDFKit
import PDFReader
import PencilKit

/// Reads one highlighter stroke as a mark on the page's text, makes the mark,
/// and says so; or says it is not one and leaves the stroke be.
///
/// Over words it is a highlight fitted to them; run along under the words,
/// it is an underline. The pen never snaps — handwriting is handwriting —
/// and a highlighter in the margin, where there are no words, stays ink too.
/// The same judgement on the iPad's canvas and the Mac's mouse.
@MainActor
enum StrokeSnapper {
    static func snap(_ stroke: PKStroke, on page: PDFPage, session: DocumentSession) -> Bool {
        guard stroke.ink.inkType == .marker else { return false }
        let geometry = PageGeometry(page: page)
        let box = stroke.renderBounds
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY),
        ].map(geometry.pdfPoint(fromCanvas:))
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)

        // The lines of text the stroke touches, or lies just under.
        guard let around = page.selection(for: rect.insetBy(dx: 0, dy: -6)),
              around.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return false }
        let lines = around.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.isFinite && $0.height > 0 }
        guard let line = lines.min(by: { abs($0.midY - rect.midY) < abs($1.midY - rect.midY) }) else { return false }

        // Only the words under the stroke, line by line: a selection run from
        // one end of the stroke to the other follows the text instead and,
        // across a column gap, floods half the page.
        let kind: MarkupDescriptor.Kind
        var pieces: [CGRect] = []
        // A highlighter is wide: one stroke along one line is a box taller
        // than the line, spilling onto the neighbours. Judge by the stroke's
        // core — the band around its centre when it is a line's worth tall,
        // the box less half a nib when it is deliberately taller.
        let core: CGRect = rect.height < line.height * 1.8
            ? CGRect(x: rect.minX, y: rect.midY - line.height * 0.25, width: rect.width, height: line.height * 0.5)
            : rect.insetBy(dx: 0, dy: min(rect.height * 0.3, line.height * 0.6))
        let crossed = lines.filter { $0.maxY > core.minY && $0.minY < core.maxY }
        let isFlat = rect.height < line.height * 0.6
        let sitsLow = rect.midY < line.minY + line.height * 0.28 && rect.midY > line.minY - line.height * 0.7
        if isFlat, sitsLow {
            kind = .underline
            pieces = [CGRect(x: rect.minX, y: line.minY, width: rect.width, height: line.height)]
        } else {
            guard !crossed.isEmpty, rect.height <= line.height * 2.4 * CGFloat(crossed.count) else { return false }
            kind = .highlight
            pieces = crossed.map { CGRect(x: rect.minX, y: $0.minY, width: rect.width, height: $0.height) }
        }
        let span = PDFSelection(document: session.document)
        for piece in pieces {
            if let part = page.selection(for: piece) { span.add(part) }
        }
        guard span.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }

        let color = nearestMarkupColor(to: stroke.ink.color)
        return !session.addMarkup(for: span, kind: kind, color: color).isEmpty
    }

    /// The mark colour nearest an ink, read through Core Graphics so the
    /// answer is the same for an `NSColor` and a `UIColor`.
    static func nearestMarkupColor(to color: PlatformColor) -> MarkupColor {
        guard let converted = color.cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
        ), let parts = converted.components, parts.count >= 3 else { return .yellow }
        return MarkupColor.nearest(red: parts[0], green: parts[1], blue: parts[2])
    }
}
