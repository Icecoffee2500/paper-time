import Foundation

/// Where a Markdown note has math, code and comments — read the way Latex
/// Suite reads it.
///
/// Latex Suite does not ask the editor where math is; it parses the note with
/// `@lezer/markdown` (CommonMark + GFM) plus its own `$`/`$$`, `%%comment%%`,
/// `[[wikilink]]` and `==highlight==` rules, and asks that tree. So this is a
/// port of the parts of that parser that decide whether a `$` can open math:
/// the block structure (containers, fences, `$$` blocks, indented code, HTML
/// blocks, block comments, tables) and, inside paragraphs, the inline
/// constructs that swallow a `$` before the math rule sees it (code spans,
/// escapes, HTML tags and autolinks, link destinations, wikilinks, comments,
/// bare URLs). Emphasis, entities, hard breaks, strikethrough and highlights
/// are left out on purpose: none of them can contain or hide a `$`.
///
/// The block pass walks line starts from the top of the document to the
/// caret's block — block structure cannot be read backwards from the caret,
/// because whether a ```` ``` ```` line opens or closes a fence depends on
/// every fence above it. That walk looks at the first few characters of each
/// line; the character-level work (inline parsing) is done only for the
/// paragraphs that touch the caret.
struct LSMarkdown {
    struct Fence {
        var from: Int
        var to: Int
        var openMark: Range<Int>
        var info: Range<Int>?
        var closeMark: Range<Int>?
        var codeText: [Range<Int>]
    }

    struct DisplayBlock {
        var from: Int
        var to: Int
        var open: Range<Int>
        var close: Range<Int>?
        var content: [Range<Int>]
        /// Whether a line after the first carried a `>` marker: those markers
        /// are children of the block too, between the opening `$$` and what
        /// follows it.
        var hasMarkers = false
    }

    /// A paragraph, heading or table cell: text the inline rules run over.
    /// `blanks` are container prefixes (`> `, list indentation) on
    /// continuation lines, which lezer replaces with spaces (`Line.scrub`).
    struct Section {
        var from: Int
        var to: Int
        var blanks: [Range<Int>] = []
    }

    struct InlineMath {
        var from: Int
        var to: Int
        /// The opening and closing delimiters, `${}`/`{}$` included when the
        /// math uses them.
        var open: Range<Int>
        var close: Range<Int>
        var display: Bool
    }

    let source: LSUnits
    var fences: [Fence] = []
    var displayBlocks: [DisplayBlock] = []
    var sections: [Section] = []
    var inlineMath: [InlineMath] = []
    var inlineCode: [Range<Int>] = []

    /// Parses `doc` far enough to answer questions about `window`: every block
    /// that starts at or before its upper end, and the inline content of the
    /// sections that touch it.
    init(_ doc: LSUnits, window: ClosedRange<Int>) {
        source = doc
        // The block pass reads every line above the caret on every keystroke;
        // through a buffer pointer that costs half what array subscripts do
        // in a debug build, which is where it was slowest.
        (fences, displayBlocks, sections) = doc.withUnsafeBufferPointer { buffer in
            let parser = LSBlockParser(buffer)
            parser.run(until: window.upperBound)
            return (parser.fences, parser.displayBlocks, parser.sections)
        }
        for section in sections where section.from <= window.upperBound && section.to >= window.lowerBound {
            var inline = LSInlineParser(doc, section)
            inline.parse(until: window.upperBound)
            inlineMath += inline.math
            inlineCode += inline.code
        }
        inlineMath.sort { $0.from < $1.from }
    }
}

// MARK: - Block structure (lezer-markdown's BlockContext)

private enum ContainerType { case document, blockquote, bulletList, orderedList, listItem }

private struct Container {
    var type: ContainerType
    var value: Int
}

private struct Line {
    var start = 0
    var length = 0
    var baseIndent = 0
    var basePos = 0
    var depth = 0
    var pos = 0
    var indent = 0
    var next = -1
    /// Blockquote markers matched on this line.
    var marks = 0
}

/// The note's units, borrowed for the length of one parse.
typealias LSBuffer = UnsafeBufferPointer<UInt16>

final class LSBlockParser {
    private let doc: LSBuffer
    private var line = Line()
    private var lineEnd = 0
    private var atEnd = false
    private var stack: [Container] = [Container(type: .document, value: 0)]
    private var stopped = false

    fileprivate(set) var fences: [LSMarkdown.Fence] = []
    fileprivate(set) var displayBlocks: [LSMarkdown.DisplayBlock] = []
    fileprivate(set) var sections: [LSMarkdown.Section] = []

    init(_ doc: LSBuffer) {
        self.doc = doc
    }

    // MARK: Line helpers

    /// The character at `i` of the current line, -1 outside it.
    @inline(__always)
    private func ch(_ i: Int) -> Int {
        i >= 0 && i < line.length ? Int(doc[line.start + i]) : -1
    }

    private func skipSpace(_ from: Int) -> Int {
        var i = from
        while i < line.length, LS.isMarkdownSpace(ch(i)) { i += 1 }
        return i
    }

    private func skipSpaceBack(_ from: Int, to: Int) -> Int {
        var i = from
        while i > to, LS.isMarkdownSpace(ch(i - 1)) { i -= 1 }
        return i
    }

    private func countIndent(_ to: Int, from: Int = 0, indent: Int = 0) -> Int {
        var indent = indent
        var i = from
        while i < to {
            indent += ch(i) == 9 ? 4 - indent % 4 : 1
            i += 1
        }
        return indent
    }

    private func findColumn(_ goal: Int) -> Int {
        var i = 0
        var indent = 0
        while i < line.length, indent < goal {
            indent += ch(i) == 9 ? 4 - indent % 4 : 1
            i += 1
        }
        return i
    }

    private func forwardInner() {
        let newPos = skipSpace(line.basePos)
        line.indent = countIndent(newPos, from: line.pos, indent: line.indent)
        line.pos = newPos
        line.next = newPos == line.length ? -1 : ch(newPos)
    }

    private func forward() {
        if line.basePos > line.pos { forwardInner() }
    }

    private func moveBase(_ to: Int) {
        line.basePos = to
        line.baseIndent = countIndent(to, from: line.pos, indent: line.indent)
    }

