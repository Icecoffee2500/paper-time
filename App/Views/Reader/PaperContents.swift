#if os(macOS)
import AppKit
import PDFKit

/// A paper's table of contents, from the outline it carries or, failing
/// that, from the headings on its pages.
///
/// Each entry is the heading in pieces: its words, to be set in the list's
/// own type, and — where the heading has mathematics in it — a picture of
/// that mathematics cut from the page, so that "The π₀ Model" reads as the
/// paper set it rather than as the "w0" PDFKit makes of it.
enum PaperContents {
    struct Item: Identifiable {
        let id: Int
        let title: String
        let level: Int
        /// Where the heading is, as a page index and a point on that page:
        /// the contents are read from a copy of the document on another
        /// thread, and a destination in the copy is no use to the view.
        let pageIndex: Int?
        let point: CGPoint?
        let pieces: [Piece]

        var pageNumber: Int? { pageIndex.map { $0 + 1 } }
    }

    enum Piece {
        case words(String)
        case picture(NSImage)
    }

    /// The contents, by preference: the outline the PDF carries, when it is
    /// one — some PDFs carry one entry a page named "a000", "a001", and some
    /// carry two entries with the numbers chewed off — and otherwise the
    /// headings read off the pages themselves.
    static func items(in document: PDFDocument, listSize: CGFloat) -> [Item] {
        let outline = fromOutline(document, listSize: listSize)
        if isUsable(outline) { return outline }
        let headings = fromHeadings(document, listSize: listSize)
        if !headings.isEmpty { return headings }
        return outline.filter { isWordy($0.title) }
    }

    // MARK: - Outline

    private static func isWordy(_ label: String) -> Bool {
        let letters = label.filter(\.isLetter).count
        guard letters >= 2, let first = label.first, first.isLetter || first.isNumber || first == "(" else { return false }
        return label.contains(" ") || letters >= 5
    }

    private static func isUsable(_ outline: [Item]) -> Bool {
        guard outline.count >= 3 else { return false }
        let wordy = outline.filter { isWordy($0.title) }.count
        return wordy * 10 >= outline.count * 6
    }

