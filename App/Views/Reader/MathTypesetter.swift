#if os(macOS)
import AppKit
import CoreText
import InkEngine

/// Sets a piece of LaTeX the way a paper sets it.
///
/// Not a TeX engine: notes are written while reading, and what gets written is
/// the mathematics of a sentence — a symbol, a subscript, a fraction, a sum
/// with its limits, a bracket around something tall. That is what this lays
/// out, and it lays it out by TeX's rules rather than by eye: the spacing
/// between two symbols depends on what kind of symbols they are, and every
/// height and thickness comes from the font's own `MATH` table rather than
/// from a fraction of the point size that happened to look right.
enum MathTypesetter {
    /// A formula, drawn. Nil when there is nothing to draw.
    ///
    /// `maxWidth` is the room the formula has. A displayed formula that does
    /// not fit is broken across lines at its relations, the way a paper breaks
    /// one; if it still does not fit — a single long fraction, say — it is set
    /// smaller. Nothing is ever cut off.
    static func image(
        latex: String,
        display: Bool,
        pointSize: CGFloat,
        color: NSColor,
        maxWidth: CGFloat? = nil
    ) -> (image: NSImage, descent: CGFloat)? {
        let source = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }

        var parser = Parser(source: source)
        let node = parser.parseSequence(until: nil)
        var style = Style(pointSize: pointSize, display: display, color: color)

        let box = fitted(node, style: &style, display: display, maxWidth: maxWidth)
        guard box.width > 0, box.ascent + box.descent > 0 else { return nil }

        // Whatever room is left after breaking and shrinking: the last resort
        // is to squeeze the drawing, which is still better than losing it.
        let squeeze = maxWidth.map { min(1, $0 / max(box.width, 1)) } ?? 1
        let size = NSSize(
            width: ceil(box.width * squeeze) + 2,
            height: ceil((box.ascent + box.descent) * squeeze) + 2
        )
        guard size.width > 0, size.height > 0 else { return nil }
        let descent = box.descent * squeeze + 1

