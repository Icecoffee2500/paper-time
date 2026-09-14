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

/// Paints the quotations and the chips, then lets the text draw on top.
final class NoteLayoutFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        drawQuotes(in: context)
        drawChips(in: context)
        super.draw(at: point, in: context)
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
        let reach = room > 0 && room < 10_000 ? room - box.minX : box.width
        // The fragment already begins where its words do — a paragraph set
        // in by twenty points has a box that starts twenty points in — so
        // the rule is placed from the fragment's own left edge and not from
        // the indent, which would put it under the first letter.
        return (edge, CGRect(x: -NoteQuoteBar.gap, y: 0,
                             width: max(reach, box.width) + NoteQuoteBar.gap,
                             height: box.height))
    }

    /// What a fragment may paint on. The default is the box its words
    /// occupy, and everything outside it is clipped — which is where the
    /// rule stands and where the ground reaches, so without this a quotation
    /// of two words got two words' worth of quotation.
    override var renderingSurfaceBounds: CGRect {
        guard let quotation else { return super.renderingSurfaceBounds }
        return super.renderingSurfaceBounds.union(quotation.ground)
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
}
#endif
