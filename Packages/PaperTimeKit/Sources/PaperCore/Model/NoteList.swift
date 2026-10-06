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
    /// before, `caret` in the text after).
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String
        public var caret: Int

        public init(range: NSRange, replacement: String, caret: Int) {
            self.range = range
            self.replacement = replacement
            self.caret = caret
        }
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
    static func difference(from old: String, to new: String, caret: Int) -> Edit {
        let a = Array(old.utf16), b = Array(new.utf16)
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let replacement = String(decoding: b[head..<(b.count - tail)], as: UTF16.self)
        return Edit(range: NSRange(location: head, length: a.count - tail - head), replacement: replacement, caret: caret)
    }
}