    private func moveBaseColumn(_ indent: Int) {
        line.baseIndent = indent
        line.basePos = findColumn(indent)
    }

    // MARK: Reading lines

    private func readLine() {
        var end = line.start
        while end < doc.count, doc[end] != 10 { end += 1 }
        lineEnd = end
        line.length = end - line.start
        line.baseIndent = 0
        line.basePos = 0
        line.pos = 0
        line.indent = 0
        line.marks = 0
        forwardInner()
        line.depth = 1
        while line.depth < stack.count {
            if !skipMarkup(line.depth) {
                forward()
                break
            }
            forward()
            line.depth += 1
        }
    }

    /// Moves to the next line; false at the end of the document.
    @discardableResult
    private func nextLine() -> Bool {
        if lineEnd >= doc.count {
            line.start = doc.count
            atEnd = true
            readLine()
            return false
        }
        line.start = lineEnd + 1
        readLine()
        return true
    }

    private func prevLineEnd() -> Int { atEnd ? line.start : line.start - 1 }

    private func peekLine() -> Range<Int> {
        let start = lineEnd + 1
        guard start <= doc.count else { return doc.count..<doc.count }
        var end = start
        while end < doc.count, doc[end] != 10 { end += 1 }
        return start..<end
    }

    private func skipMarkup(_ depth: Int) -> Bool {
        let block = stack[depth]
        switch block.type {
        case .document:
            return true
        case .blockquote:
            if line.next != 62 { return false }
            line.marks += 1
            moveBase(line.pos + (LS.isMarkdownSpace(ch(line.pos + 1)) ? 2 : 1))
            return true
        case .listItem:
            if line.indent < line.baseIndent + block.value && line.next > -1 { return false }
            moveBaseColumn(line.baseIndent + block.value)
            return true
        case .bulletList, .orderedList:
            if line.pos == line.length ||
                (depth != stack.count - 1 && line.indent >= stack[line.depth + 1].value + line.baseIndent) {
                return true
            }
            if line.indent >= line.baseIndent + 4 { return false }
            let size = block.type == .orderedList ? isOrderedList(breaking: false) : isBulletList(breaking: false)
            return size > 0 &&
                (block.type != .bulletList || isHorizontalRule(breaking: false) < 0) &&
                ch(line.pos + size - 1) == block.value
        }
    }

    // MARK: Line tests

    private func isFencedCode() -> Int {
        guard line.next == 96 || line.next == 126 else { return -1 }
        var p = line.pos + 1
        while p < line.length, ch(p) == line.next { p += 1 }
        if p < line.pos + 3 { return -1 }
        if line.next == 96 {
            var i = p
            while i < line.length {
                if ch(i) == 96 { return -1 }
                i += 1
            }
        }
        return p
    }

    private func isBlockquote() -> Int {
        line.next != 62 ? -1 : ch(line.pos + 1) == 32 ? 2 : 1
    }

    private func isHorizontalRule(breaking: Bool) -> Int {
        guard line.next == 42 || line.next == 45 || line.next == 95 else { return -1 }
        var count = 1
        var p = line.pos + 1
        while p < line.length {
            let c = ch(p)
            if c == line.next {
                count += 1
            } else if !LS.isMarkdownSpace(c) {
                return -1
            }
            p += 1
        }
        // Setext headings take precedence.
        if breaking && line.next == 45 && isSetextUnderline() > -1 && line.depth == stack.count { return -1 }
        return count < 3 ? -1 : 1
    }

    private func inList(_ type: ContainerType) -> Bool { stack.contains { $0.type == type } }

    private func isBulletList(breaking: Bool) -> Int {
        let n = line.next
        guard n == 45 || n == 43 || n == 42 else { return -1 }
        guard line.pos == line.length - 1 || LS.isMarkdownSpace(ch(line.pos + 1)) else { return -1 }
        if breaking && !inList(.bulletList) && skipSpace(line.pos + 2) >= line.length { return -1 }
        return 1
    }

    private func isOrderedList(breaking: Bool) -> Int {
        var p = line.pos
        var next = line.next
        while true {
            if LS.isDigit(next) { p += 1 } else { break }
            if p == line.length { return -1 }
            next = ch(p)
        }
        if p == line.pos || p > line.pos + 9 || (next != 46 && next != 41) ||
            (p < line.length - 1 && !LS.isMarkdownSpace(ch(p + 1))) {
            return -1
        }
        if breaking && !inList(.orderedList) &&
            (skipSpace(p + 1) == line.length || p > line.pos + 1 || line.next != 49) {
            return -1
        }
        return p + 1 - line.pos
    }

    private func isAtxHeading() -> Int {
        guard line.next == 35 else { return -1 }
        var p = line.pos + 1
        while p < line.length, ch(p) == 35 { p += 1 }
        if p < line.length && ch(p) != 32 { return -1 }
        let size = p - line.pos
        return size > 6 ? -1 : size
    }

    private func isSetextUnderline() -> Int {
        if (line.next != 45 && line.next != 61) || line.indent >= line.baseIndent + 4 { return -1 }
        var p = line.pos + 1
        while p < line.length, ch(p) == line.next { p += 1 }
        let end = p
        while p < line.length, LS.isMarkdownSpace(ch(p)) { p += 1 }
        return p == line.length ? end : -1
    }

    private func isHTMLBlock(breaking: Bool) -> Int {
        guard line.next == 60 else { return -1 }
        let rest = LS.string(doc, line.start + line.pos, line.start + line.length)
        let count = LSHTML.blockStarts.count - (breaking ? 1 : 0)
        for i in 0..<count where LSHTML.matches(LSHTML.blockStarts[i], rest) { return i }
        return -1
    }

    private func getListIndent(_ pos: Int) -> Int {
        let indentAfter = countIndent(pos, from: line.pos, indent: line.indent)
        let skipped = skipSpace(pos)
        let indented = countIndent(skipped, from: pos, indent: indentAfter)
        return indented >= indentAfter + 5 || skipped == line.length ? indentAfter + 1 : indented
    }

    private func isDisplayBlockStart() -> Int {
        guard line.next == LS.dollarInt, line.indent - line.baseIndent <= 3 else { return -1 }
        var p = line.pos + 1
        while p < line.length, ch(p) == line.next { p += 1 }
        if p < line.pos + 2 { return -1 }
        var i = p
        while i < line.length {
            if ch(i) == LS.dollarInt { return -1 }
            i += 1
        }
        return p
    }

