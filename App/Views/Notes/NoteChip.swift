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

/// Paints the chips, then lets the text draw on top of them.
final class NoteLayoutFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        drawChips(in: context)
        super.draw(at: point, in: context)
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