        let image = NSImage(size: size)
        image.lockFocusFlipped(false)
        if let context = NSGraphicsContext.current?.cgContext {
            context.textMatrix = .identity
            context.saveGState()
            if squeeze < 1 { context.scaleBy(x: squeeze, y: squeeze) }
            box.draw(at: CGPoint(x: 1 / squeeze, y: box.descent + 1 / squeeze), in: context)
            context.restoreGState()
        }
        image.unlockFocus()
        return (image, descent)
    }

    /// Lays the formula out so it fits: broken across lines first, then set
    /// smaller, because a smaller formula is harder to read than a taller one.
    private static func fitted(
        _ node: Node, style: inout Style, display: Bool, maxWidth: CGFloat?
    ) -> Box {
        var box = node.layout(style)
        guard let maxWidth, maxWidth > 20, box.width > maxWidth else { return box }

        if display, let broken = broken(node, style: style, maxWidth: maxWidth) {
            box = broken
            guard box.width > maxWidth else { return box }
        }

        // Still too wide: set it smaller, but never so small it stops being
        // readable — the squeeze at the end takes whatever is left.
        let floor = max(style.pointSize * 0.6, 8)
        for _ in 0..<3 {
            guard box.width > maxWidth, style.pointSize > floor else { break }
            style.pointSize = max(floor, style.pointSize * (maxWidth / box.width) * 0.99)
            box = broken(node, style: style, maxWidth: maxWidth) ?? node.layout(style)
        }
        return box
    }

    // MARK: - Style

    struct Style {
        var pointSize: CGFloat
        var display: Bool
        var color: NSColor
        /// 0 for the formula itself, 1 for a script, 2 for a script's script.
        var level: Int = 0

        var font: NSFont { MathFont.shared.font(ofSize: pointSize) }
        var metrics: MathFont.Constants { MathFont.shared.constants }
        /// Ems, in points.
        func em(_ ems: CGFloat) -> CGFloat { ems * pointSize }
        var axis: CGFloat { em(metrics.axisHeight) }

        /// The style a script inside this one is set in. The font says how
        /// much smaller a script goes, and a script's script goes no smaller
        /// again — three sizes is all TeX has, and all a note needs.
        var scripted: Style {
            var copy = self
            copy.display = false
            copy.level = min(level + 1, 2)
            copy.pointSize = max(pointSize / scale(at: level) * scale(at: copy.level), 5)
            return copy
        }

        private func scale(at level: Int) -> CGFloat {
            switch level {
            case 0: 1
            case 1: metrics.scriptPercentScaleDown
            default: metrics.scriptScriptPercentScaleDown
            }
        }

        /// The style the halves of a fraction are set in.
        var fractional: Style {
            var copy = self
            if display { copy.display = false } else { return scripted }
            return copy
        }
    }

    // MARK: - Boxes

    /// A laid-out piece: something that knows its size and how to draw itself.
    struct Box {
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        /// How far the last glyph's ink leans past its advance.
        var italic: CGFloat = 0
        /// The lowest the ink reaches, which for a mark drawn on its own is
        /// well above the baseline.
        var inkBottom: CGFloat = 0
        /// Drawing, in a coordinate space whose origin is the baseline's left.
        var render: (CGPoint, CGContext) -> Void = { _, _ in }

        func draw(at origin: CGPoint, in context: CGContext) {
            render(origin, context)
        }
    }

    // MARK: - What kind of thing a symbol is

    /// TeX's classes. What goes between two symbols depends on these and on
    /// nothing else — it is why "a + b" is spaced differently from "f(x)".
    enum Class {
        case ord, op, bin, rel, open, close, punct, inner
    }

    /// The space between two classes, in eighteenths of an em. A negative
    /// entry is a space that only appears at full size, never inside a script.
    private static let spacing: [[Int]] = [
        //        ord  op  bin  rel open close punct inner
        /* ord */ [0, 1, -2, -3, 0, 0, 0, -1],
        /* op  */ [1, 1, 0, -3, 0, 0, 0, -1],
        /* bin */ [-2, -2, 0, 0, -2, 0, 0, -2],
        /* rel */ [-3, -3, 0, 0, -3, 0, 0, -3],
        /* open*/ [0, 0, 0, 0, 0, 0, 0, 0],
        /* clos*/ [0, 1, -2, -3, 0, 0, 0, -1],
        /* punc*/ [-1, -1, 0, -1, -1, -1, -1, -1],
        /* innr*/ [-1, 1, -2, -3, -1, 0, -1, -1],
    ]

    private static func index(of kind: Class) -> Int {
        switch kind {
        case .ord: 0
        case .op: 1
        case .bin: 2
        case .rel: 3
        case .open: 4
        case .close: 5
        case .punct: 6
        case .inner: 7
        }
    }

    static func space(between left: Class, and right: Class, style: Style) -> CGFloat {
        let entry = spacing[index(of: left)][index(of: right)]
        guard entry != 0 else { return 0 }
        if entry < 0, style.level > 0 { return 0 }
        return style.em(CGFloat(abs(entry)) / 18)
    }

    // MARK: - Nodes

    indirect enum Node {
        case sequence([Node])
        /// A run of characters set in the maths font exactly as given.
        case symbols(String, Class)
        /// Something already laid out, kept so it can be built on.
        case rendered(Box, Class)
        case fraction(Node, Node)
        case radical(Node)
        case scripted(base: Node, sup: Node?, sub: Node?)
        case bigOperator(String, sup: Node?, sub: Node?)
        case accent(String, Node)
        case delimited(String?, Node, String?)
        case space(CGFloat)
        case empty

        var kind: Class {
            switch self {
            case .symbols(_, let kind): kind
            case .rendered(_, let kind): kind
            case .bigOperator: .op
            case .fraction, .radical: .inner
            case .delimited: .inner
            case .scripted(let base, _, _): base.kind == .op ? .op : base.kind
            case .accent(_, let body): body.kind
            case .sequence(let parts): parts.first?.kind ?? .ord
            case .space, .empty: .ord
            }
        }

        func layout(_ style: Style) -> Box {
            switch self {
            case .empty:
                return Box()
            case .space(let ems):
                return Box(width: style.em(ems))
            case .symbols(let string, _):
                return MathTypesetter.run(string, style: style)
            case .rendered(let box, _):
                return box
            case .sequence(let parts):
                return MathTypesetter.row(parts, style: style)
            case .fraction(let top, let bottom):
                return MathTypesetter.fraction(top: top, bottom: bottom, style: style)
            case .radical(let body):
                return MathTypesetter.radical(body: body, style: style)
            case .scripted(let base, let sup, let sub):
                return MathTypesetter.scripted(base: base, sup: sup, sub: sub, style: style)
            case .bigOperator(let symbol, let sup, let sub):
                return MathTypesetter.bigOperator(symbol, sup: sup, sub: sub, style: style)
            case .accent(let mark, let body):
                return MathTypesetter.accented(mark, over: body, style: style)
            case .delimited(let open, let body, let close):
                return MathTypesetter.delimited(open, body, close, style: style)
            }
        }
    }

    // MARK: - Laying out

    private static func run(_ string: String, style: Style) -> Box {
        let attributed = NSAttributedString(
            string: string,
            attributes: [.font: style.font, .foregroundColor: style.color]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        // The ink, not the line's nominal height: a formula is stacked around
        // what is actually drawn.
        let ink = CTLineGetImageBounds(line, nil)
        let italic = string.unicodeScalars.last
            .flatMap { MathFont.shared.glyph(for: $0, size: style.pointSize) }
            .map { MathFont.shared.italicCorrection(of: $0) * style.pointSize } ?? 0
        return Box(
            width: width,
            ascent: max(ink.maxY, 0),
            descent: max(-ink.minY, 0),
            italic: italic,
            inkBottom: ink.isNull ? 0 : ink.minY
        ) { origin, context in
            context.textMatrix = .identity
            context.textPosition = origin
            CTLineDraw(line, context)
        }
    }

    /// A row of atoms with TeX's spacing between them.
    private static func row(_ parts: [Node], style: Style) -> Box {
        let atoms = binariesResolved(parts)
        var boxes: [(box: Box, lead: CGFloat)] = []
        var previous: Class?
        for atom in atoms {
            let box = atom.layout(style)
            let lead = previous.map { space(between: $0, and: atom.kind, style: style) } ?? 0
            boxes.append((box, lead))
            if case .space = atom {} else { previous = atom.kind }
        }
        let width = boxes.reduce(0) { $0 + $1.lead + $1.box.width }
        let ascent = boxes.map(\.box.ascent).max() ?? 0
        let descent = boxes.map(\.box.descent).max() ?? 0
        return Box(
            width: width, ascent: ascent, descent: descent,
            italic: boxes.last?.box.italic ?? 0
        ) { origin, context in
            var x = origin.x
            for entry in boxes {
                x += entry.lead
                entry.box.draw(at: CGPoint(x: x, y: origin.y), in: context)
                x += entry.box.width
            }
        }
    }

    /// A binary operator that has nothing to bind on its left is not binary:
    /// the minus of "−x" is a sign, and TeX sets it without the space a
    /// subtraction would get.
    private static func binariesResolved(_ parts: [Node]) -> [Node] {
        var result: [Node] = []
        var previous: Class?
        for part in parts {
            var part = part
            if case .symbols(let text, .bin) = part {
                let binds = switch previous {
                case .none, .some(.bin), .some(.op), .some(.rel), .some(.open), .some(.punct): false
                default: true
                }
                if !binds { part = .symbols(text, .ord) }
            }
            result.append(part)
            if case .space = part {} else { previous = part.kind }
        }
        return result
    }

    private static func fraction(top: Node, bottom: Node, style: Style) -> Box {
        let inner = style.fractional
        let numerator = top.layout(inner)
        let denominator = bottom.layout(inner)
        let metrics = style.metrics
        let rule = style.em(metrics.fractionRuleThickness)
        let axis = style.axis
        let numeratorShift = style.em(style.display
            ? metrics.fractionNumeratorDisplayStyleShiftUp
            : metrics.fractionNumeratorShiftUp)
        let denominatorShift = style.em(style.display
            ? metrics.fractionDenominatorDisplayStyleShiftDown
            : metrics.fractionDenominatorShiftDown)
        let numeratorGap = style.em(style.display
            ? metrics.fractionNumDisplayStyleGapMin : metrics.fractionNumeratorGapMin)
        let denominatorGap = style.em(style.display
            ? metrics.fractionDenomDisplayStyleGapMin : metrics.fractionDenominatorGapMin)

        // The halves are pushed apart until the bar has room on both sides.
        let barTop = axis + rule / 2, barBottom = axis - rule / 2
        let up = max(numeratorShift, barTop + numeratorGap + numerator.descent)
        let down = max(denominatorShift, denominator.ascent + denominatorGap - barBottom)

        let padding = style.em(0.12)
        let width = max(numerator.width, denominator.width) + padding * 2
        let ascent = up + numerator.ascent
        let descent = down + denominator.descent
        let color = style.color

        return Box(width: width, ascent: ascent, descent: descent) { origin, context in
            let centre = origin.x + width / 2
            numerator.draw(
                at: CGPoint(x: centre - numerator.width / 2, y: origin.y + up), in: context
            )
            denominator.draw(
                at: CGPoint(x: centre - denominator.width / 2, y: origin.y - down), in: context
            )
            context.setFillColor(color.cgColor)
            context.fill(CGRect(
                x: origin.x, y: origin.y + barBottom, width: width, height: rule
            ))
        }
    }

    private static func radical(body: Node, style: Style) -> Box {
        let inner = body.layout(style)
        let metrics = style.metrics
        let rule = style.em(metrics.radicalRuleThickness)
        let gap = style.em(style.display
            ? metrics.radicalDisplayStyleVerticalGap : metrics.radicalVerticalGap)
        let extra = style.em(metrics.radicalExtraAscender)
        let needed = inner.ascent + inner.descent + gap + rule
        let sign = stretched("√", to: needed, style: style)
        let bodyHeight = max(needed, sign.ascent + sign.descent)
        let ascent = max(inner.ascent + gap + rule + extra, sign.ascent)
        let width = sign.width + inner.width + style.em(0.05)
        let color = style.color

        return Box(width: width, ascent: ascent, descent: max(inner.descent, sign.descent)) {
            origin, context in
            // The sign hangs so its own bar meets the one drawn across the top.
            let lift = ascent - extra - rule - sign.ascent
            sign.draw(at: CGPoint(x: origin.x, y: origin.y + lift), in: context)
            let bodyX = origin.x + sign.width
            inner.draw(at: CGPoint(x: bodyX, y: origin.y), in: context)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(
                x: bodyX - style.em(0.01), y: origin.y + ascent - extra - rule,
                width: inner.width + style.em(0.06), height: rule
            ))
            _ = bodyHeight
        }
    }

    private static func scripted(base: Node, sup: Node?, sub: Node?, style: Style) -> Box {
        let baseBox = base.layout(style)
        let small = style.scripted
        let supBox = sup?.layout(small)
        let subBox = sub?.layout(small)
        let metrics = style.metrics

        var supShift = max(
            style.em(metrics.superscriptShiftUp),
            baseBox.ascent - style.em(metrics.superscriptBaselineDropMax)
        )
        var subShift = max(
            style.em(metrics.subscriptShiftDown),
            baseBox.descent + style.em(metrics.subscriptBaselineDropMin)
        )
        if let supBox {
            supShift = max(supShift, style.em(metrics.superscriptBottomMin) + supBox.descent)
        }
        if let subBox {
            subShift = max(subShift, subBox.ascent - style.em(metrics.subscriptTopMax))
        }
        // With both, they are pushed apart until they cannot touch.
        if let supBox, let subBox {
            let gap = (supShift - supBox.descent) - (subBox.ascent - subShift)
            let minimum = style.em(metrics.subSuperscriptGapMin)
            if gap < minimum { subShift += minimum - gap }
        }

        let after = style.em(metrics.spaceAfterScript)
        let scriptWidth = max(supBox?.width ?? 0, subBox?.width ?? 0)
        let width = baseBox.width + (scriptWidth > 0 ? scriptWidth + after : 0)
        var ascent = baseBox.ascent
        var descent = baseBox.descent
        if let supBox { ascent = max(ascent, supShift + supBox.ascent) }
        if let subBox { descent = max(descent, subShift + subBox.descent) }
        let italic = baseBox.italic

        return Box(width: width, ascent: ascent, descent: descent) { origin, context in
            baseBox.draw(at: origin, in: context)
            let x = origin.x + baseBox.width
            // A superscript clears the lean of an italic letter; a subscript
            // tucks under it.
            supBox?.draw(at: CGPoint(x: x + italic, y: origin.y + supShift), in: context)
            subBox?.draw(at: CGPoint(x: x, y: origin.y - subShift), in: context)
        }
    }

    private static func bigOperator(
        _ symbol: String, sup: Node?, sub: Node?, style: Style
    ) -> Box {
        let isWord = symbol.unicodeScalars.count > 1
        let glyph: Box = if style.display, !isWord {
            stretched(symbol, to: style.pointSize * style.metrics.displayOperatorMinHeight,
                      style: style)
        } else {
            run(symbol, style: style)
        }
        // A big operator is centred on the axis, not sat on the baseline.
        let centred = isWord ? glyph : recentred(glyph, on: style.axis)

        // Limits go over and under only when the formula is displayed, and an
        // integral never takes them above and below at all — TeX sets those
        // beside the sign whatever the style, and so does every paper.
        guard style.display, !"∫∬∭∮∯∰".contains(symbol) else {
            return scripted(
                base: .rendered(centred, .op), sup: sup, sub: sub, style: style
            )
        }
        guard sup != nil || sub != nil else { return centred }

        let small = style.scripted
        let supBox = sup?.layout(small)
        let subBox = sub?.layout(small)
        let metrics = style.metrics
        let width = max(centred.width, max(supBox?.width ?? 0, subBox?.width ?? 0))
        var ascent = centred.ascent
        var descent = centred.descent
        var supRise: CGFloat = 0, subDrop: CGFloat = 0
        if let supBox {
            supRise = max(
                centred.ascent + style.em(metrics.upperLimitGapMin) + supBox.descent,
                style.em(metrics.upperLimitBaselineRiseMin) + supBox.descent
            )
            ascent = max(ascent, supRise + supBox.ascent)
        }
        if let subBox {
            subDrop = max(
                centred.descent + style.em(metrics.lowerLimitGapMin) + subBox.ascent,
                style.em(metrics.lowerLimitBaselineDropMin) + subBox.ascent
            )
            descent = max(descent, subDrop + subBox.descent)
        }

        return Box(width: width, ascent: ascent, descent: descent) { origin, context in
            let centre = origin.x + width / 2
            centred.draw(at: CGPoint(x: centre - centred.width / 2, y: origin.y), in: context)
            if let supBox {
                supBox.draw(
                    at: CGPoint(x: centre - supBox.width / 2, y: origin.y + supRise), in: context
                )
            }
            if let subBox {
                subBox.draw(
                    at: CGPoint(x: centre - subBox.width / 2, y: origin.y - subDrop), in: context
                )
            }
        }
    }

    private static func accented(_ mark: String, over body: Node, style: Style) -> Box {
        let baseBox = body.layout(style)
        let markBox = run(mark, style: style)
        // A mark set on its own already sits high above the baseline — it is
        // drawn for a lowercase letter. Where it goes here is decided by its
        // ink, lowered onto the letter it belongs to, and never below the
        // height the font says an accent rests at.
        let rest = max(baseBox.ascent, style.em(style.metrics.accentBaseHeight))
        let lift = rest - markBox.inkBottom + style.em(0.02)
        let ascent = max(baseBox.ascent, lift + markBox.ascent)
        return Box(
            width: baseBox.width, ascent: ascent, descent: baseBox.descent, italic: baseBox.italic
        ) { origin, context in
            baseBox.draw(at: origin, in: context)
            // Centred over the letter, allowing for its lean.
            let centre = origin.x + (baseBox.width + baseBox.italic) / 2
            markBox.draw(
                at: CGPoint(x: centre - markBox.width / 2, y: origin.y + lift), in: context
            )
        }
    }

    private static func delimited(
        _ open: String?, _ body: Node, _ close: String?, style: Style
    ) -> Box {
        let inner = body.layout(style)
        let axis = style.axis
        // Tall enough to clear what it holds, on both sides of the axis.
        let reach = max(inner.ascent - axis, inner.descent + axis) * 2 + style.em(0.1)
        let left = open.map { recentred(stretched($0, to: reach, style: style), on: axis) }
        let right = close.map { recentred(stretched($0, to: reach, style: style), on: axis) }
        let width = (left?.width ?? 0) + inner.width + (right?.width ?? 0)
        let ascent = max(inner.ascent, max(left?.ascent ?? 0, right?.ascent ?? 0))
        let descent = max(inner.descent, max(left?.descent ?? 0, right?.descent ?? 0))
        return Box(width: width, ascent: ascent, descent: descent) { origin, context in
            var x = origin.x
            if let left {
                left.draw(at: CGPoint(x: x, y: origin.y), in: context)
                x += left.width
            }
            inner.draw(at: CGPoint(x: x, y: origin.y), in: context)
            x += inner.width
            right?.draw(at: CGPoint(x: x, y: origin.y), in: context)
        }
    }

    /// A glyph in the largest cut that is still no taller than asked for —
    /// the font carries several of each bracket, and of the sum and integral.
    private static func stretched(_ symbol: String, to height: CGFloat, style: Style) -> Box {
        guard let scalar = symbol.unicodeScalars.first, symbol.unicodeScalars.count == 1,
              let glyph = MathFont.shared.glyph(for: scalar, size: style.pointSize),
              let cut = MathFont.shared.variant(of: glyph, reaching: height / style.pointSize),
              cut != glyph
        else { return run(symbol, style: style) }

        let font = style.font as CTFont
        var glyphs = [cut]
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyphs, &bounds, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .default, &glyphs, &advance, 1)
        let color = style.color
        let lean = min(bounds.minX, 0)
        return Box(
            width: max(advance.width, bounds.maxX) - lean,
            ascent: max(bounds.maxY, 0),
            descent: max(-bounds.minY, 0),
            inkBottom: bounds.minY
        ) { origin, context in
            context.setFillColor(color.cgColor)
            context.textMatrix = .identity
            var at = CGPoint(x: origin.x - lean, y: origin.y)
            CTFontDrawGlyphs(font, &glyphs, &at, 1, context)
        }
    }

    /// A box moved so its middle sits on the axis, which is where a sum, an
    /// integral and a tall bracket belong.
    private static func recentred(_ box: Box, on axis: CGFloat) -> Box {
        let middle = (box.ascent - box.descent) / 2
        let shift = axis - middle
        guard abs(shift) > 0.01 else { return box }
        let inner = box
        return Box(
            width: box.width, ascent: box.ascent + shift, descent: box.descent - shift,
            italic: box.italic
        ) { origin, context in
            inner.draw(at: CGPoint(x: origin.x, y: origin.y + shift), in: context)
        }
    }

    // MARK: - Breaking a long formula

    /// A displayed formula broken across lines, the way a paper breaks one:
    /// before a relation where it can, before a binary operator where it must,
    /// with the continuations indented under the first line.
    private static func broken(_ node: Node, style: Style, maxWidth: CGFloat) -> Box? {
        guard case .sequence(let parts) = node, parts.count > 2 else { return nil }
        let atoms = binariesResolved(parts)
        let widths = atoms.map { $0.layout(style).width }

        var lines: [[Node]] = []
        var line: [Node] = []
        var width: CGFloat = 0
        var lastBreak: Int?
        var previous: Class?
        for (index, atom) in atoms.enumerated() {
            let lead = previous.map { space(between: $0, and: atom.kind, style: style) } ?? 0
            let breakable = atom.kind == .rel || atom.kind == .bin
            if width + lead + widths[index] > maxWidth, let point = lastBreak, point > 0 {
                lines.append(Array(line[0..<point]))
                line = Array(line[point...])
                width = Node.sequence(line).layout(style).width
                lastBreak = nil
            }
            if breakable, !line.isEmpty { lastBreak = line.count }
            line.append(atom)
            width += lead + widths[index]
            if case .space = atom {} else { previous = atom.kind }
        }
        guard !lines.isEmpty else { return nil }
        lines.append(line)
        guard lines.count > 1 else { return nil }

        let boxes = lines.map { Node.sequence($0).layout(style) }
        let indent = style.em(1.2)
        let leading = style.em(0.35)
        let total = boxes.enumerated()
            .map { $0.offset == 0 ? $0.element.width : $0.element.width + indent }
            .max() ?? 0
        var height: CGFloat = 0
        for (offset, box) in boxes.enumerated() {
            height += box.ascent + box.descent + (offset == 0 ? 0 : leading)
        }
        let ascent = boxes[0].ascent
        return Box(width: total, ascent: ascent, descent: height - ascent) { origin, context in
            var y = origin.y
            for (offset, box) in boxes.enumerated() {
                if offset > 0 {
                    y -= boxes[offset - 1].descent + leading + box.ascent
                }
                box.draw(at: CGPoint(x: origin.x + (offset == 0 ? 0 : indent), y: y), in: context)
            }
        }
    }
}

/// Hands the drawing layer the typesetter, so a card with `$…$` in it is
/// set as mathematics on the page — the same setting a note gets. Installed
/// once; the pictures are kept so redrawing a page does not set its formulas
/// again.
enum MathBridge {
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var cache: [String: SketchTypesetter.MathPiece] = [:]

    static func install() {
        guard !installed else { return }
        installed = true
        SketchTypesetter.mathProvider = { latex, points, color in
            let key = "\(latex)|\(points)|\(color.components ?? [])"
            if let hit = cache[key] { return hit }
            guard let made = MathTypesetter.image(latex: latex, display: false, pointSize: points, color: NSColor(cgColor: color) ?? .black),
                  let cg = made.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return nil }
            let piece = SketchTypesetter.MathPiece(
                image: cg, width: made.image.size.width,
                ascent: made.image.size.height - made.descent, descent: made.descent
            )
            if cache.count > 500 { cache.removeAll() }
            cache[key] = piece
            return piece
        }
    }
}
#endif
