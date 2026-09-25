import Foundation
import PaperCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// The Markdown a run stands for, when the run is not its own source: a
    /// heading whose `##` is not shown, a formula set as mathematics, a link
    /// shown as what it points at. Plain text is its own source.
    static let paperTimeSource = NSAttributedString.Key("PaperTimeSource")
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

    // MARK: - Reading the source back

    static func markdown(from attributed: NSAttributedString) -> String {
        var result = ""
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attributes, range, _ in
            if let source = attributes[.paperTimeSource] as? String {
                result += source
                return
            }
            result += attributed.attributedSubstring(from: range).string
        }
        return result
    }

    /// Where the caret sits in the source, given where it sits on screen.
    static func sourceIndex(in attributed: NSAttributedString, displayIndex: Int) -> Int {
        var source = 0
        var display = 0
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attributes, range, stop in
            let text = attributes[.paperTimeSource] as? String
                ?? attributed.attributedSubstring(from: range).string
            let sourceLength = (text as NSString).length

            if displayIndex >= display + range.length {
                source += sourceLength
                display += range.length
                return
            }
            if sourceLength == range.length {
                source += displayIndex - display
            } else if displayIndex > display {
                source += sourceLength
            }
            stop.pointee = true
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

    private static var syntaxColor: NoteColor { .tertiaryLabelColor }

    #if os(macOS)
    /// Renders a note file and prints what each run of it became, then quits.
    ///
    /// The note editor is three panes deep and its rows do not answer a
    /// synthetic click, so "is a quotation actually set as a quotation?" was a
    /// question that could only be answered by looking. This answers it in a
    /// terminal.
    /// The Markdown itself, not a path to it: the app is sandboxed, and a
    /// path handed to it on the command line is a path it may not read.
    @MainActor
    static func dump(_ markdown: String) {
        let rendered = render(markdown, raw: false).text
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
            if let font = attributes[.font] as? NSFont,
               font.fontDescriptor.symbolicTraits.contains(.italic) { marks.append("italic") }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle, style.headIndent > 0 {
                marks.append("indent \(Int(style.headIndent))")
            }
            print(String(format: "%5d %-14@ %@", range.location,
                         marks.isEmpty ? "—" : marks.joined(separator: "+") as NSString,
                         String(text.prefix(60)) as NSString))
        }
        // What the runs *say* is only half of it: the rule down a quotation
        // and the formula set as mathematics are drawn, not spelled, and
        // neither shows up in a list of attributes. With a path to write to,
        // the same note is laid out and saved as a picture.
        if let path = Boot.setting("PAPERTIME_DUMP_NOTE_IMAGE") {
            draw(markdown, to: path)
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
    private static func draw(_ markdown: String, to path: String, width: CGFloat = 620) {
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        view.textContainerInset = CGSize(width: 20, height: 18)
        view.backgroundColor = .textBackgroundColor
        let fragments = Fragments()
        view.textLayoutManager?.delegate = fragments
        view.textStorage?.setAttributedString(render(markdown, width: width - 64).text)
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
        if let last = lines.last, !last.hasPrefix("$$"), !last.hasPrefix("#") {
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
    /// own in the paper, and putting it back on one keeps the quotation
    /// looking like what was quoted.
    static func quotationLines(of text: String) -> [String] {
        let whole = text as NSString
        var lines: [String] = []
        var index = 0
        func add(_ piece: String) {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        for match in displayMathPattern.matches(
            in: text, range: NSRange(location: 0, length: whole.length)
        ) {
            add(whole.substring(with: NSRange(location: index,
                                              length: match.range.location - index)))
            add(whole.substring(with: match.range))
            index = match.range.location + match.range.length
        }
        add(whole.substring(from: index))
        return lines.isEmpty ? [text] : lines
    }

    private static let displayMathPattern = try! NSRegularExpression(
        pattern: #"\$\$[^$]+\$\$"#
    )

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
        appearance: NoteAppearance? = nil
    ) -> Rendered {
        Trace.time("note: render \(source.count) characters") {
            renderNow(source, caret: caret, raw: raw, width: width, appearance: appearance)
        }
    }

    private static func renderNow(
        _ source: String, caret: Int? = nil, raw: Bool = false, width: CGFloat? = nil,
        appearance: NoteAppearance? = nil
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

        func append(_ piece: NSAttributedString, source range: NSRange) {
            guard piece.length > 0 else { return }
            let start = result.length
            result.append(piece)
            pieces.append((NSRange(location: start, length: piece.length), range))
        }

        // Every line is read before any is set, because a quoted line needs
        // to know whether the line above and below it are quoted too.
        let lineRanges = lines(of: text, joiningMathBlocksIn: source)
        var blocks = lineRanges.map { Block(line: text.substring(with: $0)) }
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

        for (lineRange, block) in zip(lineRanges, blocks) {
            let revealed = caret.map {
                $0 >= lineRange.location && $0 <= lineRange.location + lineRange.length
            } ?? false
            let style = block.paragraphStyle
            let markerLength = (block.marker as NSString).length

            if markerLength > 0 {
                let shown = revealed ? block.marker : block.shownMarker
                var attributes: [NSAttributedString.Key: Any] = revealed
                    ? [.font: block.font, .foregroundColor: syntaxColor]
                    : [.font: block.markerFont, .foregroundColor: block.markerColor]
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
                    piece(for: token, block: block, style: style),
                    source: NSRange(location: contentStart + token.range.location,
                                    length: token.range.length)
                )
                index = token.range.location + token.range.length
            }

            let newline = lineRange.location + lineRange.length
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
        enum Kind: Equatable { case plain, heading(Int), quote, bullet, ordered(Int), task(Bool) }

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
        var shownMarker: String {
            switch kind {
            case .plain: ""
            case .heading, .quote: NoteMarkdown.hiddenMarker
            case .bullet: "•\t"
            case .ordered(let number): "\(number).\t"
            case .task(let done): done ? "☑\t" : "☐\t"
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
            case .bullet, .ordered, .task:
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
        static let bulletPattern = try! NSRegularExpression(pattern: #"^[-*+]\s+"#)
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
        for block in NoteMath.blocks(in: source).reversed() {
            guard let first = ranges.firstIndex(where: { $0.location == block.location }),
                  let last = ranges.firstIndex(where: {
                      $0.location + $0.length == block.location + block.length
                  }), last >= first
            else { continue }
            ranges.replaceSubrange(first...last, with: [block])
        }
        return ranges
    }

    // MARK: - Inline

    private enum Kind {
        case anchorLink(label: String, url: URL)
        case noteLink(id: String, title: String)
        /// `source` is the span as written, delimiters and line breaks and
        /// all: the run has to stand for exactly those characters.
        case math(latex: String, display: Bool, source: String)
        case emphasis(text: String, bold: Bool, italic: Bool, mono: Bool, source: String)
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
    private static let mathPattern = try! NSRegularExpression(
        pattern: #"(\$\$)([^$]+)(\$\$)|(\$)([^$\n]+)(\$)"#
    )
    private static let emphasisPattern = try! NSRegularExpression(
        pattern: #"(\*\*)([^*\n]+)(\*\*)|(\*)([^*\n]+)(\*)|(`)([^`\n]+)(`)"#
    )

    /// Whether a line could hold any of the four things that are set
    /// differently — a link, a note link, a formula, or emphasis. All four
    /// begin with one of these characters.
    private static func holdsMarkup(_ line: String) -> Bool {
        // Over the bytes, not through `NSString.character(at:)` — that is a
        // message send per character, and there are thirty thousand of them
        // in a note worth worrying about.
        line.utf8.contains { $0 == 0x5B || $0 == 0x24 || $0 == 0x2A || $0 == 0x60 }
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
            consider(Token(range: match.range, kind: .noteLink(id: target, title: shown)))
        }
        if let match = mathPattern.firstMatch(in: line as String, range: range) {
            let display = match.range(at: 2).location != NSNotFound
            let body = display ? match.range(at: 2) : match.range(at: 5)
            if body.location != NSNotFound {
                consider(Token(range: match.range, kind: .math(
                    latex: line.substring(with: body)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    display: display, source: line.substring(with: match.range)
                )))
            }
        }
        if let match = emphasisPattern.firstMatch(in: line as String, range: range) {
            let groups = [(2, true, false, false), (5, false, true, false), (8, false, false, true)]
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
        for token: Token, block: Block, style: NSParagraphStyle
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

        case .noteLink(let id, let title):
            let shown = title.isEmpty ? id : title
            let source = title.isEmpty ? "[[\(id)]]" : "[[\(id)|\(title)]]"
            return atomic(shown, source: source,
                          attributes: linkAttributes(noteURL(id: id)), style: style)

        case .math(let latex, let display, let source):
            #if os(macOS)
            if let piece = mathPiece(latex: latex, display: display, source: source,
                                     size: NoteTypography.baseSize, style: style,
                                     width: available) {
                return piece
            }
            #endif
            return NSAttributedString(string: source, attributes: [
                .font: NoteTypography.mono(),
                .foregroundColor: NoteColor.secondaryLabelColor,
                .paragraphStyle: style,
            ])

        case .emphasis(let text, let bold, let italic, let mono, let source):
            // Inside a quotation the words are set in italics, so bold there
            // is bold italic: it is the paper's own emphasis, still quoted.
            let quoted = block.kind == .quote && block.heading == nil
            var attributes: [NSAttributedString.Key: Any] = [
                .font: mono ? NoteTypography.mono()
                            : NoteTypography.body(bold: bold, italic: italic || quoted),
                .foregroundColor: NoteColor.labelColor,
            ]
            if mono { attributes[.backgroundColor] = NoteColor.quaternaryLabelColor }
            return atomic(text, source: source, attributes: attributes, style: style)
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

    #if os(macOS)
    /// Formulas are drawn once and kept as images. The attachment around an
    /// image is made fresh every time: one attachment shared between two text
    /// storages is one attachment too few for TextKit.
    private nonisolated(unsafe) static var mathCache: [String: (image: NSImage, descent: CGFloat)] = [:]

    private static func mathPiece(
        latex: String, display: Bool, source: String, size: CGFloat, style: NSParagraphStyle,
        width: CGFloat?
    ) -> NSAttributedString? {
        // Rounded, so nudging the pane by a point does not redraw every
        // formula in the note.
        let room = width.map { max(80, ($0 / 8).rounded(.down) * 8) }
        let appearance = current ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let key = "\(display ? "D" : "I")|\(size)|\(room ?? 0)|\(appearance.name.rawValue)|\(latex)"
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
                maxWidth: room
            ) else { return nil }
            if mathCache.count > 400 { mathCache.removeAll() }
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