    private func isDisplayBlockEnd(_ length: Int) -> Range<Int>? {
        var start = line.pos
        while start < line.length, ch(start) != LS.dollarInt { start += 1 }
        var p = start
        while p < line.length, ch(p) == LS.dollarInt { p += 1 }
        return p - start >= length && skipSpace(p) == line.length ? start..<p : nil
    }

    private func isBlockCommentBegin() -> Bool {
        guard line.next == 37, ch(line.pos + 1) == 37 else { return false }
        var i = line.pos + 2
        while i < line.length - 1 {
            if ch(i) == 37 && ch(i + 1) == 37 { return false }
            i += 1
        }
        return true
    }

    private func commentEnd() -> Int {
        var i = line.pos
        while i < line.length {
            if ch(i) == 37 && ch(i + 1) == 37 { return i }
            i += 1
        }
        return -1
    }

    // MARK: The block loop

    private enum Outcome { case no, container, leaf, stop }

    /// The block parsers, in the order lezer tries them. An enum rather than
    /// an array of method references: that array is ten closure contexts
    /// allocated for every line of the note, on every keystroke.
    private enum BlockStart {
        case indentedCode, fencedCode, displayMath, blockquote, horizontalRule
        case bulletList, orderedList, atxHeading, htmlBlock, blockComment

        static let order: [BlockStart] = [.indentedCode, .fencedCode, .displayMath, .blockquote, .horizontalRule,
                                          .bulletList, .orderedList, .atxHeading, .htmlBlock, .blockComment]
    }

    private func start(_ parser: BlockStart) -> Outcome {
        switch parser {
        case .indentedCode: return indentedCode()
        case .fencedCode: return fencedCode()
        case .displayMath: return displayMath()
        case .blockquote: return blockquote()
        case .horizontalRule: return horizontalRule()
        case .bulletList: return bulletList()
        case .orderedList: return orderedList()
        case .atxHeading: return atxHeading()
        case .htmlBlock: return htmlBlock()
        case .blockComment: return blockComment()
        }
    }

    func run(until limit: Int) {
        line.start = 0
        readLine()
        outer: while !stopped {
            // Close the containers this line did not continue, skip blank lines.
            while true {
                while line.depth < stack.count { stack.removeLast() }
                if line.pos < line.length { break }
                if !nextLine() { return }
            }
            if line.start > limit { return }
            blocks: while true {
                for parser in BlockStart.order {
                    switch start(parser) {
                    case .no: continue
                    case .leaf: continue outer
                    case .stop: return
                    case .container:
                        forward()
                        continue blocks
                    }
                }
                break
            }
            if line.pos == line.length {
                if !nextLine() { return }
                continue
            }
            paragraph()
        }
    }

    private func startContainer(_ type: ContainerType, value: Int = 0) {
        stack.append(Container(type: type, value: value))
    }

    private func indentedCode() -> Outcome {
        let base = line.baseIndent + 4
        if line.indent < base { return .no }
        while nextLine() && line.depth >= stack.count {
            if line.pos == line.length { continue }
            if line.indent < base { break }
        }
        return .leaf
    }

    private func fencedCode() -> Outcome {
        let fenceEnd = isFencedCode()
        if fenceEnd < 0 { return .no }
        let from = line.start + line.pos
        let fenceChar = line.next
        let length = fenceEnd - line.pos
        let infoFrom = skipSpace(fenceEnd)
        let infoTo = skipSpaceBack(line.length, to: infoFrom)
        var fence = LSMarkdown.Fence(from: from, to: from, openMark: from..<(from + length),
                                     info: infoFrom < infoTo ? (line.start + infoFrom)..<(line.start + infoTo) : nil,
                                     closeMark: nil, codeText: [])
        func addCodeText(_ range: Range<Int>) {
            if let last = fence.codeText.last, last.upperBound == range.lowerBound {
                fence.codeText[fence.codeText.count - 1] = last.lowerBound..<range.upperBound
            } else {
                fence.codeText.append(range)
            }
        }
        var first = true
        var empty = true
        var hasLine = false
        while nextLine() && line.depth >= stack.count {
            var i = line.pos
            if line.indent - line.baseIndent < 4 {
                while i < line.length, ch(i) == fenceChar { i += 1 }
            }
            if i - line.pos >= length && skipSpace(i) == line.length {
                if empty && hasLine { addCodeText((line.start - 1)..<line.start) }
                fence.closeMark = (line.start + line.pos)..<(line.start + i)
                nextLine()
                break
            }
            hasLine = true
            if !first {
                addCodeText((line.start - 1)..<line.start)
                empty = false
            }
            let textStart = line.start + line.basePos
            let textEnd = line.start + line.length
            if textStart < textEnd {
                addCodeText(textStart..<textEnd)
                empty = false
            }
            first = false
        }
        fence.to = prevLineEnd()
        fences.append(fence)
        return .leaf
    }

    /// Latex Suite's `$$` block (mathjax-parser.ts, blockParserDisplayMath):
    /// fenced like ```` ``` ````, closed by the first line whose first run of
    /// `$` is long enough and followed only by space.
    private func displayMath() -> Outcome {
        let dollarEnd = isDisplayBlockStart()
        if dollarEnd < 0 { return .no }
        let startPos = line.start + line.pos
        let length = dollarEnd - line.pos
        let firstEqChar = skipSpace(dollarEnd)
        var endLine = line.start + line.length
        var block = LSMarkdown.DisplayBlock(from: startPos, to: endLine, open: startPos..<(line.start + dollarEnd),
                                            close: nil, content: [])
        func add(_ range: Range<Int>) {
            if let last = block.content.last, last.upperBound == range.lowerBound {
                block.content[block.content.count - 1] = last.lowerBound..<range.upperBound
            } else {
                block.content.append(range)
            }
        }
        var first = true
        if firstEqChar < line.length {
            add((line.start + firstEqChar)..<(line.start + line.length))
            first = false
        }
        let depth = stack.count
        while nextLine() && ((line.length > 0 && depth >= 2) || depth < 2) {
            endLine = line.start + line.length
            if line.marks > 0 { block.hasMarkers = true }
            if let end = isDisplayBlockEnd(length) {
                let endFrom = line.start + end.lowerBound
                if line.start + line.basePos < endFrom {
                    add((line.start - 1)..<line.start)
                    add((line.start + line.basePos)..<endFrom)
                }
                block.close = endFrom..<(line.start + end.upperBound)
                nextLine()
                break
            }
            if !first { add((line.start - 1)..<line.start) }
            let textStart = line.start + line.basePos
            let textEnd = line.start + line.length
            if textStart < textEnd { add(textStart..<textEnd) }
            first = false
        }
        block.to = endLine
        displayBlocks.append(block)
        return .leaf
    }

