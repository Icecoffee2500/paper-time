import InkEngine
import PDFKit

/// The app's own drawing of the marks on a page.
///
/// The marks in the file are ordinary PDF text markups — a highlight is four
/// corners per line, an underline a rectangle PDFKit fills along its bottom —
/// which is what Preview and everything else will draw, squarely. The file is
/// not changed here. What changes is how this app paints them: PDFKit is told
/// not to display each one (in memory only; saving re-reads the file and
/// writes the marks from their descriptors), and the page overlay draws them
/// back on itself. Highlights become rounded bands, pale enough for the ink
/// to stay black; underlines and strikes become lines dark enough to be seen.
/// A quotation in a note has rounded ends and the accent for its words, and
/// the mark on the page it points back to should look like family.
///
/// A `PDFPage` subclass overriding `draw(with:to:)` was the first attempt.
/// Its draw was called — by the bitmap that measures where a line's ink is —
/// and never once by the view: PDFView renders pages through its own path.
public enum RoundedMarks {
    /// The kinds this takes over from PDFKit.
    public static let kinds: Set<String> = ["Highlight", "Underline", "StrikeOut"]

    /// Whether a band is laid over the page translucently rather than
    /// multiplied onto it. The Mac multiplies the overlay's layer; UIKit
    /// ignores that filter, and an opaque pale band hid the words under it.
    public nonisolated(unsafe) static var blendsByAlpha = false

    /// How round a highlight's ends are, as a share of its height, and the
    /// most they get. A short line of small type is nearly a capsule; a tall
    /// line carrying an equation stays a rounded box rather than a pill.
    static let rounding: CGFloat = 0.3
    static let maximumRadius: CGFloat = 3.5

    /// The marks on a page, hidden from PDFKit's own drawing.
    ///
    /// `shouldDisplay` is the Hidden flag, and it is only ever set on the
    /// document in memory.
    public static func takeOver(_ page: PDFPage) -> [PDFAnnotation] {
        let marks = page.annotations.filter { kinds.contains($0.type ?? "") }
        for mark in marks where mark.shouldDisplay {
            mark.shouldDisplay = false
        }
        return marks
    }

    /// Draws one mark, in page space. The overlay's layer multiplies the
    /// result onto the page, so a pale band still lets the ink through and a
    /// dark line only gets darker.
    public static func draw(_ annotation: PDFAnnotation, in context: CGContext) {
        guard let color = Tone(annotation.color) else { return }
        let isHovered = MarkHover.hovered === annotation
        context.saveGState()
        switch annotation.type {
        case "Highlight": drawHighlight(annotation, color: color, hovered: isHovered, in: context)
        case "Underline": drawLine(annotation, color: color, hovered: isHovered, along: .bottom, in: context)
        case "StrikeOut": drawLine(annotation, color: color, hovered: isHovered, along: .middle, in: context)
        default: break
        }
        context.restoreGState()
    }

    /// A rounded band, lighter than the colour the file names.
    ///
    /// At full strength the highlighter colours multiplied the black of the
    /// type down with them and a marked line was harder to read than an
    /// unmarked one, which is backwards. Under the pointer the band gets
    /// lighter still and a thin edge in the true colour, so what is about to
    /// be pressed is the most legible line on the page rather than the least.
    private static func drawHighlight(
        _ annotation: PDFAnnotation, color: Tone, hovered: Bool, in context: CGContext
    ) {
        var fill = color.blended(toward: 1, by: hovered ? 0.55 : 0.35)
        if Self.blendsByAlpha {
            fill = color
            fill.alpha = hovered ? 0.3 : 0.42
        }
        let path = CGMutablePath()
        for rect in lineRects(of: annotation) {
            let radius = min(rect.height * rounding, maximumRadius)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        }
        context.addPath(path)
        context.setFillColor(fill.cgColor)
        context.fillPath()
        if hovered {
            context.addPath(path)
            context.setStrokeColor(color.blended(toward: 0, by: 0.15).cgColor)
            context.setLineWidth(0.9)
            context.strokePath()
        }
    }

    private enum LinePosition { case bottom, middle }

    /// An underline or a strike, darker than the colour the file names.
    ///
    /// A line is thin and has no area to carry a colour, so the pale tint that
    /// suits a band leaves it barely there. Deepened, and thicker under the
    /// pointer, in the colour itself.
    private static func drawLine(
        _ annotation: PDFAnnotation, color: Tone, hovered: Bool,
        along position: LinePosition, in context: CGContext
    ) {
        let ink = hovered ? color : color.blended(toward: 0, by: 0.3)
        context.setStrokeColor(ink.cgColor)
        context.setLineCap(.round)
        for rect in lineRects(of: annotation) {
            let thickness = max(1.0, rect.height * (hovered ? 0.13 : 0.085))
            context.setLineWidth(thickness)
            let y: CGFloat = switch position {
            case .bottom: rect.minY + thickness / 2
            case .middle: rect.midY
            }
            context.move(to: CGPoint(x: rect.minX + thickness / 2, y: y))
            context.addLine(to: CGPoint(x: rect.maxX - thickness / 2, y: y))
            context.strokePath()
        }
    }

    /// A colour as four numbers, the same on every platform, that can be
    /// blended toward white or black.
    struct Tone {
        var red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat

        init?(_ color: PlatformColor) {
            guard let converted = color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
                  let parts = converted.components, parts.count >= 3
            else { return nil }
            red = parts[0]; green = parts[1]; blue = parts[2]; alpha = parts.count > 3 ? parts[3] : 1
        }

        func blended(toward grey: CGFloat, by fraction: CGFloat) -> Tone {
            var tone = self
            tone.red += (grey - red) * fraction
            tone.green += (grey - green) * fraction
            tone.blue += (grey - blue) * fraction
            return tone
        }

        var cgColor: CGColor {
            CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
        }
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
            let corners: [CGPoint] = (0..<4).map { quads[start + $0].platformPoint }
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

/// Which mark the pointer is over, for the view to redraw as it draws.
public enum MarkHover {
    public nonisolated(unsafe) static weak var hovered: PDFAnnotation?
}
