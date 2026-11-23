#if os(macOS)
import AppKit
import Foundation

/// What the format panel does to a note, as edits of its Markdown.
///
/// Pure: the note as written and the selection in it go in, one replacement
/// and the selection after it come out. The editor makes the replacement as
/// one step of its undo and sets the note again from the result — the way a
/// list's keys are done (`NoteList`), and for the same reason: what is on
/// screen is a rendering, and an edit made to the rendering is an edit made
/// to the wrong text.
enum NoteFormat {
    struct Edit {
        var range: NSRange
        var replacement: String
        /// What is selected afterwards, in the note as it then is. Empty for
        /// a caret.
        var selection: NSRange
    }

    // MARK: - What the panel shows

    enum Paragraph: String, CaseIterable, Identifiable {
        case title, heading, subheading, body, quote
        var id: String { rawValue }

        var name: String {
            switch self {
            case .title: L("제목", "Title")
            case .heading: L("머리말", "Heading")
            case .subheading: L("작은 머리말", "Subheading")
            case .body: L("본문", "Body")
            case .quote: L("인용", "Quote")
            }
        }

        var prefix: String {
            switch self {
            case .title: "# "
            case .heading: "## "
            case .subheading: "### "
            case .body: ""
            case .quote: "> "
            }
        }

        var headingLevel: Int? {
            switch self {
            case .title: 1
            case .heading: 2
            case .subheading: 3
            default: nil
            }
        }
    }

    enum List: String, CaseIterable, Identifiable {
        case none, bullet, numbered, task, toggle
        var id: String { rawValue }

        var name: String {
            switch self {
            case .none: L("없음", "None")
            case .bullet: L("글머리표", "Bullet")
            case .numbered: L("번호", "Numbered")
            case .task: L("할 일", "Checklist")
            case .toggle: L("토글", "Toggle")
            }
        }
    }

    /// The format where the selection begins.
    struct State: Equatable {
        var style = NoteSpanStyle()
        var paragraph = Paragraph.body
        var list = List.none
        var alignment = NoteAlignment.left
        /// The size the words are set at, whether or not a span says so.
        var size: Double = Double(NoteTypography.baseSize)
        /// The size they would be with no span.
        var ownSize: Double = Double(NoteTypography.baseSize)
        /// Whether there is anything to format: a note has the keyboard.
        var isEditing = false
        /// In a block of code, where words are code and nothing else.
        var isCode = false
    }

    static func state(in source: String, selection: NSRange) -> State {
        var state = State()
        let text = source as NSString
        let at = min(max(selection.location, 0), text.length)
        let line = contentRange(ofLineAt: at, in: text)
        let block = NoteMarkdown.Block(line: text.substring(with: line))
        switch block.kind {
        case .heading(let level): state.paragraph = level <= 1 ? .title : level == 2 ? .heading : .subheading
        case .quote: state.paragraph = .quote
        case .bullet: state.list = .bullet
        case .ordered: state.list = .numbered
        case .task: state.list = .task
        case .toggle: state.list = .toggle
        case .plain: break
        }
        if let aligned = NoteAlignment.read(block.content) { state.alignment = aligned.alignment }
        state.ownSize = Double(block.font.pointSize)
        state.size = state.ownSize
        let marker = (block.marker as NSString).length
        let content = block.content as NSString
        let offset = at - line.location - marker
        if offset >= 0, NoteMarkdown.holdsMarkup(block.content) {
            var index = 0
            while index < content.length, let token = NoteMarkdown.nextToken(in: content, from: index) {
                // A selection is asked where it begins; a caret, where it
                // stands — after the letter before it, as typing would be.
                let inside = selection.length > 0
                    ? token.range.location <= offset && offset < NSMaxRange(token.range)
                    : token.range.location < offset && offset <= NSMaxRange(token.range)
                if inside {
                    switch token.kind {
                    case .styled(_, let style, _, _): state.style = style
                    case .emphasis(_, let bold, let italic, false, _):
                        state.style.bold = bold
                        state.style.italic = italic
                    case .highlight(_, let color, _):
                        state.style.highlight = color ?? NoteHighlight.defaultName
                    default: break
                    }
                    break
                }
                index = NSMaxRange(token.range)
            }
        }
        if let size = state.style.size { state.size = size }
        return state
    }

    // MARK: - Characters

