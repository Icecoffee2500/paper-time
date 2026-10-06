import Foundation
import PaperCore

#if os(macOS)
import AppKit
import CoreText
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// The Markdown a run stands for, when the run is not its own source: a
    /// heading whose `##` is not shown, a formula set as mathematics, a link
    /// shown as what it points at. Plain text is its own source.
    static let paperTimeSource = NSAttributedString.Key("PaperTimeSource")
    /// The lines folded away under a collapsed toggle, as written — carried
    /// by a zero-width run at the end of the toggle's line, which is also
    /// their `paperTimeSource`, so the note reads back whole.
    static let paperTimeFolded = NSAttributedString.Key("PaperTimeFolded")
    /// Which piece of its line a run belongs to, counted from the start of
    /// the line: a run that stands for a source is part of one piece, and a
    /// piece is often several runs — a Korean word in italics leans in a
    /// face of its own, the room either side of a code span is set apart
    /// from its letters. A piece is read back once however many runs it is
    /// set in (`markdown(from:)`); read run by run, a code span split three
    /// ways had come back as three code spans. Counted per line rather than
    /// across the note, so a line set again unchanged is the same line
    /// (`NoteEditor.changedLines` compares lines whole).
    static let paperTimePiece = NSAttributedString.Key("PaperTimePiece")
    /// Where the words a piece shows begin in its source, when they are
    /// written there as they are shown: the words of `**bold**` begin at 2.
    /// A caret put down among them goes to the same place among the words
    /// as written — it went to the end of the piece, past the closing `**`.
    static let paperTimeSourceLead = NSAttributedString.Key("PaperTimeSourceLead")
}

/// Turns a note between the Markdown that is stored and the text that is read.
///
/// The file on disk stays ordinary Markdown — links are links, formulas are
/// `$…$` — so a note can be read, searched and kept without this app. On screen
/// it is shown the way it reads: headings large, list markers as bullets,
/// formulas set as mathematics.
///
/// The one exception is the line the caret is on, which is always shown exactly
/// as it is written. That is what makes the thing editable: you can only change
/// what you can see, so the line being worked on shows its own syntax and every
/// other line shows its meaning.
enum NoteMarkdown {
    /// A note as it is shown, with the thread back to the Markdown it came
    /// from so the caret can be put back where the typist left it.
    struct Rendered {
        var text: NSAttributedString
        /// Display range and the source range it stands for, in order.
        var pieces: [(display: NSRange, source: NSRange)]

        func displayIndex(forSource index: Int) -> Int {
            for piece in pieces {
                let end = piece.source.location + piece.source.length
                if index < piece.source.location { return piece.display.location }
                if index <= end {
                    if piece.display.length == piece.source.length {
                        return piece.display.location + (index - piece.source.location)
                    }
                    return index >= end
                        ? piece.display.location + piece.display.length
                        : piece.display.location
                }
            }
            return text.length
        }
    }

    /// The paragraph styles, one per kind of line — see `paragraphStyle`.
    fileprivate nonisolated(unsafe) static var styles: [String: NSParagraphStyle] = [:]

    /// Stands in for syntax that is not shown, so the run has something to hang
    /// its source on and the caret has somewhere to be.
    static let hiddenMarker = "\u{200B}"
    /// A toggle's marker, open and folded.
    static let openToggle = "▾"
    static let closedToggle = "▸"

    /// The colour of the characters that do something — the `$` of a
    /// formula, the `**` round bold words, the `#` of a heading — on the
    /// line being edited, where they are shown as written. Coloured so they
    /// read as controls, not as words (the accent, a little quieter).
    static var syntaxColor: NoteColor { accent.withAlphaComponent(0.85) }

    /// Which characters of a line's words are syntax: the delimiters of the
    /// formulas, emphasis, links and escaped dollars in it, as `nextToken`
    /// finds them. Offsets are into `content`.
    static func syntaxRanges(inContent content: NSString) -> [NSRange] {
        guard holdsMarkup(content as String) else { return [] }
        var ranges: [NSRange] = []
        var index = 0
        while index < content.length, let token = nextToken(in: content, from: index) {
            let range = token.range
            let source = content.substring(with: range) as NSString
            func ends(_ head: Int, _ tail: Int) {
                guard head + tail <= range.length else { return }
                if head > 0 { ranges.append(NSRange(location: range.location, length: head)) }
                if tail > 0 { ranges.append(NSRange(location: NSMaxRange(range) - tail, length: tail)) }
            }
            switch token.kind {
            case .anchorLink:
                // "[" and "](url)".
                let close = source.range(of: "](", options: .backwards)
                ends(1, close.location == NSNotFound ? 0 : range.length - close.location)
            case .noteLink:
                // "[[id|" (or "[[") and "]]".
                let bar = source.range(of: "|")
                ends(bar.location == NSNotFound ? 2 : bar.location + 1, 2)
            case .math:
                if source.hasPrefix("$$") { ends(2, 2) }
                else if source.hasPrefix("$") { ends(1, 1) }
                else if source.hasPrefix("\\(") || source.hasPrefix("\\[") { ends(2, 2) }
                else if source.hasPrefix("\\begin{"),
                        let head = source.range(of: "}").location as Int?, head != NSNotFound,
                        let tail = source.range(of: "\\end{", options: .backwards).location as Int?, tail != NSNotFound {
                    ends(head + 1, range.length - tail)
                } else {
                    ends(0, 0)
                }
            case .emphasis(_, let bold, let italic, let mono, _):
                let width = emphasisWidth(bold: bold, italic: italic, mono: mono)
                ends(width, width)
            case .dollar:
                ends(1, 0)
            }
            index = NSMaxRange(range)
        }
        return ranges
    }

    /// How many characters each side of emphasised words are its marks:
    /// `*`, `**`, `***`, or a backtick.
    static func emphasisWidth(bold: Bool, italic: Bool, mono: Bool) -> Int {
        mono ? 1 : (bold ? 2 : 0) + (italic ? 1 : 0)
    }

    /// The words of the line being edited, as they are written: the line's
    /// own face and colour, the characters that do something in the syntax
    /// colour — and what they do already done, as Obsidian does it: the
    /// words between `**` bold, between `*` in italics, between backticks
    /// set as code. It had been only the colour, so a word made bold stayed
    /// plain for as long as the caret stayed on its line, which is to say
    /// while it was being looked at.
    ///
    /// `range` is a line's words — not its marker — in `text`. Used when the
    /// note is set (`render`) and on every keystroke that stays on the line
    /// (`NoteEditor.recolorCaretLine`), which is why the faces are put back
    /// first: a `*` taken away takes its italics with it.
    ///
    /// Only what is written as it is shown is touched. A line that is still
    /// set — a selection made on it by hand is not rebuilt under the hand —
    /// holds pieces (a chip, a formula, a bold word with its stars out of
    /// sight), and those keep their own faces; the stars ⌘B has just put in
    /// beside them are set all the same.
    static func styleAsWritten(_ text: NSMutableAttributedString, range: NSRange, block: Block) {
        guard range.length > 0 else { return }
        var written: [NSRange] = []
        text.enumerateAttribute(.paperTimeSource, in: range) { value, run, _ in
            guard value == nil else { return }
            if let last = written.last, NSMaxRange(last) == run.location {
                written[written.count - 1].length += run.length
            } else {
                written.append(run)
            }
        }
        for run in written {
            text.addAttributes([.font: block.font, .foregroundColor: block.colour], range: run)
            text.removeAttribute(.kern, range: run)
            #if os(macOS)
            text.removeAttribute(NoteCodeStyle.attribute, range: run)
            #endif
        }
        func isWritten(_ span: NSRange) -> Bool {
            written.contains { $0.location <= span.location && NSMaxRange(span) <= NSMaxRange($0) }
        }
        let content = (text.string as NSString).substring(with: range) as NSString
        if holdsMarkup(content as String) {
            var index = 0
            while index < content.length, let token = nextToken(in: content, from: index) {
                let whole = NSRange(location: range.location + token.range.location, length: token.range.length)
                if case .emphasis(_, let bold, let italic, let mono, _) = token.kind, isWritten(whole) {
                    let width = emphasisWidth(bold: bold, italic: italic, mono: mono)
                    if mono {
                        // The backticks in the code's face too, and the tint
                        // behind all of it.
                        text.addAttributes(codeAttributes(in: block), range: whole)
                    } else if whole.length > 2 * width {
                        text.addAttribute(.font, value: emphasisFont(in: block, bold: bold, italic: italic),
                                          range: NSRange(location: whole.location + width, length: whole.length - 2 * width))
                    }
                }
                index = NSMaxRange(token.range)
            }
            for syntax in syntaxRanges(inContent: content) {
                let span = NSRange(location: range.location + syntax.location, length: syntax.length)
                if isWritten(span) { text.addAttribute(.foregroundColor, value: syntaxColor, range: span) }
            }
        }
        #if os(macOS)
        NoteTypography.slantHangul(in: text, range: range)
        #endif
    }

    /// The face of emphasised words: the line's size — a heading's bold
    /// word is the heading's size, not the body's — with the weight and the
    /// slant asked for. Inside a quotation the words are in italics already,
    /// so bold there is bold italic: it is the paper's own emphasis, still
    /// quoted.
    static func emphasisFont(in block: Block, bold: Bool, italic: Bool) -> NoteFont {
        if let level = block.headingLevel { return NoteTypography.heading(level: level, bold: bold, italic: italic) }
        let quoted = block.kind == .quote
        return NoteTypography.body(bold: bold, italic: italic || quoted)
    }