    private func blockquote() -> Outcome {
        let size = isBlockquote()
        if size < 0 { return .no }
        startContainer(.blockquote)
        moveBase(line.pos + size)
        return .container
    }

    private func horizontalRule() -> Outcome {
        if isHorizontalRule(breaking: false) < 0 { return .no }
        nextLine()
        return .leaf
    }

    private func bulletList() -> Outcome {
        if isBulletList(breaking: false) < 0 { return .no }
        if stack.last?.type != .bulletList { startContainer(.bulletList, value: line.next) }
        let newBase = getListIndent(line.pos + 1)
        startContainer(.listItem, value: newBase - line.baseIndent)
        moveBaseColumn(newBase)
        return .container
    }

    private func orderedList() -> Outcome {
        let size = isOrderedList(breaking: false)
        if size < 0 { return .no }
        if stack.last?.type != .orderedList { startContainer(.orderedList, value: ch(line.pos + size - 1)) }
        let newBase = getListIndent(line.pos + size)
        startContainer(.listItem, value: newBase - line.baseIndent)
        moveBaseColumn(newBase)
        return .container
    }

    private func atxHeading() -> Outcome {
        let size = isAtxHeading()
        if size < 0 { return .no }
        let off = line.pos
        let endOfSpace = skipSpaceBack(line.length, to: off)
        var after = endOfSpace
        while after > off, ch(after - 1) == line.next { after -= 1 }
        if after == endOfSpace || after == off || !LS.isMarkdownSpace(ch(after - 1)) { after = line.length }
        let from = line.start + off + size + 1
        let to = line.start + after
        if from < to { sections.append(LSMarkdown.Section(from: from, to: to)) }
        nextLine()
        return .leaf
    }

    private func htmlBlock() -> Outcome {
        let kind = isHTMLBlock(breaking: false)
        if kind < 0 { return .no }
        let end = LSHTML.blockEnds[kind]
        var trailing = end != nil
        func ends() -> Bool {
            let text = LS.string(doc, line.start, line.start + line.length)
            if let end { return LSHTML.contains(end, text) }
            return LSHTML.isEmptyLine(text)
        }
        while !ends() && nextLine() {
            if line.depth < stack.count {
                trailing = false
                break
            }
        }
        if trailing { nextLine() }
        return .leaf
    }

    private func blockComment() -> Outcome {
        if !isBlockCommentBegin() { return .no }
        while nextLine() {
            let end = commentEnd()
            if end == -1 { continue }
            let endPos = line.start + end + 2
            if endPos < line.start + line.length {
                sections.append(LSMarkdown.Section(from: endPos, to: line.start + line.length))
            }
            nextLine()
            return .leaf
        }
        // An unclosed block comment consumes every line to the end without
        // leaving a node, and the parse then finishes (the parser returns false
        // after moving the line, and the empty last line ends the document).
        return .stop
    }

    // MARK: Paragraphs, headings, tables

    private func paragraph() {
        let leafStart = line.start + line.pos
        var section = LSMarkdown.Section(from: leafStart, to: line.start + line.length)
        let firstLine = leafStart..<(line.start + line.length)
        let tableCandidate = hasPipe(firstLine)
        var tableRows: [LSMarkdown.Section]?
        var tableChecked = false
        while nextLine() {
            if line.pos == line.length { break }
            if line.indent < line.baseIndent + 4 && endsLeaf(tableCandidate: tableCandidate) { break }
            // Leaf parsers, in lezer's order: the table, then setext headings.
            if tableCandidate {
                if !tableChecked {
                    tableChecked = true
                    let rest = (line.start + line.pos)..<(line.start + line.length)
                    if line.next == 45 || line.next == 58 || line.next == 124,
                       LSTable.isDelimiterLine(doc, rest),
                       LSTable.rowCount(doc, section.from..<section.to, cells: nil) == LSTable.rowCount(doc, rest, cells: nil) {
                        var header: [LSMarkdown.Section] = []
                        _ = LSTable.rowCount(doc, section.from..<section.to, cells: &header)
                        tableRows = header
                    }
                } else if tableRows != nil {
                    var cells: [LSMarkdown.Section] = []
                    _ = LSTable.rowCount(doc, (line.start + line.pos)..<(line.start + line.length), cells: &cells)
                    tableRows! += cells
                }
            }
            if line.depth >= stack.count && isSetextUnderline() > -1 {
                nextLine()
                sections.append(section)
                return
            }
            if line.baseIndent > 0 && line.basePos > 0 {
                section.blanks.append(line.start..<(line.start + line.basePos))
            }
            section.to = line.start + line.length
        }
        if let tableRows {
            sections += tableRows
        } else {
            sections.append(section)
        }
    }

    private func hasPipe(_ range: Range<Int>) -> Bool {
        var i = range.lowerBound
        while i < range.upperBound {
            let c = doc[i]
            if c == 124 { return true }
            if c == 92 { i += 1 }
            i += 1
        }
        return false
    }

    private func endsLeaf(tableCandidate: Bool) -> Bool {
        if isAtxHeading() >= 0 || isFencedCode() >= 0 || isBlockquote() >= 0 ||
            isBulletList(breaking: true) >= 0 || isOrderedList(breaking: true) >= 0 ||
            isHorizontalRule(breaking: true) >= 0 || isHTMLBlock(breaking: true) >= 0 {
            return true
        }
        // GFM: a line with a pipe followed by a matching delimiter row starts a table.
        if !tableCandidate && hasPipe((line.start + line.basePos)..<(line.start + line.length)) {
            let next = peekLine()
            if LSTable.isDelimiterLine(doc, next) {
                let here = (line.start + line.basePos)..<(line.start + line.length)
                let nextRow = (next.lowerBound + Swift.min(line.basePos, next.count))..<next.upperBound
                if LSTable.rowCount(doc, here, cells: nil) == LSTable.rowCount(doc, nextRow, cells: nil) { return true }
            }
        }
        return isDisplayBlockStart() >= 0 || isBlockCommentBegin()
    }
}

