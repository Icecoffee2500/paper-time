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
    /// Marks a run as part of a quoted paragraph.
    static let attribute = NSAttributedString.Key("PaperTimeQuote")

    static var bar: NSColor { .controlAccentColor.withAlphaComponent(0.55) }
    static var ground: NSColor { .controlAccentColor.withAlphaComponent(0.05) }
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

    /// One bar per quoted paragraph, the height of the lines it covers.
    ///
    /// Drawn from the fragment's own bounds rather than per line, so a
    /// quotation that wraps gets one continuous rule rather than a dotted
    /// column of them.
    private func drawQuotes(in context: CGContext) {
        guard let paragraph = textElement as? NSTextParagraph else { return }
        let text = paragraph.attributedString
        guard text.length > 0,
              text.attribute(NoteQuoteBar.attribute, at: 0, effectiveRange: nil) != nil
        else { return }

        let box = layoutFragmentFrame
        let indent = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                      as? NSParagraphStyle)?.headIndent ?? 0
        let top = box.minY - layoutFragmentFrame.minY
        let ground = CGRect(x: indent - NoteQuoteBar.gap, y: top,
                            width: max(box.width - indent + NoteQuoteBar.gap, 0),
                            height: box.height)

        context.saveGState()
        NoteQuoteBar.ground.setFill()
        NSBezierPath(roundedRect: ground, xRadius: 4, yRadius: 4).fill()
        NoteQuoteBar.bar.setFill()
        NSBezierPath(
            roundedRect: CGRect(x: ground.minX, y: top,
                                width: NoteQuoteBar.width, height: box.height),
            xRadius: NoteQuoteBar.width / 2, yRadius: NoteQuoteBar.width / 2
        ).fill()
        context.restoreGState()
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
            for rect in rects(for: range, in: paragraph) {
                let box = rect.insetBy(dx: -NoteChip.padding.width, dy: -NoteChip.padding.height)
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
