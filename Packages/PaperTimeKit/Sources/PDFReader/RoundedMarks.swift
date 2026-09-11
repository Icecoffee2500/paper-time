import PDFKit

/// Highlights with rounded ends, drawn by the app over the page.
///
/// The highlight in the file is an ordinary PDF text markup — four corners
/// per line, which is what Preview and everything else will draw as a hard
/// rectangle. The file is not changed here. What changes is how this app
/// paints it: PDFKit is told not to display the highlight, and the view draws
/// it back on itself as a rounded band. A quotation in a note has rounded
/// ends and the accent for its words; the mark on the page it points back to
/// should look like it belongs to the same family.
///
/// A `PDFPage` subclass overriding `draw(with:to:)` was the first attempt, via
/// `PDFDocumentDelegate.classForPage`. Its draw was called — by the bitmap
/// that measures where a line's ink is — and never once by the view: PDFView
/// renders pages through its own path and does not go near that method. The
/// view's `drawPage(_:to:)` is the one it does call.
public enum RoundedMarks {
    /// How round the ends are, as a share of the band's height, and the most
    /// they get. A short line of small type is nearly a capsule; a tall line
    /// carrying an equation stays a rounded box rather than a pill.
    static let rounding: CGFloat = 0.3
    static let maximumRadius: CGFloat = 3.5

    /// The highlights on a page, hidden from PDFKit's own drawing.
    ///
    /// `shouldDisplay` is the Hidden flag, and it is only ever set on the
    /// document in memory: saving re-reads the file and writes the marks from
    /// their descriptors, so nothing of this reaches the PDF.
    public static func takeOver(_ page: PDFPage) -> [PDFAnnotation] {
        let highlights = page.annotations.filter { $0.type == "Highlight" }
        for highlight in highlights where highlight.shouldDisplay {
            highlight.shouldDisplay = false
        }
        return highlights
    }

    /// Draws one highlight, in page space, the way the page would have.
    public static func draw(_ annotation: PDFAnnotation, in context: CGContext) {
        guard let color = annotation.color.usingColorSpace(.sRGB) else { return }
        let isHovered = MarkHover.hovered === annotation
        context.saveGState()
        // Plain paint here; the overlay's layer multiplies the whole result
        // onto the page, so the ink shows through the colour.
        context.setFillColor(
            isHovered ? color.blended(withFraction: 0.3, of: .black)?.cgColor ?? color.cgColor
                      : color.cgColor
        )
        for rect in lineRects(of: annotation) {
            let radius = min(rect.height * rounding, maximumRadius)
            context.addPath(
                CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            )
        }
        context.fillPath()
        context.restoreGState()
    }

    /// The lines a markup covers, put back onto the page from the corners
    /// PDFKit stores relative to the annotation's own box.
    static func lineRects(of annotation: PDFAnnotation) -> [CGRect] {
        guard let quads = annotation.quadrilateralPoints, quads.count >= 4 else {
            return [annotation.bounds]
        }
        let origin = annotation.bounds.origin
        var rects: [CGRect] = []
        for start in stride(from: 0, to: quads.count - 3, by: 4) {
            let corners = (0..<4).map { quads[start + $0].pointValue }
            guard let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(),
                  let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max()
            else { continue }
            let rect = CGRect(x: origin.x + minX, y: origin.y + minY,
                              width: maxX - minX, height: maxY - minY)
            if rect.width > 0.5, rect.height > 0.5 { rects.append(rect) }
        }
        return rects.isEmpty ? [annotation.bounds] : rects
    }
}

/// Which mark the pointer is over, for the view to deepen as it draws.
public enum MarkHover {
    public nonisolated(unsafe) static weak var hovered: PDFAnnotation?
}