extension LS {
    static let dollarInt = 36
}

// MARK: - GFM tables

enum LSTable {
    /// `/^[>\s]*\|?(\s*:?-+:?\s*\|)+(\s*:?-+:?\s*)?$/`, by hand.
    static func isDelimiterLine(_ doc: LSBuffer, _ range: Range<Int>) -> Bool {
        var i = range.lowerBound
        let end = range.upperBound
        while i < end, doc[i] == 62 || LS.isSpace(doc[i]) { i += 1 }
        // The leading run may have eaten spaces that belong to the first cell;
        // that is harmless because `\s*` would have taken them anyway.
        if i < end, doc[i] == 124 { i += 1 }
        var cells = 0
        while true {
            var j = i
            while j < end, LS.isSpace(doc[j]) { j += 1 }
            if j < end, doc[j] == 58 { j += 1 }
            let dashes = j
            while j < end, doc[j] == 45 { j += 1 }
            if j == dashes { break }
            if j < end, doc[j] == 58 { j += 1 }
            while j < end, LS.isSpace(doc[j]) { j += 1 }
            if j < end, doc[j] == 124 {
                cells += 1
                i = j + 1
                continue
            }
            // The optional last cell without a closing pipe.
            return cells > 0 && j == end
        }
        guard cells > 0 else { return false }
        var j = i
        while j < end, LS.isSpace(doc[j]) { j += 1 }
        return j == end
    }

    /// lezer's `parseRow`: the number of cells, and optionally each cell as an
    /// inline section.
    @discardableResult
    static func rowCount(_ doc: LSBuffer, _ range: Range<Int>, cells: UnsafeMutablePointer<[LSMarkdown.Section]>?) -> Int {
        var count = 0
        var first = true
        var cellStart = -1
        var cellEnd = -1
        var escaped = false
        var i = range.lowerBound
        while i < range.upperBound {
            let next = doc[i]
            if next == 124 && !escaped {
                if !first || cellStart > -1 { count += 1 }
                first = false
                if cellStart > -1 { cells?.pointee.append(LSMarkdown.Section(from: cellStart, to: cellEnd)) }
                cellStart = -1
                cellEnd = -1
            } else if escaped || (next != 32 && next != 9) {
                if cellStart < 0 { cellStart = i }
                cellEnd = i + 1
            }
            escaped = !escaped && next == LS.backslash
            i += 1
        }
        if cellStart > -1 {
            count += 1
            cells?.pointee.append(LSMarkdown.Section(from: cellStart, to: cellEnd))
        }
        return count
    }

    static func rowCount(_ doc: LSBuffer, _ range: Range<Int>, cells: inout [LSMarkdown.Section]) -> Int {
        withUnsafeMutablePointer(to: &cells) { rowCount(doc, range, cells: $0) }
    }
}

// MARK: - HTML blocks and tags

enum LSHTML {
    private static let space = "[\\t\\n\\u000b\\u000c\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]"
    private static let notSpace = "[^\\t\\n\\u000b\\u000c\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]"
    private static let word = "[A-Za-z0-9_]"

    private static func re(_ pattern: String, _ caseless: Bool = false) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: caseless ? [.caseInsensitive] : [])
    }

    /// lezer-markdown's HTMLBlockStyle openers, in order.
    static let blockStarts: [NSRegularExpression] = [
        re("^<(?:script|pre|style)(?:\(space)|>|$)", true),
        re("^\(space)*<!--"),
        re("^\(space)*<\\?"),
        re("^\(space)*<![A-Z]"),
        re("^\(space)*<!\\[CDATA\\["),
        re("^\(space)*</?(?:address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h1|h2|h3|h4|h5|h6|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|section|source|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:\(space)|/?>|$)", true),
        re("^\(space)*(?:</[a-z]\(word.dropLast())\\-]*\(space)*>|<[a-z]\(word.dropLast())\\-]*(\(space)+[a-z:_]\(word.dropLast())\\-.]*(?:\(space)*=\(space)*(?:[^\\t\\n\\u000b\\u000c\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff\"'=<>`]+|'[^']*'|\"[^\"]*\"))?)*\(space)*>)\(space)*$", true),
    ]

    /// The matching closers; nil means "an empty line".
    static let blockEnds: [NSRegularExpression?] = [
        re("</(?:script|pre|style)>", true), re("-->"), re("\\?>"), re(">"), re("\\]\\]>"), nil, nil,
    ]

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, options: [.anchored], range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func contains(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func isEmptyLine(_ text: String) -> Bool {
        text.utf16.allSatisfy { $0 == 32 || $0 == 9 }
    }

    /// The inline HTMLTag parser's four patterns, tried in its order on the
    /// text after `<`. Returns the length matched after the `<`.
    static let inlineAutolink = re("(?:[a-z][\\-A-Za-z0-9_+.]+:[^\\t\\n\\u000b\\u000c\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff>]+|[a-z0-9.!#$%&'*+/=?^_`{|}~\\-]+@[a-z0-9](?:[a-z0-9\\-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9\\-]{0,61}[a-z0-9])?)*)>", true)
    static let inlineComment = re("!--[^>](?:-[^\\-]|[^\\-])*?-->")
    static let inlineProcessing = re("\\?[\\s\\S]*?\\?>")
    static let inlineTag = re("(?:![A-Z][\\s\\S]*?>|!\\[CDATA\\[[\\s\\S]*?\\]\\]>|/\(space)*[a-zA-Z]\(word.dropLast())\\-]*\(space)*>|\(space)*[a-zA-Z]\(word.dropLast())\\-]*(\(space)+[a-zA-Z:_]\(word.dropLast())\\-.:]*(?:\(space)*=\(space)*(?:[^\\t\\n\\u000b\\u000c\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff\"'=<>`]+|'[^']*'|\"[^\"]*\"))?)*\(space)*(/\(space)*)?>)")

    static func inlineLength(_ text: NSString, from: Int) -> Int? {
        let range = NSRange(location: from, length: text.length - from)
        for regex in [inlineAutolink, inlineComment, inlineProcessing, inlineTag] {
            if let m = regex.firstMatch(in: text as String, options: [.anchored], range: range) {
                return m.range.length
            }
        }
        return nil
    }
}