    /// Words in backticks, as Notion sets them: a monospaced face a size
    /// below the line, in a warm red, on a rounded warm grey (`NoteCodeStyle`).
    static func codeAttributes(in block: Block) -> [NSAttributedString.Key: Any] {
        let face = NoteTypography.code(size: block.font.pointSize)
        var attributes: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: NoteCodeStyle.ink]
        #if os(macOS)
        attributes[NoteCodeStyle.attribute] = face.pointSize
        #else
        attributes[.backgroundColor] = NoteCodeStyle.fill
        #endif
        return attributes
    }

    /// The lines folded under a toggle at `index`: those indented deeper than
    /// it, and blank lines between such lines.
    static func children(ofToggleAt index: Int, lines: [NSRange], blocks: [Block], in text: NSString) -> Range<Int> {
        let depth = blocks[index].indent
        var end = index + 1
        var last = index
        while end < blocks.count {
            let line = text.substring(with: lines[end])
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                end += 1
                continue
            }
            guard blocks[end].indent > depth else { break }
            last = end
            end += 1
        }
        return (index + 1)..<(last + 1)
    }

    /// The number of a nested ordered item as a letter: 1 is a, 26 is z,
    /// 27 is aa — a spreadsheet's columns, in lower case.
    static func letters(_ number: Int) -> String {
        guard number > 0 else { return "\(number)" }
        var result = ""
        var left = number
        while left > 0 {
            left -= 1
            result = String(UnicodeScalar(UInt8(97 + left % 26))) + result
            left /= 26
        }
        return result
    }

    /// The number of an item nested twice as a roman numeral, in lower case.
    static func roman(_ number: Int) -> String {
        guard number > 0, number < 4000 else { return "\(number)" }
        let steps: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
            (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var left = number
        var result = ""
        for (value, numeral) in steps {
            while left >= value {
                result += numeral
                left -= value
            }
        }
        return result
    }

    /// The room a line has while a note is being rendered. Set for the length
    /// of a render rather than passed down through every kind of token, which
    /// only formulas care about. Rendering happens on the main thread, one
    /// note at a time, which is what makes a single value enough.
    private nonisolated(unsafe) static var available: CGFloat?
    /// The appearance the note is shown in, for the formulas: they are
    /// bitmaps, and a dynamic colour drawn into a bitmap outside a drawing
    /// pass resolves to the light appearance — dark notes got black
    /// formulas. `nil` is the application's.
    private nonisolated(unsafe) static var current: NoteAppearance?
    #if os(macOS)
    /// Where each formula of the note being set starts counting, and the
    /// labels it refers to, by where the formula is in the source — worked
    /// out for the whole note before any line is set (`numbered`).
    private nonisolated(unsafe) static var numbering: [Int: MathJaxEngine.Numbered] = [:]
    #endif

    // MARK: - Reading the source back

    static func markdown(from attributed: NSAttributedString) -> String {
        var result = ""
        var piece: Int?
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attributes, range, _ in
            if let source = attributes[.paperTimeSource] as? String {
                // The rest of a piece already read.
                let number = attributes[.paperTimePiece] as? Int
                if let number, number == piece { return }
                piece = number
                result += source
                return
            }
            piece = nil
            result += attributed.attributedSubstring(from: range).string
        }
        return result
    }

    /// Where the caret sits in the source, given where it sits on screen.
    static func sourceIndex(in attributed: NSAttributedString, displayIndex: Int) -> Int {
        let length = attributed.length
        var source = 0
        var location = 0
        while location < length {
            var run = NSRange()
            let attributes = attributed.attributes(at: location, effectiveRange: &run)
            guard let text = attributes[.paperTimeSource] as? String else {
                // Plain words are their own source, character for character.
                if displayIndex < NSMaxRange(run) { return source + max(0, displayIndex - run.location) }
                source += run.length
                location = NSMaxRange(run)
                continue
            }
            // A piece, however many runs it is set in.
            var piece = run
            if attributes[.paperTimePiece] != nil {
                _ = attributed.attribute(.paperTimePiece, at: location, longestEffectiveRange: &piece,
                                         in: NSRange(location: location, length: length - location))
            }
            let sourceLength = (text as NSString).length
            if displayIndex >= NSMaxRange(piece) {
                source += sourceLength
                location = NSMaxRange(piece)
                continue
            }
            let offset = displayIndex - piece.location
            if offset <= 0 { return source }
            if sourceLength == piece.length { return source + offset }
            if let lead = attributes[.paperTimeSourceLead] as? Int, lead + offset <= sourceLength {
                return source + lead + offset
            }
            return source + sourceLength
        }
        return source
    }

    // MARK: - Colours and attributes

    static var bodyFont: NoteFont { NoteTypography.body() }

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NoteColor.labelColor]
    }

    static var rawAttributes: [NSAttributedString.Key: Any] {
        [.font: NoteTypography.mono(), .foregroundColor: NoteColor.labelColor]
    }

    /// Links into the paper carry the app's accent rather than the system's
    /// link blue: they point inside this document, not out to the web.
    static var accent: NoteColor {
        #if os(macOS)
        NSColor.controlAccentColor
        #else
        UIColor.tintColor
        #endif
    }

    /// A link out of the note — to another note, or to the web.
    static func linkAttributes(_ url: URL) -> [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .link: url,
            .foregroundColor: accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    /// A passage lifted out of the paper, which is a different thing: not a
    /// pointer to somewhere else but a quotation with an address. No
    /// underline, and `NoteChip` paints the rounded tint behind it.
    #if os(macOS)
    static func passageAttributes(_ url: URL) -> [NSAttributedString.Key: Any] {
        // Deliberately not a `.link`. An `NSTextView` paints every link run in
        // its own link colour whatever the run says, so a chip that was also a
        // link came out blue no matter what colour it asked for. It carries
        // its destination in its own attribute instead, and `NoteTextView`
        // follows it on a click.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NoteChip.ink,
            NoteChip.attribute: url,
            // The hand, over the words. `NSTextView` honours this itself,
            // which is the one thing a `.link` would have given us for free.
            .cursor: NSCursor.pointingHand,
        ]
        // And a word about where it goes. A tint the pointer deepened would
        // have said "pressable" too, but TextKit 2 keeps a fragment's
        // rendering and would not draw the chip again on a hover — and a
        // tooltip says more: not just that it goes somewhere, but where.
        if let anchor = NoteAnchor(url: url) {
            attributes[.toolTip] = ReleaseNotes.string(
                "논문 \(anchor.pageIndex + 1)쪽의 이 구절로 가요",
                "Goes to this passage on page \(anchor.pageIndex + 1) of the paper"
            )
        }
        return attributes
    }
    #else
    static func passageAttributes(_ url: URL) -> [NSAttributedString.Key: Any] {
        linkAttributes(url)
    }
    #endif

    /// A passage standing inside a quotation: the block's own words, and
    /// pressable. On the Mac the pointer turns to a hand over it; everywhere
    /// the press goes back to the page.
    /// `words` is true when the link *is* the quotation — a note written
    /// before a passage became a block quote, where the whole line is one
    /// long link. Then it is set as the quoted words are. Otherwise it is the
    /// page under the quotation, which is a citation: the one thing in the
    /// block that goes somewhere, so it carries the accent.
    static func quotedPassageAttributes(
        _ url: URL, style: NSParagraphStyle, words: Bool = true
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: words
                ? NoteTypography.body(italic: true)
                : NoteTypography.body(size: NoteTypography.baseSize * 0.76),
            .foregroundColor: words ? NoteColor.labelColor : accent,
            .paragraphStyle: style,
        ]
        #if os(macOS)
        // The words of a quotation are part of it, so the bar reaches across
        // them and the chip painter leaves them alone — without that they
        // were the one run in the quotation wearing a chip. The page at the
        // end is the exception: it is in the quotation without being of it,
        // so it keeps the rounded tint that means "this goes somewhere",
        // which is the whole of what tells a quoted passage from a quotation
        // somebody typed.
        if words { attributes[NoteQuoteBar.attribute] = QuoteEdge.anchored.rawValue }
        attributes[NoteChip.attribute] = url
        attributes[.cursor] = NSCursor.pointingHand
        if let anchor = NoteAnchor(url: url) {
            attributes[.toolTip] = ReleaseNotes.string(
                "논문 \(anchor.pageIndex + 1)쪽의 이 구절로 가요",
                "Goes to this passage on page \(anchor.pageIndex + 1) of the paper"
            )
        }
        #else
        attributes[.link] = url
        attributes[.underlineStyle] = 0
        #endif
        return attributes
    }


    #if os(macOS)
    /// Renders a note file and prints what each run of it became, then quits.
    ///
    /// The note editor is three panes deep and its rows do not answer a
    /// synthetic click, so "is a quotation actually set as a quotation?" was a
    /// question that could only be answered by looking. This answers it in a
    /// terminal.
    /// The Markdown itself, not a path to it: the app is sandboxed, and a
    /// path handed to it on the command line is a path it may not read.
    /// `PAPERTIME_DUMP_NOTE_CARET=<offset in the Markdown>` sets the note
    /// with the caret there, so its line is shown as written;
    /// `PAPERTIME_DUMP_NOTE_FONTS=1` adds each run's face and the face the
    /// text is actually drawn in (where a cascade takes over).
    @MainActor
    static func dump(_ markdown: String) {
        let caret = Boot.setting("PAPERTIME_DUMP_NOTE_CARET").flatMap { Int($0) }
        let fonts = Boot.isSet("PAPERTIME_DUMP_NOTE_FONTS")
        let rendered = render(markdown, caret: caret, raw: false).text
        let whole = NSRange(location: 0, length: rendered.length)
        print("— \(rendered.length) characters from \(markdown.count) of Markdown")
        rendered.enumerateAttributes(in: whole) { attributes, range, _ in
            let text = rendered.attributedSubstring(from: range).string
                .replacingOccurrences(of: "\n", with: "⏎")
                .replacingOccurrences(of: "\u{200B}", with: "·")
            var marks: [String] = []
            if attributes[NoteQuoteBar.attribute] != nil { marks.append("QUOTE") }
            if attributes[NoteChip.attribute] != nil { marks.append("PASSAGE") }
            if attributes[.link] != nil { marks.append("LINK") }
            if attributes[NoteCodeStyle.attribute] != nil { marks.append("CODE") }
            // A fenced block's rows: their set-in is the numbers' room, which
            // is measured from this Mac's fonts, so it is left unprinted.
            let fenced = attributes[NoteCodeStyle.Block.attribute] != nil
            if fenced { marks.append("CODEBLOCK") }
            if let font = attributes[.font] as? NSFont, NoteTypography.isItalic(font) { marks.append("italic") }
            if !fenced, let style = attributes[.paragraphStyle] as? NSParagraphStyle, style.headIndent > 0 {
                marks.append("indent \(Int(style.headIndent))")
            }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle, style.alignment == .center {
                marks.append("center")
            }
            var line = String(format: "%5d %-14@ %@", range.location,
                              marks.isEmpty ? "—" : marks.joined(separator: "+") as NSString,
                              String(text.prefix(60)) as NSString)
            if fonts, let font = attributes[.font] as? NSFont {
                let drawn = CTLineCreateWithAttributedString(rendered.attributedSubstring(from: range))
                let faces = (CTLineGetGlyphRuns(drawn) as? [CTRun] ?? []).compactMap { run -> String? in
                    guard let face = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] else { return nil }
                    return CTFontCopyPostScriptName(face as! CTFont) as String
                }
                var seen: [String] = []
                for face in faces where !seen.contains(face) { seen.append(face) }
                line += "   [\(font.fontName) \(font.pointSize)\(font.textTransform.m21 != 0 ? " leaning" : "")"
                    + "\(attributes[.kern].map { " kern \($0)" } ?? "") → \(seen.joined(separator: ", "))]"
            }
            print(line)
        }
        // That the note reads back as it was written — with the caret on
        // no line and on each — and that a caret anywhere on screen lands
        // somewhere in the source, never backwards.
        var misread: [String] = []
        let source = markdown as NSString
        var starts = [0]
        for index in 0..<source.length where source.character(at: index) == 10 { starts.append(index + 1) }
        for caretAt in [nil] + starts.map(Optional.some) {
            let shown = render(markdown, caret: caretAt).text
            let back = NoteMarkdown.markdown(from: shown)
            if back != markdown {
                let read = back as NSString
                var at = 0
                while at < min(read.length, source.length), read.character(at: at) == source.character(at: at) { at += 1 }
                func near(_ text: NSString) -> String {
                    let from = max(0, at - 12)
                    return text.substring(with: NSRange(location: from, length: min(text.length, at + 24) - from)).debugDescription
                }
                misread.append("caret \(caretAt.map(String.init) ?? "none") at \(at): \(near(read)) ≠ \(near(source))")
            }
            var last = 0
            for index in 0...shown.length {
                let at = sourceIndex(in: shown, displayIndex: index)
                if at < last || at > source.length {
                    misread.append("caret \(caretAt.map(String.init) ?? "none"): screen \(index) → \(at) after \(last)")
                    break
                }
                last = at
            }
        }
        print(misread.isEmpty ? "— reads back whole" : "— reads back WRONG: \(misread.joined(separator: "; "))")
        // What the runs *say* is only half of it: the rule down a quotation
        // and the formula set as mathematics are drawn, not spelled, and
        // neither shows up in a list of attributes. With a path to write to,
        // the same note is laid out and saved as a picture.
        if let path = Boot.setting("PAPERTIME_DUMP_NOTE_IMAGE") {
            draw(markdown, to: path, caret: caret)
        }
        exit(0)
    }

    private final class Fragments: NSObject, NSTextLayoutManagerDelegate {
        func textLayoutManager(
            _ textLayoutManager: NSTextLayoutManager,
            textLayoutFragmentFor location: any NSTextLocation,
            in textElement: NSTextElement
        ) -> NSTextLayoutFragment {
            NoteLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
    }

    @MainActor
    private static func draw(_ markdown: String, to path: String, width: CGFloat = 620, caret: Int? = nil) {
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        view.textContainerInset = CGSize(width: 20, height: 18)
        view.backgroundColor = .textBackgroundColor
        // `PAPERTIME_DUMP_NOTE_DARK=1`: the same note on a dark page.
        let dark = Boot.isSet("PAPERTIME_DUMP_NOTE_DARK") ? NSAppearance(named: .darkAqua) : nil
        if let dark { view.appearance = dark }
        let fragments = Fragments()
        view.textLayoutManager?.delegate = fragments
        view.textStorage?.setAttributedString(render(markdown, caret: caret, width: width - 64, appearance: dark).text)
        if let layout = view.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(filePath: path))
        print("— drawn to \(path)")
        // Held to the end of the call: the layout manager does not keep its
        // delegate, and a fragment asked for after it has gone is a crash.
        withExtendedLifetime(fragments) {}
    }
    #endif

    // MARK: - Writing links

    static func noteURL(id: String) -> URL {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return URL(string: "papertime://note?id=\(escaped)")!
    }

    static func noteID(from url: URL) -> String? {
        guard url.scheme == "papertime", url.host == "note" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value
    }

    /// A passage from the paper, as the Markdown that will hold it.
    ///
    /// A quotation, not a link. A link says "there is more of this somewhere
    /// else" — which is what a `[[note]]` says, and the two had come to look
    /// like the same gesture. This is the other thing: these words are not
    /// mine, they are from page seven, and here they are. So it goes in as a
    /// block quote with the page under it, which is what a quotation has
    /// looked like since long before any of this.
    ///
    /// The address rides inside the quoted line, so pressing the words still
    /// goes back to them on the page.
    static func quotationSource(for anchor: NoteAnchor) -> String {
        let text = anchor.quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = text.isEmpty ? anchor.label : text
        let page = ReleaseNotes.string("\(anchor.pageIndex + 1)쪽", "p. \(anchor.pageIndex + 1)")
        // The passage arrives with the page's own shape in it — headings,
        // paragraphs, a displayed formula on its own line — and each of those
        // lines is a line of the quotation.
        var lines = quoted.components(separatedBy: "\n").flatMap { line -> [String] in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? [""] : quotationLines(of: trimmed)
        }
        let citation = "[\(escape(page))](\(anchor.url.absoluteString))"
        // At the end of the last line rather than on a line of its own. A
        // line that says "— 2쪽" is a line of prose that has to be read; the
        // page set close after the last word is a mark, and a mark is looked
        // at rather than read. A displayed formula keeps its own line, so
        // there the page goes under it.
        if let last = lines.last, !NoteMath.isDisplay(last), !last.hasPrefix("#") {
            lines[lines.count - 1] = last + " " + citation
        } else {
            lines.append(citation)
        }
        // An empty line inside a quotation is written "> ", not left blank:
        // a blank line would end the quotation and start another.
        return lines.map { $0.isEmpty ? ">\n" : "> \($0)\n" }.joined()
    }

    /// The quoted words, broken where a displayed formula wants a line.
    ///
    /// The passage arrives from `MathReader` as one line with its
    /// mathematics in `$…$` — the same reading UltraCopy puts on the
    /// clipboard, so a formula quoted into a note is a formula and not the
    /// prose PDFKit would have made of it. A `$$…$$` was set on a line of its
    /// own in the paper — and so was a numbered `equation` or `align`, which
    /// is how UltraCopy writes one — and putting it back on one keeps the
    /// quotation looking like what was quoted.
    static func quotationLines(of text: String) -> [String] {
        let whole = text as NSString
        var lines: [String] = []
        var index = 0
        func add(_ piece: String) {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        for range in NoteMath.displays(in: text) {
            add(whole.substring(with: NSRange(location: index, length: range.location - index)))
            add(whole.substring(with: range))
            index = range.location + range.length
        }
        add(whole.substring(from: index))
        return lines.isEmpty ? [text] : lines
    }

    /// Brackets and backslashes in a label would end the link early, so they
    /// travel escaped — which is what any Markdown reader expects of them.
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if character == "\\" || character == "[" || character == "]" { result.append("\\") }
            result.append(character)
        }
        return result
    }

    static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    // MARK: - Rendering

    static func attributed(from markdown: String) -> NSAttributedString {
        render(markdown).text
    }

    /// The whole note, laid out. `caret` is where the typist is, in source
    /// coordinates: the line it falls on is shown as it is written.
    /// Renders a note.
    ///
    /// `width` is the room a line has, which formulas need: one that does not
    /// fit is broken across lines rather than run off the edge of the pane.
    static func render(
        _ source: String, caret: Int? = nil, raw: Bool = false, width: CGFloat? = nil,
        appearance: NoteAppearance? = nil, collapsed: Set<String> = []
    ) -> Rendered {
        Trace.time("note: render \(source.count) characters") {
            renderNow(source, caret: caret, raw: raw, width: width, appearance: appearance, collapsed: collapsed)
        }
    }

    private static func renderNow(
        _ source: String, caret: Int? = nil, raw: Bool = false, width: CGFloat? = nil,
        appearance: NoteAppearance? = nil, collapsed: Set<String> = []
    ) -> Rendered {
        available = width
        current = appearance
        let text = source as NSString
        if raw {
            let whole = NSMutableAttributedString(string: source, attributes: rawAttributes)
            return Rendered(
                text: whole,
                pieces: [(NSRange(location: 0, length: whole.length),
                          NSRange(location: 0, length: text.length))]
            )
        }

        let result = NSMutableAttributedString()
        var pieces: [(display: NSRange, source: NSRange)] = []
        var pieceInLine = 0

        func append(_ piece: NSAttributedString, source range: NSRange) {
            guard piece.length > 0 else { return }
            let start = result.length
            result.append(piece)
            let shown = NSRange(location: start, length: piece.length)
            if piece.attribute(.paperTimeSource, at: 0, effectiveRange: nil) != nil {
                result.addAttribute(.paperTimePiece, value: pieceInLine, range: shown)
                pieceInLine += 1
            }
            pieces.append((shown, range))
        }

        // Fenced code first: its lines are code whatever they look like —
        // `# comment` is not a heading, `- x` not a bullet, `$x$` not a
        // formula — so they are read as nothing else (`NoteCode`).
        let fenced = NoteCode.blocks(in: source)
        #if os(macOS)
        let codeRows = codeRows(of: fenced, in: text)
        #endif
        let isCode: (NSRange) -> Bool = { range in
            fenced.contains { NSLocationInRange(range.location, $0.range) || range.location == $0.range.location }
        }

        // Every line is read before any is set, because a quoted line needs
        // to know whether the line above and below it are quoted too.
        let lineRanges = lines(of: text, joiningMathBlocksIn: source)
        var blocks = lineRanges.map { isCode($0) ? Block(line: "") : Block(line: text.substring(with: $0)) }
        for index in blocks.indices where blocks[index].kind == .quote {
            var edge: QuoteEdge = []
            if index == 0 || blocks[index - 1].kind != .quote { edge.insert(.opens) }
            if index == blocks.count - 1 || blocks[index + 1].kind != .quote {
                edge.insert(.closes)
            }
            blocks[index].quoteEdge = edge
        }
        // An address anywhere in a quotation belongs to all of it: the page
        // is written at the end, and the line above it is the same quotation.
        var start = 0
        while start < blocks.count {
            guard blocks[start].kind == .quote else {
                start += 1
                continue
            }
            var end = start
            while end + 1 < blocks.count, blocks[end + 1].kind == .quote { end += 1 }
            if (start...end).contains(where: { blocks[$0].content.contains("](papertime://anchor") }) {
                for index in start...end { blocks[index].quoteEdge.insert(.anchored) }
            }
            start = end + 1
        }

        #if os(macOS)
        numbering = numbered(lineRanges, blocks, source: source)
        #endif

        let tables = Set(NoteTable.blocks(in: blankingCode(in: source, fenced.map(\.range))).map { NSStringRange($0) })
        var lineIndex = 0
        while lineIndex < lineRanges.count {
            let lineRange = lineRanges[lineIndex]
            let block = blocks[lineIndex]
            lineIndex += 1
            pieceInLine = 0
            // A folded toggle: its children are not set at all. They ride
            // along as the source of a zero-width run at the end of its
            // line, so the note reads back whole and the caret has nowhere
            // to go inside them.
            var folded: Range<Int>?
            if block.kind == .toggle, collapsed.contains(block.toggleKey) {
                let range = children(ofToggleAt: lineIndex - 1, lines: lineRanges, blocks: blocks, in: text)
                if !range.isEmpty {
                    folded = range
                    lineIndex = range.upperBound
                }
            }
            let revealed = caret.map {
                $0 >= lineRange.location && $0 <= lineRange.location + lineRange.length
            } ?? false
            #if os(macOS)
            if let row = codeRows[lineRange.location] {
                appendCode(row, line: lineRange, revealed: revealed, in: text, append: append)
                continue
            }
            // A table, drawn as a grid while the caret is elsewhere; with the
            // caret in it, its lines as they are written.
            if !revealed, tables.contains(NSStringRange(lineRange)),
               let table = NoteTable.parse(text.substring(with: lineRange)),
               let grid = tablePiece(table, source: text.substring(with: lineRange), style: block.paragraphStyle) {
                append(grid, source: lineRange)
                let newline = lineRange.location + lineRange.length
                if newline < text.length {
                    append(
                        NSAttributedString(string: "\n", attributes: [
                            .font: bodyFont, .foregroundColor: NoteColor.labelColor,
                            .paragraphStyle: block.paragraphStyle,
                        ]),
                        source: NSRange(location: newline, length: 1)
                    )
                }
                continue
            }
            #endif
            let markerLength = (block.marker as NSString).length
            // A formula set on a line of its own is set as a paper sets one:
            // in the middle of the line, and one with numbers across all of
            // it, the numbers at the right-hand edge.
            let alone = !revealed && standsAlone(block)
            let style = alone ? centered(block.paragraphStyle) : block.paragraphStyle

            if markerLength > 0 {
                // Every marker is drawn on the line being edited as well
                // (Notion): a bullet stays a bullet, a heading stays set as
                // one with its "#" out of sight, a quotation keeps its bar.
                // The way back to plain words is Backspace at the start of
                // the words, which takes the marker away (`deleteBackward`).
                // On the line being edited a heading's "#" and a quotation's
                // ">" are shown as written, coloured as syntax, so they can
                // be seen and changed — as in Obsidian. A list's marker is
                // drawn there too (Notion).
                let asWritten = revealed && (block.kind == .quote || { if case .heading = block.kind { true } else { false } }())
                let shown = asWritten ? block.marker : (folded != nil ? block.collapsedMarker : block.shownMarker)
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: block.markerFont, .foregroundColor: asWritten ? syntaxColor : block.markerColor,
                ]
                attributes[.paragraphStyle] = style
                #if os(macOS)
                // The stand-in for a quotation's "> " is the first thing in
                // the paragraph, and the rule is drawn per paragraph — so
                // leaving the marker out of the quotation was leaving the
                // quotation out of the rule. That is why no bar ever
                // appeared beside one.
                if block.kind == .quote {
                    attributes[NoteQuoteBar.attribute] = block.quoteEdge.rawValue
                }
                #endif
                let piece = NSMutableAttributedString(string: shown, attributes: attributes)
                if shown != block.marker {
                    piece.addAttribute(.paperTimeSource, value: block.marker,
                                       range: NSRange(location: 0, length: piece.length))
                }
                append(piece, source: NSRange(location: lineRange.location, length: markerLength))
            }

            let contentStart = lineRange.location + markerLength
            let content = block.content as NSString
            var index = 0
            // Four regular expressions used to be run over every line of
            // every note on every keystroke, looking for links, wiki links,
            // formulas and emphasis. Most lines of most notes are prose and
            // hold none of the four characters those begin with, and asking
            // that question costs one pass over the line instead of four.
            let mayHold = !revealed && Self.holdsMarkup(block.content)
            if revealed {
                // As written, the syntax in the syntax colour and the
                // emphasis already applied (`styleAsWritten`).
                let words = NSMutableAttributedString(string: block.content, attributes: block.attributes(style: style))
                styleAsWritten(words, range: NSRange(location: 0, length: words.length), block: block)
                append(words, source: NSRange(location: contentStart, length: content.length))
                index = content.length
            }
            while index < content.length {
                let rest = NSRange(location: index, length: content.length - index)
                guard mayHold, let token = nextToken(in: content, from: index) else {
                    append(
                        NSAttributedString(string: content.substring(with: rest),
                                           attributes: block.attributes(style: style)),
                        source: NSRange(location: contentStart + index, length: rest.length)
                    )
                    break
                }
                if token.range.location > index {
                    let plain = NSRange(location: index, length: token.range.location - index)
                    append(
                        NSAttributedString(string: content.substring(with: plain),
                                           attributes: block.attributes(style: style)),
                        source: NSRange(location: contentStart + plain.location,
                                        length: plain.length)
                    )
                }
                append(
                    piece(for: token, block: block, style: style,
                          at: contentStart + token.range.location, alone: alone),
                    source: NSRange(location: contentStart + token.range.location,
                                    length: token.range.length)
                )
                index = token.range.location + token.range.length
            }

            var newline = lineRange.location + lineRange.length
            if let folded {
                let last = lineRanges[folded.upperBound - 1]
                let hidden = NSRange(location: newline, length: NSMaxRange(last) - newline)
                let away = text.substring(with: hidden)
                let piece = NSMutableAttributedString(string: hiddenMarker, attributes: block.attributes(style: style))
                piece.addAttribute(.paperTimeSource, value: away, range: NSRange(location: 0, length: piece.length))
                piece.addAttribute(.paperTimeFolded, value: away, range: NSRange(location: 0, length: piece.length))
                append(piece, source: hidden)
                newline = NSMaxRange(last)
            }
            if newline < text.length {
                append(
                    NSAttributedString(string: "\n", attributes: [
                        .font: bodyFont,
                        .foregroundColor: NoteColor.labelColor,
                        .paragraphStyle: style,
                    ]),
                    source: NSRange(location: newline, length: 1)
                )
            }
        }

        #if os(macOS)
        // Hangul in italics leans with the Latin beside it.
        NoteTypography.slantHangul(in: result, range: NSRange(location: 0, length: result.length))
        #endif
        return Rendered(text: result, pieces: pieces)
    }

    // MARK: - Blocks

    /// Which ends of a quotation a line owns.
    ///
    /// A block quote is several lines and so several paragraphs, and a
    /// paragraph is what the layout draws at a time. Without this each line
    /// would get its own little rule with a gap above and below it, which is
    /// a dotted column rather than a quotation. Knowing which line opens and
    /// which closes lets the rule be rounded at the two ends and run
    /// straight through everything between.
    struct QuoteEdge: OptionSet {
        let rawValue: Int
        static let opens = QuoteEdge(rawValue: 1)
        static let closes = QuoteEdge(rawValue: 2)
        /// The quotation carries a passage's address — it came off a page
        /// with ⌘L rather than being typed. It is drawn differently: the
        /// accent rather than a grey, a faint ground under it, and the page
        /// itself at the end of the last line.
        static let anchored = QuoteEdge(rawValue: 4)
    }

    /// What kind of line this is, and what the characters at its head mean.
    struct Block {
        enum Kind: Equatable { case plain, heading(Int), quote, bullet, ordered(Int), task(Bool), toggle }

        var kind: Kind = .plain
        var marker = ""
        var content = ""
        var indent = 0
        /// Set by the renderer once it can see the lines on either side.
        var quoteEdge: QuoteEdge = []
        /// The heading level of a quoted line that was a section title on the
        /// page. Nil for everything else, including an ordinary heading —
        /// that is `kind`.
        var heading: Int?

        init(line: String) {
            let text = line as NSString
            var spaces = 0
            while spaces < text.length,
                  text.substring(with: NSRange(location: spaces, length: 1)) == " " {
                spaces += 1
            }
            indent = spaces / 2
            let body = text.substring(from: spaces) as NSString
            let lead = String(repeating: " ", count: spaces)
            let whole = NSRange(location: 0, length: body.length)

            func take(_ pattern: NSRegularExpression) -> NSTextCheckingResult? {
                pattern.firstMatch(in: body as String, range: whole)
            }

            // Every one of these patterns is anchored to the first character,
            // so a line that does not begin with one of their characters
            // cannot match any of them — and asking four regular expressions
            // about it, per line, per keystroke, was most of what it cost to
            // set a note.
            let head = (body as String).utf8.first ?? 0
            let couldBeMarked = head == 0x23 || head == 0x2D || head == 0x2A  // # - *
                || head == 0x2B || head == 0x3E || (head >= 0x30 && head <= 0x39)  // + > 0-9
            guard couldBeMarked else {
                marker = ""
                content = line
                return
            }

            if let match = take(Self.taskPattern) {
                marker = lead + body.substring(with: match.range)
                content = body.substring(from: match.range.length)
                kind = .task(body.substring(with: match.range(at: 2)).lowercased() == "x")
            } else if let match = take(Self.headingPattern) {
                marker = lead + body.substring(with: match.range)
                content = body.substring(from: match.range.length)
                kind = .heading(body.substring(with: match.range(at: 1)).count)
            } else if let match = take(Self.togglePattern) {
                // A "+" item is a toggle (Notion's): its children are the
                // lines indented under it, and the marker folds them away.
                // Everywhere else it is a bullet, which is what the file says.
                marker = lead + body.substring(with: match.range)
                content = body.substring(from: match.range.length)
                kind = .toggle
            } else if let match = take(Self.bulletPattern) {
                marker = lead + body.substring(with: match.range)
                content = body.substring(from: match.range.length)
                kind = .bullet
            } else if let match = take(Self.orderedPattern) {
                marker = lead + body.substring(with: match.range)
                content = body.substring(from: match.range.length)
                kind = .ordered(Int(body.substring(with: match.range(at: 1))) ?? 1)
            } else if body.hasPrefix(">") {
                let after = body.hasPrefix("> ") ? 2 : 1
                marker = lead + body.substring(to: after)
                content = body.substring(from: after)
                kind = .quote
                // A quotation can hold the section it was taken from. The
                // "###" belongs to the marker, so it is hidden with the ">"
                // and the words are set as the heading they were on the page.
                let inner = content as NSString
                if let match = Self.headingPattern.firstMatch(
                    in: content, range: NSRange(location: 0, length: inner.length)
                ) {
                    marker += inner.substring(with: match.range)
                    heading = inner.substring(with: match.range(at: 1)).count
                    content = inner.substring(from: match.range.length)
                }
            } else {
                marker = ""
                content = line
            }
        }

        /// What stands in for the marker when the line is not being edited.
        /// A list marker stands in on the line being edited too: a bullet
        /// is a bullet, never "- " (a reader saw his bullets come and go as
        /// the caret came and went). Nested lists step through the marks
        /// an outliner does — •, ◦, ▪ and 1., a., i. — by depth.
        var shownMarker: String {
            switch kind {
            case .plain: ""
            case .heading, .quote: NoteMarkdown.hiddenMarker
            case .bullet: ["•", "◦", "▪"][indent % 3] + "\t"
            case .ordered(let number):
                switch indent % 3 {
                case 0: "\(number).\t"
                case 1: "\(NoteMarkdown.letters(number)).\t"
                default: "\(NoteMarkdown.roman(number)).\t"
                }
            case .task(let done): done ? "☑\t" : "☐\t"
            case .toggle: NoteMarkdown.openToggle + "\t"
            }
        }

        /// The toggle's marker when its children are folded away.
        var collapsedMarker: String { NoteMarkdown.closedToggle + "\t" }

        /// What names a toggle across edits elsewhere in the note: the line
        /// as written, without its indentation.
        var toggleKey: String { String((marker + content).drop { $0 == " " }) }

        /// The size of heading the line is set at — a heading's own, or a
        /// quoted section title's — or nil.
        var headingLevel: Int? {
            if let heading { return heading }
            if case .heading(let level) = kind { return level }
            return nil
        }

        /// Whether the marker is a list's: drawn as its stand-in wherever
        /// the caret is.
        var isListItem: Bool {
            switch kind {
            case .bullet, .ordered, .task, .toggle: true
            default: false
            }
        }

        var font: NoteFont {
            if let heading { return NoteTypography.heading(level: heading) }
            switch kind {
            case .heading(let level): return NoteTypography.heading(level: level)
            case .quote: return NoteTypography.body(italic: true)
            default: return NoteTypography.body()
            }
        }

        var markerFont: NoteFont {
            switch kind {
            case .heading(let level): NoteTypography.heading(level: level)
            default: NoteTypography.body()
            }
        }

        var markerColor: NoteColor {
            switch kind {
            case .task(let done): done ? .secondaryLabelColor : .labelColor
            default: .secondaryLabelColor
            }
        }

        var colour: NoteColor {
            switch kind {
            // A quotation lifted off a page is somebody's actual words and
            // is set as darkly as the note around it. One typed by hand is
            // an aside — the writer's own voice, quoted — and steps back.
            case .quote:
                heading != nil || quoteEdge.contains(.anchored)
                    ? .labelColor : .secondaryLabelColor
            case .task(let done): done ? .secondaryLabelColor : .labelColor
            default: .labelColor
            }
        }

        func attributes(style: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: colour,
                .paragraphStyle: style,
            ]
            if case .task(true) = kind {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            #if os(macOS)
            // The bar down the left of a quotation is drawn, not typed, so the
            // layout needs to know which lines are quoted, and which of them
            // are the first and the last.
            if kind == .quote { attributes[NoteQuoteBar.attribute] = quoteEdge.rawValue }
            #endif
            return attributes
        }

        /// Wrapped lines of a list item line up under the first word rather
        /// than under the bullet — what every outliner does and no plain text
        /// view does by itself.
        var paragraphStyle: NSParagraphStyle {
            // One style per kind of line, not one per line: they are read
            // from here and never changed.
            let key = "\(kind)|\(indent)"
            if let known = NoteMarkdown.styles[key] { return known }
            let style = NSMutableParagraphStyle()
            // Where a line may end. Without this, TextKit ends one wherever it
            // runs out of room, and Korean has no rule against that being the
            // middle of a word: 라이브러리를 comes apart as 라이브 / 러리를 and
            // the reader puts the word back together before they read the
            // sentence. Asked, TextKit breaks at the space instead, and still
            // goes inside a word when the word is wider than the column.
            style.lineBreakStrategy = .standard
            // Air. A note is read in a narrow column beside a paper, and the
            // old setting — two points of leading, three between paragraphs —
            // was a page of type with nowhere to rest. This is roughly the
            // rhythm the system's own writing apps use.
            style.lineSpacing = 4.5
            style.paragraphSpacing = 11
            let step = NoteTypography.baseSize * 1.5
            switch kind {
            case .bullet, .ordered, .task, .toggle:
                let base = step * CGFloat(indent + 1)
                style.firstLineHeadIndent = base - step * 0.62
                style.headIndent = base
                style.tabStops = [NSTextTab(textAlignment: .left, location: base)]
            case .quote:
                // Room on the left for the bar, and above and below so the
                // quotation reads as a thing set into the note rather than a
                // paragraph that happens to be in italics.
                style.firstLineHeadIndent = step * 0.85
                style.headIndent = step * 0.85
                style.paragraphSpacing = 3
                style.paragraphSpacingBefore = 3
            case .heading:
                style.paragraphSpacing = 6
                style.paragraphSpacingBefore = 18
            case .plain:
                break
            }
            NoteMarkdown.styles[key] = style
            return style
        }

        static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})\s+"#)
        static let bulletPattern = try! NSRegularExpression(pattern: #"^[-*]\s+"#)
        static let togglePattern = try! NSRegularExpression(pattern: #"^\+\s+"#)
        static let orderedPattern = try! NSRegularExpression(pattern: #"^(\d{1,3})[.)]\s+"#)
        static let taskPattern = try! NSRegularExpression(pattern: #"^([-*+])\s+\[([ xX])\]\s+"#)
    }

    // MARK: - Lines

    static func lines(of text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var start = 0
        while start <= text.length {
            let searchRange = NSRange(location: start, length: text.length - start)
            let newline = text.range(of: "\n", range: searchRange)
            if newline.location == NSNotFound {
                result.append(searchRange)
                break
            }
            result.append(NSRange(location: start, length: newline.location - start))
            start = newline.location + 1
            if start == text.length {
                result.append(NSRange(location: start, length: 0))
                break
            }
        }
        return result
    }

    /// The lines, with a `$$` that opens on one line and closes on another
    /// read as one. Latex Suite's `dm` writes exactly that shape —
    /// `$$`, a line of LaTeX, `$$` — and read a line at a time it was three
    /// lines of prose, so the formula stayed raw. Joined, the block goes
    /// through the same formula pattern as `$$x$$` on a line, and the
    /// caret anywhere in it shows the whole block as it is written.
    static func lines(of text: NSString, joiningMathBlocksIn source: String) -> [NSRange] {
        var ranges = lines(of: text)
        // A table's lines too, and for the same reason: it is one thing
        // written over several lines (`NoteTable`). Not inside fenced code,
        // where a `$$` and a `|` are code (`blankingCode`).
        let searched = blankingCode(in: source, NoteCode.blocks(in: source).map(\.range))
        let joined = (NoteMath.blocks(in: searched) + NoteTable.blocks(in: searched))
            .sorted { $0.location < $1.location }
        for block in joined.reversed() {
            guard let first = ranges.firstIndex(where: { $0.location == block.location }),
                  let last = ranges.firstIndex(where: {
                      $0.location + $0.length == block.location + block.length
                  }), last >= first
            else { continue }
            ranges.replaceSubrange(first...last, with: [block])
        }
        return ranges
    }

    #if os(macOS)
    // MARK: - Fenced code

    /// A line of a fenced block, as the renderer sets it: its block, what it
    /// is in the block, where it starts in the block's code, and the
    /// block's colours (in the code's offsets).
    struct CodeRow {
        var block: NoteCode.Block
        var row: NoteCodeStyle.Block.Row
        var offset: Int
        var runs: [CodeHighlighter.Run]
    }

    /// Every line of every fenced block, by where the line starts.
    static func codeRows(of fenced: [NoteCode.Block], in text: NSString) -> [Int: CodeRow] {
        var rows: [Int: CodeRow] = [:]
        for block in fenced {
            let code = NoteCode.code(of: block, in: text)
            let runs = CodeHighlighter.shared.runs(of: code, language: block.language)
            let closed = block.close != nil
            rows[block.open.location] = CodeRow(
                block: block, row: .init(role: .header, isLast: !closed && block.lines.isEmpty), offset: 0, runs: runs)
            var offset = 0
            for (index, line) in block.lines.enumerated() {
                let last = !closed && index == block.lines.count - 1
                rows[line.location] = CodeRow(block: block, row: .init(role: .line, number: index + 1, isLast: last),
                                             offset: offset, runs: runs)
                offset += line.length + 1
            }
            if let close = block.close {
                rows[close.location] = CodeRow(block: block, row: .init(role: .close, isLast: true), offset: 0, runs: runs)
            }
        }
        return rows
    }

    /// A line of a fenced block, set: the header shows the language (the
    /// fence as written while the caret is on it), each line of code is
    /// itself in the code face with its colours, and the closing fence is
    /// the box's foot. The box, the numbers and the copy button are painted
    /// behind by `NoteLayoutFragment.drawCodeBlock`.
    static func appendCode(_ row: CodeRow, line: NSRange, revealed: Bool, in text: NSString,
                           append: (NSAttributedString, NSRange) -> Void) {
        let block = NoteCodeStyle.Block.self
        let gutter = block.gutter(lines: row.block.lines.count)
        let codeFont = NoteTypography.code()
        let written = text.substring(with: line)
        let style: NSParagraphStyle
        let piece: NSMutableAttributedString
        switch row.row.role {
        case .header:
            style = codeParagraph(.header(written: revealed), gutter: gutter, isLast: row.row.isLast)
            if revealed {
                piece = NSMutableAttributedString(string: written, attributes: [
                    .font: codeFont, .foregroundColor: syntaxColor, .paragraphStyle: style,
                    .baselineOffset: block.headerLift(for: codeFont),
                ])
                // The language as words, after the fence's marks.
                let marks = written.prefix { $0 == " " || $0 == "`" || $0 == "~" }.utf16.count
                if marks < piece.length {
                    piece.addAttribute(.foregroundColor, value: NoteColor.secondaryLabelColor,
                                       range: NSRange(location: marks, length: piece.length - marks))
                }
            } else {
                let name = NoteCode.displayName(of: row.block.language)
                let font = block.headerFont()
                // In the accent, in the middle of the chip `drawCodeBlock` paints.
                piece = NSMutableAttributedString(string: name.isEmpty ? hiddenMarker : name, attributes: [
                    .font: font, .foregroundColor: block.labelInk, .paragraphStyle: style,
                    .baselineOffset: block.headerLift(for: font),
                ])
                piece.addAttribute(.paperTimeSource, value: written, range: NSRange(location: 0, length: piece.length))
            }
        case .line:
            style = codeParagraph(.line(first: row.row.number == 1), gutter: gutter, isLast: row.row.isLast)
            piece = NSMutableAttributedString(string: written, attributes: [
                .font: codeFont, .foregroundColor: NoteColor.labelColor, .paragraphStyle: style,
            ])
            let span = NSRange(location: row.offset, length: line.length)
            for run in row.runs {
                let overlap = NSIntersectionRange(run.range, span)
                guard overlap.length > 0 else { continue }
                piece.addAttribute(.foregroundColor, value: block.ink(run.role),
                                   range: NSRange(location: overlap.location - row.offset, length: overlap.length))
            }
        case .close:
            if revealed {
                style = codeParagraph(.writtenFoot, gutter: gutter, isLast: true)
                piece = NSMutableAttributedString(string: written, attributes: [
                    .font: codeFont, .foregroundColor: syntaxColor, .paragraphStyle: style,
                ])
            } else {
                style = codeParagraph(.foot, gutter: gutter, isLast: true)
                piece = NSMutableAttributedString(string: hiddenMarker, attributes: [
                    .font: NoteTypography.code(size: 6), .foregroundColor: NoteColor.labelColor, .paragraphStyle: style,
                ])
                piece.addAttribute(.paperTimeSource, value: written, range: NSRange(location: 0, length: piece.length))
            }
        }
        piece.addAttribute(block.attribute, value: row.row.raw, range: NSRange(location: 0, length: piece.length))
        append(piece, line)
        let newline = NSMaxRange(line)
        if newline < text.length {
            // The line's own look on its line break: an empty line of code is
            // nothing but this, and it still has to be a row of the box.
            let font = (piece.length > 0 ? piece.attribute(.font, at: 0, effectiveRange: nil) as? NoteFont : nil) ?? codeFont
            append(NSAttributedString(string: "\n", attributes: [
                .font: font, .foregroundColor: NoteColor.labelColor, .paragraphStyle: style,
                block.attribute: row.row.raw,
            ]), NSRange(location: newline, length: 1))
        }
    }

    /// The colours of the block around a display offset, laid over its lines
    /// again while it is typed into: its rows are the lines round about that
    /// carry `NoteCodeStyle.Block.attribute`, from its header to its foot.
    static func recolourCode(_ text: NSMutableAttributedString, around index: Int) {
        let string = text.string as NSString
        let key = NoteCodeStyle.Block.attribute
        func row(of line: NSRange) -> NoteCodeStyle.Block.Row? {
            guard text.length > 0 else { return nil }
            return NoteCodeStyle.Block.Row(text.attribute(key, at: min(line.location, text.length - 1), effectiveRange: nil))
        }
        var rows = [string.lineRange(for: NSRange(location: min(index, string.length), length: 0))]
        guard let here = row(of: rows[0]) else { return }
        if here.role != .header {
            while let first = rows.first, first.location > 0 {
                let above = string.lineRange(for: NSRange(location: first.location - 1, length: 0))
                guard let kind = row(of: above), kind.role != .close else { break }
                rows.insert(above, at: 0)
                if kind.role == .header { break }
            }
        }
        if !here.isLast {
            while let last = rows.last, NSMaxRange(last) < string.length {
                let below = string.lineRange(for: NSRange(location: NSMaxRange(last), length: 0))
                guard let kind = row(of: below), kind.role != .header else { break }
                rows.append(below)
                if kind.role == .close || kind.isLast { break }
            }
        }
        // The language: the header's fence, as written or behind its name.
        var language = ""
        if let header = rows.first, row(of: header)?.role == .header {
            let fence = (text.attribute(.paperTimeSource, at: header.location, effectiveRange: nil) as? String)
                ?? string.substring(with: header).trimmingCharacters(in: .newlines)
            language = NoteCode.opening(fence)?.language ?? ""
        }
        let lines = rows.filter { row(of: $0)?.role == .line }.map { line -> NSRange in
            var range = line
            if range.length > 0, string.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
            return range
        }
        let code = lines.map { string.substring(with: $0) }.joined(separator: "\n")
        let runs = CodeHighlighter.shared.runs(of: code, language: language)
        var offset = 0
        for line in lines {
            text.addAttribute(.foregroundColor, value: NoteColor.labelColor, range: line)
            let span = NSRange(location: offset, length: line.length)
            for run in runs {
                let overlap = NSIntersectionRange(run.range, span)
                guard overlap.length > 0 else { continue }
                text.addAttribute(.foregroundColor, value: NoteCodeStyle.Block.ink(run.role),
                                  range: NSRange(location: line.location + overlap.location - offset, length: overlap.length))
            }
            offset += line.length + 1
        }
    }

    private enum CodeParagraph: Hashable {
        /// `written`: the fence as typed, which may run to the box's edge —
        /// otherwise the words keep clear of the copy pill.
        case header(written: Bool), line(first: Bool), foot, writtenFoot
    }

    private nonisolated(unsafe) static var codeStyles: [String: NSParagraphStyle] = [:]

    /// The paragraph of a row: the code set in past the numbers, the header
    /// and foot their own heights, and the block's margin above and below.
    private static func codeParagraph(_ kind: CodeParagraph, gutter: CGFloat, isLast: Bool) -> NSParagraphStyle {
        let key = "\(kind)|\(gutter)|\(isLast)"
        if let kept = codeStyles[key] { return kept }
        let block = NoteCodeStyle.Block.self
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = .standard
        style.tailIndent = -block.inset
        switch kind {
        case .header(let written):
            // Inside the chip, and the fence as written where the chip was.
            style.firstLineHeadIndent = block.labelIndent
            style.headIndent = block.labelIndent
            style.tailIndent = -(written ? block.inset : block.copyRoom)
            style.minimumLineHeight = block.headerHeight
            style.maximumLineHeight = block.headerHeight
            style.lineBreakMode = .byTruncatingTail
            style.paragraphSpacingBefore = block.margin
        case .line(let first):
            style.firstLineHeadIndent = block.inset + gutter
            style.headIndent = block.inset + gutter
            style.minimumLineHeight = block.lineHeight()
            style.maximumLineHeight = block.lineHeight()
            if first { style.paragraphSpacingBefore = block.firstLineGap }
        case .foot:
            style.minimumLineHeight = block.footHeight
            style.maximumLineHeight = block.footHeight
        case .writtenFoot:
            style.firstLineHeadIndent = block.inset + gutter
            style.headIndent = block.inset + gutter
            style.minimumLineHeight = block.lineHeight()
            style.maximumLineHeight = block.lineHeight()
        }
        // The last row carries the room under the box, and in a block never
        // closed that is its last line.
        if isLast { style.paragraphSpacing = block.margin + (kind == .foot ? 0 : block.footHeight / 2) }
        codeStyles[key] = style
        return style
    }
    #endif

    /// The source with every fenced block's characters but its line breaks
    /// turned to spaces: what the readers of mathematics and tables are
    /// given, so nothing inside code is read as either, at the same offsets.
    static func blankingCode(in source: String, _ code: [NSRange]) -> String {
        guard !code.isEmpty else { return source }
        var units = Array(source.utf16)
        for range in code {
            for index in range.location..<min(NSMaxRange(range), units.count) where units[index] != 10 {
                units[index] = 32
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: - Inline

    private enum Kind {
        case anchorLink(label: String, url: URL)
        /// `source` as written: `[[id]]` and `[[id|id]]` show the same and
        /// are not the same characters.
        case noteLink(id: String, title: String, source: String)
        /// `source` is the span as written, delimiters and line breaks and
        /// all: the run has to stand for exactly those characters.
        case math(latex: String, display: Bool, source: String)
        case emphasis(text: String, bold: Bool, italic: Bool, mono: Bool, source: String)
        /// `\$`: a dollar, written so it does not open a formula — shown as
        /// the dollar it is, as LaTeX and every Markdown reader show it.
        case dollar
    }

    private struct Token {
        var range: NSRange
        var kind: Kind
    }

    private static let linkPattern = try! NSRegularExpression(
        pattern: #"\[((?:\\.|[^\\\]\n]|\](?!\())*)\]\((papertime://[^)\s]+)\)"#
    )
    private static let wikiPattern = try! NSRegularExpression(
        pattern: #"\[\[([^\]|\n]+)(?:\|([^\]\n]*))?\]\]"#
    )
    private static let dollarPattern = try! NSRegularExpression(pattern: #"\\\$"#)
    private static let emphasisPattern = try! NSRegularExpression(
        pattern: #"(\*\*\*)([^*\n]+)(\*\*\*)|(\*\*)([^*\n]+)(\*\*)|(\*)([^*\n]+)(\*)|(`)([^`\n]+)(`)"#
    )

    /// A table cell's words in pieces: emphasis as emphasis, and the rest
    /// as written with stray `**`, `__` and backticks left out — Portable's
    /// `emphasisPieces`, the same rule.
    static func emphasisPieces(_ cell: String) -> [(text: String, bold: Bool, italic: Bool, mono: Bool)] {
        var pieces: [(text: String, bold: Bool, italic: Bool, mono: Bool)] = []
        let line = cell as NSString
        func plain(_ range: NSRange) {
            guard range.length > 0 else { return }
            var text = line.substring(with: range)
            for mark in ["**", "__", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
            if !text.isEmpty { pieces.append((text, false, false, false)) }
        }
        var at = 0
        for match in emphasisPattern.matches(in: cell, range: NSRange(location: 0, length: line.length)) {
            plain(NSRange(location: at, length: match.range.location - at))
            let groups = [(2, true, true, false), (5, true, false, false), (8, false, true, false), (11, false, false, true)]
            for (group, bold, italic, mono) in groups where match.range(at: group).location != NSNotFound {
                pieces.append((line.substring(with: match.range(at: group)), bold, italic, mono))
                break
            }
            at = NSMaxRange(match.range)
        }
        plain(NSRange(location: at, length: line.length - at))
        return pieces
    }

    /// Whether a line could hold any of the four things that are set
    /// differently — a link, a note link, a formula, or emphasis. All four
    /// begin with one of these characters: a formula with `$` or, written as
    /// LaTeX writes it, with a backslash.
    private static func holdsMarkup(_ line: String) -> Bool {
        // Over the bytes, not through `NSString.character(at:)` — that is a
        // message send per character, and there are thirty thousand of them
        // in a note worth worrying about.
        line.utf8.contains { $0 == 0x5B || $0 == 0x24 || $0 == 0x2A || $0 == 0x60 || $0 == 0x5C }
    }

    /// Whether a line is one displayed formula and nothing else — the way a
    /// paper sets one, on a line of its own. A list item or a heading keeps
    /// its own shape whatever it holds.
    static func standsAlone(_ block: Block) -> Bool {
        switch block.kind {
        case .plain, .quote: break
        default: return false
        }
        let content = block.content as NSString
        guard holdsMarkup(block.content), let token = nextToken(in: content, from: 0),
              case .math(_, true, _) = token.kind else { return false }
        let before = content.substring(to: token.range.location)
        let after = content.substring(from: token.range.location + token.range.length)
        return before.allSatisfy(\.isWhitespace) && after.allSatisfy(\.isWhitespace)
    }

    private static func centered(_ style: NSParagraphStyle) -> NSParagraphStyle {
        let copy = (style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        copy.alignment = .center
        return copy
    }

    private static func nextToken(in line: NSString, from index: Int) -> Token? {
        let range = NSRange(location: index, length: line.length - index)
        var best: Token?

        func consider(_ token: Token?) {
            guard let token else { return }
            guard let current = best else { best = token; return }
            // The earliest match wins, and where two begin at the same
            // character the shorter one does. A `[[note]]` and a link whose
            // label was allowed to run past it both start at that bracket,
            // and the greedy one had been swallowing the rest of the line —
            // the note link, the words after it, and the passage at the end.
            if token.range.location < current.range.location
                || (token.range.location == current.range.location
                    && token.range.length < current.range.length) {
                best = token
            }
        }

        if let match = linkPattern.firstMatch(in: line as String, range: range),
           let url = URL(string: line.substring(with: match.range(at: 2))) {
            consider(Token(range: match.range, kind: .anchorLink(
                label: unescape(line.substring(with: match.range(at: 1))), url: url
            )))
        }
        if let match = wikiPattern.firstMatch(in: line as String, range: range) {
            let target = line.substring(with: match.range(at: 1))
            let shown = match.range(at: 2).location == NSNotFound
                ? target : line.substring(with: match.range(at: 2))
            consider(Token(range: match.range, kind: .noteLink(
                id: target, title: shown, source: line.substring(with: match.range))))
        }
        // One with nothing in it is still a formula — it is shown as it was
        // typed, and the line is read on after it.
        if let formula = NoteMath.firstFormula(in: line, range: range) {
            consider(Token(range: formula.range, kind: .math(
                latex: formula.latex, display: formula.display,
                source: line.substring(with: formula.range)
            )))
        }
        if let match = dollarPattern.firstMatch(in: line as String, range: range) {
            consider(Token(range: match.range, kind: .dollar))
        }
        if let match = emphasisPattern.firstMatch(in: line as String, range: range) {
            // `***both***` is bold and italic — what ⌘B then ⌘I make of a
            // selection.
            let groups = [(2, true, true, false), (5, true, false, false), (8, false, true, false), (11, false, false, true)]
            for (group, bold, italic, mono) in groups
            where match.range(at: group).location != NSNotFound {
                consider(Token(range: match.range, kind: .emphasis(
                    text: line.substring(with: match.range(at: group)),
                    bold: bold, italic: italic, mono: mono,
                    source: line.substring(with: match.range)
                )))
                break
            }
        }
        return best
    }

    private static func piece(
        for token: Token, block: Block, style: NSParagraphStyle, at location: Int, alone: Bool
    ) -> NSAttributedString {
        switch token.kind {
        case .anchorLink(let label, let url):
            // A passage from the paper is styled as a chip, anything else as a
            // link. Reading the note back had been going through the generic
            // path, so a passage was a chip when it was dropped in and a plain
            // blue link the next time the note was opened.
            //
            // Inside a quotation it is neither: the block is already saying
            // "these words are quoted", and a tinted chip inside a tinted
            // quote says it twice. It keeps the words the quote's own, and
            // only the press survives.
            let attributes: [NSAttributedString.Key: Any]
            if NoteAnchor(url: url) == nil {
                attributes = linkAttributes(url)
            } else if block.kind == .quote {
                // The whole line, or a part of it: a note written before a
                // passage became a block quote holds the quotation itself
                // inside the link, and a note written since holds the page
                // reference under the quoted words.
                let whole = token.range.location == 0
                    && token.range.length == (block.content as NSString).length
                attributes = quotedPassageAttributes(url, style: style, words: whole)
            } else {
                attributes = passageAttributes(url)
            }
            return atomic(label, source: "[\(escape(label))](\(url.absoluteString))",
                          attributes: attributes, style: style)

        case .noteLink(let id, let title, let source):
            // The source as it was written. It was made again from the id and
            // the title, and `[[id]]` — whose title is its id — came back
            // as `[[id|id]]`, rewritten in the file at the next save.
            let shown = title.isEmpty ? id : title
            return atomic(shown, source: source,
                          attributes: linkAttributes(noteURL(id: id)), style: style)

        case .math(let latex, let display, let source):
            #if os(macOS)
            let counted = numbering[location] ?? MathJaxEngine.Numbered(start: 0, known: [:])
            if let piece = mathPiece(latex: latex, display: display, source: source,
                                     size: NoteTypography.baseSize, style: style,
                                     width: available, numbered: counted, fillsWidth: alone) {
                return piece
            }
            #endif
            return NSAttributedString(string: source, attributes: [
                .font: NoteTypography.mono(),
                .foregroundColor: NoteColor.secondaryLabelColor,
                .paragraphStyle: style,
            ])

        case .emphasis(let text, let bold, let italic, let mono, let source):
            if mono { return codePiece(text, source: source, block: block, style: style) }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: emphasisFont(in: block, bold: bold, italic: italic),
                .foregroundColor: block.kind == .task(true) ? block.colour : NoteColor.labelColor,
                .paperTimeSourceLead: emphasisWidth(bold: bold, italic: italic, mono: false),
            ]
            if block.kind == .task(true) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            return atomic(text, source: source, attributes: attributes, style: style)

        case .dollar:
            return atomic("$", source: "\\$", attributes: block.attributes(style: style), style: style)
        }
    }

    private static func atomic(
        _ shown: String, source: String,
        attributes: [NSAttributedString.Key: Any], style: NSParagraphStyle
    ) -> NSAttributedString {
        var attributes = attributes
        attributes[.paragraphStyle] = style
        let piece = NSMutableAttributedString(string: shown, attributes: attributes)
        piece.addAttribute(.paperTimeSource, value: source,
                           range: NSRange(location: 0, length: piece.length))
        return piece
    }

    /// A code span set as Notion sets one. The tint reaches past the
    /// letters by 0.4 em either side, which has to be room on the line, not
    /// paint over the next word: a narrow no-break space at each end, opened
    /// to that width by kerning. The two stand where the backticks stand, so
    /// the piece is as long as its source and a caret in it is the same
    /// character over.
    private static func codePiece(_ text: String, source: String, block: Block, style: NSParagraphStyle) -> NSAttributedString {
        var attributes = codeAttributes(in: block)
        if block.kind == .task(true) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let piece = NSMutableAttributedString(attributedString: atomic(
            codePad + text + codePad, source: source, attributes: attributes, style: style))
        // The room is set in the line's own face: the code face has no
        // narrow space and would borrow one from another face.
        let room = NoteTypography.body(size: block.font.pointSize)
        let face = NoteTypography.code(size: block.font.pointSize)
        let kern = NoteCodeStyle.padding.width * face.pointSize - advance(of: codePad, in: room)
        for end in [0, piece.length - 1] {
            piece.addAttributes([.font: room, .kern: kern], range: NSRange(location: end, length: 1))
        }
        return piece
    }

    /// What stands either side of a code span's letters.
    static let codePad = "\u{202F}"

    private static func advance(of text: String, in font: NoteFont) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return size.width
    }

    /// An `NSRange` that can go in a set.
    private struct NSStringRange: Hashable {
        let location: Int
        let length: Int
        init(_ range: NSRange) { location = range.location; length = range.length }
    }

    #if os(macOS)
    /// The note's formulas counted from the top: an `equation` takes the next
    /// number wherever the caret is, so every formula is counted — the one
    /// being typed too — before any is set.
    private static func numbered(
        _ lineRanges: [NSRange], _ blocks: [Block], source: String
    ) -> [Int: MathJaxEngine.Numbered] {
        // Nothing takes a number or refers to one without one of these.
        guard source.contains("\\begin") || source.contains("\\label") || source.contains("\\ref")
        else { return [:] }
        var formulas: [(location: Int, latex: String, display: Bool)] = []
        for (lineRange, block) in zip(lineRanges, blocks) where holdsMarkup(block.content) {
            let content = block.content as NSString
            let start = lineRange.location + (block.marker as NSString).length
            var index = 0
            while index < content.length, let token = nextToken(in: content, from: index) {
                if case .math(let latex, let display, _) = token.kind {
                    formulas.append((start + token.range.location, latex, display))
                }
                index = token.range.location + token.range.length
            }
        }
        guard !formulas.isEmpty,
              let steps = MathJaxEngine.shared.number(formulas.map { ($0.latex, $0.display) })
        else { return [:] }
        var result: [Int: MathJaxEngine.Numbered] = [:]
        for (formula, step) in zip(formulas, steps) { result[formula.location] = step }
        return result
    }

    private nonisolated(unsafe) static var tableCache: [String: NSImage] = [:]

    /// A table as a picture of itself: a header set in bold on a faint
    /// ground, hairlines between the cells, the whole in a rounded frame.
    /// The source rides along, so copying it gives the Markdown back.
    private static func tablePiece(_ table: NoteTable.Table, source: String, style: NSParagraphStyle) -> NSAttributedString? {
        let room = max(160, ((available ?? 520) - 4) / 8 * 8).rounded(.down)
        let appearance = current ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let key = "\(room)|\(appearance.name.rawValue)|\(source)"
        let image: NSImage
        if let cached = tableCache[key] {
            image = cached
        } else {
            guard let drawn = NoteTableDrawing.image(table, width: room, appearance: appearance) else { return nil }
            if tableCache.count > 200 { tableCache.removeAll() }
            tableCache[key] = drawn
            image = drawn
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -6, width: image.size.width, height: image.size.height)
        let piece = NSMutableAttributedString(attachment: attachment)
        piece.addAttributes([
            .paperTimeSource: source,
            .font: NoteTypography.body(),
            .foregroundColor: NoteColor.labelColor,
            .paragraphStyle: style,
        ], range: NSRange(location: 0, length: piece.length))
        return piece
    }

    /// Formulas are drawn once and kept as images. The attachment around an
    /// image is made fresh every time: one attachment shared between two text
    /// storages is one attachment too few for TextKit.
    private nonisolated(unsafe) static var mathCache: [String: (image: NSImage, descent: CGFloat)] = [:]

    private static func mathPiece(
        latex: String, display: Bool, source: String, size: CGFloat, style: NSParagraphStyle,
        width: CGFloat?, numbered: MathJaxEngine.Numbered, fillsWidth: Bool
    ) -> NSAttributedString? {
        // Rounded, so nudging the pane by a point does not redraw every
        // formula in the note. A quotation or a list item sets its lines in
        // from the edge, and its formulas have that much less room.
        let indent = max(style.headIndent, style.firstLineHeadIndent)
        let room = width.map { max(80, (($0 - indent) / 8).rounded(.down) * 8) }
        let appearance = current ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let labels = numbered.known.keys.sorted().map { "\($0)=\(numbered.known[$0] ?? "")" }.joined(separator: ",")
        let key = "\(display ? "D" : "I")|\(fillsWidth ? "F" : "")|\(size)|\(room ?? 0)|"
            + "\(appearance.name.rawValue)|\(numbered.start)|\(labels)|\(latex)"
        let drawn: (image: NSImage, descent: CGFloat)
        if let cached = mathCache[key] {
            drawn = cached
        } else {
            var ink = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                ink = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
            }
            guard let made = MathTypesetter.image(
                latex: latex, display: display,
                pointSize: NoteTypography.mathSize(forBody: size) * (display ? 1.12 : 1),
                color: ink,
                maxWidth: room,
                start: numbered.start, known: numbered.known, fillsWidth: fillsWidth
            ) else { return nil }
            // A note holds its formulas at once, so the cache has room for a
            // long one: emptied at a thousand rather than four hundred, which
            // a note of five hundred formulas emptied on every keystroke.
            if mathCache.count > 1000 { mathCache.removeAll() }
            mathCache[key] = made
            drawn = made
        }

        let attachment = NSTextAttachment()
        attachment.image = drawn.image
        attachment.bounds = CGRect(x: 0, y: -drawn.descent,
                                   width: drawn.image.size.width,
                                   height: drawn.image.size.height)
        let piece = NSMutableAttributedString(attachment: attachment)
        piece.addAttributes([
            .paperTimeSource: source,
            .font: NoteTypography.body(),
            .foregroundColor: NoteColor.labelColor,
            .paragraphStyle: style,
        ], range: NSRange(location: 0, length: piece.length))
        return piece
    }
    #endif
}
