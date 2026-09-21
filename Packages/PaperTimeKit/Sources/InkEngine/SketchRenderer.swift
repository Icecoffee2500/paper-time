import CoreGraphics
import CoreText
import Foundation

/// Sets the words of a sketch: measures them, wraps them, and hands back the
/// lines with where each one sits — Core Text only, so the same file of text
/// comes out the same size on the Mac, the iPad and in the PDF's copy.
public enum SketchTypesetter {
    public struct Line {
        public let line: CTLine
        /// The line's left edge, from the block's left edge.
        public let x: CGFloat
        /// The baseline, measured down from the block's top.
        public let baseline: CGFloat
        public let width: CGFloat
    }

    public struct Layout {
        public var lines: [Line]
        public var size: CGSize
    }

    /// The system's own face, which every device has and which sets Korean
    /// beside Latin without being asked.
    public static func font(_ size: SketchStyle.TextSize) -> CTFont { font(points: size.points) }

    public static func font(points: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, points, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, points, nil)
    }

    /// The space between the words and the edge of the card they sit on.
    public static let padding: CGFloat = 5

    /// Lays the text out, wrapped to a width when one is given and as one
    /// long line otherwise, and says how big the block came out.
    public static func layout(
        _ text: String, size: SketchStyle.TextSize, color: CGColor, width: CGFloat? = nil,
        centered: Bool = false
    ) -> Layout {
        layout(text, points: size.points, color: color, width: width, align: centered ? .center : .left)
    }

    public static func layout(
        _ text: String, points: CGFloat, color: CGColor, width: CGFloat? = nil,
        align: SketchStyle.TextAlign = .left
    ) -> Layout {
        let font = font(points: points)
        let attributed = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: color,
            ]
        )
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let column = width.map { max($0, 4) } ?? 100_000
        let tall: CGFloat = 100_000
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: column, height: tall), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var result: [Line] = []
        var widest: CGFloat = 0
        var bottom: CGFloat = 0
        for (line, origin) in zip(lines, origins) {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            // The trailing whitespace a wrapped line ends in is not width.
            let trailing = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            let measured = max(advance - trailing, 0)
            let baseline = tall - origin.y
            result.append(Line(line: line, x: origin.x, baseline: baseline, width: measured))
            widest = max(widest, measured)
            bottom = max(bottom, baseline + descent)
        }
        let blockWidth = width ?? widest
        switch align {
        case .left: break
        case .center:
            result = result.map { Line(line: $0.line, x: (blockWidth - $0.width) / 2, baseline: $0.baseline, width: $0.width) }
        case .right:
            result = result.map { Line(line: $0.line, x: blockWidth - $0.width, baseline: $0.baseline, width: $0.width) }
        }
        return Layout(lines: result, size: CGSize(width: blockWidth, height: bottom))
    }

    /// How big a block of text is, alone on the page, plus its padding.
    public static func cardSize(for text: String, size: SketchStyle.TextSize, width: CGFloat? = nil) -> CGSize {
        cardSize(for: text, points: size.points, width: width)
    }

    public static func cardSize(for text: String, points: CGFloat, width: CGFloat? = nil) -> CGSize {
        let inner = width.map { $0 - padding * 2 }
        let block = layout(text, points: points, color: CGColor(gray: 0, alpha: 1), width: inner).size
        return CGSize(width: block.width + padding * 2, height: block.height + padding * 2)
    }

    /// The box a text card takes for its words: as wide as its longest line
    /// when it sizes to its width, and as tall as its lines at the width it
    /// was given otherwise. Anchored at its top-left corner, which is where
    /// the eye has it while typing.
    public static func fittedRect(for element: SketchElement) -> CGRect {
        let r = element.rect
        let size: CGSize
        switch element.sizing {
        case .autoWidth:
            let natural = cardSize(for: element.text, points: element.style.points)
            size = CGSize(width: max(natural.width, 24), height: natural.height)
        case .autoHeight:
            let width = max(r.width, 24)
            size = CGSize(width: width, height: cardSize(for: element.text, points: element.style.points, width: width).height)
        }
        return CGRect(x: r.minX, y: r.maxY - size.height, width: size.width, height: size.height)
    }
}