// MARK: - Inline constructs (lezer-markdown's InlineContext)

struct LSInlineParser {
    private let doc: LSUnits
    private let section: LSMarkdown.Section
    private var text: LSUnits
    private let offset: Int
    private var end: Int { offset + text.count }

    private enum Part {
        case linkStart(from: Int, to: Int, image: Bool, open: Bool)
        case element
        case removed
    }
    private var parts: [Part] = []

    private(set) var math: [LSMarkdown.InlineMath] = []
    private(set) var code: [Range<Int>] = []
    /// The section as an `NSString` for the HTML patterns, made the first
    /// time a `<` needs it.
    private var string: NSString?
    /// Where the section has an `@`, relative to its start: an e-mail
    /// autolink needs one close ahead, and most paragraphs have none.
    private let ats: [Int]

    init(_ doc: LSUnits, _ section: LSMarkdown.Section) {
        self.doc = doc
        self.section = section
        offset = section.from
        var text = doc.slice(section.from, section.to)
        for blank in section.blanks {
            for i in blank where i >= section.from && i < section.to { text[i - section.from] = 32 }
        }
        self.text = text
        // A `while`, not `for … in`: a debug build steps a range's iterator
        // through calls, twenty times slower over a long paragraph.
        ats = text.withUnsafeBufferPointer { buffer in
            var ats: [Int] = []
            var i = 0
            while i < buffer.count {
                if buffer[i] == 64 { ats.append(i) }
                i += 1
            }
            return ats
        }
    }

    @inline(__always)
    private func char(_ pos: Int) -> Int {
        pos >= end || pos < offset ? -1 : Int(text[pos - offset])
    }

    private func skipSpace(_ from: Int) -> Int {
        var i = from
        while i < end, LS.isMarkdownSpace(char(i)) { i += 1 }
        return i
    }

    /// Reads the constructs that start at or before `limit`. Nothing that
    /// starts later can change them — lezer reads inline content strictly
    /// left to right, and a construct's own end is found by scanning ahead —
    /// so the rest of a long paragraph is not read on every keystroke.
    mutating func parse(until limit: Int = .max) {
        var pos = offset
        let stop = limit == .max ? end : Swift.min(end, limit + 1)
        var at = 0
        while true {
            pos = nextCandidate(from: pos, before: stop, at: &at)
            if pos >= stop { break }
            let next = char(pos)
            if let to = parseAt(pos, next) {
                pos = to
            } else {
                pos += 1
            }
        }
    }

    /// The first position from `from` where `parseAt` could find anything:
    /// one of the characters an inline rule starts with, or the start of a
    /// word that could begin a bare URL (`www.`, `http`, `mailto:`, `xmpp:`)
    /// or an e-mail address (an `@` within reach). Everywhere else it answers
    /// nil, and asking it character by character was nine tenths of a
    /// keystroke in a long paragraph. `at` walks `ats` along with the scan.
    private func nextCandidate(from: Int, before stop: Int, at: inout Int) -> Int {
        text.withUnsafeBufferPointer { buffer in
            var i = from - offset
            let n = stop - offset
            while i < n {
                let c = buffer[i]
                switch c {
                case 92, 96, 60, 91, 33, 93, 37, 36: // \ ` < [ ! ] % $
                    return i + offset
                case 48...57, 65...90, 97...122, 95, 46, 43, 45: // what `autolink` looks at
                    if i > 0 {
                        let p = buffer[i - 1]
                        if (p >= 48 && p <= 57) || (p >= 65 && p <= 90) || (p >= 97 && p <= 122) || p == 95 { break }
                    }
                    if c == 119 || c == 104 || c == 109 || c == 120 { return i + offset } // w h m x
                    while at < ats.count, ats[at] <= i { at += 1 }
                    if at < ats.count, ats[at] <= i + 100 { return i + offset }
                default:
                    break
                }
                i += 1
            }
            return stop
        }
    }

    private static let escapable = Set(LS.units("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"))