    private static func fromOutline(_ document: PDFDocument, listSize: CGFloat) -> [Item] {
        guard let root = document.outlineRoot else { return [] }
        var found: [Item] = []
        func walk(_ node: PDFOutline, level: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !label.isEmpty {
                    let page = child.destination?.page
                    let line = child.destination.flatMap { headingLine(matching: label, at: $0) }
                    found.append(Item(
                        id: found.count, title: label, level: level,
                        pageIndex: page.map { document.index(for: $0) },
                        point: child.destination?.point,
                        pieces: line.map { pieces(label: label, line: $0.selection, on: $0.page, listSize: listSize) } ?? [.words(label)]
                    ))
                }
                // Two levels is what a paper has — sections and subsections.
                // Deeper than that is a thesis, and a thesis can scroll.
                if level < 1 { walk(child, level: level + 1) }
            }
        }
        walk(root, level: 0)
        return found
    }

    // MARK: - Headings off the page

    private struct Line {
        let page: PDFPage
        let pageIndex: Int
        let pageHeight: CGFloat
        var selection: PDFSelection
        var text: String
        var bounds: CGRect
        /// The size most of the line's characters are set in.
        var size: CGFloat
        /// How much of the line's width is set bold.
        var boldCoverage: CGFloat
        /// The bold stretch the line opens with, if it opens with one.
        var leadBold: (text: String, end: CGFloat)?
        /// A section number set apart from its heading, joined back on.
        var number: String?

        var isBold: Bool { boldCoverage >= 0.9 }
    }

    private static let captionPrefixes = ["fig", "table", "algorithm", "listing", "scheme", "eq.", "equation", "theorem", "lemma", "proof", "definition", "corollary", "proposition", "remark", "example", "note", "keywords", "index terms"]
    // "1", "1.2", "IV.", "A.", "A.1" — or a bare letter before a capital,
    // "A Related Work", which "A group of kids" is not.
    private static let numbering = try? NSRegularExpression(pattern: #"^(\d+(\.\d+)*\.?|[IVX]+\.|[A-Z](\.\d+)+\.?|[A-Z]\.)\s+\S|^[A-Z]\s+[A-Z0-9]"#)
    private static let numberAlone = try? NSRegularExpression(pattern: #"^(\d+(\.\d+)*\.?|[IVX]+\.?|[A-Z](\.\d+)+\.?|[A-Z]\.)$"#)
    private static let subfigure = try? NSRegularExpression(pattern: #"^\([a-z0-9]\)"#)

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A heading is a short line on its own, set a step larger than the
    /// body or set bold, or a bold stretch a paragraph opens with; the body's
    /// size is the size most of the document's characters are set in.
    /// Lines much larger than that are the title; author lists are long and
    /// full of commas; captions begin "Fig."; a bold abstract is bold for
    /// many lines running; a running head appears on page after page — none
    /// of them is a heading, and a list with them in it was not a table of
    /// contents.
    private static func fromHeadings(_ document: PDFDocument, listSize: CGFloat) -> [Item] {
        var weight: [CGFloat: Int] = [:]
        var lines: [Line] = []
        var repeats: [String: Set<Int>] = [:]
        for pageIndex in 0..<min(document.pageCount, 120) {
            guard let page = document.page(at: pageIndex),
                  let all = page.selection(for: page.bounds(for: .mediaBox))
            else { continue }
            let pageBounds = page.bounds(for: .mediaBox)
            let bold = PageText.runs(on: page).filter { $0.bold && $0.isHorizontal && $0.size > 3 }.sorted { $0.minX < $1.minX }
            var pageLines: [Line] = []
            for selection in all.selectionsByLine() {
                guard let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      let attributed = selection.attributedString, attributed.length > 0
                else { continue }
                let bounds = selection.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0, bounds.height < bounds.width * 2 else { continue }
                var sizes: [CGFloat: Int] = [:]
                attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                    let size = ((value as? NSFont)?.pointSize ?? 0).rounded()
                    sizes[size, default: 0] += range.length
                }
                let size = sizes.max { $0.value < $1.value }?.key ?? 0
                weight[size, default: 0] += text.count

                // The bold stretches on this line, merged where they touch.
                var spans: [(minX: CGFloat, maxX: CGFloat, size: CGFloat)] = []
                for run in bold where run.start.y >= bounds.minY - 1 && run.start.y <= bounds.maxY + 1
                    && run.maxX > bounds.minX - 2 && run.minX < bounds.maxX + 2 {
                    if let last = spans.last, run.minX - last.maxX <= max(2, run.size * 0.4) {
                        spans[spans.count - 1].maxX = max(last.maxX, run.maxX)
                    } else {
                        spans.append((run.minX, run.maxX, run.size))
                    }
                }
                // PDFKit's line is a little wider than its ink; a bold line
                // is one the bold runs fill to within a character's width.
                let covered = spans.reduce(0) { $0 + min($1.maxX, bounds.maxX) - max($1.minX, bounds.minX) }
                let coverage = max(0, covered) >= bounds.width - size * 1.2 ? 1 : max(0, covered) / bounds.width
                var leadBold: (String, CGFloat)?
                if let first = spans.first, first.minX <= bounds.minX + 2.5, coverage < 0.9 {
                    let y = bounds.minY + bounds.height * 0.4
                    if let stretch = page.selection(from: CGPoint(x: first.minX + 0.5, y: y), to: CGPoint(x: first.maxX - 0.5, y: y))?.string?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !stretch.isEmpty {
                        leadBold = (stretch, first.maxX)
                    }
                }
                pageLines.append(Line(page: page, pageIndex: pageIndex, pageHeight: pageBounds.height, selection: selection, text: text, bounds: bounds, size: size, boldCoverage: coverage, leadBold: leadBold, number: nil))
            }

            // A section number set off from its heading by a gap wide
            // enough that PDFKit reads it as a line of its own is joined
            // back on to the heading beside it.
            var dropped = Set<Int>()
            for (index, line) in pageLines.enumerated() where matches(numberAlone, line.text) {
                guard let title = pageLines.indices.first(where: { other in
                    other != index && !dropped.contains(other)
                        && abs(pageLines[other].bounds.midY - line.bounds.midY) < line.size * 0.5
                        && pageLines[other].bounds.minX >= line.bounds.maxX - 1
                        && pageLines[other].bounds.minX - line.bounds.maxX < line.size * 4
                }) else { continue }
                let joined = pageLines[title]
                let width = line.bounds.width + joined.bounds.width
                pageLines[title].number = line.text
                pageLines[title].text = line.text + " " + joined.text.trimmingCharacters(in: .whitespaces)
                pageLines[title].bounds = line.bounds.union(joined.bounds)
                pageLines[title].boldCoverage = (line.boldCoverage * line.bounds.width + joined.boldCoverage * joined.bounds.width) / width
                dropped.insert(index)
            }
            for (index, line) in pageLines.enumerated() where !dropped.contains(index) {
                lines.append(line)
                if line.text.count <= 100, line.bounds.minY < pageBounds.height * 0.1 || line.bounds.maxY > pageBounds.height * 0.9 {
                    repeats[line.text.lowercased().filter { $0.isLetter || $0.isNumber }, default: []].insert(pageIndex)
                }
            }
        }
        guard let body = weight.max(by: { $0.value < $1.value })?.key, body > 0 else { return [] }

        // Lines stacked directly on one another in one style are a block:
        // a heading is a block of one line, or two when it wrapped, and a
        // block of three or more is a paragraph, however it is set.
        var above = [Int?](repeating: nil, count: lines.count)
        var byPage: [Int: [Int]] = [:]
        for (index, line) in lines.enumerated() { byPage[line.pageIndex, default: []].append(index) }
        for (_, members) in byPage {
            for index in members where !matches(numbering, lines[index].text) {
                let line = lines[index]
                var best: (gap: CGFloat, index: Int)?
                for other in members where other != index {
                    let candidate = lines[other]
                    let gap = candidate.bounds.minY - line.bounds.maxY
                    guard gap > -line.size * 0.5, gap < max(line.size, candidate.size) * 1.2,
                          abs(candidate.size - line.size) <= 0.5,
                          candidate.isBold == line.isBold,
                          min(candidate.bounds.maxX, line.bounds.maxX) - max(candidate.bounds.minX, line.bounds.minX)
                            > min(candidate.bounds.width, line.bounds.width) * 0.5
                    else { continue }
                    if best == nil || gap < best!.gap { best = (gap, other) }
                }
                above[index] = best?.index
            }
        }
        var top = [Int](repeating: 0, count: lines.count)
        var blockSize: [Int: Int] = [:]
        var below: [Int: Int] = [:]
        for index in lines.indices {
            var root = index, steps = 0
            while let up = above[root], steps < 64 { root = up; steps += 1 }
            top[index] = root
            blockSize[root, default: 0] += 1
            if let up = above[index] { below[up] = index }
        }

        struct Found {
            var text: String
            var level: Int
            var line: Line
            var stretch: PDFSelection?
            var numbered: Bool
            var wrapped: Bool
        }
        var found: [Found] = []
        for (position, line) in lines.enumerated() where top[position] == position {
            let text = line.text
            let lowered = text.lowercased()
            let block = blockSize[position] ?? 1
            // Seen on three pages or more: a running head or foot.
            if let pages = repeats[lowered.filter { $0.isLetter || $0.isNumber }], pages.count >= 3 { continue }
            if captionPrefixes.contains(where: { lowered.hasPrefix($0) }) { continue }
            let hasNumber = matches(numbering, text)
            let step = line.size - body
            let letters = text.filter(\.isLetter).count
            let asciiLetters = text.filter { $0.isLetter && $0.isASCII }.count
            let words = text.split(separator: " ")
            let first = text.first ?? " "
            let plausible = letters >= 3 && asciiLetters >= 2 && words.contains(where: { $0.count > 1 })
                && text.count <= 100 && text.filter({ $0 == "," }).count < 3
                && !text.hasSuffix(",")
                && (first.isUppercase || first.isNumber || first == "(" || first == "\"" || first == "“")
                && !matches(subfigure, text)
                && !text.contains("=") && !text.contains(where: { ("\u{1D400}"..."\u{1D7FF}").contains($0) })

            // A step up, but not the title's leap; a bold line at body size,
            // alone or with one more; a numbered line in capitals.
            let larger = step >= 1 && step <= body * 0.7 && block <= 2
            let boldLine = line.isBold && line.size >= body - 1.5 && line.size <= body * 1.7 && block <= 2
            let capitals = hasNumber && text.count <= 60 && letters >= 3
                && text.filter(\.isUppercase).count * 10 >= letters * 8
            if plausible, larger || boldLine || capitals,
               text.contains(where: \.isLowercase) || letters >= 5 || capitals,
               text.count >= 3 {
                var title = text
                var wrapped = false
                if block == 2, let second = below[position] {
                    // The heading wrapped: both lines are the one heading —
                    // unless together they are a paragraph's worth.
                    let next = lines[second]
                    guard next.text.count + text.count <= 140 else { continue }
                    title = text + " " + next.text
                    wrapped = true
                }
                let head = text.prefix { !$0.isWhitespace }
                var trimmedHead = head
                while trimmedHead.hasSuffix(".") { trimmedHead = trimmedHead.dropLast() }
                var subsection = hasNumber && trimmedHead.contains(".") && (trimmedHead.first?.isNumber == true || trimmedHead.first?.isLetter == true)
                if boldLine, !hasNumber, !wrapped, title.hasSuffix(".") {
                    // A bold sentence that fills its line and stops is a
                    // run-in heading that ran to the margin.
                    title.removeLast()
                    subsection = true
                }
                found.append(Found(text: title, level: subsection ? 1 : 0, line: line, stretch: nil, numbered: hasNumber, wrapped: wrapped))
                continue
            }

            // A paragraph that opens with a bold stretch ending in a stop:
            // "Results." and its text run in, the way a journal sets them.
            if let lead = line.leadBold, line.size >= body - 1.5, line.size <= body + 0.5 {
                var label = lead.text
                while let last = label.last, [".", ":", "—", "–", "-"].contains(String(last)) { label.removeLast() }
                let leadLetters = label.filter(\.isLetter).count
                if leadLetters >= 3, label.count <= 100, lead.text.count < text.count - 3,
                   label.split(separator: " ").contains(where: { $0.count > 1 }),
                   [".", ":", "—", "–"].contains(where: { lead.text.hasSuffix($0) }),
                   !captionPrefixes.contains(where: { label.lowercased().hasPrefix($0) }),
                   label.first?.isUppercase == true,
                   label.filter({ $0 == "," }).count < 2 {
                    let y = line.bounds.minY + line.bounds.height * 0.4
                    let stretch = line.page.selection(from: CGPoint(x: line.bounds.minX + 0.5, y: y), to: CGPoint(x: lead.end - 0.5, y: y))
                    found.append(Found(text: label, level: 1, line: line, stretch: stretch, numbered: false, wrapped: false))
                }
            }
            if found.count >= 150 { break }
        }

        // A document that numbers its headings has no unnumbered ones,
        // except the ones a paper always has — the abstract, the references.
        let numberedCount = found.filter(\.numbered).count
        if numberedCount >= 3, numberedCount * 3 >= found.count {
            let always = ["abstract", "references", "acknowledgments", "acknowledgements", "appendix", "bibliography", "conclusion", "conclusions", "introduction", "summary", "supplementary"]
            found = found.filter { item in item.numbered || always.contains(where: { item.text.lowercased().hasPrefix($0) }) }
        }
        // Run-in headings are subsections of the headings around them; with
        // no heading above them, they are the sections.
        if !found.contains(where: { $0.level == 0 }) {
            found = found.map { var item = $0; item.level = 0; return item }
        }
        // In reading order: page by page, the left column before the right.
        func order(_ item: Found) -> (Int, Int, CGFloat) {
            let page = item.line.page.bounds(for: .mediaBox)
            let column = item.line.bounds.minX > page.midX ? 1 : 0
            return (item.line.pageIndex, column, -item.line.bounds.maxY)
        }
        found.sort { order($0) < order($1) }
        // Fewer than two is not a table of contents; say so rather than
        // show a stray line dressed up as one.
        guard found.count >= 2 else { return [] }
        return found.enumerated().map { offset, item in
            let bounds = item.line.bounds
            let item = { var copy = item; copy.text = item.text.split(whereSeparator: \.isWhitespace).joined(separator: " "); return copy }()
            var pieces: [Piece]
            if item.wrapped {
                pieces = [.words(item.text)]
            } else if let number = item.line.number {
                // The number was set apart; the heading's own line has
                // only the words, and any mathematics among them.
                pieces = [.words(number + " ")] + Self.pieces(label: String(item.text.dropFirst(number.count + 1)), line: item.line.selection, on: item.line.page, listSize: listSize)
            } else {
                pieces = Self.pieces(label: item.text, line: item.stretch ?? item.line.selection, on: item.line.page, listSize: listSize)
            }
            return Item(
                id: offset, title: item.text, level: item.level,
                pageIndex: item.line.pageIndex, point: CGPoint(x: bounds.minX, y: bounds.maxY + 12),
                pieces: pieces
            )
        }
    }

    // MARK: - The heading as the page prints it

    /// The printed heading an outline label stands for.
    ///
    /// LaTeX writes bookmarks from the heading with the mathematics taken out
    /// — "The π₀ Model" becomes "The 0 Model" — and reading the text back
    /// off the page is no better: the maths font hands PDFKit a "w" for π.
    /// So the line is not read, it is *drawn*: this finds the line at the
    /// place the bookmark points to whose letters and digits contain the
    /// label's, and the row shows a rendering of that line, in the paper's
    /// own type, symbol and all.
    private static func headingLine(matching label: String, at destination: PDFDestination) -> (selection: PDFSelection, page: PDFPage)? {
        guard let page = destination.page else { return nil }
        let key = compact(label)
        guard key.count >= 3 else { return nil }
        let box = page.bounds(for: .cropBox)
        let band = CGRect(x: box.minX, y: destination.point.y - 48, width: box.width, height: 64)
        guard let lines = page.selection(for: band)?.selectionsByLine() else { return nil }
        var best: (extra: Int, line: PDFSelection)?
        for line in lines {
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let candidate = compact(text)
            // Letters the maths font mangles are skipped on both sides: the
            // label has none of them and the line has the wrong ones.
            guard contains(candidate, inOrder: key, slack: 3) else { continue }
            let extra = abs(candidate.count - key.count)
            if best == nil || extra < best!.extra { best = (extra, line) }
        }
        guard let best else { return nil }
        return (best.line, page)
    }

    /// The heading as words with its mathematics spliced in as pictures.
    ///
    /// PDFKit reports every run of a line as "Helvetica", whatever the PDF
    /// set it in, so a formula cannot be told by its font. It can be told by
    /// its letters: the outline's label was written with the mathematics
    /// left out, so whatever the printed line has that the label does not —
    /// read in order, letter by letter — is the formula. "IV. THE ω0 MODEL"
    /// against "The 0 Model" leaves the ω (PDFKit's reading of π), and the
    /// small "0" beside it is taken along as its subscript. That stretch is
    /// cut from the page as a picture; the words either side come from the
    /// label, in the label's own case. A heading with no label of its own is
    /// read the same way, with any letter outside ASCII standing as the
    /// formula.
    private static func pieces(label: String, line: PDFSelection, on page: PDFPage, listSize: CGFloat) -> [Piece] {
        guard let attributed = line.attributedString, attributed.length > 0,
              let pageString = page.string
        else { return [.words(label)] }
        let printed = attributed.string
        let characters = Array(printed)
        guard characters.count == attributed.length else { return [.words(label)] }

        // Each character's size, and the size most of them have.
        var sizes = [CGFloat](repeating: 0, count: characters.count)
        var weight: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let size = ((value as? NSFont)?.pointSize ?? 0).rounded()
            for index in range.location..<(range.location + range.length) where index < sizes.count { sizes[index] = size }
            weight[size, default: 0] += range.length
        }
        let dominant = weight.max { $0.value < $1.value }?.key ?? 0

        // Where the formula is: the printed letters the label has no match
        // for, in order, after the section number the label never carries.
        // The section number the label never carries — unless it does.
        let lead = stripNumbering(label).count == label.count ? printed.count - stripNumbering(printed).count : 0
        var candidates: [Int] = []
        if compact(label) == compact(printed) {
            for (index, character) in characters.enumerated() where index >= lead {
                if !character.isASCII, !character.isWhitespace, character.isLetter || character.isSymbol {
                    candidates.append(index)
                }
            }
        } else {
            let key = compact(label)
            var next = 0
            for (index, character) in characters.enumerated() where index >= lead {
                let lowered = Character(character.lowercased())
                if character.isLetter || character.isNumber {
                    if next < key.count, lowered == key[next] {
                        next += 1
                    } else {
                        candidates.append(index)
                    }
                } else if !character.isASCII, !character.isWhitespace {
                    candidates.append(index)
                }
            }
        }
        guard let first = candidates.first, let last = candidates.last else { return [.words(label)] }

        // The formula's own sub- and superscripts sit beside it, smaller.
        var from = first, to = last
        while from - 1 >= lead, !characters[from - 1].isWhitespace, sizes[from - 1] < dominant - 0.5 { from -= 1 }
        while to + 1 < characters.count, !characters[to + 1].isWhitespace, sizes[to + 1] < dominant - 0.5 { to += 1 }
        guard to - from + 1 < characters.count * 3 / 5 else { return [.words(label)] }

        // Where the stretch sits on the page, so it can be cut out: a
        // selection over those characters, asked for its bounds. Not
        // `characterBounds(at:)`, which on this very heading answered with
        // rectangles a hundred points from the line and a third its height —
        // a selection's bounds are the ones PDFKit itself draws with.
        let lineRange = (pageString as NSString).range(of: printed)
        guard lineRange.location != NSNotFound else { return [.words(label)] }
        let lineBounds = line.bounds(for: page)
        let stretch = NSRange(location: lineRange.location + from, length: to - from + 1)
        guard let glyphs = page.selection(for: stretch) else { return [.words(label)] }
        let box = glyphs.bounds(for: page)
        guard box.width > 1, box.height > 2, lineBounds.insetBy(dx: -8, dy: -8).contains(box),
              let picture = snippet(of: box.insetBy(dx: -1.5, dy: -1), on: page, scale: listSize / max(dominant, 4))
        else { return [.words(label)] }

        // The words either side, from the label: as many of its letters as
        // were matched before the formula, and after it.
        let (head, tail): (String, String)
        if compact(label) == compact(printed) {
            head = String(characters[lead..<from]).trimmingCharacters(in: .whitespaces)
            tail = String(characters[(to + 1)...]).trimmingCharacters(in: .whitespaces)
        } else {
            // Label letters matched inside the stretch (a digit under the
            // symbol) belong to the picture; count only what lies outside.
            let key = compact(label)
            var before = 0, after = 0, next = 0
            for (index, character) in characters.enumerated() where index >= lead && (character.isLetter || character.isNumber) {
                let lowered = Character(character.lowercased())
                guard next < key.count, lowered == key[next] else { continue }
                next += 1
                if index < from { before += 1 } else if index > to { after += 1 }
            }
            (head, tail) = split(label, keepingFirst: before, last: after)
        }
        var result: [Piece] = []
        if !head.isEmpty { result.append(.words(head)) }
        result.append(.picture(picture))
        if !tail.isEmpty { result.append(.words(tail)) }
        return result
    }

    private static func stripNumbering(_ text: String) -> String {
        text.replacingOccurrences(of: #"^\s*(\d+(\.\d+)*\.?|[IVXLC]+\.|[A-Z](\.\d+)*\.?)\s+"#, with: "", options: .regularExpression)
    }

    /// The label's opening and closing words, by how many of its letters and
    /// digits belong to each; what lies between was the formula.
    private static func split(_ label: String, keepingFirst prefix: Int, last suffix: Int) -> (String, String) {
        let characters = Array(label)
        let alnum = characters.indices.filter { characters[$0].isLetter || characters[$0].isNumber }
        let headEnd = prefix > 0 && prefix <= alnum.count ? alnum[prefix - 1] + 1 : 0
        let tailStart = suffix > 0 && suffix <= alnum.count ? alnum[alnum.count - suffix] : characters.count
        let head = String(characters[0..<headEnd]).trimmingCharacters(in: .whitespaces)
        let tail = tailStart < characters.count ? String(characters[tailStart...]).trimmingCharacters(in: .whitespaces) : ""
        return (head, tail)
    }

    private static func compact(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Whether the needle's characters appear in the haystack in order,
    /// allowing a few of them to be missing — the ones a symbol displaced.
    private static func contains(_ haystack: [Character], inOrder needle: [Character], slack: Int) -> Bool {
        var index = 0, missed = 0
        var position = 0
        while index < needle.count {
            if let found = haystack[position...].firstIndex(of: needle[index]) {
                position = found + 1
            } else {
                missed += 1
                if missed > slack { return false }
            }
            index += 1
        }
        return true
    }

    /// The stretch as the page prints it, drawn at four times its size so
    /// it stays crisp, and shown scaled so that the paper's type comes out
    /// the size of the list's — a formula set at 10 points in a 12-point
    /// list is shown at six-fifths of its size, and sits level with the
    /// words either side of it.
    private static func snippet(of rect: CGRect, on page: PDFPage, scale: CGFloat) -> NSImage? {
        guard rect.width > 2, rect.height > 3, rect.width < 400 else { return nil }
        let pixels: CGFloat = 4
        let width = Int(rect.width * pixels), height = Int(rect.height * pixels)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: pixels, y: pixels)
        // `draw(with:to:)` puts the box's corner at the origin.
        let box = page.bounds(for: .mediaBox)
        context.translateBy(x: -(rect.minX - box.minX), y: -(rect.minY - box.minY))
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: rect.width * scale, height: rect.height * scale))
    }
}
#endif