/// Draws sketch elements into a Core Graphics context whose coordinates are
/// the page's — origin at the bottom left, y going up — so one renderer
/// serves the Mac's overlay, the iPad's, and anything else that has a page.
public enum SketchRenderer {
    public struct Options: Sendable {
        /// The context is the page's, but flipped (a UIKit view): glyphs
        /// have to be turned back the right way up.
        public var flipsText = false
        /// How much of a fill's own alpha to keep. Multiplied onto the paper
        /// a wash reads at full strength; laid over it by alpha it wants
        /// the alpha the colour carries.
        public var fillAlphaScale: CGFloat = 1

        public init(flipsText: Bool = false, fillAlphaScale: CGFloat = 1) {
            self.flipsText = flipsText
            self.fillAlphaScale = fillAlphaScale
        }
    }

    /// Draws a page's elements as the tree they are: roots in the order
    /// they lie, each container followed by its children, a clipping frame
    /// hiding what its children spill past its edge.
    public static func draw(_ elements: [SketchElement], in context: CGContext, options: Options = Options()) {
        let tree = SketchTree(elements)
        func drawSubtree(_ id: UUID) {
            guard let element = tree[id] else { return }
            let children = tree.children(of: id)
            draw(element, in: context, options: options)
            guard !children.isEmpty else { return }
            context.saveGState()
            if element.kind == .frame, element.clips {
                context.addPath(path(of: element))
                context.clip()
            }
            for child in children { drawSubtree(child.id) }
            context.restoreGState()
        }
        for root in tree.roots { drawSubtree(root) }
    }