    private mutating func parseAt(_ start: Int, _ next: Int) -> Int? {
        switch next {
        case 92: // Escape
            if start != end - 1, let c = Optional(char(start + 1)), c >= 0, Self.escapable.contains(UInt16(c)) {
                parts.append(.element)
                return start + 2
            }
        case 96: // InlineCode
            if let to = inlineCode(start) { return to }
        case 60: // HTMLTag and autolinks
            if start != end - 1 {
                if string == nil { string = text.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) } }
                if let length = LSHTML.inlineLength(string!, from: start + 1 - offset) {
                    parts.append(.element)
                    return start + 1 + length
                }
            }
        case 91, 33: // Wikilink, Link, Image
            if let to = wikilink(start, next) { return to }
            if next == 91 {
                parts.append(.linkStart(from: start, to: start + 1, image: false, open: true))
                return start + 1
            }
            if char(start + 1) == 91 {
                parts.append(.linkStart(from: start, to: start + 2, image: true, open: true))
                return start + 2
            }
        case 93: // LinkEnd
            if let to = linkEnd(start) { return to }
        default:
            break
        }
        if let to = autolink(start) { return to }
        if next == 37, char(start + 1) == 37 { // ObsidianComment
            var i = start + 2
            while i < end - 1 {
                if char(i) == 37 && char(i + 1) == 37 {
                    parts.append(.element)
                    return i + 2
                }
                i += 1
            }
        }
        if next == LS.dollarInt { return inlineMathAt(start) }
        return nil
    }

    private mutating func inlineCode(_ start: Int) -> Int? {
        if start > 0 && char(start - 1) == 96 { return nil }
        var pos = start + 1
        while pos < end, char(pos) == 96 { pos += 1 }
        let size = pos - start
        var current = 0
        while pos < end {
            if char(pos) == 96 {
                current += 1
                if current == size && char(pos + 1) != 96 {
                    code.append(start..<(pos + 1))
                    parts.append(.element)
                    return pos + 1
                }
            } else {
                current = 0
            }
            pos += 1
        }
        return nil
    }

    private mutating func wikilink(_ start: Int, _ next: Int) -> Int? {
        let isLink = next == 91 && char(start + 1) == 91
        let isEmbed = !isLink && next == 33 && char(start + 1) == 91 && char(start + 2) == 91
        guard isLink || isEmbed else { return nil }
        var i = start + (isEmbed ? 1 : 0) + 2
        while i < end {
            if char(i) == 93 && char(i + 1) == 93 {
                parts.append(.element)
                return i + 2
            }
            i += 1
        }
        return nil
    }

    private mutating func linkEnd(_ start: Int) -> Int? {
        var i = parts.count - 1
        while i >= 0 {
            if case let .linkStart(from, to, image, open) = parts[i] {
                if !open || (skipSpace(to) == start && char(start + 1) != 40 && char(start + 1) != 91) {
                    parts[i] = .removed
                    return nil
                }
                parts.removeSubrange(i...)
                let linkTo = finishLink(start + 1)
                parts.append(.element)
                if !image {
                    for j in 0..<i {
                        if case let .linkStart(f, t, img, _) = parts[j], !img {
                            parts[j] = .linkStart(from: f, to: t, image: img, open: false)
                        }
                    }
                }
                _ = from
                return linkTo
            }
            i -= 1
        }
        return nil
    }

    private func finishLink(_ startPos: Int) -> Int {
        let next = char(startPos)
        if next == 40 {
            var pos = skipSpace(startPos + 1)
            if let dest = parseURL(pos) {
                pos = skipSpace(dest)
                if pos != dest, let title = parseLinkTitle(pos) {
                    pos = skipSpace(title)
                }
            }
            if char(pos) == 41 { return pos + 1 }
        } else if next == 91 {
            if let label = parseLinkLabel(startPos) { return label }
        }
        return startPos
    }

    /// The end of a link destination starting at `start`, or nil.
    private func parseURL(_ start: Int) -> Int? {
        if char(start) == 60 {
            var pos = start + 1
            while pos < end {
                let c = char(pos)
                if c == 62 { return pos + 1 }
                if c == 60 || c == 10 { return nil }
                pos += 1
            }
            return nil
        }
        var depth = 0
        var pos = start
        var escaped = false
        while pos < end {
            let c = char(pos)
            if LS.isMarkdownSpace(c) {
                break
            } else if escaped {
                escaped = false
            } else if c == 40 {
                depth += 1
            } else if c == 41 {
                if depth == 0 { break }
                depth -= 1
            } else if c == 92 {
                escaped = true
            }
            pos += 1
        }
        return pos > start ? pos : nil
    }

    private func parseLinkTitle(_ start: Int) -> Int? {
        let next = char(start)
        guard next == 39 || next == 34 || next == 40 else { return nil }
        let close = next == 40 ? 41 : next
        var pos = start + 1
        var escaped = false
        while pos < end {
            let c = char(pos)
            if escaped {
                escaped = false
            } else if c == close {
                return pos + 1
            } else if c == 92 {
                escaped = true
            }
            pos += 1
        }
        return nil
    }

    private func parseLinkLabel(_ start: Int) -> Int? {
        var pos = start + 1
        let limit = Swift.min(end, pos + 999)
        var escaped = false
        while pos < limit {
            let c = char(pos)
            if escaped {
                escaped = false
            } else if c == 93 {
                return pos + 1
            } else if c == 91 {
                return nil
            } else if c == 92 {
                escaped = true
            }
            pos += 1
        }
        return nil
    }

    private var hasOpenLink: Bool {
        parts.contains { if case .linkStart = $0 { return true } else { return false } }
    }

    // GFM autolinks: bare `www.` and `http(s)://` URLs, and e-mail addresses.
    private mutating func autolink(_ absPos: Int) -> Int? {
        let pos = absPos - offset
        if pos > 0 && LS.isWord(Int(text[pos - 1])) { return nil }
        let c = char(absPos)
        guard LS.isWord(c) || c == 46 || c == 43 || c == 45 else { return nil }
        var endPos = -1
        // Each branch needs its own first character (or an `@` in reach), so
        // a word that cannot start any of them is not tried against all five.
        if c == 119, text.hasPrefix(Self.www, at: pos) {
            endPos = urlEnd(pos + 4)
            if endPos > -1 && hasOpenLink { endPos = pos + noBracketPrefix(pos, endPos) }
        } else if c == 104, text.hasPrefix(Self.http, at: pos) || text.hasPrefix(Self.https, at: pos) {
            endPos = urlEnd(pos + (text[pos + 4] == 115 ? 8 : 7))
            if endPos > -1 && hasOpenLink { endPos = pos + noBracketPrefix(pos, endPos) }
        } else if atWithin(pos), emailLocalEnd(pos) != nil {
            endPos = emailEnd(pos)
        } else if c == 109 || c == 120, text.hasPrefix(Self.mailto, at: pos) || text.hasPrefix(Self.xmpp, at: pos) {
            let xmpp = text[pos] == 120
            endPos = emailEnd(pos + (xmpp ? 5 : 7))
            if endPos > -1 && xmpp && endPos < text.count && text[endPos] == 47 {
                var j = endPos + 1
                while j < text.count, LS.isASCIILetter(Int(text[j])) || LS.isDigit(Int(text[j])) || text[j] == 64 || text[j] == 46 { j += 1 }
                if j > endPos + 1 { endPos = j }
            }
        }
        guard endPos >= 0 else { return nil }
        parts.append(.element)
        return endPos + offset
    }

    private static let www = LS.units("www.")
    private static let http = LS.units("http://")
    private static let https = LS.units("https://")
    private static let mailto = LS.units("mailto:")
    private static let xmpp = LS.units("xmpp:")

    private func isURLWord(_ c: Int) -> Bool { LS.isWord(c) || c == 45 }

    /// `[\w-]+(\.[\w-]+)+(:\d+)?(\/[^\s<]*)?` from `from`, then GFM's
    /// trailing-punctuation rules.
    private func urlEnd(_ from: Int) -> Int {
        let n = text.count
        var i = from
        while i < n, isURLWord(Int(text[i])) { i += 1 }
        if i == from { return -1 }
        var labels = 1
        var lastLabels = (from..<i, from..<i)
        while i < n, text[i] == 46 {
            var j = i + 1
            while j < n, isURLWord(Int(text[j])) { j += 1 }
            if j == i + 1 { break }
            lastLabels = (lastLabels.1, (i + 1)..<j)
            labels += 1
            i = j
        }
        if labels < 2 { return -1 }
        if (lastLabels.0.lowerBound..<lastLabels.1.upperBound).contains(where: { text[$0] == 95 }) { return -1 }
        if i < n, text[i] == 58 {
            var j = i + 1
            while j < n, LS.isDigit(Int(text[j])) { j += 1 }
            if j > i + 1 { i = j }
        }
        if i < n, text[i] == 47 {
            i += 1
            while i < n, !LS.isSpace(text[i]), text[i] != 60 { i += 1 }
        }
        var endPos = i
        while endPos > from {
            let last = Int(text[endPos - 1])
            if [63, 33, 46, 44, 58, 42, 95, 126].contains(last) {
                endPos -= 1
            } else if last == 41 && count(41, from, endPos) > count(40, from, endPos) {
                endPos -= 1
            } else if last == 59, let entity = trailingEntity(from, endPos) {
                endPos = entity
            } else {
                break
            }
        }
        return endPos
    }

    private func count(_ c: UInt16, _ from: Int, _ to: Int) -> Int {
        var n = 0
        for i in from..<to where text[i] == c { n += 1 }
        return n
    }

    /// `/&(?:#\d+|#x[a-f\d]+|\w+);$/` against text[from..<to]: where it starts.
    private func trailingEntity(_ from: Int, _ to: Int) -> Int? {
        var j = to - 2
        while j >= from {
            if text[j] == 38 {
                let body = text.slice(j + 1, to - 1)
                if body.isEmpty { return nil }
                if body.allSatisfy({ LS.isWord(Int($0)) }) { return j }
                if body[0] == 35 {
                    let rest = body.slice(1, body.count)
                    if !rest.isEmpty && rest.allSatisfy({ LS.isDigit(Int($0)) }) { return j }
                    if rest.count > 1 && (rest[0] == 120) &&
                        rest.slice(1, rest.count).allSatisfy({ LS.isDigit(Int($0)) || ($0 >= 97 && $0 <= 102) }) { return j }
                }
                return nil
            }
            if !(LS.isWord(Int(text[j])) || text[j] == 35) { return nil }
            j -= 1
        }
        return nil
    }

    private func noBracketPrefix(_ from: Int, _ to: Int) -> Int {
        var i = from
        while i < to {
            let c = text[i]
            if c == 93 { break }
            if c == 91 {
                var j = i + 1
                while j < to, text[j] != 93 { j += 1 }
                if j >= to { break }
                i = j + 1
                continue
            }
            i += 1
        }
        return i - from
    }

    private func isEmailLocal(_ c: Int) -> Bool { LS.isWord(c) || c == 46 || c == 43 || c == 45 }

    /// Whether an `@` sits within the hundred characters after `pos`, where
    /// `emailLocalEnd` could find it.
    private func atWithin(_ pos: Int) -> Bool {
        var lo = 0
        var hi = ats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ats[mid] <= pos { lo = mid + 1 } else { hi = mid }
        }
        return lo < ats.count && ats[lo] <= pos + 100
    }

    /// `[\w.+-]{1,100}@` at `pos`: the index of the `@`.
    private func emailLocalEnd(_ pos: Int) -> Int? {
        var i = pos
        while i < text.count, i - pos < 100, isEmailLocal(Int(text[i])) { i += 1 }
        return i > pos && i < text.count && text[i] == 64 ? i : nil
    }

    /// `[\w.+-]+@[\w-]+(\.[\w.-]+)+`, then GFM's rules for its last character.
    private func emailEnd(_ from: Int) -> Int {
        let n = text.count
        var i = from
        while i < n, isEmailLocal(Int(text[i])) { i += 1 }
        guard i > from, i < n, text[i] == 64 else { return -1 }
        i += 1
        let domain = i
        while i < n, isURLWord(Int(text[i])) { i += 1 }
        guard i > domain else { return -1 }
        var groups = 0
        while i < n, text[i] == 46 {
            var j = i + 1
            while j < n, isURLWord(Int(text[j])) || text[j] == 46 { j += 1 }
            if j == i + 1 { break }
            groups += 1
            i = j
        }
        guard groups > 0 else { return -1 }
        let last = text[i - 1]
        if last == 95 || last == 45 { return -1 }
        return i - (last == 46 ? 1 : 0)
    }

    /// Latex Suite's inline math rule (mathjax-parser.ts, lines 34–106).
    private mutating func inlineMathAt(_ start: Int) -> Int? {
        let display = char(start + 1) == LS.dollarInt
        if !display && LS.isMarkdownSpace(char(start + 1)) { return nil }
        let delimiter = display ? 2 : 1
        var contentStart = start + delimiter
        var i = contentStart
        while i < end {
            let c = char(i)
            if c == 92 {
                i += 2
                continue
            }
            if c == 10 { return nil }
            if c != LS.dollarInt {
                i += 1
                continue
            }
            let nextChar = char(i + 1)
            if display {
                if nextChar != LS.dollarInt {
                    i += 1
                    continue
                }
            } else if LS.isMarkdownSpace(char(i - 1)) || LS.isDigit(nextChar) {
                i += 1
                continue
            }
            let endPos = i + delimiter
            var closingStart = i
            if !display && endPos - start >= 6 &&
                char(start + 1) == 123 && char(start + 2) == 125 && char(i - 2) == 123 && char(i - 1) == 125 {
                contentStart += 2
                closingStart -= 2
            }
            math.append(LSMarkdown.InlineMath(from: start, to: endPos, open: start..<contentStart,
                                               close: closingStart..<endPos, display: display))
            parts.append(.element)
            return endPos
        }
        if display {
            math.append(LSMarkdown.InlineMath(from: start, to: start + 2, open: start..<(start + 1),
                                               close: (start + 1)..<(start + 2), display: false))
            parts.append(.element)
            return start + 2
        }
        return nil
    }
}
