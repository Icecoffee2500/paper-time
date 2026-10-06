import Foundation

/// How a note's numbered lists count, and what moving an item in or out a
/// level does to the numbers written in the note.
///
/// A numbered item shows where it stands, not what is written in front of
/// it: it counts on from the item before it at its depth. That is what
/// Markdown means by a list, and what Notion and Word show. Reading the
/// written number instead, an item moved in under another with Tab kept its
/// «2.» and was shown as «b.», the first item of a list that should have
/// started at «a.». A list at the left starts at its first item's number —
/// «3.» after a formula carries a list on, as it does in a paper's source —
/// and a list set in under an item starts at 1, as Notion's always does.
///
/// A list is broken by a line at its depth that is not one of its items —
/// an item whose number is closed by the other mark («1)» after «1.») is
/// another list's, as Markdown has it — and by any line shallower than it;
/// blank lines and the lines deeper than it — an item's own sub-list, its
/// formula — leave it whole. A `$$`
/// block or a table over several lines is one line (the renderer reads it
/// so), and a line of fenced code is never an item. Offsets are UTF-16.
public enum NoteList {
    /// A line as the lists read it.
    struct Line {
        /// The line — or the formula or table it opens, whole — without
        /// its break.
        var range: NSRange
        var depth: Int
        var blank: Bool
        /// A list item: a bullet, a number, a box or a toggle.
        var item: Bool
        /// A numbered item's number as written, where its digits are, and
        /// what closes it — «.» or «)».
        var number: Int?
        var digits = NSRange(location: NSNotFound, length: 0)
        var delimiter: unichar = 0
        /// Where the words begin, after the indent and the marker.
        var contentStart: Int
        var code: Bool
    }

    /// What every numbered item shows, by where its line starts.
    public static func numbers(in source: String) -> [Int: Int] {
        shown(lines(of: source))
    }

    /// The same, off lines a renderer has already read — its own, with
    /// formulas and tables joined, and `isCode` naming fenced code — so a
    /// note is not read twice on every keystroke.
    public static func numbers(of lines: [NSRange], in text: NSString, isCode: (NSRange) -> Bool) -> [Int: Int] {
        shown(lines.map { read($0, in: text, code: isCode($0)) })
    }

    static func shown(_ read: [Line]) -> [Int: Int] {
        var shown: [Int: Int] = [:]
        for (line, count) in zip(read, counted(read)) {
            if let number = count.shown { shown[line.range.location] = number }
        }
        return shown
    }

    /// An edit to make: put `replacement` over `range`, then the caret goes
    /// to `caret` (both in the edited text's offsets — `range` in the text
    /// before, `caret` in the text after) — or, when `length` is more than
    /// nothing, the selection runs from there for that many characters.
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String
        public var caret: Int
        public var length: Int

        public init(range: NSRange, replacement: String, caret: Int, length: Int = 0) {
            self.range = range
            self.replacement = replacement
            self.caret = caret
            self.length = length
        }