    enum Change {
        case color(String?), size(Double?), family(String?)
        case bold(Bool), italic(Bool), underline(Bool), strike(Bool)
        /// One of the five highlights by name, or none.
        case highlight(String?)

        func apply(to style: inout NoteSpanStyle) {
            switch self {
            case .color(let value): style.color = value
            case .size(let value): style.size = value
            case .family(let value): style.family = value
            case .bold(let on): style.bold = on
            case .italic(let on): style.italic = on
            case .underline(let on): style.underline = on
            case .strike(let on): style.strike = on
            case .highlight(let name): style.highlight = name
            }
        }
    }

    /// Sets the selected words that way — or, with nothing selected, the
    /// word the caret is in. Words already in a span keep what they had and
    /// take the change; words in Markdown's bold or italic become a span
    /// when the change is more than those can say, and stay Markdown when it
    /// is not; a highlight is one more thing words can be, with the rest. Links,
    /// formulas and code are left as they are.
    static func set(_ change: Change, in source: String, selection: NSRange) -> Edit? {
        let text = source as NSString
        var selection = NSRange(location: min(max(selection.location, 0), text.length),
                                length: min(selection.length, max(0, text.length - selection.location)))
        if selection.length == 0 {
            guard let word = word(at: selection.location, in: text) else { return nil }
            selection = word
        }
        let lines = contentRanges(ofLinesTouching: selection, in: text)
        guard let first = lines.first, let last = lines.last else { return nil }
        let whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var out = ""
        var cursor = whole.location
        var changed: (start: Int, end: Int)?
        for line in lines {
            out += text.substring(with: NSRange(location: cursor, length: line.location - cursor))
            let written = text.substring(with: line)
            let block = NoteMarkdown.Block(line: written)
            let marker = (block.marker as NSString).length
            let from = max(selection.location, line.location + marker) - line.location - marker
            let to = min(NSMaxRange(selection), NSMaxRange(line)) - line.location - marker
            out += block.marker
            if to > from {
                let base = (out as NSString).length
                let (rebuilt, span) = restyled(block.content as NSString, from: from, to: to, change)
                out += rebuilt
                if let span {
                    changed = (changed?.start ?? base + span.location, base + NSMaxRange(span))
                }
            } else {
                out += block.content
            }
            cursor = NSMaxRange(line)
        }
        guard let changed, out != text.substring(with: whole) else { return nil }
        return Edit(range: whole, replacement: out,
                    selection: NSRange(location: whole.location + changed.start, length: changed.end - changed.start))
    }

    /// One line's words with the change made between two offsets. The range
    /// returned is what was changed, in the line as rebuilt.
    private static func restyled(_ content: NSString, from: Int, to: Int, _ change: Change) -> (String, NSRange?) {
        var result = ""
        var first: Int?
        var end = 0
        func emit(_ piece: String, changed: Bool = false) {
            guard !piece.isEmpty else { return }
            if changed, first == nil { first = (result as NSString).length }
            result += piece
            if changed { end = (result as NSString).length }
        }
        func sub(_ lower: Int, _ upper: Int) -> String {
            upper > lower ? content.substring(with: NSRange(location: lower, length: upper - lower)) : ""
        }
        /// A stretch with no markup in it.
        func plain(_ lower: Int, _ upper: Int) {
            let lo = max(lower, from), hi = min(upper, to)
            guard hi > lo else { return emit(sub(lower, upper)) }
            emit(sub(lower, lo))
            var style = NoteSpanStyle()
            change.apply(to: &style)
            // The spaces at either end stay outside: a span that opens on a
            // space is a space underlined, and Markdown's marks do not close
            // after one.
            let words = sub(lo, hi)
            let core = words.trimmingCharacters(in: .whitespaces)
            if core.isEmpty || style.isEmpty {
                emit(words)
            } else {
                let lead = String(words.prefix { $0 == " " || $0 == "\t" })
                emit(lead)
                emit(style.wrapping(core), changed: true)
                emit(String(words.dropFirst(lead.count + core.count)))
            }
            emit(sub(hi, upper))
        }
        /// Words already set some way, between `lower` and `upper`.
        func piece(_ lower: Int, _ upper: Int, _ old: NoteSpanStyle) {
            var lo = max(lower, from), hi = min(upper, to)
            // Only the marks were reached: all of the words, then.
            if hi <= lo { lo = lower; hi = upper }
            var new = old
            change.apply(to: &new)
            emit(old.wrapping(sub(lower, lo)))
            emit(new.wrapping(sub(lo, hi)), changed: true)
            emit(old.wrapping(sub(hi, upper)))
        }

        var index = 0
        let holds = NoteMarkdown.holdsMarkup(content as String)
        while index < content.length {
            guard holds, let token = NoteMarkdown.nextToken(in: content, from: index) else {
                plain(index, content.length)
                break
            }
            if token.range.location > index { plain(index, token.range.location) }
            let range = token.range
            let reached = range.location < to && NSMaxRange(range) > from
            switch token.kind {
            case .styled(_, let style, _, let lead) where reached:
                piece(range.location + lead, NSMaxRange(range) - (NoteSpanStyle.close as NSString).length, style)
            case .emphasis(_, let bold, let italic, false, _) where reached:
                let width = bold && italic ? 3 : bold ? 2 : 1
                var style = NoteSpanStyle()
                style.bold = bold
                style.italic = italic
                piece(range.location + width, NSMaxRange(range) - width, style)
            case .highlight(_, let color, _) where reached:
                var style = NoteSpanStyle()
                style.highlight = color ?? NoteHighlight.defaultName
                piece(range.location + NoteMarkdown.highlightLead(color: color), NSMaxRange(range) - 2, style)
            default:
                emit(content.substring(with: range))
            }
            index = NSMaxRange(range)
        }
        return (result, first.map { NSRange(location: $0, length: end - $0) })
    }

