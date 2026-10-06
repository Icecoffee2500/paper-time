#if os(macOS)
import AppKit

/// The rounded tint behind a link into the paper.
///
/// A passage you pulled out of a paper is not a hyperlink. A hyperlink says
/// "there is more of this somewhere else"; this says "these words are not
/// mine, they are from page 7" — it is a quotation you can walk back to. Blue
/// and underlined said the first thing, so it is a chip now: the words in a
/// rounded tint, the way a token reads in Mail's address field or a tag reads
/// in Reminders.
///
/// Drawn rather than attached. An `NSTextAttachment` would have been less
/// work, but it makes the whole quotation one glyph — it stops wrapping at the
/// column's edge, stops being selectable a word at a time, and stops being
/// searchable. This keeps it as text and paints behind it, so a long passage
/// still breaks across lines and each line gets its own rounded end.
enum NoteChip {
    /// Marks a run as a passage from the paper. The value is the corner style.
    static let attribute = NSAttributedString.Key("PaperTimeChip")

    static var fill: NSColor { .controlAccentColor.withAlphaComponent(0.12) }

    /// The accent, as the words themselves.
    ///
    /// These read as ink for a while — a whole quoted sentence in link blue
    /// seemed too loud — but ink on a pale tint is what a highlight looks
    /// like, and a highlight is something you made, not something you can
    /// press. The demonstrations in About set the words in the accent over a
    /// fainter tint, and side by side that version said "this goes somewhere"
    /// and this one did not. So it is the accent now, and the tint is lighter
    /// to keep the pair readable.
    static var ink: NSColor { .controlAccentColor }

    /// How far the tint reaches past the letters, and how round it is.
    static let padding = NSSize(width: 4.5, height: 1.5)
    static let radius: CGFloat = 5.5
}

/// The bar down the left of a quotation, and the faint ground behind it.
///
/// A quotation in a note is a passage from the paper — words that are not the
/// writer's. The chip said that inline, which was right while a passage was a
/// token dropped mid-sentence; a whole sentence lifted out of a paper is a
/// quotation, and a quotation has looked the same in print for centuries: set
/// in, a rule down its side. So that is what it is now, and the chip is left
/// to the passages that are still dropped inline.
enum NoteQuoteBar {
    /// Marks a run as part of a quoted paragraph. The value is a
    /// `NoteMarkdown.QuoteEdge`: which ends of the rule this line owns, and
    /// whether the quotation came off a page.
    static let attribute = NSAttributedString.Key("PaperTimeQuote")

    /// Two quotations, told apart by their rule.
    ///
    /// A quotation you typed is an aside in your own note — grey rule, no
    /// ground, the words a shade back. A quotation you took off a page with
    /// ⌘L is evidence: it is in the accent, on the faintest wash of it, with
    /// the page at the end of the last line. Neither shouts, and nobody has
    /// to be told which is which.
    static func bar(anchored: Bool) -> NSColor {
        anchored
            ? .controlAccentColor.withAlphaComponent(0.55)
            : .tertiaryLabelColor.withAlphaComponent(0.55)
    }

    static func ground(anchored: Bool) -> NSColor {
        anchored ? .controlAccentColor.withAlphaComponent(0.05) : .clear
    }

    static let width: CGFloat = 2.5
    /// How far left of the words the bar stands.
    static let gap: CGFloat = 13
}