        /// Whether the edit leaves the text as it was: a key taken, nothing
        /// changed.
        public var changesNothing: Bool { range.length == 0 && replacement.isEmpty }
    }

    /// Tab (`step` 1) or ⇧Tab (−1) on a list item: the item goes a level in
    /// or out, and what is under it goes with it — its sub-list, its
    /// formula, a toggle's children — as an outliner moves a block. Then the
    /// list it is in is numbered as it is shown, so what the note says is
    /// what the reader sees, in this app and any other; an item that comes
    /// to start a list starts it at 1. The caret keeps its place in the
    /// item's words. Nil off a list item and in fenced code; an item at the
    /// left on ⇧Tab gets an edit that changes nothing — the key is taken.
    public static func shift(in source: String, caret: Int, by step: Int) -> Edit? {
        let text = source as NSString
        let all = lines(of: source)
        guard let index = all.firstIndex(where: { $0.range.location <= caret && caret <= NSMaxRange($0.range) }) else {
            return nil
        }
        let line = all[index]
        guard !line.code, line.item else { return nil }
        if step < 0, line.depth == 0 {
            return Edit(range: NSRange(location: caret, length: 0), replacement: "", caret: caret)
        }

        // The item and what is under it: the lines after it that are
        // deeper, and the blank lines among them.
        var last = index
        var next = index + 1
        while next < all.count {
            if all[next].blank {
                next += 1
                continue
            }
            guard all[next].depth > line.depth else { break }
            last = next
            next += 1
        }
        let span = NSRange(location: line.range.location, length: NSMaxRange(all[last].range) - line.range.location)
        let code = NoteCode.blocks(in: source).map(\.range)
        let spanned = text.substring(with: span) as NSString
        var moved: [String] = []
        for physical in NoteMath.lineRanges(of: spanned) {
            let absolute = span.location + physical.location
            var written = spanned.substring(with: physical)
            let isBlank = written.allSatisfy(\.isWhitespace)
            let isCode = code.contains { NSLocationInRange(absolute, $0) }
            if !isBlank, !isCode {
                if step > 0 {
                    written = "  " + written
                } else {
                    let spaces = written.prefix(2).prefix { $0 == " " }.count
                    written.removeFirst(spaces)
                }
            }
            moved.append(written)
        }
        var updated = text.replacingCharacters(in: span, with: moved.joined(separator: "\n"))

        // An item that comes to start a list starts it at 1.
        var read = lines(of: updated)
        guard let at = read.firstIndex(where: { $0.range.location == line.range.location }) else { return nil }
        if read[at].number != nil, counted(read)[at].starts, read[at].number != 1 {
            updated = (updated as NSString).replacingCharacters(in: read[at].digits, with: "1")
            read = lines(of: updated)
        }

        // The list numbered as it is shown, from the bottom up so the
        // places above stay where they are.
        let shown = counted(read)
        for row in region(around: at, in: read).reversed() {
            guard let written = read[row].number, let number = shown[row].shown, written != number else { continue }
            updated = (updated as NSString).replacingCharacters(in: read[row].digits, with: String(number))
        }
        read = lines(of: updated)

        // The caret, in the same place among the item's words.
        let offset = caret - line.range.location
        let markerBefore = line.contentStart - line.range.location
        let markerAfter = read[at].contentStart - read[at].range.location
        let landed = read[at].range.location + (offset >= markerBefore ? offset - markerBefore + markerAfter : markerAfter)
        return difference(from: source, to: updated, caret: landed)
    }

    /// Tab or ⇧Tab over a selection: every line from the first one selected
    /// to the last — and what is under the last, as for one item — goes a
    /// level in or out, and the selection stays on the same words. A
    /// selection that ends at the start of a line does not take that line.
    /// The first line selected has to be a list item; ⇧Tab leaves a line
    /// at the left where it is. With nothing selected, `shift(in:caret:by:)`.
    /// It was the caret's item alone that moved, and the selection was let
    /// go: three items selected and Tab moved the first.
    public static func shift(in source: String, selection: NSRange, by step: Int) -> Edit? {
        guard selection.length > 0 else { return shift(in: source, caret: selection.location, by: step) }
        let text = source as NSString
        let all = lines(of: source)
        func index(of offset: Int) -> Int? {
            all.firstIndex { $0.range.location <= offset && offset <= NSMaxRange($0.range) }
        }
        var end = NSMaxRange(selection)
        if end > selection.location, end > 0, end <= text.length, text.character(at: end - 1) == 10 { end -= 1 }
        guard let first = index(of: selection.location), var last = index(of: end), last >= first,
              !all[first].code, all[first].item
        else { return nil }
        let depth = all[first...last].filter { $0.item }.map(\.depth).min() ?? all[first].depth
        var next = last + 1
        while next < all.count {
            if all[next].blank {
                next += 1
                continue
            }
            guard all[next].depth > depth else { break }
            last = next
            next += 1
        }
        let moving = all[first...last].filter { !$0.blank && !$0.code }
        if step < 0, moving.allSatisfy({ $0.depth == 0 }) {
            return Edit(range: NSRange(location: selection.location, length: 0), replacement: "",
                        caret: selection.location, length: selection.length)
        }

        // Every line of them in or out by two spaces, from the bottom up so
        // the places above stay where they are. What is carried along — the
        // selection's ends, and where each moved line starts — moves with
        // the words: a place at a line's start stays at its start.
        let code = NoteCode.blocks(in: source).map(\.range)
        let span = NSRange(location: all[first].range.location,
                           length: NSMaxRange(all[last].range) - all[first].range.location)
        var edits: [(start: Int, spaces: Int)] = []
        for physical in NoteMath.lineRanges(of: text.substring(with: span) as NSString) {
            let start = span.location + physical.location
            let written = text.substring(with: NSRange(location: start, length: physical.length))
            guard !written.allSatisfy(\.isWhitespace), !code.contains(where: { NSLocationInRange(start, $0) }) else { continue }
            let spaces = step > 0 ? 2 : written.prefix(2).prefix { $0 == " " }.count
            if spaces > 0 { edits.append((start, spaces)) }
        }
        // The selection's two ends first, then where each moved line starts.
        var carried = [selection.location, NSMaxRange(selection)] + edits.map(\.start)
        var updated = source
        for edit in edits.reversed() {
            if step > 0 {
                updated = (updated as NSString).replacingCharacters(in: NSRange(location: edit.start, length: 0), with: "  ")
                carried = carried.map { $0 > edit.start ? $0 + 2 : $0 }
            } else {
                updated = (updated as NSString).replacingCharacters(in: NSRange(location: edit.start, length: edit.spaces), with: "")
                carried = carried.map { $0 > edit.start + edit.spaces ? $0 - edit.spaces : ($0 > edit.start ? edit.start : $0) }
            }
        }

        // An item that comes to start a list starts it at 1.
        let read = lines(of: updated)
        let counts = counted(read)
        let moved = Set(carried.dropFirst(2))
        for row in read.indices.reversed() where moved.contains(read[row].range.location) {
            guard let number = read[row].number, number != 1, counts[row].starts, read[row].depth == 0 else { continue }
            let digits = read[row].digits
            updated = (updated as NSString).replacingCharacters(in: digits, with: "1")
            let delta = 1 - digits.length
            carried = carried.map { $0 >= NSMaxRange(digits) ? $0 + delta : $0 }
        }
        (updated, carried) = numbered(updated, around: Array(carried.dropFirst(2)), carrying: carried)
        return difference(from: source, to: updated, caret: carried[0], length: max(0, carried[1] - carried[0]))
    }

    // MARK: - Return, Backspace, Delete

    /// Return with nothing selected: what the line was doing goes on — the
    /// next bullet, the next number, another empty box, another line of the
    /// quotation, a toggle's first child — and the list is numbered as it is
    /// shown. An empty item steps out a level, as ⇧Tab moves it; at the left
    /// it ends the list, the marker going and the line breaking, so a blank
    /// line stands between the list and what is written next (Markdown reads
    /// a line straight after an item as more of the item). An empty line of a
    /// toggle's children steps out to the toggle's own level: Return twice
    /// leaves a toggle. On a toggle whose children are folded away
    /// (`folded`), the new line goes after them, at the toggle's level.
    ///
    /// In the editors this was the text view's newline followed by the next
    /// marker typed in: two changes, which the note's undo read as a
    /// keystroke and an edit — ⌘Z took the marker and left a bare line, the
    /// next one took the line with the words before it, and «- » was short
    /// enough to count as typing, so a whole list of bullets was one ⌘Z. With
    /// the caret before a marker — a line's start — the next marker went in
    /// front of the old one, which became words: «3. 2. b». Nil where Return
    /// is a line break and nothing more: plain words, a heading, fenced code.
    public static func newLine(in source: String, caret: Int, folded: Bool = false) -> Edit? {
        let text = source as NSString
        guard caret >= 0, caret <= text.length, !inCode(caret, source) else { return nil }
        // Inside a formula, Return breaks the formula's line, not the item:
        // the next marker had gone into the middle of the LaTeX.
        guard NoteMath.span(at: caret, in: source) == nil else { return nil }
        let line = physicalLine(at: caret, in: text)
        let written = text.substring(with: line)
        guard let head = head(of: written), head.kind != .heading else {
            return stepOutOfToggle(line, written: written, caret: caret, in: source)
                ?? keepingIndent(line, caret: caret, in: text)
        }
        let wordsStart = line.location + head.length
        // A quotation's «>» is there to see on the line being edited, and a
        // caret before it is a line break before the quotation. A list's
        // marker is drawn: a caret before it is at its words.
        if head.kind == .quote, caret < wordsStart { return nil }
        let at = max(caret, wordsStart)
        let words = text.substring(with: NSRange(location: wordsStart, length: NSMaxRange(line) - wordsStart))
        if words.trimmingCharacters(in: .whitespaces).isEmpty {
            if head.depth > 0 {
                if head.isListItem { return shift(in: source, caret: wordsStart, by: -1) }
                return finished(source, NSRange(location: line.location, length: 2), "", caret: wordsStart - 2)
            }
            return finished(source, line, "\n", caret: line.location + 1)
        }
        let lead = String(repeating: " ", count: head.spaces)
        // At the start of a toggle's words the new line is an empty toggle
        // above it, as at the start of an item's: its words are its title,
        // and would have gone down into its first child.
        if head.kind == .toggle, at == wordsStart {
            let above = lead + "+ \n"
            return finished(source, NSRange(location: line.location, length: 0), above, caret: at + (above as NSString).length)
        }
        if head.kind == .toggle, folded, let end = childrenEnd(ofLineAt: line.location, in: source) {
            return finished(source, NSRange(location: end, length: 0), "\n" + lead, caret: end + 1 + head.spaces)
        }
        let marker = switch head.kind {
        case .bullet: lead + head.mark + " "
        case .ordered: lead + "\((head.number ?? 0) + 1)" + head.mark + " "
        case .task: lead + head.mark + " [ ] "
        case .quote: lead + "> "
        // A toggle's next line is its first child: a plain line, one step in.
        case .toggle, .heading: lead + "  "
        }
        return finished(source, NSRange(location: at, length: 0), "\n" + marker,
                        caret: at + 1 + (marker as NSString).length)
    }

    /// Backspace with nothing selected and the caret at the edge of a line's
    /// marker: a nested item steps out a level (with what is under it, as
    /// ⇧Tab moves it), and one at the left loses its marker and is plain
    /// words again — Notion's way back from a bullet. A list's marker is
    /// drawn, so its edge is both the start of its words and the start of
    /// the line; a quotation's or a heading's is shown as written on the
    /// line being edited, and its edge is where its words start. Nil
    /// anywhere else, where Backspace takes a character: at a line's start
    /// it had joined the line to the one above, «2. b3. c».
    public static func backspace(in source: String, caret: Int) -> Edit? {
        let text = source as NSString
        guard caret >= 0, caret <= text.length else { return nil }
        let line = physicalLine(at: caret, in: text)
        guard let head = head(of: text.substring(with: line)) else { return nil }
        let wordsStart = line.location + head.length
        guard head.isListItem ? caret <= wordsStart : caret == wordsStart, !inCode(caret, source) else { return nil }
        if head.depth > 0 {
            if head.isListItem { return shift(in: source, caret: wordsStart, by: -1) }
            return finished(source, NSRange(location: line.location, length: 2), "", caret: wordsStart - 2)
        }
        return finished(source, NSRange(location: line.location, length: head.length), "", caret: line.location)
    }

    /// Delete with nothing selected, at the end of a line, before a line with
    /// a marker: the next line's words join this one, without its marker —
    /// they had come in with it, «1. a2. b». From an empty line it is the
    /// empty line that goes, and the item below keeps its marker. Nil
    /// anywhere else, where Delete takes a character.
    public static func deleteForward(in source: String, caret: Int) -> Edit? {
        let text = source as NSString
        guard caret >= 0, caret < text.length else { return nil }
        let line = physicalLine(at: caret, in: text)
        guard caret == NSMaxRange(line) else { return nil }
        var nextStart = caret
        while nextStart < text.length, text.character(at: nextStart) == 13 { nextStart += 1 }
        guard nextStart < text.length, text.character(at: nextStart) == 10 else { return nil }
        nextStart += 1
        let next = physicalLine(at: nextStart, in: text)
        guard let head = head(of: text.substring(with: next)), !inCode(caret, source), !inCode(nextStart, source) else { return nil }
        if text.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty {
            return finished(source, NSRange(location: line.location, length: nextStart - line.location), "",
                            caret: line.location + head.length)
        }
        return finished(source, NSRange(location: caret, length: nextStart + head.length - caret), "", caret: caret)
    }

    /// A space typed with nothing selected, after «[]» at the start of a line
    /// or of a bullet's words — a box to tick, as Notion makes one — or after
    /// «--» at the start of a line — a toggle (Notion's `>` is a quotation
    /// in Markdown). Nil anywhere else, where the space is typed.
    public static func shortcut(in source: String, caret: Int) -> Edit? {
        let text = source as NSString
        guard caret >= 2, caret <= text.length,
              ["[]", "--"].contains(text.substring(with: NSRange(location: caret - 2, length: 2)))
        else { return nil }
        let line = physicalLine(at: caret, in: text)
        let sofar = text.substring(with: NSRange(location: line.location, length: caret - line.location)) as NSString
        var spaces = 0
        while spaces < sofar.length, sofar.character(at: spaces) == 32 { spaces += 1 }
        let typed = sofar.substring(from: spaces)
        let start = line.location + spaces
        let made: String
        if typed == "[]" {
            made = "- [ ] "
        } else if typed == "--" {
            made = "+ "
        } else if let match = boxedBulletPattern.firstMatch(in: typed, range: NSRange(location: 0, length: (typed as NSString).length)) {
            made = (typed as NSString).substring(with: match.range(at: 1)) + " [ ] "
        } else {
            return nil
        }
        guard !inCode(caret, source) else { return nil }
        return Edit(range: NSRange(location: start, length: caret - start), replacement: made,
                    caret: start + (made as NSString).length)
    }

    /// «- []», a bullet with a box typed as its words.
    static let boxedBulletPattern = try! NSRegularExpression(pattern: #"^([-*])\s+\[\]$"#)

    /// What a line starts with, read the way the renderer's `Block(line:)`
    /// reads it: a list's marker, a quotation's, a heading's.
    struct Head: Equatable {
        enum Kind: Equatable { case bullet, ordered, task, toggle, quote, heading }
        var kind: Kind
        /// The indentation, in spaces.
        var spaces: Int
        /// The indentation and the marker together: where the words start.
        var length: Int
        /// A bullet's or a box's character — `-`, `*`, `+` — or what closes
        /// a number, `.` or `)`. A list goes on in its own marks: «1)» and
        /// then «2.» would be two lists (`counted`), and «- » after «* »
        /// two lists to any other reader.
        var mark: String
        var number: Int?

        var depth: Int { spaces / 2 }
        var isListItem: Bool { kind != .quote && kind != .heading }
    }

    // The renderer's own patterns (`NoteMarkdown.Block`), for the lines that
    // are not counted: a heading's, and a toggle's and a bullet's as it
    // tells them apart.
    static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})\s+"#)
    static let blockTogglePattern = try! NSRegularExpression(pattern: #"^\+\s+"#)
    static let blockBulletPattern = try! NSRegularExpression(pattern: #"^[-*]\s+"#)

    static func head(of line: String) -> Head? {
        let text = line as NSString
        var spaces = 0
        while spaces < text.length, text.character(at: spaces) == 32 { spaces += 1 }
        let body = text.substring(from: spaces) as NSString
        // # - * + > and the digits: anything else is passed over on its first character.
        guard body.length > 0 else { return nil }
        let first = body.character(at: 0)
        guard [35, 45, 42, 43, 62].contains(first) || (48...57).contains(first) else { return nil }
        let whole = NSRange(location: 0, length: body.length)
        func match(_ pattern: NSRegularExpression) -> NSTextCheckingResult? {
            pattern.firstMatch(in: body as String, range: whole)
        }
        if let found = match(taskPattern) {
            return Head(kind: .task, spaces: spaces, length: spaces + found.range.length,
                        mark: body.substring(with: found.range(at: 1)))
        }
        if let found = match(headingPattern) {
            return Head(kind: .heading, spaces: spaces, length: spaces + found.range.length, mark: "")
        }
        if let found = match(blockTogglePattern) {
            return Head(kind: .toggle, spaces: spaces, length: spaces + found.range.length, mark: "+")
        }
        if let found = match(blockBulletPattern) {
            return Head(kind: .bullet, spaces: spaces, length: spaces + found.range.length,
                        mark: body.substring(with: NSRange(location: 0, length: 1)))
        }
        if let found = match(orderedPattern) {
            let digits = found.range(at: 1)
            return Head(kind: .ordered, spaces: spaces, length: spaces + found.range.length,
                        mark: body.substring(with: NSRange(location: NSMaxRange(digits), length: 1)),
                        number: Int(body.substring(with: digits)) ?? 1)
        }
        if first == 62 {
            var length = body.length > 1 && body.character(at: 1) == 32 ? 2 : 1
            // A quotation can hold the section it was taken from; its «###»
            // is part of the marker.
            let rest = body.substring(from: length)
            if let found = headingPattern.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
                length += found.range.length
            }
            return Head(kind: .quote, spaces: spaces, length: spaces + length, mark: ">")
        }
        return nil
    }

    /// The line an offset is on, without its break — split at «\n» alone, as
    /// the renderer splits a note.
    static func physicalLine(at offset: Int, in text: NSString) -> NSRange {
        var start = min(max(offset, 0), text.length)
        while start > 0, text.character(at: start - 1) != 10 { start -= 1 }
        var end = min(max(offset, 0), text.length)
        while end < text.length, text.character(at: end) != 10 { end += 1 }
        while end > start, text.character(at: end - 1) == 13 { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Whether the line an offset is on is fenced code.
    static func inCode(_ offset: Int, _ source: String) -> Bool {
        let start = physicalLine(at: offset, in: source as NSString).location
        return NoteCode.blocks(in: source).contains { NSLocationInRange(start, $0.range) || start == $0.range.location }
    }

    /// An empty line among a toggle's children — spaces only, two or more,
    /// the caret at its end — steps out to the toggle's own level.
    static func stepOutOfToggle(_ line: NSRange, written: String, caret: Int, in source: String) -> Edit? {
        let spaces = (written as NSString).length
        guard spaces >= 2, written.allSatisfy({ $0 == " " }), caret == NSMaxRange(line) else { return nil }
        let text = source as NSString
        var end = line.location - 1
        while end >= 0 {
            let above = physicalLine(at: end, in: text)
            let words = text.substring(with: above)
            if !words.trimmingCharacters(in: .whitespaces).isEmpty {
                let lead = words.prefix { $0 == " " }.count
                if lead < spaces {
                    guard let head = head(of: words), head.kind == .toggle else { return nil }
                    return finished(source, line, String(repeating: " ", count: head.spaces), caret: line.location + head.spaces)
                }
            }
            end = above.location - 1
        }
        return nil
    }

    /// Return on a line set in with no marker — a toggle's child, the rest
    /// of an item's words on a line of their own — goes on at the same
    /// indent, as CodeMirror's Return does in the Portable build
    /// (`insertNewlineAndIndent`, whose rules these are: a tab counts to
    /// the next multiple of four, the white space after the caret goes, and
    /// a caret in the indent breaks the line at its start). The Mac's text
    /// view broke the line at the left: the second line under a toggle was
    /// out of it, there and not here. Nil for a line at the left, where
    /// Return is a line break.
    static func keepingIndent(_ line: NSRange, caret: Int, in text: NSString) -> Edit? {
        var columns = 0
        var at = line.location
        while at < NSMaxRange(line), [9, 32].contains(text.character(at: at)) {
            columns = text.character(at: at) == 9 ? columns + 4 - columns % 4 : columns + 1
            at += 1
        }
        guard columns > 0 else { return nil }
        var from = caret, to = caret
        while to < NSMaxRange(line), isScriptSpace(text.character(at: to)) { to += 1 }
        var before = line.location
        while before < from, isScriptSpace(text.character(at: before)) { before += 1 }
        if from > line.location, from < line.location + 100, before == from { from = line.location }
        let insert = "\n" + String(repeating: " ", count: columns)
        return Edit(range: NSRange(location: from, length: to - from), replacement: insert,
                    caret: from + (insert as NSString).length)
    }

    /// JavaScript's `\s`, which CodeMirror's Return reads white space by.
    static func isScriptSpace(_ unit: unichar) -> Bool {
        switch unit {
        case 9...13, 32, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }

    /// Where a toggle's children end: the end of the last line under the
    /// line at `start` that is deeper than it — blank lines between them
    /// counting, blank lines after them not (`NoteMarkdown.children`). Nil
    /// when it has none.
    static func childrenEnd(ofLineAt start: Int, in source: String) -> Int? {
        let all = lines(of: source)
        guard let index = all.firstIndex(where: { $0.range.location == start }) else { return nil }
        var last: Int?
        var next = index + 1
        while next < all.count {
            if all[next].blank {
                next += 1
                continue
            }
            guard all[next].depth > all[index].depth else { break }
            last = next
            next += 1
        }
        return last.map { NSMaxRange(all[$0].range) }
    }

    /// An edit made, and the lists round it numbered as they are shown, the
    /// caret carried along — the numbers written in the note were the ones
    /// the items had before, and a list the reader saw as 1, 2, 3, 4 said
    /// 1, 2, 2, 3 in the file until something moved.
    static func finished(_ source: String, _ range: NSRange, _ replacement: String, caret: Int) -> Edit {
        let changed = (source as NSString).replacingCharacters(in: range, with: replacement)
        let (updated, ends) = numbered(changed, around: [range.location, caret], carrying: [caret])
        return difference(from: source, to: updated, caret: ends[0])
    }

    /// The lists round these places numbered as they are shown, and the
    /// positions carried through the digits that changed.
    static func numbered(_ source: String, around places: [Int], carrying positions: [Int]) -> (String, [Int]) {
        let read = lines(of: source)
        let shown = counted(read)
        var rows = Set<Int>()
        for place in places {
            guard let index = read.firstIndex(where: { $0.range.location <= place && place <= NSMaxRange($0.range) }) else { continue }
            rows.formUnion(region(around: index, in: read))
        }
        var updated = source
        var carried = positions
        for row in rows.sorted(by: >) {
            guard let written = read[row].number, let number = shown[row].shown, written != number else { continue }
            let digits = read[row].digits
            let replacement = String(number)
            updated = (updated as NSString).replacingCharacters(in: digits, with: replacement)
            let delta = (replacement as NSString).length - digits.length
            carried = carried.map { $0 >= NSMaxRange(digits) ? $0 + delta : $0 }
        }
        return (updated, carried)
    }

    // MARK: - Reading

    /// The note's lines as the lists read them: a formula or a table over
    /// several lines is one, as the renderer reads it.
    static func lines(of source: String) -> [Line] {
        let text = source as NSString
        let code = NoteCode.blocks(in: source).map(\.range)
        var ranges = NoteMath.lineRanges(of: text)
        let searched = blanking(source, code)
        let joined = (NoteMath.blocks(in: searched) + NoteTable.blocks(in: searched)).sorted { $0.location < $1.location }
        for block in joined.reversed() {
            guard let first = ranges.firstIndex(where: { $0.location == block.location }),
                  let last = ranges.firstIndex(where: { NSMaxRange($0) == NSMaxRange(block) }), last >= first
            else { continue }
            ranges.replaceSubrange(first...last, with: [block])
        }
        return ranges.map { range in
            let isCode = code.contains { NSLocationInRange(range.location, $0) || range.location == $0.location }
            return read(range, in: text, code: isCode)
        }
    }

    /// One line's depth and marker, read off its first physical line the
    /// way the renderer's `Block(line:)` reads them.
    static func read(_ range: NSRange, in text: NSString, code: Bool) -> Line {
        let whole = text.substring(with: range) as NSString
        let breakAt = whole.range(of: "\n").location
        let first = breakAt == NSNotFound ? whole : whole.substring(to: breakAt) as NSString
        var spaces = 0
        while spaces < first.length, first.character(at: spaces) == 32 { spaces += 1 }
        let body = first.substring(from: spaces)
        let blank = body.allSatisfy { $0.isWhitespace }
        var line = Line(range: range, depth: spaces / 2, blank: blank, item: false, number: nil,
                        contentStart: range.location + spaces, code: code)
        // A marker starts with a digit, a dash, a star or a plus: most lines
        // are passed over on their first character.
        guard !code, !blank, let head = body.utf16.first,
              (48...57).contains(head) || head == 45 || head == 42 || head == 43
        else { return line }
        let whole16 = NSRange(location: 0, length: (body as NSString).length)
        if let match = orderedPattern.firstMatch(in: body, range: whole16) {
            line.item = true
            line.number = Int((body as NSString).substring(with: match.range(at: 1))) ?? 1
            line.digits = NSRange(location: range.location + spaces + match.range(at: 1).location,
                                  length: match.range(at: 1).length)
            line.delimiter = (body as NSString).character(at: NSMaxRange(match.range(at: 1)))
            line.contentStart = range.location + spaces + match.range.length
        } else if let match = taskPattern.firstMatch(in: body, range: whole16)
                    ?? togglePattern.firstMatch(in: body, range: whole16)
                    ?? bulletPattern.firstMatch(in: body, range: whole16) {
            line.item = true
            line.contentStart = range.location + spaces + match.range.length
        }
        return line
    }

    // The renderer's own patterns (`NoteMarkdown.Block`).
    static let orderedPattern = try! NSRegularExpression(pattern: #"^(\d{1,3})[.)]\s+"#)
    static let taskPattern = try! NSRegularExpression(pattern: #"^([-*+])\s+\[([ xX])\]\s+"#)
    static let togglePattern = try! NSRegularExpression(pattern: #"^\+ "#)
    static let bulletPattern = try! NSRegularExpression(pattern: #"^[-*+]\s+"#)

    /// Each line's shown number, and whether it starts its list.
    static func counted(_ lines: [Line]) -> [(shown: Int?, starts: Bool)] {
        var open: [Int: (next: Int, delimiter: unichar)] = [:]
        var result: [(shown: Int?, starts: Bool)] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            guard !line.blank else {
                result.append((nil, false))
                continue
            }
            open = open.filter { $0.key <= line.depth }
            guard let written = line.number else {
                open[line.depth] = nil
                result.append((nil, false))
                continue
            }
            if let run = open[line.depth], run.delimiter == line.delimiter {
                result.append((run.next, false))
                open[line.depth] = (run.next + 1, line.delimiter)
            } else {
                let start = line.depth == 0 ? written : 1
                result.append((start, true))
                open[line.depth] = (start + 1, line.delimiter)
            }
        }
        return result
    }

    /// The list a line is in: the lines round it that are items, deeper
    /// than the left, or blank — up to a line at the left that is none of
    /// those (a paragraph, a heading, a formula, code).
    static func region(around index: Int, in lines: [Line]) -> ClosedRange<Int> {
        func inList(_ line: Line) -> Bool { line.blank || line.item || line.depth > 0 }
        var lower = index, upper = index
        while lower > 0, inList(lines[lower - 1]) { lower -= 1 }
        while upper + 1 < lines.count, inList(lines[upper + 1]) { upper += 1 }
        return lower...upper
    }

    /// The text with every fenced block's characters but its line breaks
    /// made spaces (`NoteMarkdown.blankingCode`): nothing in code is read as
    /// a formula or a table.
    static func blanking(_ source: String, _ code: [NSRange]) -> String {
        guard !code.isEmpty else { return source }
        var units = Array(source.utf16)
        for range in code {
            for index in range.location..<min(NSMaxRange(range), units.count) where units[index] != 10 {
                units[index] = 32
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// The one change between two texts: what they share at either end left
    /// out.
    static func difference(from old: String, to new: String, caret: Int, length: Int = 0) -> Edit {
        let a = Array(old.utf16), b = Array(new.utf16)
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        // Never between the halves of a character written as two units: the
        // replacement would begin or end with half a character.
        while head > 0, UTF16.isLeadSurrogate(a[head - 1]) { head -= 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        while tail > 0, UTF16.isTrailSurrogate(a[a.count - tail]) { tail -= 1 }
        let replacement = String(decoding: b[head..<(b.count - tail)], as: UTF16.self)
        return Edit(range: NSRange(location: head, length: a.count - tail - head), replacement: replacement,
                    caret: caret, length: length)
    }
}