    /// The word a caret is in or beside — or the styled words it is in.
    private static func word(at caret: Int, in text: NSString) -> NSRange? {
        let line = contentRange(ofLineAt: caret, in: text)
        let block = NoteMarkdown.Block(line: text.substring(with: line))
        let start = line.location + (block.marker as NSString).length
        let content = block.content as NSString
        let offset = caret - start
        guard offset >= 0 else { return nil }
        if NoteMarkdown.holdsMarkup(block.content) {
            var index = 0
            while index < content.length, let token = NoteMarkdown.nextToken(in: content, from: index) {
                if token.range.location <= offset, offset <= NSMaxRange(token.range) {
                    switch token.kind {
                    case .styled, .emphasis(_, _, _, false, _), .highlight:
                        return NSRange(location: start + token.range.location, length: token.range.length)
                    default: return nil
                    }
                }
                index = NSMaxRange(token.range)
            }
        }
        let letters = CharacterSet.alphanumerics
        func isLetter(_ index: Int) -> Bool {
            guard index >= 0, index < content.length, let scalar = Unicode.Scalar(content.character(at: index)) else {
                // Half of a pair: part of a word all the same.
                return index >= 0 && index < content.length
            }
            return letters.contains(scalar)
        }
        var lower = offset, upper = offset
        while isLetter(lower - 1) { lower -= 1 }
        while isLetter(upper) { upper += 1 }
        return upper > lower ? NSRange(location: start + lower, length: upper - lower) : nil
    }

    // MARK: - Paragraphs

    /// Makes each selected line that kind of paragraph. A list's item stays
    /// a list's item when it is asked to be body, which it is.
    static func set(_ paragraph: Paragraph, in source: String, selection: NSRange) -> Edit? {
        rewritingLines(in: source, selection: selection) { block, _ in
            if block.isListItem, paragraph == .body { return nil }
            if block.content.isEmpty, block.marker.isEmpty, paragraph == .body { return nil }
            var words = block.content
            // A quotation keeps to its rule, as a list's item to its edge.
            if paragraph == .quote, let wrapped = NoteAlignment.read(words) {
                words = (words as NSString).substring(with: wrapped.inner)
            }
            return paragraph.prefix + words
        }
    }

    /// Makes each selected line an item of that kind of list, or takes it
    /// out of its list. An item keeps how far in it is.
    static func set(_ list: List, in source: String, selection: NSRange) -> Edit? {
        var number = 0
        return rewritingLines(in: source, selection: selection) { block, many in
            // A blank line between items is not an item.
            if many, block.content.isEmpty, block.marker.isEmpty { return nil }
            let lead = String(block.marker.prefix { $0 == " " })
            number += 1
            // An item keeps to its list's edge: a line set to the centre or
            // the right gives that up to become one.
            var words = block.content
            if list != .none, let wrapped = NoteAlignment.read(words) {
                words = (words as NSString).substring(with: wrapped.inner)
            }
            switch list {
            case .none: return block.isListItem ? words : nil
            case .bullet: return lead + "- " + words
            case .numbered: return lead + "\(number). " + words
            case .task:
                if case .task = block.kind { return nil }
                return lead + "- [ ] " + words
            case .toggle: return lead + "+ " + words
            }
        }
    }