/// Paints the quotations, the chips and the code, then lets the text draw
/// on top.
final class NoteLayoutFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        drawCodeBlock(in: context)
        drawQuotes(in: context)
        drawChips(in: context)
        drawCode(in: context)
        super.draw(at: point, in: context)
    }

    // MARK: Fenced code

    /// The row of a fenced block this paragraph is, if it is one.
    var codeRow: NoteCodeStyle.Block.Row? {
        guard let paragraph = textElement as? NSTextParagraph else { return nil }
        let text = paragraph.attributedString
        guard text.length > 0 else { return nil }
        return NoteCodeStyle.Block.Row(text.attribute(NoteCodeStyle.Block.attribute, at: 0, effectiveRange: nil))
    }

    /// This row's slice of the block's box, in the fragment's coordinates:
    /// the column's width less the line padding, and the row's height less
    /// the block's margin above its header and below its last row.
    private func codeBox(for row: NoteCodeStyle.Block.Row) -> CGRect {
        let container = textLayoutManager?.textContainer
        let padding = container?.lineFragmentPadding ?? 0
        let room = container.map(\.size.width).flatMap { $0 > 0 && $0 < 10_000 ? $0 : nil }
            ?? layoutFragmentFrame.maxX + padding
        let left = padding - layoutFragmentFrame.minX
        let right = room - padding - layoutFragmentFrame.minX
        let top = row.role == .header ? NoteCodeStyle.Block.margin : 0
        var bottom = layoutFragmentFrame.height
        // The last row ends at its words (and the foot's room): the space
        // under it is the block's margin — and the note's last paragraph has
        // none, which is why this is not measured from the bottom.
        if row.isLast, let line = textLineFragments.last {
            bottom = min(bottom, line.typographicBounds.maxY + (row.role == .close ? 0 : NoteCodeStyle.Block.footHeight / 2))
        }
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    /// Where the copy button stands over a block's header, in the
    /// fragment's coordinates. Nil on any other row, on a header shown as
    /// written, and on paper (`NotePDFExport` draws no buttons).
    var codeCopyButton: CGRect? {
        guard let row = codeRow, row.role == .header,
              let paragraph = textElement as? NSTextParagraph,
              paragraph.attributedString.attribute(.paperTimeSource, at: 0, effectiveRange: nil) != nil
        else { return nil }
        let box = codeBox(for: row)
        let size = Self.copyLabel(copied: false).size()
        let width = size.width + 16
        return CGRect(x: box.maxX - NoteCodeStyle.Block.inset / 2 - width, y: box.minY + 4,
                      width: width, height: NoteCodeStyle.Block.headerHeight - 8)
    }

    /// The copy button's words, and its picture.
    static func copyLabel(copied: Bool) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NoteTypography.baseSize * 0.72, weight: .regular)
        let label = NSMutableAttributedString()
        if let symbol = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular)) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attachment.bounds = CGRect(x: 0, y: -1.5, width: symbol.size.width, height: symbol.size.height)
            label.append(NSAttributedString(attachment: attachment))
            label.append(NSAttributedString(string: " "))
        }
        label.append(NSAttributedString(string: copied ? L("복사했어요", "Copied") : L("복사", "Copy")))
        label.addAttributes([.font: font, .foregroundColor: NSColor.secondaryLabelColor],
                            range: NSRange(location: 0, length: label.length))
        return label
    }

    /// The block's box, a row at a time, behind its words: the fill, the
    /// outline (its sides on every row, its rounded top on the header and
    /// its rounded foot on the last row), the rule under the header, the
    /// line's number, and the copy button. Each row's slice is drawn from a
    /// box that runs on past the row where the block does, clipped to the
    /// row — so the corners belong to the header and the foot only, and the
    /// slices meet without a seam.
    private func drawCodeBlock(in context: CGContext) {
        guard let row = codeRow, let paragraph = textElement as? NSTextParagraph else { return }
        let block = NoteCodeStyle.Block.self
        var band = codeBox(for: row)
        guard band.width > 0, band.height > 0 else { return }
        // Rows meet on whole device pixels. Two translucent slices that both
        // half-cover the pixel row where they meet paint it twice, and the
        // block showed a faint line between every two lines of code. Snapped
        // through the context's own transform: the fragment is drawn at
        // wherever the view and the container's inset put it, which the
        // fragment's frame alone does not say — snapping by that left one
        // pixel row painted twice and another missed.
        func snapped(_ y: CGFloat) -> CGFloat {
            let device = context.convertToDeviceSpace(CGPoint(x: 0, y: y))
            return context.convertToUserSpace(CGPoint(x: device.x, y: device.y.rounded())).y
        }
        let snappedTop = snapped(band.minY)
        band = CGRect(x: band.minX, y: snappedTop, width: band.width, height: snapped(band.maxY) - snappedTop)
        let top = row.role == .header
        let bottom = row.isLast
        let reach = block.radius + 4
        let whole = CGRect(x: band.minX, y: band.minY - (top ? 0 : reach), width: band.width,
                           height: band.height + (top ? 0 : reach) + (bottom ? 0 : reach))
        let shape = NSBezierPath(roundedRect: whole, xRadius: block.radius, yRadius: block.radius)
        context.saveGState()
        NSBezierPath(rect: band).addClip()
        block.fill.setFill()
        shape.fill()
        block.border.setStroke()
        let outline = NSBezierPath(roundedRect: whole.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: block.radius - 0.5, yRadius: block.radius - 0.5)
        outline.lineWidth = 1
        outline.stroke()
        context.restoreGState()

        let text = paragraph.attributedString
        if top, !bottom {
            block.rule.setFill()
            NSRect(x: band.minX + 1, y: band.maxY - 1, width: band.width - 2, height: 1).fill()
        }
        if row.role == .line, row.number > 0, let line = textLineFragments.first,
           let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
            let font = block.numberFont()
            let number = NSAttributedString(string: "\(row.number)", attributes: [
                .font: font, .foregroundColor: block.lineNumber,
            ])
            let size = number.size()
            let baseline = line.typographicBounds.minY + line.glyphOrigin.y
            let codeStart = band.minX + style.headIndent
            Self.drawDownward(number, at: CGPoint(x: codeStart - 9 - size.width, y: baseline - font.ascender), in: context)
        }
        if let button = codeCopyButton, NSGraphicsContext.current?.isDrawingToScreen ?? true {
            let copied = text.attribute(block.copied, at: 0, effectiveRange: nil) != nil
            let label = Self.copyLabel(copied: copied)
            let size = label.size()
            Self.drawDownward(label, at: CGPoint(x: button.maxX - 8 - size.width, y: button.midY - size.height / 2), in: context)
        }
    }

    /// Words drawn in the fragment's own space, which runs downward wherever
    /// the fragment is drawn. The text view's graphics context says so; the
    /// PDF export's (`NotePDFExport`) turns the page over with its transform
    /// and says otherwise — and there a block's numbers came out upside down.
    static func drawDownward(_ words: NSAttributedString, at point: CGPoint, in context: CGContext) {
        if NSGraphicsContext.current?.isFlipped ?? true { return words.draw(at: point) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        words.draw(at: point)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The quotation this fragment belongs to, if it belongs to one: which
    /// ends of the rule it owns, and the box the ground fills.
    ///
    /// Drawn from the fragment's own frame rather than per line, so a
    /// quotation that wraps gets one continuous rule rather than a dotted
    /// column of them.
    private var quotation: (edge: NoteMarkdown.QuoteEdge, ground: CGRect)? {
        guard let paragraph = textElement as? NSTextParagraph else { return nil }
        let text = paragraph.attributedString
        guard text.length > 0 else { return nil }

        // Looked for across the paragraph rather than at its first
        // character. A quoted line begins with the stand-in for the "> " that
        // is not shown, and that marker was not part of the quotation as far
        // as this was concerned — so the guard failed on every quotation
        // there was, and the rule was never drawn once.
        var edge: NoteMarkdown.QuoteEdge?
        text.enumerateAttribute(
            NoteQuoteBar.attribute, in: NSRange(location: 0, length: text.length)
        ) { value, _, stop in
            guard let raw = value as? Int else { return }
            edge = NoteMarkdown.QuoteEdge(rawValue: raw)
            stop.pointee = true
        }
        guard let edge else { return nil }

        let box = layoutFragmentFrame
        // Nothing is added below. A quotation of three lines is three
        // paragraphs drawn one after another, and their boxes meet exactly —
        // the space between the lines is inside them — so the three rules
        // already read as one. Reaching past the foot of one into the next
        // only painted the seam twice, and a translucent tint painted twice
        // is a line across the quotation.
        // As wide as the column, not as wide as the line. A ground that
        // stopped at the last word would give the quotation a ragged right
        // edge and make its two-word last line look like a different thing
        // from the line above it.
        let room = textLayoutManager?.textContainer?.size.width ?? 0
        // A formula set in the middle of its line begins where the middle
        // puts it, and the rule stays where the quotation's words begin.
        var shift: CGFloat = 0
        if let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
           style.alignment == .center {
            let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
            shift = max(0, box.minX - padding - style.firstLineHeadIndent)
        }
        let reach = room > 0 && room < 10_000 ? room - (box.minX - shift) : box.width
        // The fragment already begins where its words do — a paragraph set
        // in by twenty points has a box that starts twenty points in — so
        // the rule is placed from the fragment's own left edge and not from
        // the indent, which would put it under the first letter.
        return (edge, CGRect(x: -NoteQuoteBar.gap - shift, y: 0,
                             width: max(reach, box.width) + NoteQuoteBar.gap,
                             height: box.height))
    }

    /// What a fragment may paint on. The default is the box its words
    /// occupy, and everything outside it is clipped — which is where the
    /// rule stands and where the ground reaches, so without this a quotation
    /// of two words got two words' worth of quotation.
    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        // A block of code is as wide as the column, past its words.
        if let row = codeRow { bounds = bounds.union(codeBox(for: row).insetBy(dx: -1, dy: -1)) }
        // A code span's tint reaches 0.2 em above and below its letters,
        // which on the first and last lines is past the box of the words.
        if holdsCode { bounds = bounds.insetBy(dx: 0, dy: -4) }
        guard let quotation else { return bounds }
        return bounds.union(quotation.ground)
    }

    private var holdsCode: Bool {
        guard let paragraph = textElement as? NSTextParagraph else { return false }
        let text = paragraph.attributedString
        var found = false
        text.enumerateAttribute(NoteCodeStyle.attribute, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// The rounded warm grey behind code, a box per line it runs over. Its
    /// height is the code face's, from the baseline — not the line's, which
    /// holds the space between lines too — and 0.2 em more each way.
    private func drawCode(in context: CGContext) {
        guard let paragraph = textElement as? NSTextParagraph else { return }
        let text = paragraph.attributedString
        guard text.length > 0 else { return }
        context.saveGState()
        NoteCodeStyle.fill.setFill()
        text.enumerateAttribute(
            NoteCodeStyle.attribute, in: NSRange(location: 0, length: text.length)
        ) { value, range, _ in
            guard let size = value as? CGFloat, size > 0 else { return }
            let face = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let above = face.ascender + size * NoteCodeStyle.padding.height
            let below = -face.descender + size * NoteCodeStyle.padding.height
            for (frame, baseline) in segments(for: range, in: paragraph) where frame.width > 0 {
                let box = CGRect(x: frame.minX, y: frame.minY + baseline - above,
                                 width: frame.width, height: above + below)
                NSBezierPath(roundedRect: box, xRadius: NoteCodeStyle.radius, yRadius: NoteCodeStyle.radius).fill()
            }
        }
        context.restoreGState()
    }

    private func drawQuotes(in context: CGContext) {
        guard let quotation else { return }
        let (edge, ground) = quotation

        let anchored = edge.contains(.anchored)
        context.saveGState()
        NoteQuoteBar.ground(anchored: anchored).setFill()
        Self.path(ground, radius: 4, top: edge.contains(.opens),
                  bottom: edge.contains(.closes)).fill()
        NoteQuoteBar.bar(anchored: anchored).setFill()
        Self.path(CGRect(x: ground.minX, y: 0,
                         width: NoteQuoteBar.width, height: ground.height),
                  radius: NoteQuoteBar.width / 2,
                  top: edge.contains(.opens), bottom: edge.contains(.closes)).fill()
        context.restoreGState()
    }

    /// A rectangle rounded only at the ends that are ends.
    ///
    /// One path rather than two fills: the tint is translucent, and a corner
    /// painted twice is a corner that is darker than the rest of the rule.
    /// Overlapping rectangles in a single path are filled once.
    private static func path(
        _ rect: CGRect, radius: CGFloat, top: Bool, bottom: Bool
    ) -> NSBezierPath {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        let path = NSBezierPath()
        path.windingRule = .nonZero
        path.appendRoundedRect(rect, xRadius: radius, yRadius: radius)
        if !top {
            path.appendRect(CGRect(x: rect.minX, y: rect.minY,
                                   width: rect.width, height: radius))
        }
        if !bottom {
            path.appendRect(CGRect(x: rect.minX, y: rect.maxY - radius,
                                   width: rect.width, height: radius))
        }
        return path
    }

    private func drawChips(in context: CGContext) {
        guard let paragraph = textElement as? NSTextParagraph else { return }
        let text = paragraph.attributedString
        guard text.length > 0 else { return }

        context.saveGState()
        text.enumerateAttribute(
            NoteChip.attribute, in: NSRange(location: 0, length: text.length)
        ) { value, range, _ in
            guard value != nil else { return }
            // Not inside a quotation: the block is already tinted, and a chip
            // on top of it is the same thing said twice.
            if text.attribute(NoteQuoteBar.attribute, at: range.location, effectiveRange: nil) != nil {
                return
            }
            // The page at the end of a quotation is the one chip that
            // follows a word instead of standing among them, and the tint
            // reaching its usual four points to the left ate the space
            // between them: "probe.3쪽". It keeps its room on the right and
            // gives back the space on the left.
            let isCitation = quotation != nil
            for rect in rects(for: range, in: paragraph) {
                let box = CGRect(
                    x: rect.minX - (isCitation ? 0 : NoteChip.padding.width),
                    y: rect.minY - NoteChip.padding.height,
                    width: rect.width + NoteChip.padding.width * (isCitation ? 1 : 2),
                    height: rect.height + NoteChip.padding.height * 2
                )
                let path = NSBezierPath(roundedRect: box,
                                        xRadius: NoteChip.radius, yRadius: NoteChip.radius)
                NoteChip.fill.setFill()
                path.fill()
            }
        }
        context.restoreGState()
    }

    /// Where a run of the paragraph actually sits, a line at a time — so a
    /// passage that wraps gets one rounded box per line rather than one box
    /// around the whole span, which would swallow the lines between.
    private func rects(for range: NSRange, in paragraph: NSTextParagraph) -> [CGRect] {
        guard let content = textLayoutManager?.textContentManager,
              let paragraphStart = paragraph.elementRange?.location,
              let start = content.location(paragraphStart, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let span = NSTextRange(location: start, end: end)
        else { return [] }

        var found: [CGRect] = []
        textLayoutManager?.enumerateTextSegments(
            in: span, type: .standard, options: []
        ) { _, frame, _, _ in
            // Frames come in the layout manager's space; the fragment draws in
            // its own, so they are moved back by where the fragment begins.
            found.append(frame.offsetBy(dx: -layoutFragmentFrame.minX,
                                        dy: -layoutFragmentFrame.minY))
            return true
        }
        return found
    }

    /// The same, with where the baseline is in each — measured down from
    /// the top of the segment.
    private func segments(for range: NSRange, in paragraph: NSTextParagraph) -> [(frame: CGRect, baseline: CGFloat)] {
        guard let content = textLayoutManager?.textContentManager,
              let paragraphStart = paragraph.elementRange?.location,
              let start = content.location(paragraphStart, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let span = NSTextRange(location: start, end: end)
        else { return [] }

        var found: [(CGRect, CGFloat)] = []
        textLayoutManager?.enumerateTextSegments(
            in: span, type: .standard, options: []
        ) { _, frame, baseline, _ in
            found.append((frame.offsetBy(dx: -layoutFragmentFrame.minX,
                                         dy: -layoutFragmentFrame.minY), baseline))
            return true
        }
        return found
    }
}
#endif