    public static func draw(_ element: SketchElement, in context: CGContext, options: Options = Options()) {
        context.saveGState()
        defer { context.restoreGState() }
        let translucent = element.style.opacity < 0.999
        if translucent {
            context.setAlpha(element.style.opacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        switch element.kind {
        case .rectangle, .ellipse, .frame:
            drawBox(element, in: context, options: options)
        case .line, .arrow:
            drawConnector(element, in: context)
        case .text:
            drawText(element, in: context, options: options)
        case .group:
            // Nothing of its own: a group is its children.
            break
        }
        if translucent { context.endTransparencyLayer() }
    }

    // MARK: - Shapes

    /// The outline of a box or an oval, or the curve of a connector.
    public static func path(of element: SketchElement) -> CGPath {
        switch element.kind {
        case .rectangle, .text, .frame, .group:
            let radius = element.cornerRadius
            let box = element.rect
            guard radius > 0, box.width > radius * 2, box.height > radius * 2 else { return CGPath(rect: box, transform: nil) }
            return CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: element.rect, transform: nil)
        case .line, .arrow:
            let path = CGMutablePath()
            path.move(to: element.start)
            if let control = element.control {
                path.addQuadCurve(to: element.end, control: control)
            } else {
                path.addLine(to: element.end)
            }
            return path
        }
    }

    static func applyStroke(_ style: SketchStyle, to context: CGContext) {
        context.setStrokeColor(style.stroke.cgColor)
        context.setLineWidth(style.width)
        context.setLineJoin(.round)
        context.setLineCap(style.dash == .dotted ? .round : .round)
        if let pattern = style.dashPattern {
            context.setLineDash(phase: 0, lengths: pattern)
        } else {
            context.setLineDash(phase: 0, lengths: [])
        }
    }

    private static func drawBox(_ element: SketchElement, in context: CGContext, options: Options) {
        let outline = path(of: element)
        if let fill = element.style.fill {
            context.addPath(outline)
            context.setFillColor(fill.withAlpha(fill.alpha * options.fillAlphaScale).cgColor)
            context.fillPath()
        }
        if element.style.drawsOutline(for: element.kind) {
            context.addPath(outline)
            applyStroke(element.style, to: context)
            context.strokePath()
        }
        if !element.text.isEmpty {
            drawLabel(element, in: context, options: options)
        }
    }

    private static func drawConnector(_ element: SketchElement, in context: CGContext) {
        context.addPath(path(of: element))
        applyStroke(element.style, to: context)
        context.strokePath()
        // Heads are solid even on a dashed line.
        context.setLineDash(phase: 0, lengths: [])
        drawHead(element.style.startHead, at: element.start, direction: element.startDirection, element: element, in: context)
        drawHead(element.style.endHead, at: element.end, direction: element.endDirection, element: element, in: context)
    }

    /// The head's own outline, for the PDF copy to trace as well.
    public static func headPath(
        _ head: SketchStyle.Head, at tip: CGPoint, direction d: CGPoint, length: CGFloat, width: CGFloat
    ) -> (path: CGPath, filled: Bool)? {
        let n = CGPoint(x: -d.y, y: d.x)
        let base = CGPoint(x: tip.x - d.x * length, y: tip.y - d.y * length)
        let path = CGMutablePath()
        switch head {
        case .none:
            return nil
        case .arrow:
            let spread = length * 0.5
            path.move(to: CGPoint(x: base.x + n.x * spread, y: base.y + n.y * spread))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: base.x - n.x * spread, y: base.y - n.y * spread))
            return (path, false)
        case .triangle:
            let spread = length * 0.42
            path.move(to: tip)
            path.addLine(to: CGPoint(x: base.x + n.x * spread, y: base.y + n.y * spread))
            path.addLine(to: CGPoint(x: base.x - n.x * spread, y: base.y - n.y * spread))
            path.closeSubpath()
            return (path, true)
        case .bar:
            let spread = length * 0.45
            path.move(to: CGPoint(x: tip.x + n.x * spread, y: tip.y + n.y * spread))
            path.addLine(to: CGPoint(x: tip.x - n.x * spread, y: tip.y - n.y * spread))
            return (path, false)
        case .dot:
            let radius = max(width * 1.5, 3)
            path.addEllipse(in: CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2))
            return (path, true)
        }
    }

    private static func drawHead(
        _ head: SketchStyle.Head, at tip: CGPoint, direction: CGPoint, element: SketchElement, in context: CGContext
    ) {
        guard let (path, filled) = headPath(head, at: tip, direction: direction, length: element.headLength, width: element.style.width) else { return }
        context.addPath(path)
        if filled {
            context.setFillColor(element.style.stroke.cgColor)
            context.fillPath()
        } else {
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
    }

    // MARK: - Words

    private static func drawText(_ element: SketchElement, in context: CGContext, options: Options) {
        let box = element.rect
        if let fill = element.style.fill {
            context.addPath(path(of: element))
            context.setFillColor(fill.withAlpha(fill.alpha * options.fillAlphaScale).cgColor)
            context.fillPath()
        }
        if element.style.border {
            context.addPath(path(of: element))
            applyStroke(element.style, to: context)
            context.strokePath()
        }
        guard !element.text.isEmpty else { return }
        let inner = box.insetBy(dx: SketchTypesetter.padding, dy: SketchTypesetter.padding)
        // A card sized to its width is set as one line per paragraph; one
        // sized to its height wraps at its edge.
        let layout = SketchTypesetter.layout(
            element.text, points: element.style.points, color: element.style.stroke.cgColor,
            width: element.sizing == .autoWidth ? nil : inner.width, align: element.style.textAlign
        )
        // With no wrapping the block can be narrower than the card (the
        // card was made wider by hand); the alignment says where it sits.
        var x = inner.minX
        if element.sizing == .autoWidth, layout.size.width < inner.width {
            switch element.style.textAlign {
            case .left: break
            case .center: x = inner.midX - layout.size.width / 2
            case .right: x = inner.maxX - layout.size.width
            }
        }
        drawLines(layout, at: CGPoint(x: x, y: inner.maxY), in: context, options: options)
    }

    /// The words inside a box, centred on it.
    private static func drawLabel(_ element: SketchElement, in context: CGContext, options: Options) {
        let inner = element.rect.insetBy(dx: SketchTypesetter.padding, dy: SketchTypesetter.padding)
        guard inner.width > 4 else { return }
        let layout = SketchTypesetter.layout(
            element.text, points: element.style.points, color: element.style.stroke.cgColor,
            width: inner.width, align: .center
        )
        let top = inner.midY + layout.size.height / 2
        context.saveGState()
        context.addPath(CGPath(rect: inner, transform: nil))
        context.clip()
        drawLines(layout, at: CGPoint(x: inner.minX, y: top), in: context, options: options)
        context.restoreGState()
    }

    /// Draws laid-out lines with their block's top-left corner at `origin`,
    /// in a page-space context.
    static func drawLines(_ layout: SketchTypesetter.Layout, at origin: CGPoint, in context: CGContext, options: Options) {
        context.saveGState()
        // Core Text draws glyphs upright in a y-up context. Where the view
        // has flipped the context, the text matrix flips them back — about
        // their own baseline, so the lines keep their places.
        context.textMatrix = options.flipsText ? CGAffineTransform(scaleX: 1, y: -1) : .identity
        for line in layout.lines {
            context.textPosition = CGPoint(x: origin.x + line.x, y: origin.y - line.baseline)
            CTLineDraw(line.line, context)
        }
        context.restoreGState()
    }
}