    /// Sets each selected line that way across the page: a paragraph or a
    /// heading. A list's items and a quotation keep their own edge.
    static func set(_ alignment: NoteAlignment, in source: String, selection: NSRange) -> Edit? {
        rewritingLines(in: source, selection: selection) { block, _ in
            switch block.kind {
            case .plain, .heading: break
            default: return nil
            }
            var words = block.content
            if let wrapped = NoteAlignment.read(words) { words = (words as NSString).substring(with: wrapped.inner) }
            guard !words.isEmpty else { return nil }
            return block.marker + (alignment == .left ? words : alignment.open + words + NoteAlignment.close)
        }
    }

    /// Each line the selection touches, written again by `rewrite` — nil
    /// leaves a line as it is. A caret stays as far from the end of its line
    /// as it was; a selection becomes the lines.
    private static func rewritingLines(
        in source: String, selection: NSRange, _ rewrite: (NoteMarkdown.Block, Bool) -> String?
    ) -> Edit? {
        let text = source as NSString
        let selection = NSRange(location: min(max(selection.location, 0), text.length),
                                length: min(selection.length, max(0, text.length - selection.location)))
        let lines = contentRanges(ofLinesTouching: selection, in: text)
        guard let first = lines.first, let last = lines.last else { return nil }
        let whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var out = ""
        var cursor = whole.location
        var caret = selection.location
        for line in lines {
            out += text.substring(with: NSRange(location: cursor, length: line.location - cursor))
            let written = text.substring(with: line)
            let made = rewrite(NoteMarkdown.Block(line: written), lines.count > 1) ?? written
            if selection.length == 0 {
                let fromEnd = NSMaxRange(line) - selection.location
                let length = (made as NSString).length
                caret = whole.location + (out as NSString).length + max(0, length - min(fromEnd, length))
                // Never left of the words: a caret that was in a marker now
                // gone stands where the words begin.
                let marker = (NoteMarkdown.Block(line: made).marker as NSString).length
                caret = max(caret, whole.location + (out as NSString).length + min(marker, length))
            }
            out += made
            cursor = NSMaxRange(line)
        }
        guard out != text.substring(with: whole) else { return nil }
        return Edit(range: whole, replacement: out,
                    selection: selection.length == 0 ? NSRange(location: caret, length: 0)
                        : NSRange(location: whole.location, length: (out as NSString).length))
    }

    // MARK: - Pictures

    /// Puts a picture on a line of its own, after the line the caret is on —
    /// or on that line, when it is empty — and leaves the caret on the line
    /// under it, so the picture is seen and not its Markdown.
    static func insertPicture(_ path: String, in source: String, selection: NSRange) -> Edit {
        let text = source as NSString
        let line = contentRange(ofLineAt: NSMaxRange(selection), in: text)
        let written = "![](\(path))"
        if text.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty {
            return Edit(range: line, replacement: written + "\n",
                        selection: NSRange(location: line.location + (written as NSString).length + 1, length: 0))
        }
        let end = NSMaxRange(line)
        let insert = "\n\n" + written + "\n"
        return Edit(range: NSRange(location: end, length: 0), replacement: insert,
                    selection: NSRange(location: end + (insert as NSString).length, length: 0))
    }

    // MARK: - Lines

    /// The line a position is on, without what ends it.
    static func contentRange(ofLineAt index: Int, in text: NSString) -> NSRange {
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                          for: NSRange(location: min(max(index, 0), text.length), length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    /// Every line a selection touches, each without what ends it. A
    /// selection that ends at the very start of a line does not touch it.
    static func contentRanges(ofLinesTouching selection: NSRange, in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = selection.location
        let stop = NSMaxRange(selection)
        repeat {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
            if ranges.isEmpty || start < stop { ranges.append(NSRange(location: start, length: contentsEnd - start)) }
            if end <= index { break }
            index = end
        } while index < stop
        return ranges
    }
}
#endif
