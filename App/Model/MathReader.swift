import Foundation
import PDFKit

/// Reads a passage out of a PDF with its mathematics intact.
///
/// A PDF does not know it contains mathematics, and the text it hands over has
/// already been through the file's own idea of what its glyphs mean — an idea
/// that, for a paper set in TeX, is often missing or wrong. So this does not
/// read the text. It reads what the page draws: which glyph, from which font,
/// at which point, and which thin rectangles were filled. From that the formula
/// can be put back together the way a person reading the page would write it
/// down — the fraction bar makes a `\frac`, the sign with things stacked over
/// and under it makes a `\sum` with limits, the small glyph that dropped below
/// the line makes a subscript.
///
/// Where a page cannot be read that way — a scan, or a PDF with no usable font
/// information — it falls back to the text PDFKit gives, tidied.
enum MathReader {
    /// The passage, with each run of mathematics wrapped in `$…$`.
    ///
    /// Everything is decided from the selection itself. PDFKit reads a drag as
    /// a range in reading order, so a box drawn round a displayed formula
    /// comes back as the formula *plus* the opening words of the sentence
    /// below — but it also says, line by line, exactly how much of each line
    /// it took, and that is enough to tell a line that was meant from the half
    /// of one the range spilled into.
    ///
    /// Laid out as the page is: a displayed formula on a line of its own —
    /// its rows one a line when it has several — the sentence it sits in
    /// going on on the next line, and a new paragraph after a blank one. It
    /// used to be one line, and pasted anywhere the displays ran into the
    /// words around them: "…normal, $$E_i…$$ $$\Sigma…$$ $$\tau…$$".
    @MainActor
    static func latex(from selection: PDFSelection) -> String {
        let read = pieces(from: selection)
        guard !read.isEmpty else { return selection.string ?? "" }
        return lines(of: read, markdown: false).joined(separator: "\n")
    }

    /// One thing the selection reached, in reading order, with what the page
    /// made of it.
    ///
    /// The clipboard wants one line and takes `plain`; a note wants the page
    /// back and takes the rest — whether this was a heading, whether it was a
    /// formula set on its own, which words were in bold, and where the line
    /// began and ended, which is how a new paragraph gives itself away.
    struct Piece {
        enum Kind: Equatable {
            case prose
            /// A section title, with how much larger than the body it was set.
            case heading(level: Int)
            /// A formula on its own line.
            case display
            /// A formula small enough to sit inside a sentence.
            case inline
        }

        var kind: Kind
        /// Whether the row was a table's (`isTableRow`): its cells of
        /// measurements are not a displayed equation, however much of the
        /// line is mathematics.
        var isTable = false
        /// Whether the row sets a big operator in display style, its limits
        /// stacked over and under it (`stacksLimits`) — a displayed equation
        /// with a word on it, which a sentence never is: a slide's
        /// "MC : ∑ⁿᵢ₌₁ (…)²   (1)". It stands on a line of its own.
        var displayStyle = false
        /// What `latex(from:)` has always answered with.
        var plain: String
        /// The same, with the page's bold kept as Markdown.
        var marked: String
        /// Where the row began and ended, in page points.
        var left: CGFloat = 0
        var right: CGFloat = 0
        /// The row's baseline, and which page it was on: two lines of one
        /// paragraph sit a line apart, and the gap before a new paragraph is
        /// wider. That, and a line that stops short of the column, is how a
        /// paragraph ends — an indent is not, because a bulleted list indents
        /// every line it has.
        var baseline: CGFloat = 0
        var page = 0
        /// The size the row was set at, against the page's body size.
        var scale: CGFloat = 1
    }

    /// How many formulas the last reading left out because the file does not
    /// say what their glyphs are — so the one who asked can be told.
    nonisolated(unsafe) static var skippedFormulas = 0

    /// What to tell somebody when the last reading left formulas out, or
    /// nil when it did not.
    static func leftOutSentence(copied: Bool = false) -> String? {
        let count = skippedFormulas
        guard count > 0 else { return nil }
        return copied
            ? L("수식 \(count)개는 빼고 복사했어요. 파일에 그 기호가 무엇인지 적혀 있지 않아요.",
                "Copied without \(count == 1 ? "one formula" : "\(count) formulas"). The file doesn't say what \(count == 1 ? "its" : "their") symbols are.")
            : L("수식 \(count)개는 빼고 넣었어요. 파일에 그 기호가 무엇인지 적혀 있지 않아요.",
                "Linked without \(count == 1 ? "one formula" : "\(count) formulas"). The file doesn't say what \(count == 1 ? "its" : "their") symbols are.")
    }

    /// A part of a page to read: the boxes it covers (in the page's own
    /// coordinates, as PDFKit and the scanner give them — what `lineBoxes`
    /// makes of a selection) and the words to fall back on when the page
    /// cannot be scanned.
    struct Region {
        var page: PDFPage
        var boxes: [CGRect]
        var fallback: String
        /// Whether a glyph is in a box when the middle of its ink is — a
        /// rectangle drawn by hand — rather than when its baseline is, which
        /// is what a selection's line boxes mean (`belongs`).
        var byInk = false
    }

    @MainActor
    static func pieces(from selection: PDFSelection) -> [Piece] {
        pieces(of: selection.pages.map {
            Region(page: $0, boxes: lineBoxes(of: selection, on: $0), fallback: selection.string ?? "")
        })
    }

    /// A rectangle drawn by hand over a page — the formula lasso. `rect` is
    /// in the page's coordinates as PDFKit gives them, the way a selection's
    /// bounds are. The rectangle stands in for the selection's line boxes,
    /// and the reader does what it does for a drag: a formula touched
    /// anywhere comes whole, prose comes as the words inside — where a glyph
    /// is inside when the middle of its ink is.
    @MainActor
    static func pieces(on page: PDFPage, rect: CGRect) -> [Piece] {
        pieces(of: [Region(page: page, boxes: [box(of: rect)],
                           fallback: page.selection(for: rect)?.string ?? "", byInk: true)])
    }

    @MainActor
    static func latex(on page: PDFPage, rect: CGRect) -> String {
        let read = pieces(on: page, rect: rect)
        guard !read.isEmpty else { return page.selection(for: rect)?.string ?? "" }
        return lines(of: read, markdown: false).joined(separator: "\n")
    }

    @MainActor
    static func structured(on page: PDFPage, rect: CGRect) -> [String] {
        let read = pieces(on: page, rect: rect)
        guard !read.isEmpty else {
            let plain = (page.selection(for: rect)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return plain.isEmpty ? [] : [plain]
        }
        return lines(of: read, markdown: true)
    }

    /// Where what a rectangle would read actually stands: the glyphs the
    /// reader takes for it — whole formulas touched, the words inside
    /// otherwise, and nothing of a line a formula's reach only clipped —
    /// united, in the page's coordinates as PDFKit gives them. Nil when the
    /// rectangle reaches nothing the page can be read for. This is what the
    /// lasso snaps to, so that what it holds is exactly what ⇧⌘C will copy.
    @MainActor
    static func extentRead(on page: PDFPage, rect: CGRect) -> CGRect? {
        guard let rows = extentRows(on: page, rect: rect), let first = rows.first else { return nil }
        return rows.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The same glyphs, a rectangle per line they were set on. A formula's
    /// rows (its limits, its numerator) are lines of their own; two that
    /// touch or overlap are one.
    @MainActor
    static func extentRows(on page: PDFPage, rect: CGRect) -> [CGRect]? {
        guard let caught = caught(on: page, rect: rect) else { return nil }
        let rows = caught.lines.compactMap { line -> CGRect? in
            guard let first = line.first else { return nil }
            return line.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        }
        return rows.isEmpty ? nil : joinedRows(rows)
    }

    /// Where the ink of what a rectangle reads is: a box for every glyph the
    /// reader takes, and the rules drawn among them (a fraction's bar, a
    /// root's vinculum, a brace's fill). The lasso recolours the page's ink
    /// inside these and nowhere else — a segmentation of the formula, laid
    /// over its own letters, not a box round them.
    @MainActor
    static func extentInk(on page: PDFPage, rect: CGRect) -> [CGRect]? {
        guard let caught = caught(on: page, rect: rect) else { return nil }
        var ink: [CGRect] = []
        for line in caught.lines {
            guard let first = line.first else { continue }
            ink += line.map(\.rect)
            let reach = line.dropFirst().reduce(first.rect) { $0.union($1.rect) }.insetBy(dx: -1, dy: -1)
            ink += caught.rules.filter { $0.intersects(reach) }
        }
        return ink.isEmpty ? nil : ink
    }

    /// The glyphs a rectangle reads, a list a line, and the page's rules.
    @MainActor
    private static func caught(on page: PDFPage, rect: CGRect) -> (lines: [[PDFContentScanner.Glyph]], rules: [CGRect])? {
        guard let scanned = scan(page), !scanned.glyphs.isEmpty else { return nil }
        let layout = layout(of: page, scanned: scanned)
        let boxes = [box(of: rect)]
        let reached = reached(in: layout, boxes: boxes, byInk: true)
        let wantsFormula = reached.contains { $0.block.isFormula }
        MathTranscriber.variablesInTextItalic = layout.variablesInTextItalic
        MathTranscriber.sansTextFace = layout.sansText
        defer { MathTranscriber.variablesInTextItalic = false; MathTranscriber.sansTextFace = false }
        var lines: [[PDFContentScanner.Glyph]] = []
        for (block, glyphs) in reached {
            if block.isFormula {
                // Every row of a formula that was touched (`reached`).
                lines += block.rows.filter { !$0.isEmpty }
            } else {
                if wantsFormula, glyphs.count * 10 < block.rows[0].count * 9 { continue }
                let line = grown(glyphs, in: block.rows[0])
                if !line.isEmpty { lines.append(line) }
            }
        }
        guard !lines.isEmpty else { return nil }
        return (lines, scanned.rules.map(\.rect))
    }

    /// What a rectangle takes of a line of prose, grown to the whole of the
    /// inline formula it landed in: from the glyphs inside the rectangle,
    /// outwards over anything that is the formula's — a maths glyph, a
    /// script, a bracket or a sign — as long as the gaps stay a formula's
    /// (under 0.3 em; a word space is a third of an em and more). A hand
    /// that starts its rectangle after the "(" of "(y_t − Q(S_t, A_t))²"
    /// still catches the "(": copied as drawn, the bracket came out odd.
    private static func grown(_ kept: [PDFContentScanner.Glyph], in row: [PDFContentScanner.Glyph]) -> [PDFContentScanner.Glyph] {
        let ordered = row.sorted { $0.rect.minX < $1.rect.minX }
        guard let first = kept.min(by: { $0.rect.minX < $1.rect.minX }),
              let last = kept.max(by: { $0.rect.maxX < $1.rect.maxX }),
              var low = ordered.firstIndex(where: { $0.rect.minX >= first.rect.minX - 0.01 }),
              var high = ordered.lastIndex(where: { $0.rect.maxX <= last.rect.maxX + 0.01 })
        else { return kept }
        func formulaGlyph(_ glyph: PDFContentScanner.Glyph, beside neighbour: PDFContentScanner.Glyph) -> Bool {
            let spelled = MathTranscriber.spelling(of: glyph)
            if spelled.isEmpty || MathTranscriber.isAccent(glyph) { return true }
            if isMathish(glyph) || isFormulaMark(glyph) { return true }
            if glyph.size < neighbour.size * 0.92 && !MathTranscriber.isPiece(glyph) { return true }
            return ["(", ")", "[", "]", "+", "-", "=", "|", ",", "'", "\\{", "\\}", "\\|"].contains(spelled)
        }
        // A formula's own spaces stay under a third of an em, but for the
        // ones TeX puts round a binary operator or a relation: four and five
        // eighteenths of an em, and the glyphs' own side bearings besides —
        // the "+" in "(R_{i+1} + γ" stood a third of an em and more from
        // both. A word's space is wider still, and never next to one.
        func room(_ one: PDFContentScanner.Glyph, _ other: PDFContentScanner.Glyph) -> CGFloat {
            MathTranscriber.isOperatorOrRelation(one) || MathTranscriber.isOperatorOrRelation(other) ? 0.5 : 0.3
        }
        while low > 0 {
            let previous = ordered[low - 1], edge = ordered[low]
            guard edge.rect.minX - previous.rect.maxX < edge.size * room(previous, edge),
                  formulaGlyph(previous, beside: edge) else { break }
            low -= 1
        }
        while high + 1 < ordered.count {
            let next = ordered[high + 1], edge = ordered[high]
            guard next.rect.minX - edge.rect.maxX < edge.size * room(next, edge),
                  formulaGlyph(next, beside: edge) else { break }
            high += 1
        }
        return Array(ordered[low...high])
    }

    /// Rows that touch or overlap in height, united — top to bottom.
    static func joinedRows(_ rows: [CGRect]) -> [CGRect] {
        var joined: [CGRect] = []
        for row in rows.sorted(by: { $0.maxY > $1.maxY }) {
            if let last = joined.last, row.maxY >= last.minY - 1 {
                joined[joined.count - 1] = last.union(row)
            } else {
                joined.append(row)
            }
        }
        return joined
    }

    /// A rectangle in PDFKit's page coordinates as a box the reader uses: a
    /// point wider either side. (PDFKit's page coordinates are the file's own
    /// — the scanner's — whatever the crop box: a box once had the crop
    /// box's origin added, and on a page whose crop box does not start at
    /// the origin every line it reached was the wrong one.)
    private static func box(of rect: CGRect) -> CGRect {
        rect.insetBy(dx: -1, dy: 0)
    }

    /// What the boxes reach. A formula is two-dimensional — its limits sit
    /// under the sign and its numerator over the bar — so touching one means
    /// taking all of it; of a line of prose, the glyphs inside.
    private static func reached(
        in layout: Layout, boxes: [CGRect], byInk: Bool = false
    ) -> [(block: Layout.Block, glyphs: [PDFContentScanner.Glyph])] {
        func selected(_ glyph: PDFContentScanner.Glyph) -> Bool {
            boxes.contains { belongs(glyph, to: $0, byInk: byInk) }
        }
        var reached: [(block: Layout.Block, glyphs: [PDFContentScanner.Glyph])] = []
        for block in layout.blocks {
            if block.isFormula {
                let all = block.rows.flatMap { $0 }
                if all.contains(where: selected) { reached.append((block, all)) }
            } else {
                let kept = block.rows[0].filter(selected)
                if !kept.isEmpty { reached.append((block, kept)) }
            }
        }
        return reached
    }

    @MainActor
    static func pieces(of regions: [Region]) -> [Piece] {
        skippedFormulas = 0
        var pieces: [Piece] = []
        for (number, region) in regions.enumerated() {
            let page = region.page
            let pageCharacters = characters(of: page)
            let pageText = (page.string ?? "") as NSString
            MathTranscriber.fallback = characterLookup(for: page)
            defer { MathTranscriber.fallback = nil }
            guard let scanned = scan(page), !scanned.glyphs.isEmpty else {
                if !region.fallback.isEmpty {
                    pieces.append(Piece(kind: .prose, plain: region.fallback, marked: region.fallback))
                }
                continue
            }
            // The page, laid out: every row it was set on, gathered into the
            // things they belong to.
            let layout = layout(of: page, scanned: scanned)
            MathTranscriber.variablesInTextItalic = layout.variablesInTextItalic
            MathTranscriber.sansTextFace = layout.sansText
            defer { MathTranscriber.variablesInTextItalic = false; MathTranscriber.sansTextFace = false }
            let boxes = region.boxes
            let rules = markingBraceFills(scanned.rules, glyphs: scanned.glyphs)
            let pageBody = size(of: scanned.glyphs)
            // How wide the page sets its text, so "this line stops short" has
            // something to be short of.
            let extents = layout.blocks.compactMap { block -> CGFloat? in
                guard let row = block.rows.first, let first = row.first else { return nil }
                let band = row.dropFirst().reduce(first.rect) { $0.union($1.rect) }
                return band.width
            }
            let columnWidth = extents.max() ?? page.bounds(for: .cropBox).width

            func selected(_ glyph: PDFContentScanner.Glyph) -> Bool {
                boxes.contains { belongs(glyph, to: $0, byInk: region.byInk) }
            }

            // What the selection reaches (`reached(in:boxes:)`).
            let reached = reached(in: layout, boxes: boxes, byInk: region.byInk)

            // A range that ends anywhere on a line takes in the whole start of
            // it, so a drag round a displayed formula arrives with the opening
            // words of the sentence below. When a formula is what was asked
            // for, a line the range only clipped was not: a line that was
            // meant comes whole.
            let wantsFormula = reached.contains { $0.block.isFormula }

            var position = 0
            while position < reached.count {
                let (block, glyphs) = reached[position]
                position += 1
                // Displayed formulas one under another that line up at a
                // relation are the lines of one aligned formula; lines that
                // break into cells at the same places are a matrix; lines
                // that only start, or are centred, at the same place are an
                // aligned or a gathered formula.
                if block.isFormula,
                   let aligned = alignedRun(from: position - 1, in: reached, selected: selected, rules: rules)
                    ?? matrixRun(from: position - 1, in: reached, rules: rules)
                    ?? alignedRun(from: position - 1, in: reached, selected: selected, rules: rules, atRelation: false) {
                    position = aligned.end
                    let wrapped = displayed(aligned.latex)
                    pieces.append(Piece(
                        kind: .display, plain: wrapped, marked: wrapped,
                        left: aligned.bounds.minX, right: aligned.bounds.maxX,
                        baseline: aligned.baseline, page: number
                    ))
                    continue
                }
                guard block.isFormula else {
                    let whole = block.rows[0].count
                    if wantsFormula, glyphs.count * 10 < whole * 9 { continue }
                    let band = glyphs.dropFirst().reduce(glyphs[0].rect) { $0.union($1.rect) }
                    let nearby = rules.filter { band.insetBy(dx: -2, dy: -2).intersects($0.rect) }
                    let text = read(
                        glyphs, rules: nearby, characters: pageCharacters, text: pageText
                    )
                    guard !text.isEmpty else { continue }
                    let marked = readMarkingBold(
                        glyphs, rules: nearby, characters: pageCharacters, text: pageText
                    )
                    let scale = size(of: glyphs) / max(pageBody, 1)
                    pieces.append(Piece(
                        kind: heading(level: scale, glyphs: glyphs, text: text,
                                      short: band.width < columnWidth * 0.55),
                        isTable: isTableRow(block.rows[0]),
                        displayStyle: stacksLimits(block.rows[0]),
                        plain: text, marked: marked,
                        left: band.minX, right: band.maxX,
                        baseline: glyphs[0].origin.y, page: number, scale: scale
                    ))
                    continue
                }

                // The number a journal prints beside a displayed equation is
                // not part of the formula. It comes along because the whole
                // formula does, so whether it was wanted is asked of the
                // selection: LaTeX writes it as \tag, or it is left behind.
                var all = glyphs
                var tag: String?
                if let numbered = numbered(all, body: size(of: all)) {
                    all = numbered.formula
                    if numbered.number.allSatisfy(selected) {
                        let inner = MathTranscriber.latex(glyphs: numbered.number, rules: [])
                            .trimmingCharacters(in: CharacterSet(charactersIn: "() "))
                        if !inner.isEmpty { tag = "\\tag{\(inner)}" }
                    }
                }
                guard !all.isEmpty else { continue }
                // A formula whose glyphs mostly say nothing about what they
                // are — a Word equation in a subset font with no cmap and a
                // ToUnicode of zeros — is left out rather than written down
                // as braces and carets with nothing in them.
                let unread = all.filter(MathTranscriber.isUnreadable).count
                if unread * 4 > all.count {
                    skippedFormulas += 1
                    continue
                }

                let bounds = all.dropFirst().reduce(all[0].rect) { $0.union($1.rect) }
                var body = MathTranscriber.latex(
                    glyphs: all.sorted { $0.origin.x < $1.origin.x },
                    rules: rules.filter { bounds.insetBy(dx: -2, dy: -2).intersects($0.rect) }
                )
                if let tag { body += tag }
                guard !body.isEmpty else { continue }
                let standsAlone = all.count > 3
                let wrapped = standsAlone ? displayed(body) : "$\(body)$"
                pieces.append(Piece(
                    kind: standsAlone ? .display : .inline,
                    plain: wrapped, marked: wrapped,
                    left: bounds.minX, right: bounds.maxX,
                    baseline: all[0].origin.y, page: number
                ))
            }
        }
        return pieces
    }

    /// The relations an aligned formula lines up at.
    private static let relations: Set<String> = [
        "=", "<", ">", ":", "\\leq", "\\geq", "\\neq", "\\approx", "\\equiv", "\\sim", "\\simeq",
        "\\propto", "\\in", "\\subset", "\\subseteq", "\\supset", "\\supseteq", "\\to",
        "\\rightarrow", "\\Rightarrow", "\\Leftrightarrow", "\\leftarrow", "\\coloneqq",
        "\\ll", "\\gg", "\\leqslant", "\\geqslant", "\\lesssim", "\\gtrsim", "\\triangleq",
        "\\doteq", "\\cong", "\\mapsto", "\\iff", "\\implies", "\\prec", "\\succ",
        "\\preceq", "\\succeq",
    ]

    /// Displayed formulas one under another that line up, as the lines of
    /// one formula — what an `align`, a `gather` or an `aligned` sets, and
    /// what a person copying it wants back, not formulas that lost their
    /// alignment.
    ///
    /// `atRelation`: lines that each have a relation standing at the same
    /// place across the page, lined up there with `&`. Otherwise lines set
    /// a line apart — a `\jot` between them, not the space round a display
    /// — that start at the same place (`&` at the head of each line), end
    /// at the same place, or are centred on one another (`gathered`). Three
    /// lines of an `align*` that only begin together came back as three
    /// `$$` of their own.
    private static func alignedRun(
        from start: Int,
        in reached: [(block: Layout.Block, glyphs: [PDFContentScanner.Glyph])],
        selected: (PDFContentScanner.Glyph) -> Bool,
        rules: [PDFContentScanner.Rule],
        atRelation: Bool = true
    ) -> (end: Int, latex: String, bounds: CGRect, baseline: CGFloat)? {
        struct Line {
            var glyphs: [PDFContentScanner.Glyph]
            var tag: String?
            var relations: [CGFloat]
            var baseline: CGFloat
            var bounds: CGRect
            /// Where in `reached` the run goes on after this line.
            var next: Int
        }
        func line(_ block: Layout.Block, _ glyphs: [PDFContentScanner.Glyph], next: Int) -> Line? {
            guard block.isFormula, !glyphs.isEmpty else { return nil }
            var all = glyphs
            var tag: String?
            if let numbered = numbered(all, body: size(of: all)) {
                all = numbered.formula
                if numbered.number.allSatisfy(selected) {
                    let inner = MathTranscriber.latex(glyphs: numbered.number, rules: [])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "() "))
                    if !inner.isEmpty { tag = inner }
                }
            }
            guard !all.isEmpty else { return nil }
            let body = MathTranscriber.ordinarySize(of: all)
            let standing = all.filter {
                $0.size >= body * 0.92 && relations.contains(MathTranscriber.spelling(of: $0))
            }
            let baseline: CGFloat
            if let first = standing.first {
                let heights = standing.map(\.origin.y).sorted()
                baseline = heights[heights.count / 2] == 0 ? first.origin.y : heights[heights.count / 2]
            } else if atRelation {
                return nil
            } else {
                baseline = context(of: all).baseline
            }
            return Line(glyphs: all, tag: tag, relations: standing.map(\.rect.minX).sorted(),
                        baseline: baseline, bounds: extent(of: all), next: next)
        }
        guard let head = line(reached[start].block, reached[start].glyphs, next: start + 1) else { return nil }
        var lines = [head]
        // The number of an `equation` round an `aligned` with an even number
        // of lines: centred on the whole, so between two of its lines, on a
        // row of its own at the right — "(1)", read as a line of prose.
        var shared: String?
        var next = start + 1
        while next < reached.count {
            let previous = lines[lines.count - 1]
            let body = MathTranscriber.ordinarySize(of: previous.glyphs)
            var after = next
            var number: String?
            if shared == nil, !reached[next].block.isFormula,
               let found = standaloneNumber(reached[next].glyphs, rightOf: lines.map(\.bounds.maxX).max() ?? 0, body: body),
               next + 1 < reached.count {
                number = reached[next].glyphs.allSatisfy(selected) ? found : ""
                after = next + 1
            }
            guard let candidate = line(reached[after].block, reached[after].glyphs, next: after + 1) else { break }
            let drop = previous.baseline - candidate.baseline
            // A line apart — or further, when the limits of the lines' sums
            // fill what is between them: then the ink of one line comes
            // within a \jot of the next's, and three lines of a derivation
            // 3.5 lines apart came back as three formulas.
            let gap = previous.bounds.minY - candidate.bounds.maxY
            guard drop > body * 0.9, drop < body * 3.5 || (drop < body * 6 && gap < body * 0.9),
                  candidate.bounds.maxX > previous.bounds.minX, candidate.bounds.minX < previous.bounds.maxX
            else { break }
            if let number {
                let height = reached[next].glyphs[0].origin.y
                guard height < previous.baseline, height > candidate.baseline else { break }
                shared = number
            }
            lines.append(candidate)
            next = after + 1
        }
        guard lines.count >= 2 else { return nil }

        // The most lines from the first that line up, and how.
        enum Lining { case relation(CGFloat), left, right, centre }
        func lining(_ run: ArraySlice<Line>) -> Lining? {
            if atRelation {
                // The first of the first line's relations that every other
                // line has a relation at too.
                return run.first!.relations.first(where: { x in
                    run.dropFirst().allSatisfy { line in line.relations.contains { abs($0 - x) < 1 } }
                }).map(Lining.relation)
            }
            // A line apart, not a display apart: a \jot and the line's own
            // depth between the ink of one line and the next.
            let tight = zip(run, run.dropFirst()).allSatisfy { upper, lower in
                upper.bounds.minY - lower.bounds.maxY < MathTranscriber.ordinarySize(of: upper.glyphs) * 0.9
            }
            // A bar between two of them, across both, makes them a fraction.
            let barred = zip(run, run.dropFirst()).contains { upper, lower in
                rules.contains { rule in
                    rule.rect.midY < upper.baseline && rule.rect.midY > lower.baseline
                        && rule.rect.maxX > max(upper.bounds.minX, lower.bounds.minX)
                        && rule.rect.minX < min(upper.bounds.maxX, lower.bounds.maxX)
                }
            }
            // A table's rows are set a line apart and start together too; a
            // row of cells an em or more apart, or of measured numbers —
            // "93.2 ± 0.3" — is a table's, not a formula's line.
            let tabular = run.contains { line in
                let body = MathTranscriber.ordinarySize(of: line.glyphs)
                let ordered = line.glyphs.sorted { $0.rect.minX < $1.rect.minX }
                var reach = -CGFloat.greatestFiniteMagnitude
                var gaps = 0
                for glyph in ordered {
                    if reach > -.greatestFiniteMagnitude, glyph.rect.minX - reach >= body * 0.8 { gaps += 1 }
                    reach = max(reach, glyph.rect.maxX)
                }
                let measured = line.glyphs.filter { MathTranscriber.spelling(of: $0) == "\\pm" }.count
                // Nor is a line that could not stand as a display on its own
                // — a figure's labels stack a line apart too — a step of an
                // algorithm, "7:", or an item of a list.
                let spelled = ordered.map(MathTranscriber.spelling(of:))
                let digits = spelled.prefix { $0.count == 1 && $0.first!.isNumber }.count
                let numbered = digits > 0 && digits < spelled.count && spelled[digits] == ":"
                let bulleted = spelled.first == "\\bullet" || spelled.first == "\u{2022}"
                // Nor is a label in brackets on a line of its own — the
                // "(ℓ₂-CL)" a long equation's name drops to under it.
                let label = spelled.first == "(" && spelled.last == ")" && spelled.count <= 16
                return gaps >= 3 || measured >= 2 || line.glyphs.count <= 3 || numbered || bulleted || label
            }
            guard tight, !barred, !tabular else { return nil }
            func same(_ value: (Line) -> CGFloat, within slack: CGFloat) -> Bool {
                let values = run.map(value)
                return (values.max() ?? 0) - (values.min() ?? 0) < slack
            }
            if same({ $0.bounds.minX }, within: 1) { return .left }
            if same({ $0.bounds.midX }, within: 1.5) { return .centre }
            if same({ $0.bounds.maxX }, within: 1) { return .right }
            return nil
        }
        var count = lines.count
        var found: Lining?
        while count >= 2 {
            if let lined = lining(lines[..<count]) { found = lined; break }
            count -= 1
        }
        guard let found else { return nil }
        let run = Array(lines[..<count])
        // A number between the lines belongs to the whole only if all of
        // the lines it stood between are in the run.
        let tags = run.compactMap(\.tag) + (count == lines.count ? [shared].compactMap { $0 }.filter { !$0.isEmpty } : [])
        var written: [String] = []
        for line in run {
            let nearby = rules.filter { line.bounds.insetBy(dx: -2, dy: -2).intersects($0.rect) }
            var text: String
            switch found {
            case .relation(let column):
                let left = line.glyphs.filter { $0.rect.minX < column - 0.5 }
                let right = line.glyphs.filter { $0.rect.minX >= column - 0.5 }
                let before = left.isEmpty ? "" : MathTranscriber.latex(glyphs: left, rules: nearby)
                text = (before.isEmpty ? "" : before + " ") + "&" + MathTranscriber.latex(glyphs: right, rules: nearby)
            case .left:
                text = "&" + MathTranscriber.latex(glyphs: line.glyphs, rules: nearby)
            case .right:
                text = MathTranscriber.latex(glyphs: line.glyphs, rules: nearby) + " &"
            case .centre:
                text = MathTranscriber.latex(glyphs: line.glyphs, rules: nearby)
            }
            if tags.count > 1, let tag = line.tag { text += " \\tag{\(tag)}" }
            written.append(text)
        }
        // One number for the whole is the aligned formula's; a number for
        // each line takes `align` — or `gather` — which lets each line keep
        // its own.
        let centred: Bool
        if case .centre = found { centred = true } else { centred = false }
        let environment = tags.count > 1 ? (centred ? "gather" : "align") : (centred ? "gathered" : "aligned")
        var latex = "\\begin{\(environment)} " + written.joined(separator: " \\\\ ") + " \\end{\(environment)}"
        if tags.count == 1 { latex += "\\tag{\(tags[0])}" }
        let bounds = run.dropFirst().reduce(run[0].bounds) { $0.union($1.bounds) }
        return (run[run.count - 1].next, latex, bounds, run[0].baseline)
    }

    /// A row that is only an equation's number — "(1)", "(2a)" — set well to
    /// the right of the lines it numbers, as its text.
    private static func standaloneNumber(
        _ glyphs: [PDFContentScanner.Glyph], rightOf edge: CGFloat, body: CGFloat
    ) -> String? {
        guard glyphs.count >= 3, glyphs.count <= 8,
              let left = glyphs.map(\.rect.minX).min(), left > edge + body else { return nil }
        let spelled = glyphs.sorted { $0.origin.x < $1.origin.x }.map(MathTranscriber.spelling(of:)).joined()
        guard spelled.range(of: #"^\([0-9]+(\.[0-9]+)?[a-z]?\)$"#, options: .regularExpression) != nil
        else { return nil }
        return String(spelled.dropFirst().dropLast())
    }

    /// Displayed lines a line apart that break into cells at the same places
    /// — an `array` or a `matrix` with nothing round it — as one `matrix`.
    private static func matrixRun(
        from start: Int,
        in reached: [(block: Layout.Block, glyphs: [PDFContentScanner.Glyph])],
        rules: [PDFContentScanner.Rule]
    ) -> (end: Int, latex: String, bounds: CGRect, baseline: CGFloat)? {
        func cells(_ glyphs: [PDFContentScanner.Glyph]) -> [(glyphs: [PDFContentScanner.Glyph], span: CGRect)] {
            let body = MathTranscriber.ordinarySize(of: glyphs)
            var result: [(glyphs: [PDFContentScanner.Glyph], span: CGRect)] = []
            for glyph in glyphs.sorted(by: { $0.rect.minX < $1.rect.minX }) {
                if let last = result.last, glyph.rect.minX - last.span.maxX < body * 0.8 {
                    result[result.count - 1].glyphs.append(glyph)
                    result[result.count - 1].span = last.span.union(glyph.rect)
                } else {
                    result.append(([glyph], glyph.rect))
                }
            }
            return result
        }
        var lines: [(cells: [(glyphs: [PDFContentScanner.Glyph], span: CGRect)], baseline: CGFloat)] = []
        var next = start
        while next < reached.count, reached[next].block.isFormula, reached[next].block.rows.count == 1 {
            let glyphs = reached[next].glyphs
            let split = cells(glyphs)
            guard split.count >= 2 else { break }
            let baseline = MathReader.context(of: glyphs).baseline
            if let previous = lines.last {
                let body = MathTranscriber.ordinarySize(of: glyphs)
                let drop = previous.baseline - baseline
                guard previous.cells.count == split.count, drop > body * 0.9, drop < body * 1.6,
                      zip(previous.cells, split).allSatisfy({
                          $0.span.maxX > $1.span.minX && $0.span.minX < $1.span.maxX
                      })
                else { break }
            }
            lines.append((split, baseline))
            next += 1
        }
        guard lines.count >= 2 else { return nil }
        let cells = lines.map { line in line.cells.map { MathTranscriber.latex(glyphs: $0.glyphs, rules: rules) } }
        // What lines up in cells and is not a matrix: a table of results —
        // many columns, most cells a measured number ("93.2 ± 0.3") — and an
        // algorithm, whose lines begin with their numbers ("4:"). Both came
        // back as one \begin{matrix}; each line is its own formula.
        let all = cells.flatMap { $0 }
        let measured = all.filter { $0.range(of: #"[0-9]\.[0-9]"#, options: .regularExpression) != nil }.count
        guard lines[0].cells.count <= 6, measured * 2 <= all.count,
              !cells.allSatisfy({ $0.first?.range(of: #"^[0-9]+:$"#, options: .regularExpression) != nil })
        else { return nil }
        let written = cells.map { $0.joined(separator: " & ") }
        let latex = "\\begin{matrix} " + written.joined(separator: " \\\\ ") + " \\end{matrix}"
        let bounds = lines.flatMap { $0.cells.map(\.span) }.dropFirst()
            .reduce(lines[0].cells[0].span) { $0.union($1) }
        return (next, latex, bounds, lines[0].baseline)
    }

    /// A line that holds nothing but mathematics, as a displayed formula.
    ///
    /// Nil when the line is prose with a formula in it, which is the common
    /// case and must stay where it is.
    private static func displayedEquation(in line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.contains("$") else { return nil }
        var maths: [String] = []
        var rest = ""
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "$") {
            rest += text[index..<open]
            guard let close = text[text.index(after: open)...].firstIndex(of: "$") else {
                rest += text[open...]
                index = text.endIndex
                break
            }
            maths.append(String(text[text.index(after: open)..<close]))
            index = text.index(after: close)
        }
        rest += text[index...]
        guard !maths.isEmpty else { return nil }

        // What is left over once the mathematics is taken out: an equation
        // carries at most its number and the punctuation that ends the
        // sentence it completes.
        var tag: String?
        var leftovers = rest.trimmingCharacters(in: .whitespaces)
        if let match = leftovers.range(of: #"\(([0-9]+[a-z]?)\)"#, options: .regularExpression) {
            tag = String(leftovers[match]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            leftovers.removeSubrange(match)
        }
        let remainder = leftovers.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:\t"))
        guard remainder.isEmpty else { return nil }

        var body = MathTranscriber.joiningText(maths.joined(separator: " "))
        if let tag { body += "\\tag{\(tag)}" }
        return displayed(body)
    }

    /// A formula set on its own line, as LaTeX that compiles. With no number
    /// that is `$$…$$`, which every editor reads. With one, amsmath will not
    /// have it there — `\tag` inside `$$` and `align` inside any display are
    /// errors in LaTeX, though MathJax lets both pass — so a numbered formula
    /// is an `equation`, and lines that each keep a number are the `align`
    /// they already are.
    static func displayed(_ body: String) -> String {
        if body.hasPrefix("\\begin{align}") || body.hasPrefix("\\begin{gather}") { return body }
        if body.contains("\\tag{") { return "\\begin{equation} \(body) \\end{equation}" }
        return "$$\(body)$$"
    }

    /// Whether a row is a section title, and how loud a one.
    ///
    /// Set larger than the body is what makes a heading a heading; bold alone
    /// is a run-in heading — "Architecture." at the head of a paragraph — and
    /// that stays a bold phrase inside its sentence, which is what it is.
    private static func heading(
        level scale: CGFloat, glyphs: [PDFContentScanner.Glyph], text: String,
        short: Bool
    ) -> Piece.Kind {
        // A title is short and does not end in a full stop; the first line of
        // a paragraph set in a larger face is neither.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasSuffix("."), !trimmed.hasSuffix(","), trimmed.count < 90,
              // A line that is a formula with its number is an equation,
              // however large its symbols are set; a title with a symbol in
              // it ("Intractability of posterior of $A$") is still a title.
              !(trimmed.contains("$") && wordsOutsideFormulas(trimmed) < 2)
        else { return .prose }
        // Either it is set larger than the body, or it is a line of its own,
        // set entirely in bold, that stops well short of the column: that is
        // a subsection heading in every paper's template, and it is often no
        // more than half a point larger than the text under it.
        let bold = !glyphs.isEmpty && glyphs.allSatisfy(isBold)
        if scale >= 1.12 { return .heading(level: scale >= 1.45 ? 2 : scale >= 1.22 ? 3 : 4) }
        if bold, short, scale >= 1.0 { return .heading(level: 4) }
        return .prose
    }

    /// How many words of letters a line has outside its `$…$`.
    private static func wordsOutsideFormulas(_ text: String) -> Int {
        var outside = ""
        var inMath = false
        for character in text {
            if character == "$" { inMath.toggle(); outside.append(" "); continue }
            if !inMath { outside.append(character) }
        }
        return outside.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 2 }.count
    }

    /// The row, read as `read` reads it, with its bold words wrapped.
    private static func readMarkingBold(
        _ row: [PDFContentScanner.Glyph],
        rules: [PDFContentScanner.Rule],
        characters: [PageCharacter],
        text: NSString
    ) -> String {
        // Runs of one weight at a time: a bold lead-in and the sentence that
        // follows it are one row on the page and two things to read. The
        // runs are made of whole words, and a word with mathematics in it is
        // never a bold word: a bold "D" with a light "1:t" hanging under it
        // is one formula, \mathbf{D}_{1:t}, and cut at the change of weight it
        // was "**D** $1:t$".
        let body = context(of: row).bodySize
        var runs: [(bold: Bool, glyphs: [PDFContentScanner.Glyph])] = []
        for word in words(in: row.sorted(by: { $0.origin.x < $1.origin.x }), body: body) {
            let formula = word.contains(where: MathTranscriber.isMathFont)
                || MathTranscriber.hasWordSubscript(word, body: body)
            let bold = !formula && word.allSatisfy(isBold)
            if var last = runs.last, last.bold == bold {
                last.glyphs += word
                runs[runs.count - 1] = last
            } else {
                runs.append((bold, word))
            }
        }
        guard runs.contains(where: \.bold), runs.count > 1 else {
            return read(row, rules: rules, characters: characters, text: text)
        }
        var out = ""
        for run in runs {
            let piece = read(run.glyphs, rules: rules, characters: characters, text: text)
                .trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if !out.isEmpty { out += " " }
            out += run.bold ? "**\(piece)**" : piece
        }
        return out
    }

    /// Whether a glyph was drawn in a bold face.
    ///
    /// From the font's own name, which is all a PDF says about weight: TeX
    /// writes bold as CMBX or NimbusRomNo9L-Medi, everybody else writes the
    /// word out.
    ///
    /// The subset tag in front of the name is six random letters, and is left
    /// out: "MBXRYI+URWPalladioL-Roma" has a "BX" in it, and a whole line of
    /// Palatino came back in bold.
    static func isBold(_ glyph: PDFContentScanner.Glyph) -> Bool {
        let name = MathTranscriber.family(of: glyph)
        // "BX" catches the bold extended faces every TeX paper is set with —
        // CMBX10, SFBX1000 — and "-BD" the OpenType ones the newer templates
        // use, OptimisticDisp-Bd among them.
        return name.contains("BOLD") || name.contains("BX") || name.contains("-BD")
            || name.contains("MEDI") || name.contains("SEMIB") || name.contains("HEAVY")
            || name.contains("BLACK") || name.hasSuffix("-B")
    }

    /// The passage as Markdown, with the shape of the page kept.
    ///
    /// `latex(from:)` answers with one line, which is what a clipboard wants.
    /// A note wants what was on the page: a section title set as a title, a
    /// displayed equation on its own line with its number, the bold lead-in
    /// of a paragraph still bold, and a new paragraph starting a new
    /// paragraph. Quoting three pages of a paper into a note used to give one
    /// grey slab with the headings swallowed mid-sentence.
    ///
    /// An empty string in the result is a paragraph break.
    @MainActor
    static func structured(from selection: PDFSelection) -> [String] {
        let read = pieces(from: selection)
        guard !read.isEmpty else {
            let plain = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return plain.isEmpty ? [] : [plain]
        }
        return lines(of: read, markdown: true)
    }

    /// The pieces as the lines of a note — `markdown`: a title as a title,
    /// bold as bold, a blank line round every display — or as the lines of
    /// a clipboard, where a display breaks its sentence without ending its
    /// paragraph: the words after it go on on the next line, unless the
    /// page indented them, which is a new paragraph. A display of several
    /// rows is written a row a line there (`spread`).
    static func lines(of read: [Piece], markdown: Bool) -> [String] {
        // The column, as the selected rows drew it. A line that stops well
        // short of the right edge ended a paragraph; a line that starts in
        // from the left edge began one.
        let rows = read.filter { $0.kind != .inline }
        let left = rows.map(\.left).min() ?? 0
        let right = rows.map(\.right).max() ?? 0
        let column = max(right - left, 1)
        // How far apart two lines of one paragraph sit, as this page set them.
        let gaps = zip(rows, rows.dropFirst()).compactMap { above, below -> CGFloat? in
            guard above.page == below.page else { return nil }
            let gap = above.baseline - below.baseline
            return gap > 1 && gap < 80 ? gap : nil
        }.sorted()
        let leading = gaps.isEmpty ? 0 : gaps[gaps.count / 2]

        var lines: [String] = []
        var paragraph = ""
        var previous: Piece?
        // On a clipboard: that the last thing written was a display, so the
        // next line of words either goes on with its sentence or, set in
        // from the column's edge, begins a paragraph.
        var afterDisplay = false
        // The last line written for a row in display style, and where it
        // stood: the number printed out at the margin on its baseline is its.
        var styled: (line: Int, baseline: CGFloat, page: Int)?

        func close() {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
            paragraph = ""
        }
        func breakHere() {
            close()
            if lines.last != "" && !lines.isEmpty { lines.append("") }
        }
        func display(_ text: String) {
            if markdown {
                breakHere()
                lines.append(text)
                lines.append("")
            } else {
                close()
                lines.append(spread(text))
                afterDisplay = true
            }
            previous = nil
        }

        for piece in read {
            let text = markdown ? piece.marked : piece.plain
            switch piece.kind {
            case .heading(let level):
                breakHere()
                lines.append(markdown ? String(repeating: "#", count: level) + " " + text : text)
                lines.append("")
                previous = nil
                afterDisplay = false

            case .display:
                display(text)

            case .inline:
                paragraph += paragraph.isEmpty ? text : " " + text

            case .prose:
                // The number beside a line in display style — "(1)", out at
                // the margin on its baseline — is that line's.
                if let last = styled, last.page == piece.page, abs(last.baseline - piece.baseline) < 2,
                   isEquationNumber(text) {
                    lines[last.line] += " " + text.trimmingCharacters(in: .whitespaces)
                    styled = nil
                    continue
                }
                styled = nil
                // A line that opens with a bullet is an item of a list — a
                // slide's, or an itemize in a paper — and is written as one:
                // on a line of its own, the bullet a "- ". Joined into a
                // paragraph, a slide's three points ran into one sentence.
                if let item = afterBullet(text) {
                    breakHere()
                    paragraph = "- " + item
                    previous = piece
                    afterDisplay = false
                    continue
                }
                // A line that is all mathematics and an equation number is a
                // displayed equation, whatever the row was classified as —
                // "minimize" is a word, and the line it stands on is still an
                // equation. This is the line that used to arrive in the
                // middle of a sentence with its number stuck to it.
                if !piece.isTable, let equation = displayedEquation(in: text) {
                    display(equation)
                    continue
                }
                // A row in display style is a line of its own, as a display
                // is: its label made it a row of words, and joined into a
                // paragraph a slide's three labelled equations ran on as one.
                if piece.displayStyle {
                    if markdown { breakHere() } else { close() }
                    lines.append(text.trimmingCharacters(in: .whitespaces))
                    styled = (lines.count - 1, piece.baseline, piece.page)
                    if markdown { lines.append("") } else { afterDisplay = true }
                    previous = nil
                    continue
                }
                // A table's row is a line of its own: joined into a
                // paragraph, its cells and the next row's ran together.
                if piece.isTable {
                    close()
                    lines.append(text)
                    previous = piece
                    afterDisplay = false
                    continue
                }
                // After a display, TeX starts the sentence's next words at
                // the column's edge and a new paragraph a paragraph's indent
                // in from it.
                if afterDisplay {
                    afterDisplay = false
                    if piece.left > left + 6 { lines.append("") }
                }
                // A paragraph ended if the line before it stopped short of the
                // column, or this one is set in from its left edge.
                if let previous, previous.kind == .prose {
                    let endedShort = previous.right < right - column * 0.12
                    let spaced = leading > 0 && previous.page == piece.page
                        && previous.baseline - piece.baseline > leading * 1.5
                    if endedShort || spaced { breakHere() }
                }
                if paragraph.isEmpty {
                    paragraph = text
                } else if paragraph.hasSuffix("-") {
                    paragraph.removeLast()
                    paragraph += text
                } else {
                    paragraph += " " + text
                }
                previous = piece
            }
        }
        close()
        while lines.last == "" { lines.removeLast() }
        return lines
    }

    /// What a line says after the bullet it opens with — Beamer's ▶, the
    /// • of an itemize, the ◦ and – of its inner levels, set in a maths font
    /// (so `$\\bullet$`) or as the character — or nil when it opens with
    /// no bullet. A hyphen is not one: "- x" is a negation.
    static func afterBullet(_ text: String) -> String? {
        let bullets = ["\\blacktriangleright", "\\bullet", "\\triangleright", "\\circ", "\\boldsymbol{▶}",
                       "\\boldsymbol{\\blacktriangleright}", "\\boldsymbol{\\bullet}", "▶", "•", "◦", "–", "▪",
                       "\\blacksquare", "\\ast", "\\star", "\\diamond"]
        var rest = Substring(text)
        var wrapped = false
        if rest.hasPrefix("$") { rest = rest.dropFirst(); wrapped = true }
        guard let bullet = bullets.first(where: { rest.hasPrefix($0) }) else { return nil }
        rest = rest.dropFirst(bullet.count)
        if wrapped {
            guard rest.hasPrefix("$") else { return nil }
            rest = rest.dropFirst()
        }
        // The bullet stands off its item by a space; a bullet that is the
        // whole line, or one with a sign stuck to it, is not a list's.
        guard rest.first == " " else { return nil }
        let item = rest.trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }

    /// Whether a row holds a big operator with its limits stacked over or
    /// under it, the way TeX sets one in display style: a run of small
    /// glyphs centred on the sign, more than half a line off the row's
    /// baseline. (A script beside the sign — text style — is not centred on
    /// it, and a sentence that only mentions a sum has no limits at all.)
    static func stacksLimits(_ row: [PDFContentScanner.Glyph]) -> Bool {
        let line = context(of: row)
        let body = line.bodySize
        let small = row.filter { $0.size < body * 0.8 && !$0.isExtension }
        return row.contains { sign in
            guard MathTranscriber.isBigOperator(sign) else { return false }
            let ink = sign.rect
            for over in [true, false] {
                let limit = small.filter { glyph in
                    let lift = glyph.origin.y - line.baseline
                    return (over ? lift > body * 0.6 : -lift > body * 0.6)
                        && glyph.rect.maxX > ink.minX - body * 0.6 && glyph.rect.minX < ink.maxX + body * 0.6
                }
                guard let first = limit.first else { continue }
                let span = limit.dropFirst().reduce(first.rect) { $0.union($1.rect) }
                if span.maxX > ink.minX, span.minX < ink.maxX,
                   abs(span.midX - ink.midX) < max(span.width, ink.width) * 0.5 + 1 { return true }
            }
            return false
        }
    }

    /// Whether a line of words is only an equation's number: "(1)", "(3.2)",
    /// "(4a)".
    static func isEquationNumber(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces)
            .range(of: #"^\(\s*[0-9]+(\.[0-9]+)*[a-z]?\s*\)$"#, options: .regularExpression) != nil
    }

    /// One character as PDFKit read it, with where it sits on the page.
    struct PageCharacter {
        var index: Int
        var rect: CGRect
        var character: Character
    }

    @MainActor
    private static func characters(of page: PDFPage) -> [PageCharacter] {
        let key = ObjectIdentifier(page)
        if let known = characterBoxes[key], known.page === page { return known.value }
        let text = Array(page.string ?? "")
        var result: [PageCharacter] = []
        for index in text.indices {
            let bounds = page.characterBounds(at: index)
            guard !bounds.isEmpty else { continue }
            result.append(PageCharacter(index: index, rect: bounds, character: text[index]))
        }
        if characterBoxes.count > 12 { characterBoxes.removeAll() }
        characterBoxes[key] = (page, result)
        return result
    }

    /// Asking PDFKit where each character sits means asking it once per
    /// character, which is most of the cost of a copy. A page is asked once.
    @MainActor
    ///
    /// Each entry holds the page it answers for. An `ObjectIdentifier` is an
    /// address, and a page that has gone away leaves its address to the next
    /// one allocated there — a page of the next paper opened — which then
    /// read the old paper's layout: quoting a VAE equation off a page of
    /// another paper entirely. Holding the page keeps the address its own,
    /// and the check says so.
    private static var characterBoxes: [ObjectIdentifier: (page: PDFPage, value: [PageCharacter])] = [:]

    /// What PDFKit read at each point of the page, for the glyphs this cannot
    /// read on its own: ligatures, a font with an encoding of its own making,
    /// the label inside a figure.
    @MainActor
    private static func characterLookup(
        for page: PDFPage
    ) -> (PDFContentScanner.Glyph) -> String? {
        let boxes = characters(of: page).filter { !$0.character.isWhitespace }
        return { glyph in
            // The character whose box overlaps this glyph the most, and only
            // if it really does overlap: a near miss is a different letter.
            var best: (character: Character, area: CGFloat)?
            for box in boxes {
                let overlap = box.rect.intersection(glyph.rect)
                guard !overlap.isNull else { continue }
                let area = overlap.width * overlap.height
                guard area > glyph.rect.width * glyph.rect.height * 0.3 else { continue }
                if best == nil || area > best!.area { best = (box.character, area) }
            }
            guard let match = best else { return nil }
            // In a formula a wrong letter is worse than a missing symbol, so a
            // maths glyph only borrows punctuation and symbols.
            if MathTranscriber.isMathFont(glyph), match.character.isLetter || match.character.isNumber {
                return nil
            }
            return String(match.character)
        }
    }

    /// Whether a glyph is inside the selection rather than grazing it.
    ///
    /// The line a glyph is on is the line its *baseline* sits in. Asking
    /// instead how much of its body overlaps lets the ascenders of the line
    /// below reach up into this one — which is how a two-line drag comes back
    /// with three lines in it, and how a "d" from the next line becomes an
    /// accent on the "d" of this one.
    private static func belongs(_ glyph: PDFContentScanner.Glyph, to box: CGRect, byInk: Bool = false) -> Bool {
        // A rectangle drawn by hand has the glyphs whose ink is mostly in it:
        // its edge, run along the gap between two displayed lines, crossed
        // the foot of the lower limits of the line above, and a baseline
        // inside the rectangle took that whole formula in as well.
        if byInk { return box.contains(CGPoint(x: glyph.rect.midX, y: glyph.rect.midY)) }
        let slack = glyph.size * 0.15
        return glyph.origin.y > box.minY - slack && glyph.origin.y < box.maxY + slack
            && glyph.rect.maxX > box.minX && glyph.rect.minX < box.maxX
    }

    /// What the selection covers on one page, line by line.
    ///
    /// One box around the whole selection would say a three-line drag covers
    /// the full width of all three, when the first and last lines are only
    /// partly in it. Keeping the lines apart keeps a partial drag partial.
    @MainActor
    private static func lineBoxes(of selection: PDFSelection, on page: PDFPage) -> [CGRect] {
        var boxes: [CGRect] = []
        for line in selection.selectionsByLine() where line.pages.contains(page) {
            let rect = line.bounds(for: page)
            guard !rect.isEmpty else { continue }
            boxes.append(rect)
        }
        if boxes.isEmpty {
            let rect = selection.bounds(for: page)
            guard !rect.isEmpty else { return [] }
            boxes = [rect]
        }
        return boxes.map(box(of:))
    }

    /// A formula split from the number printed beside it.
    ///
    /// A journal sets the number out at the margin, past a gap far wider than
    /// anything inside a formula, and wraps it in brackets. Nothing else on a
    /// displayed line looks like that.
    private static func numbered(
        _ glyphs: [PDFContentScanner.Glyph], body: CGFloat
    ) -> (formula: [PDFContentScanner.Glyph], number: [PDFContentScanner.Glyph])? {
        let sorted = glyphs.sorted { $0.rect.minX < $1.rect.minX }
        guard sorted.count > 5 else { return nil }
        // The number is short, so only the tail is worth looking at.
        var cut: Int?
        for index in stride(from: sorted.count - 1, to: max(sorted.count - 9, 1), by: -1) {
            if sorted[index].rect.minX - sorted[index - 1].rect.maxX > body * 1.5 {
                cut = index
                break
            }
        }
        guard let cut else { return nil }
        let number = Array(sorted[cut...])
        guard MathTranscriber.spelling(of: number[0]) == "(",
              MathTranscriber.spelling(of: number[number.count - 1]) == ")",
              number.count >= 3
        else { return nil }
        return (Array(sorted[..<cut]), number)
    }

    /// Rows gathered into the things they belong to.
    ///
    /// A paragraph's lines are a whole baselineskip apart and full of words.
    /// The rows of a displayed formula carry none, and something holds them
    /// together: a fraction bar with the numerator on one and the denominator
    /// on the other, a sum or a tall bracket reaching from one to the next, a
    /// row of limits under the sign they belong to. Rows are only ever joined
    /// to the next row down in their own column.
    private static func blocks(
        of rows: [[PDFContentScanner.Glyph]], body: CGFloat, rules: [PDFContentScanner.Rule]
    ) -> [[[PDFContentScanner.Glyph]]] {
        guard !rows.isEmpty else { return [] }
        let baselines = rows.map { context(of: $0).baseline }
        let extents = rows.map(extent(of:))
        // The lines of cases hold words — "if", "otherwise" — and are still
        // the formula's: a brace two lines tall or more stands just before
        // them, or in them, as high as they are.
        let fences = tallFences(in: rows.flatMap { $0 }, body: body)
        // A pair of tall brackets holds the rows between them — the whole of
        // each — and the row they stand on; the line of an align above it,
        // passing across the brackets, is not held. The row they stand on is
        // the one they are centred on: TeX centres a \left–\right pair on
        // the axis of its line, and the line of the formula's left side runs
        // up to the bracket — with an odd number of cases, through it, into
        // the middle case. A bracket's pieces fall into the rows of their
        // own heights, none of them into that one.
        // A brace nothing closes holds the lines that begin beside it: in the
        // left column of a page, the lines of the right one stood beside it
        // too, as far along as it reaches.
        func held(_ row: Int) -> Int? {
            fences.indices.first { index in
                let fence = fences[index].region
                guard fence.minY < baselines[row], fence.maxY > baselines[row] else { return false }
                let inside = extents[row].minX > fence.minX - 1 && extents[row].maxX < fence.maxX + 1
                    && (fences[index].closed || extents[row].minX < fence.minX + body * 2)
                let standing = rows[row].contains { glyph in
                    (MathTranscriber.isDelimiter(glyph) || MathTranscriber.barToken(glyph) != nil
                        || MathTranscriber.spelling(of: glyph).isEmpty)
                        && (abs(glyph.rect.maxX - fence.minX) < 1.5 || abs(glyph.rect.minX - fence.maxX) < 1.5)
                }
                let centred = extents[row].minX < fence.minX && extents[row].maxX > fence.minX - body * 2
                    && abs(fence.midY - (baselines[row] + body * 0.25)) < body * 0.3
                return inside || standing || centred
            }
        }
        let prose = rows.indices.map { row in containsProse(rows[row]) && held(row) == nil }
        var parent = Array(rows.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { index = parent[index] }
            return index
        }
        func join(_ one: Int, _ other: Int) {
            let a = root(one), b = root(other)
            if a != b { parent[max(a, b)] = min(a, b) }
        }
        func overlap(_ one: Int, _ other: Int) -> Bool {
            extents[one].maxX > extents[other].minX && extents[one].minX < extents[other].maxX
        }
        // A fraction bar over or under a row, no wider than the row: the row
        // is a numerator or a denominator.
        func barBeside(_ row: Int) -> Bool {
            rules.contains { rule in
                rule.rect.width > 1 && rule.rect.height < rule.rect.width
                    && rule.rect.minX > extents[row].minX - 4 && rule.rect.maxX < extents[row].maxX + 4
                    && abs(rule.rect.midY - baselines[row]) < body * 1.2
            }
        }
        // The rows right over and right under each one in its own column.
        let unders = rows.indices.map { row in
            rows.indices.filter { baselines[$0] < baselines[row] && overlap($0, row) }
                .max { baselines[$0] < baselines[$1] }
        }
        let overs = rows.indices.map { row in
            rows.indices.filter { baselines[$0] > baselines[row] && overlap($0, row) }
                .min { baselines[$0] < baselines[$1] }
        }
        func small(_ index: Int) -> Bool { rows[index].allSatisfy { $0.size < body * 0.8 } }
        // How far a row is from the line on its far side — a row of limits
        // belongs to the nearer of the two lines it stands between. The
        // limits of the line beyond are no line: under the sums of one line
        // of a derivation stood the upper limits of the next, nearer than
        // either line, and the limits of both came back as lines of their own.
        // A line of prose is not a line a row of limits could belong to.
        func gap(below row: Int) -> CGFloat? {
            var under = unders[row]
            while let next = under, small(next) { under = unders[next] }
            return under.flatMap { prose[$0] ? nil : baselines[row] - baselines[$0] }
        }
        func gap(above row: Int) -> CGFloat? {
            var over = overs[row]
            while let next = over, small(next) { over = overs[next] }
            return over.flatMap { prose[$0] ? nil : baselines[$0] - baselines[row] }
        }
        // Two rows of scripts one over the other, each the limits of its own
        // line: under the sums of one line of a derivation and over the sums
        // of the next, the two rows stand closer than a line and joined the
        // lines — every glyph of both came back twice over, interleaved.
        func apart(_ upper: Int, _ lower: Int) -> Bool {
            guard small(upper), small(lower), let top = overs[upper], let bottom = unders[lower],
                  !prose[top], !prose[bottom] else { return false }
            return linked(rows[top], rows[upper], baselines: (baselines[top], baselines[upper]),
                          body: body, rules: rules)
                && linked(rows[lower], rows[bottom], baselines: (baselines[lower], baselines[bottom]),
                          body: body, rules: rules)
        }
        for row in rows.indices where !prose[row] {
            if let below = unders[row], !prose[below], !apart(row, below),
               linked(rows[row], rows[below], baselines: (baselines[row], baselines[below]),
                      body: body, rules: rules, farther: (gap(above: row), gap(below: below))) {
                join(row, below)
            }
            if let above = overs[row], !prose[above], !apart(above, row),
               linked(rows[above], rows[row], baselines: (baselines[above], baselines[row]),
                      body: body, rules: rules, farther: (gap(above: above), gap(below: row))) {
                join(above, row)
            }
            // The lines of a matrix or of cases, held by one pair of tall
            // brackets or by one brace.
            if let fence = held(row) {
                for other in rows.indices where other != row && held(other) == fence { join(row, other) }
            }
            // Side by side: the numerator and the denominator of a displayed
            // fraction are rows of their own, just after the row the formula
            // began on — "P(A | B) =" and then the fraction.
            // Only a numerator or a denominator stands a row of its own next
            // to its line; two cells of a table, one a line down, do not.
            for other in rows.indices where other != row && !prose[other] && !overlap(other, row) {
                let gap = max(extents[other].minX, extents[row].minX)
                    - min(extents[other].maxX, extents[row].maxX)
                if gap < body * 0.8, abs(baselines[other] - baselines[row]) < body * 1.3,
                   barBeside(row) || barBeside(other) {
                    join(row, other)
                }
            }
        }
        var grouped: [Int: [[PDFContentScanner.Glyph]]] = [:]
        var order: [Int] = []
        for index in rows.indices {
            let key = root(index)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(rows[index])
        }
        return order.map { grouped[$0]! }
    }

    /// The brackets two lines tall or more, each as the region it holds:
    /// between a pair of them, or after a brace that nothing closes — the
    /// brace of cases. A tall bracket is one glyph drawn down from its point
    /// (the extension fonts'), or a stack of pieces one over another at the
    /// same place — ⎛ ⎜ ⎝ in OpenType, "tp", "ex" and "bt" in TeX's fonts —
    /// or one OpenType glyph whose height the file does not say, standing off
    /// the line of what it holds, taken as two lines either side of it.
    struct Fence {
        /// What the bracket holds.
        var region: CGRect
        /// Whether a bracket closes it; a brace of cases holds what begins
        /// beside it, as far along as that runs.
        var closed: Bool
    }

    static func tallFences(in glyphs: [PDFContentScanner.Glyph], body: CGFloat) -> [Fence] {
        struct Side { var token: String; var box: CGRect }
        var sides: [Side] = []
        // A bracket's pieces are one bracket, met once.
        var taken = Set<Int>()
        for (index, glyph) in glyphs.enumerated() where !taken.contains(index) {
            let spelled = MathTranscriber.spelling(of: glyph)
            guard let token = MathTranscriber.opening(glyph) ?? MathTranscriber.closing(glyph)
                ?? TeXGlyphNames.fence(glyph.glyphName)
                ?? (["|", "\\|", "\\mid"].contains(spelled) ? spelled : nil) else { continue }
            let x = glyph.origin.x
            let column = glyphs.indices.filter {
                abs(glyphs[$0].origin.x - x) < glyph.size * 0.2
                    && (MathTranscriber.opening(glyphs[$0]) == token || MathTranscriber.closing(glyphs[$0]) == token
                        || TeXGlyphNames.fence(glyphs[$0].glyphName) == token
                        || MathTranscriber.spelling(of: glyphs[$0]) == token
                        || MathTranscriber.spelling(of: glyphs[$0]).isEmpty)
            }
            // This bracket's own pieces, not every bracket at the same place
            // down the page: taken as one, two of them made a bracket as tall
            // as the lines between them, and those lines its matrix.
            let stacked = MathTranscriber.stack(from: index, in: glyphs, candidates: column)
            taken.formUnion(stacked.members)
            var box = stacked.box
            if stacked.members.count == 1, MathTranscriber.isTallVariant(glyph, among: glyphs, body: body) {
                box = CGRect(x: glyph.rect.minX, y: glyph.origin.y - body * 2.2,
                             width: glyph.rect.width, height: body * 4.4)
            }
            guard box.height >= body * 1.8 else { continue }
            sides.append(Side(token: token, box: box))
        }
        let pairs: [String: String] = [
            "(": ")", "[": "]", "\\{": "\\}", "|": "|", "\\|": "\\|", "\\mid": "\\mid",
        ]
        var result: [Fence] = []
        var used = Set<Int>()
        for (index, left) in sides.enumerated().sorted(by: { $0.element.box.minX < $1.element.box.minX })
        where !used.contains(index) {
            guard let partner = pairs[left.token] else { continue }
            // Its partner is set at the same height: TeX sizes and places the
            // two of a \left–\right pair alike.
            let right = sides.indices.filter {
                !used.contains($0) && $0 != index && sides[$0].token == partner
                    && sides[$0].box.minX > left.box.maxX - 0.5
                    && abs(sides[$0].box.midY - left.box.midY) < body * 0.3
                    && abs(sides[$0].box.height - left.box.height) < body * 0.5
            }.min { sides[$0].box.minX < sides[$1].box.minX }
            let low = min(left.box.minY, right.map { sides[$0].box.minY } ?? left.box.minY)
            let high = max(left.box.maxY, right.map { sides[$0].box.maxY } ?? left.box.maxY)
            let region: CGRect
            if let right {
                region = CGRect(x: left.box.maxX - 0.5, y: low,
                                width: sides[right].box.minX - left.box.maxX + 1, height: high - low)
            } else if left.token == "\\{" {
                region = CGRect(x: left.box.maxX - 0.5, y: low, width: body * 40, height: high - low)
            } else {
                continue
            }
            // It holds two lines or more: what is inside, at its own full
            // size, stands a line apart. A tall bracket round one line — a
            // sum with its limits — holds one.
            let inside = glyphs.filter {
                region.contains(CGPoint(x: $0.rect.midX, y: $0.origin.y)) && !MathTranscriber.isDelimiter($0)
                    && !MathTranscriber.spelling(of: $0).isEmpty && !MathTranscriber.isBigOperator($0)
                    && (right != nil || $0.rect.minX < region.minX + body * 3)
            }
            let largest = inside.map(\.size).max() ?? 0
            let heights = inside.filter { $0.size >= largest * 0.9 }.map(\.origin.y)
            guard let top = heights.max(), let bottom = heights.min(), top - bottom >= body * 0.9 else { continue }
            used.insert(index)
            if let right { used.insert(right) }
            result.append(Fence(region: region, closed: right != nil))
        }
        return result
    }

    /// Whether two rows, one right over the other, are parts of one formula.
    /// `farther` is how far each of the two rows is from the row on its
    /// other side — over the upper one, under the lower one — when there is one.
    private static func linked(
        _ above: [PDFContentScanner.Glyph], _ below: [PDFContentScanner.Glyph],
        baselines: (above: CGFloat, below: CGFloat), body: CGFloat,
        rules: [PDFContentScanner.Rule], farther: (above: CGFloat?, below: CGFloat?) = (nil, nil)
    ) -> Bool {
        let distance = baselines.above - baselines.below
        // Closer than a line: nothing but a formula stacks rows that tight.
        if distance < body { return true }
        let top = extent(of: above), bottom = extent(of: below)
        // A fraction bar with one row on each side of it — as wide as what it
        // divides, which a table's rule between two rows of cells is not, and
        // next to both: a numerator stands on its bar and a denominator hangs
        // from it. A bar two lines under a row is the next line's fraction —
        // and the limits under a sum on one line of a derivation stood two
        // sizes over the next line's first fraction, and joined the lines.
        let reach = top.union(bottom)
        if distance < body * 4.5, rules.contains(where: { rule in
            rule.rect.midY > baselines.below && rule.rect.midY < baselines.above
                && baselines.above - rule.rect.midY < body * 1.6 && rule.rect.midY - baselines.below < body * 2
                && rule.rect.width > 1 && rule.rect.height < rule.rect.width
                && rule.rect.minX > reach.minX - 4 && rule.rect.maxX < reach.maxX + 4
                && above.contains { $0.rect.midX > rule.rect.minX - 1 && $0.rect.midX < rule.rect.maxX + 1 }
                && below.contains { $0.rect.midX > rule.rect.minX - 1 && $0.rect.midX < rule.rect.maxX + 1 }
        }) { return true }
        guard distance < body * 2 else { return false }
        // The pieces of one tall sign are one sign: STIX sets a displayed ∫
        // as its top half on one row and its bottom half, with the lower
        // limit beside it, on the next.
        func sign(_ glyph: PDFContentScanner.Glyph) -> Bool {
            MathTranscriber.isPiece(glyph) || MathTranscriber.isBigOperator(glyph)
        }
        if above.contains(where: { upper in
            sign(upper) && below.contains { lower in
                sign(lower) && (MathTranscriber.isPiece(upper) || MathTranscriber.isPiece(lower))
                    && abs(upper.origin.x - lower.origin.x) < upper.size * 0.2
                    && abs(upper.rect.minY - lower.rect.maxY) < upper.size * 0.35
            }
        }) { return true }
        // A sign that grows — a big operator, a tall bracket — reaching down
        // past the other row's baseline, or standing over what is in it.
        func reaches(_ row: [PDFContentScanner.Glyph], to other: [PDFContentScanner.Glyph],
                     at baseline: CGFloat) -> Bool {
            let span = extent(of: other)
            return row.contains { glyph in
                guard glyph.isExtension || MathTranscriber.isBigOperator(glyph) else { return false }
                let ink = glyph.rect
                let across = ink.maxX > span.minX - body * 0.6 && ink.minX < span.maxX + body * 0.6
                // Standing over what is in it means reaching into it: a sign
                // on one displayed line is over the whole of the next one,
                // and the \big brackets of two lines set tight come within a
                // point of each other — neither makes them one formula.
                let overlaps = ink.maxX > span.minX && ink.minX < span.maxX
                    && ink.minY < span.maxY - body * 0.2 && ink.maxY > span.minY + body * 0.2
                return (across && ink.minY < baseline && ink.maxY > baseline) || overlaps
            }
        }
        if reaches(above, to: below, at: baselines.below) || reaches(below, to: above, at: baselines.above) {
            return true
        }
        // A pair of brackets in one row round what is in the other: the
        // halves of \binom, and a bracket STIX draws from above its ink.
        func encloses(_ row: [PDFContentScanner.Glyph], _ other: [PDFContentScanner.Glyph]) -> Bool {
            // What the other row holds, without the brackets' own lower pieces.
            let held = other.filter {
                !MathTranscriber.spelling(of: $0).isEmpty && !MathTranscriber.isDelimiter($0)
            }
            guard !held.isEmpty else { return false }
            let span = extent(of: held)
            let opens = row.filter { MathTranscriber.opening($0) != nil && $0.rect.maxX <= span.minX + 1 }
            let closes = row.filter { MathTranscriber.closing($0) != nil && $0.rect.minX >= span.maxX - 1 }
            guard let open = opens.max(by: { $0.rect.maxX < $1.rect.maxX }),
                  let close = closes.min(by: { $0.rect.minX < $1.rect.minX }) else { return false }
            // One pair, and a tall one: the two halves of \binom are set at
            // one size and one height, taller than a letter. The "(" of one
            // formula and the ")" of its number are not a pair, and between
            // them stood the whole of the formula above.
            let tall = { (glyph: PDFContentScanner.Glyph) in
                glyph.rect.height >= body * 1.1 || MathTranscriber.isTallVariant(glyph, among: row, body: body)
            }
            guard tall(open), tall(close), abs(open.origin.y - close.origin.y) < body * 0.3 else { return false }
            return span.minX - open.rect.maxX < body * 0.6 && close.rect.minX - span.maxX < body * 0.6
        }
        if encloses(above, below) || encloses(below, above) { return true }
        // A row of limits — nothing in it at full size — over or under a big
        // operator in the other, or beside one: the limits of a displayed
        // integral sit off its top and bottom corners. Over or under anything
        // else — \lim, \underset, an \underbrace — a limit sits close, a line
        // and a half at most: further, it is the limit of the formula on its
        // other side, which a displayed sum's J over a line's "log N(z; 0, I)"
        // was, and the two displayed lines came back as one.
        func isLimits(_ row: [PDFContentScanner.Glyph], over other: [PDFContentScanner.Glyph]) -> Bool {
            guard row.allSatisfy({ $0.size < body * 0.8 }) else { return false }
            let span = extent(of: row)
            let sign = other.contains { glyph in
                guard MathTranscriber.isBigOperator(glyph) else { return false }
                return (glyph.rect.maxX > span.minX && glyph.rect.minX < span.maxX)
                    || (span.minX > glyph.rect.midX && span.minX - glyph.rect.maxX < body * 0.6)
            }
            if sign { return true }
            guard distance < body * 1.5 else { return false }
            return other.contains { $0.rect.maxX > span.minX && $0.rect.minX < span.maxX }
        }
        // A row of limits between two lines is the nearer line's: the J over
        // a sum on the second line of an align is closer to that sum than to
        // the line above, however it lines up with it.
        if let beyond = farther.above, beyond < distance, isLimits(above, over: below),
           !isLimits(below, over: above) { return false }
        if let beyond = farther.below, beyond < distance, isLimits(below, over: above),
           !isLimits(above, over: below) { return false }
        return isLimits(above, over: below) || isLimits(below, over: above)
    }

    /// The size a set of glyphs is mostly drawn at.
    private static func size(of glyphs: [PDFContentScanner.Glyph]) -> CGFloat {
        let sizes = glyphs.map(\.size).sorted()
        return sizes.isEmpty ? 10 : sizes[Int(Double(sizes.count) * 0.75)]
    }

    /// Whether a row is a table's: cells set an em and more apart, three
    /// gaps and more along it, or two measured values ("93.2 ± 0.3") in it.
    /// A formula's own spacing never opens that wide, and a formula carries
    /// one ± at a time.
    static func isTableRow(_ row: [PDFContentScanner.Glyph]) -> Bool {
        guard row.count > 3 else { return false }
        // The rows of a matrix open the same gaps between their columns and
        // are mostly digits too; a tall bracket's piece or a \cdots says
        // which is which.
        if row.contains(where: { glyph in
            glyph.isExtension || MathTranscriber.isPiece(glyph)
                || ["\\cdots", "\\vdots", "\\ddots"].contains(MathTranscriber.spelling(of: glyph))
        }) { return false }
        let body = MathTranscriber.ordinarySize(of: row)
        let ordered = row.sorted { $0.rect.minX < $1.rect.minX }
        var reach = -CGFloat.greatestFiniteMagnitude
        var gaps = 0
        for glyph in ordered {
            if reach > -.greatestFiniteMagnitude, glyph.rect.minX - reach >= body * 0.8 { gaps += 1 }
            reach = max(reach, glyph.rect.maxX)
        }
        let measured = row.filter { MathTranscriber.spelling(of: $0) == "\\pm" }.count
        // And its cells are numbers: three formulas set a \quad apart on
        // one line — "∫z dz = 0, ∫zzᵀdz = (d+2)I, ∫‖z‖²dz = d+2" — open
        // the same gaps and are a display still.
        let digits = row.filter { glyph in
            let spelled = MathTranscriber.spelling(of: glyph)
            return spelled.count == 1 && spelled.first!.isNumber
        }.count
        return (gaps >= 3 && digits * 3 >= row.count) || (measured >= 2 && digits >= 4)
    }

    /// Whether a row belongs to a displayed formula rather than to a sentence.
    ///
    /// A sentence mentions variables; a formula is made of them. The line
    /// between the two is how much of the row came from a maths font, and
    /// whether it carries something a sentence never does.
    private static func isDisplayRow(_ row: [PDFContentScanner.Glyph]) -> Bool {
        guard !row.isEmpty else { return false }
        // Cases folded into the row their brace stands on: the "if" of each
        // case is a word of a sentence and still the formula's, which a brace
        // two lines tall holding them says — and the words of two cases
        // folded together, "iiff", say nothing.
        // Only a brace nothing closes: a tall pair round a fraction in a
        // sentence is still the sentence's.
        if tallFences(in: row, body: context(of: row).bodySize).contains(where: { !$0.closed }) { return true }
        // Words settle it first. A sentence can hold a sum without being a
        // formula — a paper is full of lines like "is the sum over the
        // marginal likelihoods" — and a line that says "is:" before the
        // formula and "where" after it is a sentence however much of it is
        // symbols.
        if containsProse(row) { return false }
        // A row of a table is not a formula either, however many of its
        // cells are numbers: cells an em or more apart, three gaps and
        // more, or two measurements — "93.2 ± 0.3" — in a line. Read as a
        // formula it came back as one run of digits, "93.2\pm 0.36.4\pm 3.9".
        if isTableRow(row) { return false }
        // A row whose full-size glyphs stand a line apart and more — the rows
        // of a matrix folded into the row its brackets are on — is a
        // formula however few letters it has: an identity matrix has none.
        let standing = row.filter {
            $0.size >= context(of: row).bodySize * 0.92 && !$0.isExtension && !MathTranscriber.isDelimiter($0)
        }.map(\.origin.y)
        if let top = standing.max(), let bottom = standing.min(),
           top - bottom >= context(of: row).bodySize * 0.9,
           row.contains(where: MathTranscriber.isMathFont) {
            return true
        }

        // Then the letters, and only the letters set at the line's own size.
        // Brackets, commas and digits read the same in a sentence as in a
        // formula, and a word set small is part of the formula whatever it
        // spells — counting those buries the evidence. "L(φ) := L_teacher-
        // forcing(φ) + L_rollout(φ), (4)" is mostly brackets and a subscript,
        // and every letter in it at full size is mathematics.
        //
        // The letters of a name — "sin", "arg" — are part of the formula,
        // not evidence against it, so they do not vote: "\sin^2\theta +
        // \cos^2\theta = 1" is six roman letters and two thetas.
        let body = context(of: row).bodySize
        var deciding: [PDFContentScanner.Glyph] = []
        for word in words(in: row, body: body) {
            var letters: [PDFContentScanner.Glyph] = []
            func settle() {
                let spelled = letters.map(MathTranscriber.spelling(of:)).joined()
                if !MathTranscriber.isOperatorName(spelled) { deciding += letters }
                letters = []
            }
            for glyph in word where glyph.size >= body * 0.92 {
                let token = MathTranscriber.spelling(of: glyph)
                guard token.count > 1 || token.first?.isLetter == true else { settle(); continue }
                if !isMathish(glyph), token.count == 1 {
                    letters.append(glyph)
                } else {
                    settle()
                    deciding.append(glyph)
                }
            }
            settle()
        }
        guard !deciding.isEmpty else { return false }
        let mathish = deciding.filter(isMathish).count
        if deciding.count <= 4 { return mathish > 0 }
        if row.contains(where: MathTranscriber.isBigOperator) {
            return Double(mathish) >= Double(deciding.count) * 0.25
        }
        return Double(mathish) >= Double(deciding.count) * 0.4
    }

    /// Whether a row contains ordinary words rather than only symbols.
    ///
    /// "log" and "max" do not count: TeX sets those upright because each is
    /// one word, but they are part of the formula, not a sentence around it.
    private static func containsProse(_ row: [PDFContentScanner.Glyph]) -> Bool {
        let body = context(of: row).bodySize
        let split = words(in: row, body: body)
        return split.indices.contains { index in
            let word = split[index]
            // A name applied to what follows it — \mathrm{Laplace}\left(,
            // \mathrm{Exp}(1) — stands a thin space from its bracket, where
            // a word of a sentence stands a word's space off.
            if appliesTo(word, next: index + 1 < split.count ? split[index + 1] : nil, body: body) { return false }
            // Only what is set at the line's own size can be a word of a
            // sentence. "teacher-forcing" written small under an L is a name
            // inside the formula, not prose around it — and reading it as
            // prose is what turns a displayed equation into a line of text.
            let full = word.filter { $0.size >= body * 0.92 }
            // On a page that sets its variables in its text italic, three
            // italic letters running together are a word — stressed, a
            // title, a figure's label — not three variables multiplied, as
            // `isFormula` says of one word. Read as variables, an IEEE
            // paper's figure labels and the conference names in its
            // references came back as displayed formulas,
            // "Federatedunlearningframework", once its italic face was known
            // to be italic.
            let wordy = MathTranscriber.variablesInTextItalic && longestItalicRun(full) >= 3
            guard full.count >= 2,
                  !full.contains(where: { isMathish($0) && !(wordy && MathTranscriber.isItalicLetter($0)) })
            else { return false }
            let spelled = full.map(MathTranscriber.spelling(of:))
            guard spelled.filter({ $0.first?.isLetter == true }).count >= 2 else { return false }
            return !MathTranscriber.isOperatorName(spelled.joined())
        }
    }

    /// Whether a word is a name applied to what follows it: letters set
    /// upright at the line's size, then a bracket right after them — in the
    /// word, "Exp(1)", or opening the next one a thin space off, "Laplace"
    /// before a \bigg( — which a word of a sentence is not: it stands a
    /// word's space from anything after it.
    static func appliesTo(
        _ word: [PDFContentScanner.Glyph], next: [PDFContentScanner.Glyph]?, body: CGFloat
    ) -> Bool {
        let ordered = word.sorted { $0.rect.minX < $1.rect.minX }
        let letters = ordered.prefix { $0.size >= body * 0.92 && MathTranscriber.isUprightLetter($0) }
        // On one line: the letters of a label set on its side in a figure
        // follow one another up the page, and are no name.
        guard letters.count >= 2, let last = letters.last,
              letters.allSatisfy({ abs($0.origin.y - last.origin.y) < last.size * 0.05 }) else { return false }
        // The bracket, not a piece of it that happens to stand at the same
        // place and spells nothing.
        func opener(_ glyphs: ArraySlice<PDFContentScanner.Glyph>) -> PDFContentScanner.Glyph? {
            guard let start = glyphs.map(\.rect.minX).min() else { return nil }
            return glyphs.first { $0.rect.minX < start + 0.5 && MathTranscriber.opening($0) != nil }
        }
        if letters.count < ordered.count {
            guard let after = opener(ordered[letters.count...]) else { return false }
            return after.rect.minX - last.rect.maxX < body * 0.2
        }
        guard let next, let opener = opener(next[...]) else { return false }
        // A bracket from an extension font — a \bigl( and up — carries a
        // little room of its own before its ink: 2.5 points from the
        // "Laplace" before it in Times, which is a Times word space.
        return opener.rect.minX - last.rect.maxX < body * (opener.isExtension ? 0.3 : 0.2)
    }

    /// Glyphs grouped into the rows they were set on.
    ///
    /// The rows are set by the full-size glyphs. Anything smaller — a
    /// subscript, a superscript — belongs to the row it hangs from rather than
    /// to a row of its own, which is what stops "z_k" from being read as a "z"
    /// on one line and a "k" on the next.
    private static func rows(
        of given: [PDFContentScanner.Glyph], rules: [PDFContentScanner.Rule] = []
    ) -> [[PDFContentScanner.Glyph]] {
        // The tips of an \underbrace or \overbrace spell nothing and stand
        // on no line: hung from the nearest line — the other column's, as
        // it happened — they carried the brace's label there with them,
        // and the label came back inside the formula as its subscripts.
        let glyphs = given.filter { !($0.glyphName?.hasPrefix("bracehtip") ?? false) }
        guard !glyphs.isEmpty else { return [] }
        let sizes = glyphs.map(\.size).sorted()
        let body = sizes[Int(Double(sizes.count) * 0.75)]

        var rows: [(baseline: CGFloat, glyphs: [PDFContentScanner.Glyph])] = []
        // A bracket at one of its larger sizes can be drawn from a point above
        // its own ink, as the extension fonts' are — STIX's .s1 to .s5 for
        // pdfTeX sit a line up — so it waits until the rows are there.
        // So can a big operator from a font that is not an extension font:
        // STIX's display sum for pdfTeX stands most of a line above its line.
        func floats(_ glyph: PDFContentScanner.Glyph) -> Bool {
            if MathTranscriber.isBigOperator(glyph) { return true }
            guard MathTranscriber.isDelimiter(glyph), let name = glyph.glyphName,
                  let dot = name.lastIndex(of: ".") else { return false }
            let variant = name[name.index(after: dot)...]
            return variant.hasPrefix("s") && variant.dropFirst().allSatisfy(\.isNumber)
        }
        var floating: [PDFContentScanner.Glyph] = []
        // So do the pieces of a bar built tall out of several of one glyph —
        // STIX's "bar.x", an OpenType font's | set one over another — each a
        // full-size glyph on a line of its own making: five of them made five
        // rows, and cut a fraction round them in two.
        let pieces = barPieces(in: glyphs)
        // A radical sign is drawn from wherever its font puts its point — the
        // top of the sign, by the rule, in Computer Modern's symbol font and
        // often in the OpenType ones — and it belongs with what it covers,
        // which starts where it ends.
        var radicals: [PDFContentScanner.Glyph] = []
        for glyph in glyphs.filter({ $0.size >= body * 0.9 && !$0.isExtension })
            .sorted(by: { $0.origin.y > $1.origin.y }) {
            if floats(glyph) || pieces.contains(Place(glyph)) { floating.append(glyph); continue }
            if MathTranscriber.isRadical(glyph) { radicals.append(glyph); continue }
            // Two glyphs of one line never share their ink. One drawn over
            // another at the same height is another layer of the page — the
            // words of a figure standing level with a line of its caption —
            // and the line read with it was "tion" interleaved with
            // "I(Z;X)". A glyph printed twice for bold shares its own ink.
            func layered(_ row: [PDFContentScanner.Glyph]) -> Bool {
                // Only letters and digits say so: the pieces of a long
                // arrow, the stroke through a relation, a mark over its
                // letter all lie over one another on one line.
                func lettered(_ one: PDFContentScanner.Glyph) -> Bool {
                    // (A modifier letter is a letter to Unicode: the hat
                    // over ŷ is U+02C6, and is no letter here.)
                    guard !MathTranscriber.isAccent(one) else { return false }
                    let spelled = MathTranscriber.spelling(of: one)
                    return !spelled.isEmpty && spelled.allSatisfy { $0.isLetter || $0.isNumber }
                }
                guard glyph.width > 0.05, lettered(glyph) else { return false }
                let spelled = MathTranscriber.spelling(of: glyph)
                return row.contains { other in
                    guard other.width > 0.05, lettered(other) else { return false }
                    let overlap = min(other.rect.maxX, glyph.rect.maxX) - max(other.rect.minX, glyph.rect.minX)
                    guard overlap > min(other.width, glyph.width) * 0.5 else { return false }
                    let said = MathTranscriber.spelling(of: other)
                    // The same glyph again, a hair off: printed twice.
                    if said == spelled, abs(other.origin.x - glyph.origin.x) < glyph.size * 0.3 { return false }
                    return true
                }
            }
            if let index = rows.firstIndex(where: {
                abs($0.baseline - glyph.origin.y) < body * 0.6 && !layered($0.glyphs)
            }) {
                rows[index].glyphs.append(glyph)
            } else {
                rows.append((glyph.origin.y, [glyph]))
            }
        }

        var placedRadicals: [CGPoint] = []
        func placed(_ glyph: PDFContentScanner.Glyph) -> Bool { placedRadicals.contains(glyph.origin) }
        for sign in radicals + glyphs.filter({ $0.isExtension && MathTranscriber.isRadical($0) }) {
            // Its roof starts where it ends; what is under the roof is what it
            // takes, and that is on the row it belongs to. A glyph that only
            // happens to start where the sign ends — prose is full of them —
            // is not under anything.
            let roofs = rules.filter {
                abs($0.rect.minX - sign.rect.maxX) < max(1, sign.size * 0.15)
                    && $0.rect.midY > sign.origin.y - sign.size * 3 && $0.rect.midY < sign.origin.y + sign.size * 2.5
            }
            let under = rows.indices.filter { row in
                abs(rows[row].baseline - sign.origin.y) < body * 2 && rows[row].glyphs.contains { glyph in
                    abs(glyph.rect.minX - sign.rect.maxX) < max(1, sign.size * 0.15)
                        && roofs.contains { $0.rect.midY > glyph.origin.y && $0.rect.midY - glyph.origin.y < body * 2 }
                }
            }.min { abs(rows[$0].baseline - sign.origin.y) < abs(rows[$1].baseline - sign.origin.y) }
            if let under {
                rows[under].glyphs.append(sign)
                placedRadicals.append(sign.origin)
            } else if !sign.isExtension {
                floating.append(sign)
            }
        }
        // Each goes beside the row it belongs to, and a sign placed can bring
        // the next one to its row: the ∑ of "∑∏P", STIX's, stood too far from
        // the P to be beside it until the ∏ was, and made a row of its own
        // with its limits' baseline — too high for its lower limits to join.
        var pending = floating
        // A piece of a bar built tall is placed where the whole bar stands:
        // from its lowest piece. Measured each from its own point, the top
        // pieces of a \big| lifted into an exponent stood a line and a half
        // over the line and made a row of their own, and took the exponent's
        // sum with them.
        var feet: [Int: CGFloat] = [:]
        for glyph in floating where pieces.contains(Place(glyph)) {
            let column = Int((glyph.origin.x * 10).rounded())
            feet[column] = min(feet[column] ?? glyph.origin.y, glyph.origin.y)
        }
        func foot(_ glyph: PDFContentScanner.Glyph) -> CGFloat {
            pieces.contains(Place(glyph)) ? feet[Int((glyph.origin.x * 10).rounded())] ?? glyph.origin.y : glyph.origin.y
        }
        var placedOne = true
        while placedOne {
            placedOne = false
            var at = 0
            while at < pending.count {
                let glyph = pending[at]
                let span = glyph.rect.insetBy(dx: -body * 0.9, dy: 0)
                let nearest = rows.indices
                    .filter { beside(span, rows[$0].glyphs, body: body) }
                    .min { abs(rows[$0].baseline - foot(glyph)) < abs(rows[$1].baseline - foot(glyph)) }
                if let nearest, abs(rows[nearest].baseline - foot(glyph)) < body * 1.3 {
                    rows[nearest].glyphs.append(glyph)
                    pending.remove(at: at)
                    placedOne = true
                } else {
                    at += 1
                }
            }
        }
        for glyph in pending {
            if let index = rows.firstIndex(where: { abs($0.baseline - foot(glyph)) < body * 0.6 }) {
                rows[index].glyphs.append(glyph)
            } else {
                rows.append((glyph.origin.y, [glyph]))
            }
        }
        // The lines of two columns a few points apart are two lines. A row
        // takes every full-size glyph within a little of its baseline across
        // the page and is cut at the gutters only at the end — and until
        // then everything hung on it is measured from its first glyph's
        // baseline, whichever column that was in. The last line of an
        // algorithm in the left column stood five points under a line of
        // prose in the right and took that line's baseline: the fraction
        // and the sum's limit under it stood too far from it to hang from
        // it, and came back as a line of their own. A row whose sides of a
        // gutter stand a quarter of an em apart and more is cut there now,
        // each side with its own baseline. (Sides on one baseline stay one
        // row until the end, as before: a script between them is measured
        // the same either way.)
        let columns = gutters(of: rows.map(\.glyphs), over: glyphs)
        if !columns.isEmpty {
            rows = rows.flatMap { row -> [(baseline: CGFloat, glyphs: [PDFContentScanner.Glyph])] in
                let pieces = split([row.glyphs], at: columns)
                guard pieces.count > 1 else { return [row] }
                // Each side's baseline is the one most of its glyphs stand
                // on — not its highest glyph's: a table's label set on its
                // side has a letter a few points over each row it passes.
                func line(of piece: [PDFContentScanner.Glyph]) -> CGFloat {
                    var counts: [Int: Int] = [:]
                    for glyph in piece where !floats(glyph) && !MathTranscriber.isRadical(glyph) {
                        counts[Int((glyph.origin.y * 10).rounded()), default: 0] += 1
                    }
                    guard let most = counts.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else { return row.baseline }
                    return CGFloat(most.key) / 10
                }
                let lines = pieces.map { (baseline: line(of: $0), glyphs: $0) }
                let heights = lines.map(\.baseline)
                // And a line of the other column is a line of words: the
                // columns of a table have strips of nothing between them
                // too, and a table's row cut there was a column of cells,
                // each read as a formula of its own.
                guard let top = heights.max(), let bottom = heights.min(), top - bottom > body * 0.25,
                      lines.contains(where: { containsProse($0.glyphs) })
                else { return [row] }
                return lines
            }
        }
        // Whether a row has something on a glyph's side of every gutter — a
        // row cut at a gutter is a line of one column now, and a sign of the
        // other column may run through its baseline.
        func sameSide(_ x: CGFloat, _ row: [PDFContentScanner.Glyph]) -> Bool {
            columns.allSatisfy { gutter in row.contains { ($0.rect.midX < gutter) == (x < gutter) } }
        }

        // A big operator, or a piece of a tall delimiter, hangs from a point
        // above its own ink, so where it was *placed* is not the line it was
        // set on. It joins the row whose baseline runs through it.
        // A piece no row runs through — the top of a brace over two cases —
        // joins the piece it stands on: the nearest row was the line of prose
        // over the display, and the brace lost its top, and with it the
        // height of what it holds.
        var hung: [(glyph: PDFContentScanner.Glyph, row: Int)] = []
        var waiting: [PDFContentScanner.Glyph] = []
        for glyph in glyphs.filter({ $0.isExtension && !(MathTranscriber.isRadical($0) && placed($0)) }) {
            let ink = glyph.rect
            let through = rows.indices.filter {
                rows[$0].baseline > ink.minY - 1 && rows[$0].baseline < ink.maxY + 1 && sameSide(ink.midX, rows[$0].glyphs)
            }
            if let nearest = through.min(by: {
                abs(rows[$0].baseline - ink.midY) < abs(rows[$1].baseline - ink.midY)
            }) {
                rows[nearest].glyphs.append(glyph)
                hung.append((glyph, nearest))
            } else {
                waiting.append(glyph)
            }
        }
        func standsOn(_ glyph: PDFContentScanner.Glyph) -> Int? {
            hung.first { other in
                abs(other.glyph.origin.x - glyph.origin.x) < glyph.size * 0.2
                    && other.glyph.rect.maxY > glyph.rect.minY - glyph.size * 0.3
                    && other.glyph.rect.minY < glyph.rect.maxY + glyph.size * 0.3
            }?.row
        }
        var progress = true
        while progress, !waiting.isEmpty {
            progress = false
            for (index, glyph) in waiting.enumerated().reversed() {
                guard let row = standsOn(glyph) else { continue }
                rows[row].glyphs.append(glyph)
                hung.append((glyph, row))
                waiting.remove(at: index)
                progress = true
            }
        }
        // What is left goes where its neighbours go: a \big| lifted into an
        // exponent is nearer the line of prose over the display than the
        // display's own line, but nothing of that prose is anywhere near
        // it, and the r_{ij} it stands against is the display's. The
        // neighbours are asked whatever their size — the rows hold only the
        // full-size glyphs yet, and a sum in an exponent has none of those
        // beside it. And a bar built of pieces goes as one: measured each
        // from its own middle, its top went to that prose and its foot
        // stayed with the formula.
        var stacks: [[PDFContentScanner.Glyph]] = []
        for glyph in waiting.sorted(by: { $0.origin.y < $1.origin.y }) {
            if let at = stacks.firstIndex(where: { stack in
                stack.contains { other in
                    abs(other.origin.x - glyph.origin.x) < glyph.size * 0.2
                        && other.rect.maxY > glyph.rect.minY - glyph.size * 0.3
                        && other.rect.minY < glyph.rect.maxY + glyph.size * 0.3
                }
            }) {
                stacks[at].append(glyph)
            } else {
                stacks.append([glyph])
            }
        }
        for stack in stacks {
            let ink = extent(of: stack)
            guard !rows.isEmpty else { rows.append((ink.midY, stack)); continue }
            // A row of its own column, and near: the rows hold only the
            // full-size glyphs yet, and a formula set \small in a column of
            // ten-point text has none of those. Its \Bigl( and \Bigr) had
            // only the other column's lines anywhere near them, which they
            // joined; with those out of reach, the nearest row of their own
            // column was the theorem's title three lines up. A sign with no
            // row near it is a row of its own, and the formula's glyphs
            // come to it.
            func nearestRow(to y: CGFloat) -> Int? {
                rows.indices.filter { sameSide(ink.midX, rows[$0].glyphs) && abs(rows[$0].baseline - y) < body * 0.85 }
                    .min { abs(rows[$0].baseline - y) < abs(rows[$1].baseline - y) }
            }
            let places = Set(stack.map(Place.init))
            var votes: [Int: Int] = [:]
            // A neighbour is near in height as well — the "end." of the
            // sentence over a display stood right over the display's sum —
            // and only the nearest of them vote: the three letters under a
            // \widetilde were outvoted by the line of prose under them.
            let neighbours = glyphs.filter { glyph in
                !places.contains(Place(glyph)) && !glyph.isExtension
                    && glyph.rect.maxX > ink.minX - body * 0.6 && glyph.rect.minX < ink.maxX + body * 0.6
                    && abs(glyph.origin.y - ink.midY) < body * 1.3
            }
            let closest = neighbours.map { abs($0.origin.y - ink.midY) }.min() ?? 0
            for glyph in neighbours where abs(glyph.origin.y - ink.midY) <= closest + body * 0.3 {
                if let row = nearestRow(to: glyph.origin.y) { votes[row, default: 0] += 1 }
            }
            let most = votes.values.max() ?? 0
            let chosen = votes.filter { $0.value == most }.keys
                .min { abs(rows[$0].baseline - ink.midY) < abs(rows[$1].baseline - ink.midY) }
            if let row = chosen ?? nearestRow(to: ink.midY) {
                rows[row].glyphs += stack
            } else {
                // Centred on the axis, a quarter of an em over the baseline —
                // the row the other bracket of the pair made, if it made one.
                let baseline = ink.midY - body * 0.25
                if let row = rows.indices.first(where: {
                    abs(rows[$0].baseline - baseline) < body * 0.25 && sameSide(ink.midX, rows[$0].glyphs)
                }) {
                    rows[row].glyphs += stack
                } else {
                    rows.append((baseline, stack))
                }
            }
        }

        // Small glyphs hang from the row they are beside, as runs: a script
        // follows what it is on, and a limit is under or over it. Nearness in
        // height alone is not enough — the upper limit of a displayed sum is
        // closer to the line of prose above the display than to the sum, and
        // took itself off to that sentence, a page-width away.
        // Nor does a script stand over the ink of its line's own words:
        // a run of letters that does is another layer — the labels of
        // a figure, level with a line of its caption, came back as the
        // caption's subscripts.
    func layeredRun(_ run: [PDFContentScanner.Glyph], _ row: (baseline: CGFloat, glyphs: [PDFContentScanner.Glyph])) -> Bool {
            func lettered(_ one: PDFContentScanner.Glyph) -> Bool {
                guard one.width > 0.05, !MathTranscriber.isAccent(one) else { return false }
                let spelled = MathTranscriber.spelling(of: one)
                return !spelled.isEmpty && spelled.allSatisfy { $0.isLetter || $0.isNumber }
            }
            let letters = run.filter(lettered)
            guard letters.count >= 2 else { return false }
            // The line's own words round the run — eight letters of the
            // text face within two ems of it, which is a passage of prose
            // and not a formula: the limits under \lim and \max, and a
            // sub-subscript of a wide exponent, stand over the formula's
            // own few letters and are its. Counted round the run, not along
            // the row: before the columns are cut apart a row holds the
            // other column's line too, and its prose let the limits under
            // a \max be taken for a figure's. (Not the scripts already
            // hung from the line: the second row of a \substack stands
            // under the first.)
            let span = extent(of: run)
            let own = onOwnLine(row, body: body).filter { one in
                one.size >= body * 0.9 && lettered(one) && !MathTranscriber.isMathFont(one)
                    && MathTranscriber.spelling(of: one).allSatisfy(\.isLetter)
                    && one.rect.maxX > span.minX - body * 2 && one.rect.minX < span.maxX + body * 2
            }
            guard own.count >= 8 else { return false }
            let over = letters.filter { glyph in
                own.contains { other in
                    min(other.rect.maxX, glyph.rect.maxX) - max(other.rect.minX, glyph.rect.minX)
                        > min(other.width, glyph.width) * 0.5
                }
            }
            return over.count * 2 > letters.count
        }
        // A run of small glyphs that is a line of prose in its own right — a
        // caption, a footnote, a table set smaller than the text — is a
        // line, not a script: a dozen letters of the text face along one
        // baseline, wide as eight of them. Hung as a script, a caption's
        // second line became the subscripts of its first, letter by letter.
        // Such a line takes scripts of its own only from right beside its
        // baseline; the next line of the caption is not one.
        func isLineOfText(_ run: [PDFContentScanner.Glyph], level: CGFloat) -> Bool {
            let letters = run.filter { one in
                guard one.width > 0.05, !MathTranscriber.isAccent(one), !MathTranscriber.isMathFont(one),
                      abs(one.origin.y - level) < one.size * 0.1 else { return false }
                let spelled = MathTranscriber.spelling(of: one)
                return !spelled.isEmpty && spelled.allSatisfy(\.isLetter)
            }
            guard letters.count >= 12 else { return false }
            let size = run.map(\.size).max() ?? body
            let span = extent(of: run)
            // Not the label of a brace, however long: "continual learning
            // excess risk" under an \underbrace is the formula's.
            if rules.contains(where: { rule in
                rule.brace && rule.rect.maxX > span.minX && rule.rect.minX < span.maxX
                    && abs(rule.rect.midY - level) < size * 2.2
            }) { return false }
            return span.width >= size * 8
        }
        var textLines = Set<Int>()
        var unplaced: [(run: [PDFContentScanner.Glyph], level: CGFloat)] = []
        // The brace this run is the label of, if it is one: centred on the
        // brace, on its label side, within a line or two of it. (A label is
        // centred on its brace; the upper limits of the sums in the line
        // below stand on the label's level too, and are not it.)
        func braceLabelled(_ span: CGRect, level: CGFloat) -> PDFContentScanner.Rule? {
            let middle = span.midX
            return rules.first(where: { rule in
                rule.brace && middle > rule.rect.minX && middle < rule.rect.maxX
                    && abs(middle - rule.rect.midX) < max(span.width / 2, body)
                    && (level < rule.rect.midY) == rule.braceLabelBelow
                    && abs(rule.rect.midY - level) < body * 2.5
            })
        }
        for run in smallRuns(glyphs.filter { $0.size < body * 0.9 && !$0.isExtension }, body: body) {
            let largest = run.map(\.size).max() ?? body
            let levels = run.filter { $0.size >= largest * 0.95 }.map(\.origin.y).sorted()
            let level = levels[levels.count / 2]
            let span = extent(of: run)
            if isLineOfText(run, level: level) {
                rows.append((level, run))
                textLines.insert(rows.count - 1)
                continue
            }
            // A brace's label goes with the row the brace braces, below —
            // not with whatever line happens to run beside it: the label
            // under the second term of (7) hung from the line that held the
            // "(7)" and the other column's sentence.
            if braceLabelled(span, level: level) != nil {
                unplaced.append((run, level))
                continue
            }
            let nearest = rows.indices
                .filter {
                    beside(span, rows[$0].glyphs, body: body) && !layeredRun(run, rows[$0])
                        && !(textLines.contains($0) && abs(rows[$0].baseline - level) > largest * 0.6)
                }
                .min { abs(rows[$0].baseline - level) < abs(rows[$1].baseline - level) }
            // Close enough to hang from this row. A glyph further off than
            // this came from the line above or below, clipped by the band.
            // An exponent with a sum in it is lifted higher — TeX raises it
            // clear of the limits hanging under the sum — so a run that
            // starts or ends against a sign that grows, or a tall bracket,
            // may stand a whole line up.
            func againstASign(_ row: [PDFContentScanner.Glyph]) -> Bool {
                row.contains { glyph in
                    guard MathTranscriber.isDelimiter(glyph) || MathTranscriber.isBigOperator(glyph) || glyph.isExtension
                    else { return false }
                    return (span.minX >= glyph.rect.maxX - 1 && span.minX - glyph.rect.maxX < body * 0.5)
                        || (span.maxX <= glyph.rect.minX + 1 && glyph.rect.minX - span.maxX < body * 0.5)
                }
            }
            if let nearest, abs(rows[nearest].baseline - level) < body * (againstASign(rows[nearest].glyphs) ? 1.0 : 0.85) {
                rows[nearest].glyphs += run
            } else {
                unplaced.append((run, level))
            }
        }
        // A limit is its sign's, and goes to its sign's row first. A
        // displayed sum's limits stand a line off — TeX sets them clear of
        // the sign's own height — so nothing nearer took them, and they
        // stood as rows of their own; a formula's rows are gathered again
        // into one block later, but a line with a word on it is not: in a
        // slide's "MC : ∑ⁿᵢ₌₁ (…)²" the label made the line a sentence, the
        // limits were left behind as the lines "n" and "i=1", and the sum
        // came back without them. The next row of a \substack under (or
        // over) a limit goes where that limit went: it stands a line of
        // script further off, centred on the same sign.
        // (Not a brace's label or a run on a line of small text — those have
        // homes of their own, below.)
        // Centred as TeX centres a limit — on the sign's own box, to a point
        // or so. (Only overlapping the sign is how the rows a limit may go
        // to are narrowed; a wide exponent of the next line of a derivation
        // overlapped the sum of the line above, and went to it as a limit.)
        func centred(_ span: CGRect, on other: CGRect, size: CGFloat) -> Bool {
            abs(span.midX - other.midX) < max(1, size * 0.12)
        }
        // Which sign, the ink says where it can: TeX sets a displayed limit
        // a fixed clearance off its sign's own box — about a sixth of an em
        // under it, a fifth over it — and the baseline of the row a sign is
        // on could be a line of the other column's text, a few points off
        // the formula's. Of two equations set one over the other, each with
        // a sum, the first sum's "i=1" touched its own sign and stood an em
        // and a bit over the second; measured from the baselines it was too
        // far from its own row and went to the second sum as a row over its
        // "N_t". The ink is known only for an extension font's sign, drawn
        // from its top; elsewhere the box is a guess at the glyph's height —
        // a display sum from a font of its own came out a line short, and
        // its lower limit went to the next line's sum by it — and the
        // baselines decide, as they did.
        func limit(_ span: CGRect, at level: CGFloat) -> (row: Int, below: Bool)? {
            var best: (row: Int, below: Bool, gap: CGFloat)?
            for row in rows.indices {
                for glyph in rows[row].glyphs
                where glyph.isExtension && MathTranscriber.isBigOperator(glyph)
                    && centred(span, on: glyph.rect, size: glyph.size) {
                    let below = span.midY < glyph.rect.midY
                    let gap = below ? glyph.rect.minY - span.maxY : span.minY - glyph.rect.maxY
                    guard gap > -body * 0.35, gap < body * 0.7 else { continue }
                    if best.map({ gap < $0.gap }) ?? true { best = (row, below, gap) }
                }
            }
            if let best { return (best.row, best.below) }
            guard let sign = sign(of: span, at: level, in: rows, body: body),
                  rows[sign].glyphs.contains(where: { glyph in
                      !glyph.isExtension && MathTranscriber.isBigOperator(glyph)
                          && centred(span, on: glyph.rect, size: glyph.size)
                  })
            else { return nil }
            return (sign, level < rows[sign].baseline)
        }
        var limits: [(row: Int, span: CGRect, level: CGFloat, below: Bool)] = []
        var others: [(run: [PDFContentScanner.Glyph], level: CGFloat)] = []
        for (run, level) in unplaced {
            let span = extent(of: run)
            guard braceLabelled(span, level: level) == nil,
                  !rows.indices.contains(where: { textLines.contains($0) && abs(rows[$0].baseline - level) < body * 0.25 }),
                  let place = limit(span, at: level), !layeredRun(run, rows[place.row])
            else { others.append((run, level)); continue }
            rows[place.row].glyphs += run
            limits.append((place.row, span, level, place.below))
        }
        var moved = true
        while moved {
            moved = false
            others = others.filter { run, level in
                let span = extent(of: run)
                guard braceLabelled(span, level: level) == nil, let limit = limits.first(where: { limit in
                    let step = limit.below ? limit.level - level : level - limit.level
                    return step > 0 && step < body * 1.2
                        && span.maxX > limit.span.minX && span.minX < limit.span.maxX
                        && centred(span, on: limit.span, size: body)
                }), !layeredRun(run, rows[limit.row]) else { return true }
                rows[limit.row].glyphs += run
                limits.append((limit.row, span, level, limit.below))
                moved = true
                return false
            }
        }
        // A part stacked over another small part of a row belongs to it a
        // little further off: the numerator of a fraction inside a fraction
        // in a sentence sits most of a line above it.
        for (run, level) in others {
            let span = extent(of: run)
            let middle = span.midX
            // The label of a brace goes with the row it braces, however
            // far the brace stands from that row — under the limits of
            // the sums in it, a line and a half down.
            if let brace = braceLabelled(span, level: level) {
                // The row it braces is the nearest on its far side with a
                // glyph larger than the label over it — not the second rows
                // of the \substack limits in it, which stand nearer still
                // and are the label's size; a denominator's row is folded
                // into the line afterwards and takes the label along. (Larger
                // than the label, not the page's body: a displayed equation
                // set \small is braced too.)
                let labelSize = run.map(\.size).max() ?? body
                let host = rows.indices.filter { row in
                    (rows[row].baseline > brace.rect.midY) == brace.braceLabelBelow && rows[row].glyphs.contains {
                        $0.size >= labelSize * 1.15 && $0.rect.midX > brace.rect.minX && $0.rect.midX < brace.rect.maxX
                    }
                }.min { abs(rows[$0].baseline - brace.rect.midY) < abs(rows[$1].baseline - brace.rect.midY) }
                if let host {
                    rows[host].glyphs += run
                    continue
                }
            }
            // A line of small text on this run's own baseline is this run's
            // line before anything is: the numbers of a table set small
            // stand on the line of their row's name, and stacked on the row
            // above instead they read letter by letter with its numbers.
            if let line = rows.indices.first(where: {
                textLines.contains($0) && abs(rows[$0].baseline - level) < body * 0.25
            }) {
                rows[line].glyphs += run
                continue
            }
            // A limit is its sign's and nothing else's: the upper limits of a
            // line of a derivation set tight stood under a point from the
            // lower limits of the line above, and went to that line's row.
            let sign = sign(of: span, at: level, in: rows, body: body)
            // Whether the row holds a script this run stands a line of script
            // under, over the same place.
            func secondRow(in row: [PDFContentScanner.Glyph]) -> Bool {
                row.contains { other in
                    other.size < body * 0.9 && other.rect.maxX > span.minX && other.rect.minX < span.maxX
                        && other.origin.y - level > other.size * 0.6 && other.origin.y - level < other.size * 1.6
                }
            }
            let stacked = rows.indices.filter { row in
                if let sign, row != sign { return false }
                if layeredRun(run, rows[row]) { return false }
                let distance = abs(rows[row].baseline - level)
                return (distance < body * 1.05 && !textLines.contains(row) && rows[row].glyphs.contains {
                    $0.size < body * 0.9 && $0.rect.maxX > span.minX && $0.rect.minX < span.maxX
                })
                    // The script of a tall bracket or a sign that grows,
                    // lifted as high as they are tall — STIX's sum lifts
                    // its upper limit a third of an em higher than Computer
                    // Modern's.
                    || (distance < body * 1.5 && rows[row].glyphs.contains { glyph in
                        (MathTranscriber.isDelimiter(glyph) || MathTranscriber.isBigOperator(glyph)
                            || glyph.isExtension)
                            && span.minX >= glyph.rect.maxX - 1 && span.minX - glyph.rect.maxX < body * 0.5
                    })
                    // The second row of a \substack beside a sum in a
                    // sentence, a line of script under the first.
                    || (distance < body * 1.6 && level < rows[row].baseline && secondRow(in: rows[row].glyphs)
                        && rows[row].glyphs.contains { glyph in
                            MathTranscriber.isBigOperator(glyph)
                                && span.minX >= glyph.rect.maxX - 1 && span.minX - glyph.rect.maxX < body * 1.5
                        })
                    // A fraction set in a line stands on the line's axis, its
                    // bar a quarter of an em over the baseline, and the bar
                    // says whose line it is when nothing of the line comes
                    // within reach of its numerator: in "return 1/|P'|
                    // ∑_{p∈P'} |G∩X|/|G|" the second fraction stood clear of
                    // the sum's ink, made a line of its own, and went into
                    // the line above.
                    || (distance < body * 1.6 && rules.contains { rule in
                        guard !rule.brace, middle > rule.rect.minX, middle < rule.rect.maxX else { return false }
                        let lift = rule.rect.midY - rows[row].baseline
                        return lift > body * 0.1 && lift < body * 0.42 && rows[row].glyphs.contains {
                            $0.rect.maxX > rule.rect.minX - body * 1.5 && $0.rect.minX < rule.rect.maxX + body * 1.5
                        }
                    })
                    // Over a bar the row has something under, or under one it
                    // has something over: a numerator of a fraction inside a
                    // fraction, however far up the page it went.
                    || (distance < body * 1.6 && rules.contains { rule in
                        guard !rule.brace, middle > rule.rect.minX, middle < rule.rect.maxX else { return false }
                        let over = level > rule.rect.midY
                        return rows[row].glyphs.contains {
                            $0.rect.midX > rule.rect.minX && $0.rect.midX < rule.rect.maxX
                                && ($0.origin.y > rule.rect.midY) != over
                                && abs($0.origin.y - rule.rect.midY) < body * 1.2
                        }
                    })
            }.min { abs(rows[$0].baseline - level) < abs(rows[$1].baseline - level) }
            if let stacked {
                rows[stacked].glyphs += run
            } else if let level = rows.indices.first(where: {
                abs(rows[$0].baseline - level) < body * 0.25 && sameSide(span.midX, rows[$0].glyphs)
            }) {
                // Nothing to hang from, but a row on the same line: the
                // limits under two sums side by side are one row, as the
                // full-size glyphs of a line are — and the numbers of a
                // table set small stand on the line of their row's name.
                rows[level].glyphs += run
            } else {
                rows.append((level, run))
            }
        }

        let laid = folded(rows.sorted { $0.baseline > $1.baseline }, body: body, rules: rules)
            .map { $0.glyphs.sorted { $0.origin.x < $1.origin.x } }
        let result = gatheringBrackets(split(laid, atGuttersOf: glyphs))
        rowsObserver?(result)
        return result
    }

    /// Told of the rows a page's glyphs were laid in — for a probe. Nil in the app.
    nonisolated(unsafe) static var rowsObserver: (([[PDFContentScanner.Glyph]]) -> Void)?

    /// A bracket built from pieces belongs on its formula's line.
    ///
    /// Each piece goes to the row its own ink runs through, and a line of
    /// the other column can run through one: the top of the tall "(" round a
    /// displayed sum stood level with a line of prose across the gutter and
    /// went to it. Cut at the gutter, it was a line of its own — "() ()" —
    /// and the bracket's foot, left below the formula's line without it,
    /// was read as the subscript of the W before it. A row that holds
    /// nothing but pieces of brackets gives each of them to the row the rest
    /// of its bracket is in. Nothing else moves: the pieces of a brace are
    /// meant to be spread over the rows of its cases.
    private static func gatheringBrackets(_ rows: [[PDFContentScanner.Glyph]]) -> [[PDFContentScanner.Glyph]] {
        func strays(_ row: [PDFContentScanner.Glyph]) -> Bool {
            !row.isEmpty && row.allSatisfy(MathTranscriber.isPiece)
        }
        guard rows.contains(where: strays) else { return rows }
        func touches(_ one: PDFContentScanner.Glyph, _ other: PDFContentScanner.Glyph) -> Bool {
            MathTranscriber.isPiece(other) && abs(one.origin.x - other.origin.x) < one.size * 0.2
                && other.rect.maxY > one.rect.minY - one.size * 0.3
                && other.rect.minY < one.rect.maxY + one.size * 0.3
        }
        var rows = rows
        var moved = true
        while moved {
            moved = false
            for index in rows.indices where strays(rows[index]) {
                var kept: [PDFContentScanner.Glyph] = []
                for piece in rows[index] {
                    // The nearest row, of those not made of pieces alone, that
                    // holds another piece of its bracket.
                    let home = rows.indices.filter { other in
                        other != index && !strays(rows[other]) && rows[other].contains { touches(piece, $0) }
                    }.min { one, other in
                        func gap(_ row: Int) -> CGFloat {
                            rows[row].filter { touches(piece, $0) }.map {
                                max($0.rect.minY - piece.rect.maxY, piece.rect.minY - $0.rect.maxY, 0)
                            }.min() ?? .greatestFiniteMagnitude
                        }
                        return gap(one) < gap(other)
                    }
                    if let home {
                        rows[home].append(piece)
                        rows[home].sort { $0.origin.x < $1.origin.x }
                        moved = true
                    } else {
                        kept.append(piece)
                    }
                }
                rows[index] = kept
            }
        }
        return rows.filter { !$0.isEmpty }
    }

    /// The row whose big operator a run of small glyphs is a limit of:
    /// centred over or under the sign, up to a line and a half over its row
    /// or a line and a bit under.
    private static func sign(
        of span: CGRect, at level: CGFloat,
        in rows: [(baseline: CGFloat, glyphs: [PDFContentScanner.Glyph])], body: CGFloat
    ) -> Int? {
        rows.indices.filter { row in
            let lift = level - rows[row].baseline
            guard (lift > 0 && lift < body * 1.6) || (lift < 0 && -lift < body * 1.4) else { return false }
            return rows[row].glyphs.contains { glyph in
                MathTranscriber.isBigOperator(glyph)
                    && glyph.rect.maxX > span.minX && glyph.rect.minX < span.maxX
                    && abs(span.midX - glyph.rect.midX) < max(span.width, glyph.rect.width) * 0.5 + 1
            }
        }.min { abs(rows[$0].baseline - level) < abs(rows[$1].baseline - level) }
    }

    /// Where a glyph stands, to the hundredth of a point.
    private struct Place: Hashable {
        var x: Int, y: Int
        init(_ glyph: PDFContentScanner.Glyph) {
            x = Int((glyph.origin.x * 100).rounded())
            y = Int((glyph.origin.y * 100).rounded())
        }
    }

    /// The pieces of bars built tall out of several of one bar glyph set
    /// one over another at one place, closer than a line.
    private static func barPieces(in glyphs: [PDFContentScanner.Glyph]) -> Set<Place> {
        var columns: [Int: [PDFContentScanner.Glyph]] = [:]
        for glyph in glyphs where !glyph.isExtension && MathTranscriber.barToken(glyph) != nil {
            columns[Int((glyph.origin.x * 10).rounded()), default: []].append(glyph)
        }
        var found = Set<Place>()
        for column in columns.values where column.count >= 2 {
            let ordered = column.sorted { $0.origin.y < $1.origin.y }
            for (lower, upper) in zip(ordered, ordered.dropFirst())
            where upper.origin.y - lower.origin.y < upper.size * 0.8
                && MathTranscriber.barToken(lower) == MathTranscriber.barToken(upper) {
                found.insert(Place(lower))
                found.insert(Place(upper))
            }
        }
        return found
    }

    /// Small glyphs gathered into the runs they were set in: touching, at
    /// much the same height. The numerator and the denominator of a fraction
    /// in a sentence are two runs; "−x²/2" over an e is one.
    private static func smallRuns(
        _ glyphs: [PDFContentScanner.Glyph], body: CGFloat
    ) -> [[PDFContentScanner.Glyph]] {
        guard !glyphs.isEmpty else { return [] }
        let ordered = glyphs.enumerated().sorted {
            $0.element.origin.y != $1.element.origin.y
                ? $0.element.origin.y > $1.element.origin.y : $0.offset < $1.offset
        }.map(\.element)
        var parent = Array(ordered.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for index in ordered.indices {
            var other = index + 1
            while other < ordered.count, ordered[index].origin.y - ordered[other].origin.y < body * 0.55 {
                let one = ordered[index].rect, two = ordered[other].rect
                let gap = max(one.minX, two.minX) - min(one.maxX, two.maxX)
                if gap < body * 0.5 {
                    let a = root(index), b = root(other)
                    if a != b { parent[max(a, b)] = min(a, b) }
                }
                other += 1
            }
        }
        var runs: [Int: [PDFContentScanner.Glyph]] = [:]
        var order: [Int] = []
        for index in ordered.indices {
            let key = root(index)
            if runs[key] == nil { order.append(key) }
            runs[key, default: []].append(ordered[index])
        }
        return order.map { runs[$0]! }
    }

    /// Whether a run is beside a row: some glyph of the row is over it,
    /// under it, or within a little over half an em of it.
    private static func beside(
        _ span: CGRect, _ row: [PDFContentScanner.Glyph], body: CGFloat
    ) -> Bool {
        row.contains { $0.rect.maxX > span.minX - body * 0.6 && $0.rect.minX < span.maxX + body * 0.6 }
    }

    /// Rows cut apart at the page's gutters.
    ///
    /// Two columns share their baselines, so a line of the left column and a
    /// line of the right are, by height alone, the same row — and a displayed
    /// equation in one column arrives with a sentence from the other running
    /// through it. What separates them is the gutter: a strip of the page with
    /// no ink in it, top to bottom. A row that steps over the gutter — a
    /// title, a figure, a full-width equation — is left whole.
    private static func split(
        _ rows: [[PDFContentScanner.Glyph]], atGuttersOf glyphs: [PDFContentScanner.Glyph]
    ) -> [[PDFContentScanner.Glyph]] {
        split(rows, at: gutters(of: rows, over: glyphs))
    }

    /// Rows cut apart at the given gutters, each only where it keeps clear of one.
    private static func split(
        _ rows: [[PDFContentScanner.Glyph]], at gutters: [CGFloat]
    ) -> [[PDFContentScanner.Glyph]] {
        guard !gutters.isEmpty else { return rows }
        var result: [[PDFContentScanner.Glyph]] = []
        for row in rows {
            var pieces: [[PDFContentScanner.Glyph]] = []
            var rest = row
            for gutter in gutters {
                // Only where this row keeps clear of it.
                guard !rest.contains(where: { $0.rect.minX < gutter && $0.rect.maxX > gutter })
                else { continue }
                let before = rest.filter { $0.rect.maxX <= gutter }
                let after = rest.filter { $0.rect.minX >= gutter }
                guard !before.isEmpty, !after.isEmpty else { continue }
                pieces.append(before)
                rest = after
            }
            pieces.append(rest)
            result += pieces.filter { !$0.isEmpty }
        }
        return result
    }

    /// The x positions where the page has a strip of nothing running down it.
    ///
    /// Judged against the page's own density rather than a fixed number: a
    /// gutter is where far fewer lines reach than reach anywhere else, and how
    /// wide it is depends on the journal. Two columns set tight can leave
    /// barely ten points between them.
    private static func gutters(
        of rows: [[PDFContentScanner.Glyph]], over glyphs: [PDFContentScanner.Glyph]
    ) -> [CGFloat] {
        guard rows.count >= 10, !glyphs.isEmpty else { return [] }
        let left = glyphs.map(\.rect.minX).min() ?? 0
        let right = glyphs.map(\.rect.maxX).max() ?? 0
        guard right - left > 200 else { return [] }

        // A gutter is not a margin, so the edges of the text are left out.
        let from = left + (right - left) * 0.15, to = right - (right - left) * 0.15
        let step: CGFloat = 2
        var samples: [(x: CGFloat, crossings: Int)] = []
        var x = from
        while x <= to {
            samples.append((x, rows.reduce(0) { count, row in
                count + (row.contains { $0.rect.minX < x && $0.rect.maxX > x } ? 1 : 0)
            }))
            x += step
        }
        guard samples.count > 8 else { return [] }

        let ordered = samples.map(\.crossings).sorted()
        let median = ordered[ordered.count / 2]
        // A page with little on it has no gutter worth finding.
        guard median >= 5 else { return [] }
        let quiet = max(1, median / 5)

        var gutters: [CGFloat] = []
        var runStart: CGFloat?
        var runEnd: CGFloat?
        for sample in samples {
            if sample.crossings <= quiet {
                if runStart == nil { runStart = sample.x }
                runEnd = sample.x
                continue
            }
            if let start = runStart, let end = runEnd, end - start >= 8 {
                gutters.append((start + end) / 2)
            }
            runStart = nil
            runEnd = nil
        }
        if let start = runStart, let end = runEnd, end - start >= 8 {
            gutters.append((start + end) / 2)
        }
        return gutters
    }


    /// Rows that are only part of a line, folded into the line they belong to.
    ///
    /// A numerator sits above its own baseline, which puts it nearer the line
    /// above than the line it is part of; a row of limits and a row of tall
    /// superscripts do the same. What settles it is that type never overlaps.
    /// The line a fragment belongs to is the one it fits into — the one with
    /// no ink at those x positions — and the line above has ink there,
    /// because it is a line.
    private static func folded(
        _ rows: [(baseline: CGFloat, glyphs: [PDFContentScanner.Glyph])], body: CGFloat,
        rules: [PDFContentScanner.Rule] = []
    ) -> [(baseline: CGFloat, glyphs: [PDFContentScanner.Glyph])] {
        guard rows.count > 1 else { return rows }
        var rows = rows
        var index = 0
        while index < rows.count {
            let row = rows[index]
            let span = extent(of: row.glyphs)
            let neighbours = [index - 1, index + 1].filter { rows.indices.contains($0) }
            // A row of limits folds into its sign's line or into none: the
            // upper limit of a derivation's third line, alone and a point
            // from the lower limits of the second, fitted in beside them.
            let limitOf = row.glyphs.allSatisfy { $0.size < body * 0.8 }
                ? sign(of: span, at: row.baseline, in: rows, body: body) : nil
            let host = neighbours.filter { other in
                if let limitOf, other != limitOf { return false }
                let theirs = extent(of: rows[other].glyphs)
                // Only a fragment folds, and only into a line it is part of.
                // The pieces of a tall bracket stand where the bracket does,
                // over and under the line's own: that is no second line.
                let own = row.glyphs.filter {
                    !MathTranscriber.isPiece($0) && MathTranscriber.barToken($0) == nil
                        && !MathTranscriber.spelling(of: $0).isEmpty
                }
                // Measured from the row, or from where the line's own glyphs
                // stand: the top of an OpenType bracket, drawn from a point
                // off the line, can be what began the row.
                let distance = min(abs(rows[other].baseline - row.baseline),
                                   abs(context(of: rows[other].glyphs).baseline - row.baseline))
                // Over or under what the line already folded in — the
                // numerator over a denominator still looking for a home —
                // only with a bar between them: without one the two are two
                // lines, and folded they read letter for letter through each
                // other. (A fraction whose bar is drawn as a stroke and not
                // a filled rule is beyond this, as it was.)
                let folded = rows[other].glyphs.filter { abs($0.origin.y - rows[other].baseline) >= body * 0.25 }
                let barred = !collides(own, folded) || rules.contains { rule in
                    let (low, high) = row.baseline < rows[other].baseline
                        ? (row.baseline, folded.map(\.origin.y).max() ?? rows[other].baseline)
                        : (folded.map(\.origin.y).min() ?? rows[other].baseline, row.baseline)
                    return rule.rect.midY > low && rule.rect.midY < high
                        && rule.rect.maxX > span.minX && rule.rect.minX < span.maxX
                }
                // A row of scripts — small type, and the bars and brackets
                // sized to it — reaches a full em: Fira Math lifts an
                // exponent 0.91 em, and the exponent of an inline e was a
                // display of its own above the sentence.
                let scripts = row.glyphs.allSatisfy {
                    $0.size < body * 0.8 || MathTranscriber.barToken($0) != nil || MathTranscriber.isDelimiter($0)
                }
                return span.width < theirs.width * 0.75
                    && distance < body * (scripts ? 1.0 : 0.9)
                    && beside(span, rows[other].glyphs, body: body)
                    && !collides(own, onOwnLine(rows[other], body: body))
                    && barred
            }.min { abs(rows[$0].baseline - row.baseline) < abs(rows[$1].baseline - row.baseline) }
            guard let host else { index += 1; continue }
            rows[host].glyphs += row.glyphs
            rows.remove(at: index)
            // The host may itself be a fragment of the line beyond it, so it
            // is looked at again from wherever it now sits.
            index = min(host, index)
        }
        return rows
    }

    /// The glyphs a row was set on its own baseline — not the fragments that
    /// have been folded into it. A numerator folded in sits directly over the
    /// denominator still looking for a home, and asking whether they overlap
    /// would answer that a fraction is two different lines.
    private static func onOwnLine(
        _ row: (baseline: CGFloat, glyphs: [PDFContentScanner.Glyph]), body: CGFloat
    ) -> [PDFContentScanner.Glyph] {
        row.glyphs.filter { abs($0.origin.y - row.baseline) < body * 0.25 }
    }

    private static func extent(of glyphs: [PDFContentScanner.Glyph]) -> CGRect {
        guard let first = glyphs.first else { return .zero }
        return glyphs.dropFirst().reduce(first.rect) { $0.union($1.rect) }
    }

    /// Whether two rows have ink at the same x — which two rows of one line
    /// never do, and two lines of a paragraph always do.
    ///
    /// It is a count, not a single hit: what a glyph carries is an advance,
    /// not its ink, so a superscript and the letter after it can be recorded
    /// as touching when nothing is drawn in the same place. One or two of
    /// those is kerning. Most of a row is another line.
    private static func collides(
        _ one: [PDFContentScanner.Glyph], _ other: [PDFContentScanner.Glyph]
    ) -> Bool {
        guard !one.isEmpty, !other.isEmpty else { return false }
        let theirs = other.map { ($0.rect.minX, $0.rect.maxX) }.sorted { $0.0 < $1.0 }
        var hits = 0
        for glyph in one {
            let slack = min(glyph.rect.width, 2) * 0.5
            let low = glyph.rect.minX + slack, high = glyph.rect.maxX - slack
            guard low < high else { continue }
            // The first of theirs that could reach this glyph.
            var start = theirs.count
            var lo = 0, hi = theirs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if theirs[mid].1 > low { start = mid; hi = mid } else { lo = mid + 1 }
            }
            if start < theirs.count, theirs[start].0 < high { hits += 1 }
        }
        return Double(hits) > Double(one.count) * 0.2
    }

    /// One row of prose.
    ///
    /// Words are rebuilt from what the page drew, because that is the only way
    /// to get the mathematics right. Where a word contains a glyph this cannot
    /// read — a ligature from a font that names nothing — the word is taken
    /// from PDFKit instead, which has the file's own idea of what it spells.
    /// Borrowing a whole word is safe in a way that borrowing one glyph is
    /// not: a word is contiguous in the page's text, and a single glyph is
    /// matched by position, which is where it goes wrong.
    private static func read(
        _ row: [PDFContentScanner.Glyph],
        rules: [PDFContentScanner.Rule],
        characters: [PageCharacter],
        text: NSString
    ) -> String {
        let context = context(of: row)
        // Only this line's characters are worth searching: borrowing a word's
        // spelling means matching boxes against boxes, and matching against
        // the whole page's is most of the cost of a copy.
        let band = extent(of: row)
        let characters = characters.filter {
            $0.rect.maxY > band.minY && $0.rect.minY < band.maxY
        }
        var words = keepingRadicands(words(in: row, body: context.bodySize), rules: rules)
        // A name set upright a thin space before the bracket of the formula
        // it is applied to is the formula's: "Laplace $\bigl(E\bigr)$" is
        // $\mathrm{Laplace}\bigl(E\bigr)$.
        var joined = 0
        while joined + 1 < words.count {
            if !isFormula(words[joined], at: joined, in: words, context: context, rules: rules),
               isFormula(words[joined + 1], at: joined + 1, in: words, context: context, rules: rules),
               appliesTo(words[joined], next: words[joined + 1], body: context.bodySize) {
                words[joined + 1] = words[joined] + words[joined + 1]
                words.remove(at: joined)
                continue
            }
            joined += 1
        }
        var pieces: [Word] = []
        func prose(_ word: [PDFContentScanner.Glyph], tight: Bool = false) -> Word {
            let spelled = word.map { inProse(MathTranscriber.spelling(of: $0)) }
            if spelled.contains(where: \.isEmpty),
               let borrowed = spelling(of: word, from: characters, text: text),
               agrees(borrowed, with: spelled) {
                return Word(isMath: false, text: borrowed, tight: tight)
            }
            return Word(isMath: false, text: composed(spelled.joined()), tight: tight)
        }
        let formulas = words.indices.map {
            isFormula(words[$0], at: $0, in: words, context: context, rules: rules)
        }
        for (position, word) in words.enumerated() {
            guard formulas[position] else {
                pieces.append(prose(word))
                continue
            }
            // The text face's punctuation after a formula ends the sentence —
            // unless a formula follows it across no more than a thin space:
            // Fourier and the tx fonts draw a formula's own commas from the
            // text face, and TeX spaces them as punctuation, not as words.
            let next = position + 1
            let continued = next < words.count && formulas[next]
                && (words[next].map(\.rect.minX).min() ?? 0)
                    - (word.map(\.rect.maxX).max() ?? 0) < context.bodySize * 0.25
            let (lead, core, trail) = continued ? ([], word, []) : peeled(word)
            if !lead.isEmpty { pieces.append(prose(lead)) }
            // Left out when most of it cannot be read (see `pieces`).
            let unread = core.filter(MathTranscriber.isUnreadable).count
            if unread * 4 > core.count {
                skippedFormulas += 1
                continue
            }
            let latex = MathTranscriber.latex(glyphs: core, rules: rules, context: context)
            if !latex.isEmpty { pieces.append(Word(isMath: true, text: latex, tight: !lead.isEmpty)) }
            if !trail.isEmpty { pieces.append(prose(trail, tight: true)) }
        }
        return assemble(unbracketed(merged(pieces)))
    }

    /// Words put back together under the roof of a radical: TeX spaces the
    /// "+" in \\sqrt{x^2+y^2} as it would anywhere, and cut there, the
    /// radical held only the x².
    private static func keepingRadicands(
        _ words: [[PDFContentScanner.Glyph]], rules: [PDFContentScanner.Rule]
    ) -> [[PDFContentScanner.Glyph]] {
        let roofs = rules.filter { rule in
            words.contains { word in
                word.contains { glyph in
                    MathTranscriber.isRadical(glyph) && abs(rule.rect.minX - glyph.rect.maxX) < max(1, glyph.size * 0.15)
                }
            }
        }
        guard !roofs.isEmpty else { return words }
        var result: [[PDFContentScanner.Glyph]] = []
        for word in words {
            if let last = result.last, let roof = roofs.first(where: { roof in
                last.contains { MathTranscriber.isRadical($0) && $0.rect.maxX <= roof.rect.minX + 1 }
                    && word.contains { $0.rect.midX > roof.rect.minX && $0.rect.midX < roof.rect.maxX }
            }) {
                _ = roof
                result[result.count - 1] += word
            } else {
                result.append(word)
            }
        }
        return result
    }

    /// One word of a row as it will be written: mathematics or not, and
    /// whether it follows the one before without a space.
    private struct Word {
        var isMath: Bool
        var text: String
        var tight = false
    }

    /// Whether a word of a row is mathematics.
    ///
    /// A word with a glyph from a maths font in it is, and so is one with a
    /// subscript Word set on the line. On a page that sets its variables in
    /// the text face's italic, so is an italic letter with a script on it,
    /// and an italic letter standing alone between words that are not in
    /// italics — "for each *i*" — which an emphasised sentence is not.
    private static func isFormula(
        _ word: [PDFContentScanner.Glyph], at position: Int, in words: [[PDFContentScanner.Glyph]],
        context: MathTranscriber.Context, rules: [PDFContentScanner.Rule]
    ) -> Bool {
        let body = context.bodySize
        if word.contains(where: MathTranscriber.isMathFont)
            || MathTranscriber.hasWordSubscript(word, body: body) { return true }
        // Something set small right over or under a glyph at the line's size
        // is a formula whatever its face: a sentence never stacks its
        // letters, and \overset{\text{def}}{=} is all roman — "a d=ef b".
        if word.contains(where: { small in
            small.size < body * 0.92 && word.contains { full in
                full.size >= body * 0.92
                    && min(small.rect.maxX, full.rect.maxX) - max(small.rect.minX, full.rect.minX) > small.width * 0.5
                    && abs(small.origin.y - full.origin.y) > body * 0.35
            }
        }) { return true }
        // A name with a script on it — "log₂", "sin²" — is a formula whatever
        // face it is set in.
        let letters = word.filter { $0.size >= body * 0.92 }
        let lead = letters.prefix { MathTranscriber.isUprightLetter($0) }
        if !lead.isEmpty, MathTranscriber.isOperatorName(lead.map(MathTranscriber.spelling(of:)).joined()),
           word.contains(where: { $0.size < body * 0.92 && abs($0.origin.y - context.baseline) > body * 0.08 }) {
            return true
        }
        guard MathTranscriber.variablesInTextItalic,
              word.contains(where: isTextVariable) else { return false }
        let full = word.filter { $0.size >= body * 0.92 && !MathTranscriber.isAccent($0) }
        // Every run of italic letters in it is a variable or two, not a word:
        // "f(x)" and "Pr[X" are formulas, "(sketch)" is not.
        if longestItalicRun(full) > 2 { return false }
        let scripted = word.contains {
            $0.size < body * 0.92 && abs($0.origin.y - context.baseline) > body * 0.08
        }
        if scripted, full.count <= 3 { return true }
        // Over and under a bar: a fraction.
        if rules.contains(where: { rule in
            word.contains { $0.rect.midX > rule.rect.minX && $0.rect.midX < rule.rect.maxX && $0.origin.y > rule.rect.midY }
                && word.contains { $0.rect.midX > rule.rect.minX && $0.rect.midX < rule.rect.maxX && $0.origin.y < rule.rect.midY }
        }) { return true }
        let marks = full.map(MathTranscriber.spelling(of:))
        if marks.contains(where: { ["(", ")", "[", "]", "|", "=", "+", ",", "\\{", "\\}"].contains($0) }) {
            return true
        }
        // A variable or two standing alone between words that are not in
        // italics — "for each *i*", "*Wx*" — which an emphasised sentence,
        // and a short English word set in italics, are not.
        guard full.count <= 2, full.allSatisfy({
            MathTranscriber.spelling(of: $0).first?.isLetter == true || MathTranscriber.isTextSymbol($0)
        }), !commonShortWords.contains(marks.joined().lowercased())
        else { return false }
        // Stressed: a word of three italic letters or more, or a short
        // English one — not "dx", which is the formula going on.
        func emphasised(_ at: Int) -> Bool {
            guard words.indices.contains(at) else { return false }
            let letters = words[at].filter { $0.size >= body * 0.92 }
            if longestItalicRun(letters) >= 3 { return true }
            let spelled = letters.map(MathTranscriber.spelling(of:)).joined().lowercased()
            return letters.allSatisfy(MathTranscriber.isItalicLetter) && commonShortWords.contains(spelled)
        }
        return !emphasised(position - 1) && !emphasised(position + 1)
    }

    /// The longest run of italic letters in a row of glyphs.
    private static func longestItalicRun(_ glyphs: [PDFContentScanner.Glyph]) -> Int {
        var longest = 0, run = 0
        for glyph in glyphs {
            run = MathTranscriber.isItalicLetter(glyph) ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }

    /// English words of two letters, which a paper sets in italics to stress
    /// them and never means as a product of two variables.
    private static let commonShortWords: Set<String> = [
        "an", "as", "at", "be", "by", "do", "et", "al", "go", "he", "if", "in", "is", "it",
        "me", "my", "no", "of", "on", "or", "so", "to", "up", "us", "we", "vs", "cf", "eg", "ie",
    ]

    /// A formula word with the sentence's punctuation taken off its end: the
    /// full stops and commas the text face set after it. (A bracket is only
    /// the sentence's once the formula is whole — see `unbracketed`.)
    private static func peeled(
        _ word: [PDFContentScanner.Glyph]
    ) -> (lead: [PDFContentScanner.Glyph], core: [PDFContentScanner.Glyph], trail: [PDFContentScanner.Glyph]) {
        var core = word[...]
        var trail: [PDFContentScanner.Glyph] = []
        func textual(_ glyph: PDFContentScanner.Glyph, _ marks: Set<String>) -> Bool {
            !MathTranscriber.isMathFont(glyph) && marks.contains(MathTranscriber.spelling(of: glyph))
        }
        func balance(_ glyphs: ArraySlice<PDFContentScanner.Glyph>) -> Int {
            glyphs.reduce(0) { count, glyph in
                let spelled = MathTranscriber.spelling(of: glyph)
                return count + (["(", "["].contains(spelled) ? 1 : [")", "]"].contains(spelled) ? -1 : 0)
            }
        }
        // Only at the line's size: the full stop of "a.s." over an arrow is
        // the label's.
        let largest = word.map(\.size).max() ?? 0
        while core.count > 1, let last = core.last, textual(last, [".", ",", ";", ":"]),
              last.size >= largest * 0.92 {
            trail.insert(last, at: 0)
            core = core.dropLast()
        }
        // The sentence's apostrophe and the letter after it, in the text
        // face: "Yᵢ’s" is $Y_i$'s, not $Y_i'\mathrm{s}$ — a prime is the
        // maths font's, and this is not one.
        if let apostrophe = core.lastIndex(where: { textual($0, ["'", "\u{2019}"]) }),
           apostrophe > core.startIndex, core[..<apostrophe].contains(where: MathTranscriber.isMathFont) {
            let after = core[core.index(after: apostrophe)...]
            if after.count <= 2, after.allSatisfy({ glyph in
                !MathTranscriber.isMathFont(glyph) && MathTranscriber.spelling(of: glyph).allSatisfy(\.isLetter)
                    && !MathTranscriber.spelling(of: glyph).isEmpty
            }) {
                trail = Array(core[apostrophe...]) + trail
                core = core[..<apostrophe]
            }
        }
        _ = balance
        return ([], Array(core), trail)
    }

    /// The size a line is mostly set in, and where its baseline runs.
    ///
    /// A word is read against the line it came from, not against itself: on
    /// its own, a sum followed by four small glyphs looks like a formula set
    /// entirely in seven point, and then nothing in it is a subscript.
    private static func context(
        of row: [PDFContentScanner.Glyph]
    ) -> MathTranscriber.Context {
        // The largest size on the row, not the commonest. Nothing on a line
        // is set larger than the line — scripts and limits are only ever
        // smaller — so the largest is the body, even when a single glyph is
        // all there is of it. The denominator row of a display can be one "L"
        // and six little glyphs from the limits under the sums, and taking
        // the commonest size would put its baseline down among the limits.
        // The signs that grow to fit — a sum, a tall bracket — are left out:
        // mathptmx sets a displayed sum in fourteen point.
        // So are the pieces of a tall bracket that draw nothing of their own.
        var ordinary = row.filter {
            !$0.isExtension && !MathTranscriber.isBigOperator($0) && !MathTranscriber.isDelimiter($0)
                && !MathTranscriber.spelling(of: $0).isEmpty
        }
        // Save one: a drop cap, the paragraph's first letter set three lines
        // tall, stands on its first line's baseline and is no size of that
        // line's — measured against it, the whole line was a subscript of
        // it, "\mathbf{A}_{\mathrm{are}}". One letter alone at its size, a
        // line of glyphs under half of it, and the line going on right after
        // it. (Not a digit of the arXiv stamp in the margin, which stands
        // an inch from the line it lands in.)
        if let top = ordinary.map(\.size).max(), ordinary.filter({ $0.size >= top * 0.92 }).count == 1,
           let cap = ordinary.first(where: { $0.size >= top * 0.92 }),
           MathTranscriber.spelling(of: cap).count == 1, MathTranscriber.spelling(of: cap).first?.isLetter == true,
           let next = ordinary.map(\.size).filter({ $0 < top * 0.5 }).max(),
           ordinary.filter({ $0.size >= next * 0.92 && $0.size < top * 0.5 }).count >= 3,
           ordinary.contains(where: {
               $0.size < top * 0.5 && $0.rect.minX >= cap.rect.maxX - 1 && $0.rect.minX - cap.rect.maxX < next
           }) {
            ordinary.removeAll { $0.size >= top * 0.92 }
        }
        let body = ordinary.map(\.size).max() ?? row.filter { !$0.isExtension }.map(\.size).max()
            ?? row.map(\.size).max() ?? 10
        let full = ordinary.filter { $0.size >= body * 0.92 }
        let sample = (full.isEmpty ? row : full).map(\.origin.y).sorted()
        return MathTranscriber.Context(bodySize: body, baseline: sample[sample.count / 2])
    }

    /// The relations and operators a formula is held together by. A line of
    /// prose does not open with one, so finding one between two formulas
    /// means the three were one formula all along. Computer Modern draws
    /// "=", "+" and ":" from its text face, so they arrive as prose.
    private static let joiners: Set<String> = [
        "=", "+", "-", "<", ">", ":", "/", "\\leq", "\\geq", "\\neq", "\\approx",
        "\\sim", "\\equiv", "\\to", "\\in", "\\cdot", "\\times", "\\pm",
        "\\backslash", "\\setminus",
    ]

    /// What a formula can end with and still be waiting for more — a
    /// relation or an operator — so that the number after it is its own.
    private static let openEnds: [String] = [
        "=", "+", "-", "<", ">", ":", "/", "\\leq", "\\geq", "\\neq", "\\approx", "\\sim",
        "\\simeq", "\\equiv", "\\to", "\\rightarrow", "\\leftarrow", "\\mapsto", "\\in",
        "\\notin", "\\cdot", "\\times", "\\pm", "\\mp", "\\div", "\\ll", "\\gg",
        "\\propto", "\\le", "\\ge", "\\ne", "\\ast", "\\circ", "\\Rightarrow",
        "\\Leftarrow", "\\Leftrightarrow", "\\coloneqq",
    ]

    private static func isNumber(_ text: String) -> Bool {
        text.range(of: #"^[0-9]+([.,][0-9]+)?$"#, options: .regularExpression) != nil
    }

    private static func endsOpen(_ latex: String) -> Bool {
        let trimmed = latex.trimmingCharacters(in: .whitespaces)
        return openEnds.contains { trimmed.hasSuffix($0) }
    }

    private static func startsOpen(_ latex: String) -> Bool {
        let trimmed = latex.trimmingCharacters(in: .whitespaces)
        return openEnds.contains { trimmed.hasPrefix($0) }
    }

    /// Puts a formula back together where the spaces cut it up. TeX sets thin
    /// spaces around a relation, which look exactly like word spaces, so
    /// "x = y" arrives as three words and has to be rejoined. A name set in
    /// roman beside a formula — "arg" before "\min_w" — is part of it, and
    /// so is a number that a relation in it is waiting for: Computer Modern
    /// draws its digits from the text face, and "= 1" was left outside.
    private static func merged(_ pieces: [Word]) -> [Word] {
        var pieces = pieces
        for index in pieces.indices where !pieces[index].isMath {
            let word = pieces[index].text
            let before = index > 0 && pieces[index - 1].isMath
            let after = index + 1 < pieces.count && pieces[index + 1].isMath
            // "x_1, . . . , x_n": the dots, and the comma before them.
            if word.count >= 2, word.allSatisfy({ $0 == "." }) {
                let comma = index > 1 && pieces[index - 1].text == "," && pieces[index - 2].isMath
                if before || after || comma {
                    pieces[index] = Word(isMath: true, text: "\\ldots")
                    if comma { pieces[index - 1].isMath = true }
                }
                continue
            }
            if MathTranscriber.isOperatorName(word), before || after, !pieces[index].tight {
                pieces[index] = Word(isMath: true, text: "\\" + word)
            } else if isNumber(word), !pieces[index].tight {
                let joined = index >= 2 && !pieces[index - 1].isMath
                    && joiners.contains(pieces[index - 1].text) && pieces[index - 2].isMath
                let joining = index + 2 < pieces.count && !pieces[index + 1].isMath
                    && joiners.contains(pieces[index + 1].text) && pieces[index + 2].isMath
                if (before && endsOpen(pieces[index - 1].text))
                    || (after && startsOpen(pieces[index + 1].text)) || joined || joining {
                    pieces[index] = Word(isMath: true, text: word)
                }
            }
        }
        // A bracket the formula opened and the sentence's face closed — the
        // ")" of "\exp(-\lambda t)" in a paper set in Utopia, which sits a
        // word space's worth of italic correction away — is the formula's.
        func balance(_ text: String) -> Int {
            text.reduce(0) { $0 + ("([".contains($1) ? 1 : ")]".contains($1) ? -1 : 0) }
        }
        for index in pieces.indices where !pieces[index].isMath {
            let word = pieces[index].text
            if [")", "]"].contains(word), index > 0, pieces[index - 1].isMath,
               balance(pieces[index - 1].text) > 0 {
                pieces[index].isMath = true
                pieces[index].tight = false
            } else if ["(", "["].contains(word), index + 1 < pieces.count, pieces[index + 1].isMath,
                      balance(pieces[index + 1].text) < 0 {
                pieces[index].isMath = true
                pieces[index + 1].tight = false
            }
        }
        var result: [Word] = []
        for piece in pieces {
            if piece.isMath, !piece.tight, result.count >= 2,
               joiners.contains(result[result.count - 1].text), !result[result.count - 1].tight,
               result[result.count - 2].isMath {
                let joiner = result.removeLast().text
                var first = result.removeLast()
                first.text = "\(first.text) \(joiner) \(piece.text)"
                result.append(first)
            } else if piece.isMath, !piece.tight, var last = result.last, last.isMath {
                result.removeLast()
                last.text += spacer(after: last.text, before: piece.text) + piece.text
                result.append(last)
            } else {
                result.append(piece)
            }
        }
        return result
    }

    /// Whether two halves of one formula need a space between them. A comma
    /// that lost its formula does not; a variable that lost its formula does.
    private static func spacer(after first: String, before second: String) -> String {
        if let last = first.last, "([{_^".contains(last) { return "" }
        if let next = second.first, ",;:.)]}!?".contains(next) { return "" }
        return " "
    }

    /// A bracket the sentence opened or closed round a formula, given back to
    /// the sentence: "($x$, $y$)" and not "$(x$, $y)$". Only a bracket the
    /// formula has no partner for goes; "[0, 1)" keeps both of its own.
    private static func unbracketed(_ pieces: [Word]) -> [Word] {
        var result: [Word] = []
        for var piece in pieces {
            guard piece.isMath else { result.append(piece); continue }
            func balance(_ text: String) -> Int {
                text.reduce(0) { $0 + ("([".contains($1) ? 1 : ")]".contains($1) ? -1 : 0) }
            }
            var trailing: [Word] = []
            while let last = piece.text.last, ")]".contains(last), balance(piece.text) < 0,
                  piece.text.count > 1 {
                piece.text.removeLast()
                trailing.insert(Word(isMath: false, text: String(last), tight: true), at: 0)
            }
            while let first = piece.text.first, "([".contains(first), balance(piece.text) > 0,
                  piece.text.count > 1 {
                piece.text.removeFirst()
                result.append(Word(isMath: false, text: String(first), tight: piece.tight))
                piece.tight = true
            }
            piece.text = piece.text.trimmingCharacters(in: .whitespaces)
            result.append(piece)
            result += trailing
        }
        return result
    }

    private static func assemble(_ pieces: [Word]) -> String {
        var out = ""
        for piece in pieces {
            let text = piece.isMath ? "$\(piece.text)$" : piece.text
            if !out.isEmpty, !piece.tight { out += " " }
            out += text
        }
        return out
    }

    /// TeX sets an accent and its letter as two glyphs, the mark first and the
    /// letter under it, and on a dotless "i" at that. Put back together the
    /// way it looks, "na¨ıve" is "naïve".
    private static func composed(_ text: String) -> String {
        guard text.contains(where: { marks[$0] != nil }) else { return text }
        var result = ""
        var pending: Character?
        for character in text {
            if let mark = marks[character] {
                pending = mark
                continue
            }
            // The dot came off the "i" to make room for the accent.
            let letter: Character = pending == nil ? character
                : (character == "\u{0131}" ? "i" : character == "\u{0237}" ? "j" : character)
            result.append(letter)
            if let mark = pending { result.append(mark); pending = nil }
        }
        if let mark = pending { result.append(mark) }
        return result.precomposedStringWithCanonicalMapping
    }

    /// A glyph's spelling in a sentence. The letters TeX's text fonts keep
    /// outside ASCII are letters there, not the commands a formula writes
    /// for them: «ï» is a dotless i under an accent, and spelled `\imath`
    /// the accent landed on its backslash — «na\̈imathve», «del R\́imatho».
    private static func inProse(_ spelling: String) -> String {
        textLetters[spelling] ?? spelling
    }

    private static let textLetters: [String: String] = [
        "\\imath": "\u{0131}", "\\jmath": "\u{0237}", "\\ss": "ß", "\\ae": "æ", "\\oe": "œ", "\\o": "ø",
        "\\AE": "Æ", "\\OE": "Œ", "\\O": "Ø",
    ]

    /// The marks a text font draws on their own, and what they are as
    /// combining characters. The ASCII lookalikes — "^", "~", "`" — are left
    /// out: in a sentence those are themselves.
    private static let marks: [Character: Character] = [
        "\u{00A8}": "\u{0308}", "\u{02C6}": "\u{0302}", "\u{02DC}": "\u{0303}",
        "\u{00AF}": "\u{0304}", "\u{02D9}": "\u{0307}", "\u{02C7}": "\u{030C}",
        "\u{00B4}": "\u{0301}", "\u{02DA}": "\u{030A}", "\u{02DD}": "\u{030B}",
        "\u{00B8}": "\u{0327}", "\u{02D8}": "\u{0306}",
    ]

    /// A row split where the spaces are.
    private static func words(
        in row: [PDFContentScanner.Glyph], body: CGFloat
    ) -> [[PDFContentScanner.Glyph]] {
        var words: [[PDFContentScanner.Glyph]] = []
        var spaced = false
        for glyph in row {
            // Word and every "Save as PDF" draw their spaces as glyphs, so
            // nothing between two words is a gap: a whole justified line came
            // back as one word, and one subscript in it made the line a
            // formula. TeX draws no spaces, so this changes nothing there.
            if isSpace(glyph) {
                spaced = true
                continue
            }
            // Dots in a row are one thing, however TeX spaced them: \ldots
            // set in a text face is three full stops a thin space apart.
            if let word = words.last, let last = word.last, !spaced,
               MathTranscriber.spelling(of: glyph) == ".", word.allSatisfy({ MathTranscriber.spelling(of: $0) == "." }),
               glyph.rect.minX - last.rect.maxX < body * 0.3 {
                words[words.count - 1].append(glyph)
                continue
            }
            // The gap is from the end of everything so far, not from the last
            // glyph: the root of \sqrt[3]{x} sits inside the radical sign,
            // and measured from it the radicand was a word away.
            if let word = words.last,
               let last = word.filter({ $0.width > 0.05 }).max(by: { $0.rect.maxX < $1.rect.maxX })
                ?? word.last,
               !spaced, !isGap(between: last, and: glyph, body: body) {
                words[words.count - 1].append(glyph)
            } else {
                words.append([glyph])
            }
            spaced = false
        }
        return words
    }

    /// A glyph that draws a space (`MathTranscriber.isSpace`).
    static func isSpace(_ glyph: PDFContentScanner.Glyph) -> Bool {
        MathTranscriber.isSpace(glyph)
    }

    /// Whether a word borrowed from PDFKit spells the letters this could read
    /// on its own, in their order. PDFKit's text and its character boxes do
    /// not always agree — on a page of an MDPI paper made in Word every box
    /// was paired with a letter from a line earlier — and a borrowed word
    /// that disagrees with the glyphs is from somewhere else: "um value be-"
    /// arrived in a note for "The reduction factor".
    private static func agrees(_ borrowed: String, with spelled: [String]) -> Bool {
        let known = spelled.joined().filter { $0.isLetter || $0.isNumber }
        guard !known.isEmpty else { return true }
        var remaining = Substring(borrowed.filter { $0.isLetter || $0.isNumber })
        for character in known {
            guard let at = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: at)...]
        }
        return true
    }

    /// What PDFKit says the word is: the characters its glyphs sit on, in the
    /// page's own order.
    private static func spelling(
        of word: [PDFContentScanner.Glyph], from characters: [PageCharacter], text: NSString
    ) -> String? {
        let span = word.reduce(word[0].rect) { $0.union($1.rect) }
        let covered = characters.filter { character in
            let overlap = character.rect.intersection(span)
            guard !overlap.isNull else { return false }
            return overlap.width * overlap.height
                > character.rect.width * character.rect.height * 0.5
        }
        guard let from = covered.map(\.index).min(), let to = covered.map(\.index).max(),
              to >= from, to < text.length, to - from < 64
        else { return nil }
        let spelled = text.substring(with: NSRange(location: from, length: to - from + 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return spelled.isEmpty ? nil : spelled
    }

    /// A gap wide enough to be a word space rather than the space inside a
    /// formula. TeX never draws a space — it just moves along — so the spaces
    /// have to be put back from the distances.
    ///
    /// Letters inside a word are set touching, and a word space is about a
    /// quarter of an em, so in prose almost any gap is a space. A formula is
    /// different: it is full of deliberate thin spaces that are not word
    /// breaks, so where mathematics is involved it takes a wider gap to count
    /// as one.
    private static func isGap(
        between first: PDFContentScanner.Glyph, and second: PDFContentScanner.Glyph,
        body: CGFloat
    ) -> Bool {
        let width = second.rect.minX - first.rect.maxX
        guard width > 0 else { return false }
        // A formula's glyph beside a word of the sentence's is spaced as words
        // are, and some faces set a word space narrower than TeX's widest
        // space inside a formula: "Inline: W" was one word in Libertine.
        let mathematical = MathTranscriber.isMathFont(first) || MathTranscriber.isMathFont(second)
        let small = min(first.size, second.size) < body * 0.92
        if mathematical, !small,
           (!MathTranscriber.isMathFont(first) && isProseMark(first))
            || (!MathTranscriber.isMathFont(second) && isProseMark(second)) {
            return width > body * 0.12
        }
        // Anything set smaller than the line is a script, and a script has no
        // words in it: the small gaps between the pieces of "q_{\phi}(z^{(l)})"
        // are not spaces, however wide they look next to a five-point paren.
        let formula = min(first.size, second.size) < body * 0.92
            || MathTranscriber.isMathFont(first) || MathTranscriber.isMathFont(second)
            || (MathTranscriber.variablesInTextItalic
                && ((isTextVariable(first) && isFormulaMark(second))
                    || (isFormulaMark(first) && isTextVariable(second))))
        // Against a glyph that grows — a radical, the pieces of a tall bar —
        // TeX sets a thick space and the glyph's own side bearing, which
        // together pass for a narrow word space: a \big| after a root, and
        // a root after a sum's limits, began a new word, and the exponent
        // they were in ended there.
        // (Not against a word of the sentence: mathptmx's ∫ is a point
        // smaller than the line, and "Inline:" is still a word before it.)
        let prose = (!MathTranscriber.isMathFont(first) && isProseMark(first))
            || (!MathTranscriber.isMathFont(second) && isProseMark(second))
        if formula, !prose, first.isExtension || second.isExtension { return width > body * 0.32 }
        return width > body * (formula ? 0.22 : 0.09)
    }

    /// What a word of a sentence begins and ends with: a Latin letter, and
    /// the colon or semicolon after one. (Computer Modern's capital Greek and
    /// its digits come from the text face too, and are the formula's.)
    private static func isProseMark(_ glyph: PDFContentScanner.Glyph) -> Bool {
        let spelled = MathTranscriber.spelling(of: glyph)
        if spelled == ":" || spelled == ";" { return true }
        return !spelled.isEmpty && spelled.allSatisfy { $0.isASCII && $0.isLetter }
            && !(MathTranscriber.variablesInTextItalic && MathTranscriber.isItalicLetter(glyph))
    }

    /// A variable a text face draws: a letter from its italic, or the Greek
    /// and the signs a face like Arev's carries for its formulas.
    private static func isTextVariable(_ glyph: PDFContentScanner.Glyph) -> Bool {
        MathTranscriber.isItalicLetter(glyph) || MathTranscriber.isTextSymbol(glyph)
    }

    /// What a formula set in a text face is held together by: an italic
    /// variable, a bracket, a sign.
    private static func isFormulaMark(_ glyph: PDFContentScanner.Glyph) -> Bool {
        MathTranscriber.isItalicLetter(glyph) || MathTranscriber.isMathFont(glyph)
            || MathTranscriber.isTextSymbol(glyph)
            || ["(", ")", "[", "]", "+", "=", "|", ","].contains(MathTranscriber.spelling(of: glyph))
    }

    // MARK: - Pages

    /// How a page is laid out: its rows, gathered into the things they belong
    /// to. Worked out once, because a selection asks about all of them.
    struct Layout {
        /// One thing on the page: a line of prose, or a formula and every row
        /// it was drawn on. Whether it is a formula is settled here, once,
        /// because settling it means reading every glyph on the page.
        struct Block {
            var rows: [[PDFContentScanner.Glyph]]
            var isFormula: Bool
        }
        var blocks: [Block]
        /// Whether the page sets its variables in the italic of its text face
        /// (`MathTranscriber.variablesInTextItalic`).
        var variablesInTextItalic = false
        /// Whether the page sets its text in a sans face
        /// (`MathTranscriber.sansTextFace`).
        var sansText = false
    }

    /// Whether a page's text is sans: most of the Latin letters its text
    /// faces draw are from a sans face. A slide deck is; its "max" is \max.
    static func sansText(of glyphs: [PDFContentScanner.Glyph]) -> Bool {
        var sans = 0, serif = 0
        for glyph in glyphs where !MathTranscriber.isMathFont(glyph) {
            let spelled = MathTranscriber.spelling(of: glyph)
            guard spelled.count == 1, let letter = spelled.first, letter.isASCII, letter.isLetter else { continue }
            if MathTranscriber.isSansFace(MathTranscriber.family(of: glyph)) { sans += 1 } else { serif += 1 }
        }
        return sans > serif
    }

    /// Whether a glyph belongs to a formula by its face alone.
    private static func isMathish(_ glyph: PDFContentScanner.Glyph) -> Bool {
        MathTranscriber.isMathFont(glyph)
            || (MathTranscriber.variablesInTextItalic
                && (MathTranscriber.isItalicLetter(glyph) || MathTranscriber.isTextSymbol(glyph)))
    }

    /// Whether a paper sets its variables in the italic of its text face, as
    /// mathptmx, txfonts, pxfonts, mathpazo and fourier do.
    ///
    /// Asked of the paper, not the page: a page whose only formula is
    /// "y = Wx + b" shows nothing but italic letters and a plus. The page
    /// asked about answers first — a page with maths italic letters of its
    /// own, which is every Computer Modern page with a formula on it, says no
    /// at once — and then the paper's first pages are looked at.
    @MainActor
    private static func variablesInTextItalic(for page: PDFPage, scanned: PDFContentScanner) -> Bool {
        let here = italicEvidence(scanned.glyphs)
        if here.ownLetters { return false }
        guard let document = page.document else { return here.evidence }
        let key = ObjectIdentifier(document)
        if let known = italicPapers[key], known.document === document { return known.value }
        var evidence = here.evidence
        var answer: Bool?
        let current = document.index(for: page)
        for index in 0..<min(document.pageCount, 10) where index != current {
            guard let other = document.page(at: index), let reference = other.pageRef else { continue }
            let seen = italicEvidence(PDFContentScanner.scan(page: reference).glyphs)
            if seen.ownLetters { answer = false; break }
            evidence = evidence || seen.evidence
        }
        let value = answer ?? evidence
        italicPapers = italicPapers.filter { $0.value.document != nil }
        if italicPapers.count > 12 { italicPapers.removeAll() }
        italicPapers[key] = ItalicAnswer(document: document, value: value)
        return value
    }

    /// The answer for a paper, held without holding the paper: a closed
    /// paper's pages should go when it does, not stay for a cache.
    private struct ItalicAnswer {
        weak var document: PDFDocument?
        let value: Bool
    }

    @MainActor
    private static var italicPapers: [ObjectIdentifier: ItalicAnswer] = [:]

    /// What one page says about where a paper keeps its variables: whether a
    /// maths font on it draws a Latin letter (then the maths italic is the
    /// paper's own), and whether anything on it says the text italic is
    /// used for mathematics — Greek from one of the fonts that only carry
    /// the Greek for such a paper, or an italic letter with a script on it.
    static func italicEvidence(_ glyphs: [PDFContentScanner.Glyph]) -> (ownLetters: Bool, evidence: Bool) {
        var evidence = false
        for glyph in glyphs where MathTranscriber.isMathFont(glyph) {
            let spelled = MathTranscriber.spelling(of: glyph)
            if spelled.count == 1, let letter = spelled.first, letter.isASCII, letter.isLetter {
                return (true, false)
            }
            let family = MathTranscriber.family(of: glyph)
            if greekOnly.contains(where: { family.hasPrefix($0) }) { evidence = true }
        }
        if evidence { return (false, true) }
        // Greek from the italic of a text face — Arev's γ and θ come from
        // ArevSans-Oblique — is a formula set in the text face.
        if glyphs.contains(where: {
            MathTranscriber.isTextSymbol($0) && MathTranscriber.isItalic($0)
                && TeXGlyphNames.isGreekCommand(MathTranscriber.spelling(of: $0))
        }) { return (false, true) }
        let small = glyphs.filter { !$0.isExtension }.sorted { $0.rect.minX < $1.rect.minX }
        for letter in glyphs where MathTranscriber.isItalicLetter(letter) {
            // A script starts where its letter ends.
            var low = 0, high = small.count
            while low < high {
                let middle = (low + high) / 2
                if small[middle].rect.minX < letter.rect.maxX - 1 { low = middle + 1 } else { high = middle }
            }
            var index = low
            while index < small.count, small[index].rect.minX < letter.rect.maxX + letter.size * 0.15 {
                let script = small[index]
                let offset = abs(script.origin.y - letter.origin.y)
                if script.size < letter.size * 0.8, offset > letter.size * 0.08, offset < letter.size * 0.6,
                   !MathTranscriber.spelling(of: script).isEmpty,
                   MathTranscriber.spelling(of: script).first?.isLetter == true {
                    return (false, true)
                }
                index += 1
            }
        }
        return (false, false)
    }

    /// The maths fonts that carry only Greek, because the paper sets its
    /// Latin variables in the text face's italic: txfonts' and pxfonts'
    /// rtxmi and rpxmi, mathptmx's slanted Symbol, mathpazo's and fourier's.
    private static let greekOnly = [
        "RTXMI", "RTXBMI", "RPXMI", "RPXBMI", "STANDARDSYML-SLANT", "PAZOMATH-ITALIC",
        "PAZOMATH-BOLDITALIC", "FOURIER-MATH-LETTERS-ITALIC", "FOURIER-MATH-LETTERS-BOLD-ITALIC",
    ]

    @MainActor
    private static var layouts: [ObjectIdentifier: (page: PDFPage, value: Layout)] = [:]

    /// The page's rules with the fills of its \underbrace and \overbrace
    /// marks named as such. The tips that would identify them are dropped
    /// before any row is laid (`rows(of:)`), so they have to be named here,
    /// while the tips are still in hand: unnamed, a fill drawn as a short
    /// image under ℓ_B became an \underline on the B, and a fill with a
    /// label under it a fraction bar with the label for a denominator.
    /// Named, the transcriber writes the brace with its label
    /// (`MathTranscriber.fractionBars`).
    private static func markingBraceFills(
        _ rules: [PDFContentScanner.Rule], glyphs: [PDFContentScanner.Glyph]
    ) -> [PDFContentScanner.Rule] {
        let tips = glyphs.filter { $0.glyphName?.hasPrefix("bracehtip") == true }
        guard !tips.isEmpty else { return rules }
        var plain: [PDFContentScanner.Rule] = []
        var fills: [PDFContentScanner.Rule] = []
        for rule in rules {
            if MathTranscriber.isBraceFill(rule, in: glyphs) { fills.append(rule) } else { plain.append(rule) }
        }
        // TeX draws a brace as two fills with a pair of tips meeting in the
        // middle (\downbracefill: tip, fill, tip, tip, fill, tip), so one
        // brace is two rules; read as two, each took half the formula and
        // half the label. Fills on one level with exactly the middle pair
        // between them — two tips' width — are one brace; two braces side
        // by side have a space between them as well, and stay two.
        // (Joined by level, not by order along the page: two braces under
        // neighbouring terms stand a point apart in height and overlap.)
        let tipWidth = tips.map(\.width).max() ?? 5
        var merged: [PDFContentScanner.Rule] = []
        for fill in fills.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            if let at = merged.firstIndex(where: { other in
                abs(other.rect.midY - fill.rect.midY) < 1
                    && fill.rect.minX >= other.rect.maxX - 1 && fill.rect.minX - other.rect.maxX < tipWidth * 2 + 1
            }) {
                merged[at].rect = merged[at].rect.union(fill.rect)
            } else {
                var named = fill
                named.brace = true
                merged.append(named)
            }
        }
        // The brace reaches a tip's width past its fills on either side, and
        // what stands over the tips — the bracket that opens the braced
        // formula — is braced too. Its end tips say which way it faces:
        // an \underbrace ends in tips that point up, and its label is
        // under it; an \overbrace ends in tips that point down.
        return plain + merged.map { brace in
            var wide = brace
            if let end = tips.first(where: {
                abs($0.rect.maxX - brace.rect.minX) < 1 && abs($0.origin.y - brace.rect.midY) < tipWidth * 3
            }) {
                wide.braceLabelBelow = end.glyphName?.hasPrefix("bracehtipup") ?? true
            }
            wide.rect = brace.rect.insetBy(dx: -tipWidth, dy: 0)
            return wide
        }
    }

    @MainActor
    private static func layout(of page: PDFPage, scanned: PDFContentScanner) -> Layout {
        let key = ObjectIdentifier(page)
        if let known = layouts[key], known.page === page { return known.value }
        let rules = markingBraceFills(scanned.rules, glyphs: scanned.glyphs)
        let rows = rows(of: scanned.glyphs, rules: rules)
        let body = size(of: scanned.glyphs)
        let italic = variablesInTextItalic(for: page, scanned: scanned)
        let sans = sansText(of: scanned.glyphs)
        MathTranscriber.variablesInTextItalic = italic
        MathTranscriber.sansTextFace = sans
        defer { MathTranscriber.variablesInTextItalic = false; MathTranscriber.sansTextFace = false }
        let grouped = blocks(of: rows, body: body, rules: rules)
        // Rows stacked closer than a line are a formula's rows — when
        // something in them came from a maths font. Two short lines of a
        // reference list, all digits, stack the same way and are not.
        // A row of nothing but the pieces of a tall bracket is the bracket's,
        // not a row: the bottom of the \left( of a sentence's formula stood
        // on a row of its own, and two rows made the sentence a display.
        let laid = Layout(blocks: grouped.map { rows in
            let own = rows.filter { row in
                row.contains { !MathTranscriber.isPiece($0) && !MathTranscriber.spelling(of: $0).isEmpty }
            }
            // (Rows of small type — a footnote's — stack closer than the
            // text's lines do and are not a formula's for it.)
            let stacked = own.count > 1 && rows.contains { $0.contains(where: isMathish) }
                && own.contains { context(of: $0).bodySize >= body * 0.9 }
            // The rows of a table stack a line apart too, and their cells
            // of measurements are mathematics to the glyph: a block whose
            // every row is a table's is the table, not a formula.
            // (Most of its rows: the header row names its columns in words.)
            let tabular = !own.isEmpty && own.filter(isTableRow).count * 2 >= own.count
            return Layout.Block(rows: rows, isFormula: !tabular && (stacked || isDisplayRow(own.first ?? rows[0])))
        }, variablesInTextItalic: italic, sansText: sans)
        if layouts.count > 12 { layouts.removeAll() }
        layouts[key] = (page, laid)
        return laid
    }

    /// Reading a page costs something, and a selection usually covers one page
    /// several times over, so each page is read once.
    @MainActor
    private static var scans: [ObjectIdentifier: (page: PDFPage, value: PDFContentScanner)] = [:]

    @MainActor
    private static func scan(_ page: PDFPage) -> PDFContentScanner? {
        let key = ObjectIdentifier(page)
        if let scanned = scans[key], scanned.page === page { return scanned.value }
        guard let reference = page.pageRef else { return nil }
        let scanned = PDFContentScanner.scan(page: reference)
        if scans.count > 12 { scans.removeAll(); layouts.removeAll(); characterBoxes.removeAll() }
        scans[key] = (page, scanned)
        return scanned
    }

    /// The environments whose rows are lines of a display.
    private static let lined: Set<String> = [
        "aligned", "gathered", "alignedat", "split", "align", "align*", "gather", "gather*",
        "alignat", "alignat*", "flalign", "flalign*", "multline", "multline*",
    ]

    /// A display of several rows written a row a line, the way it is typed:
    /// `$$\begin{aligned}` on its first line, each row on one of its own,
    /// `\end{aligned}$$` on the last — and an `equation` round it opened and
    /// closed on lines of their own. A matrix or a system of cases inside a
    /// row stays in its row, and a formula of one row is left on one line.
    static func spread(_ display: String) -> String {
        guard display.contains("\\\\") else { return display }
        let characters = Array(display)
        var out = ""
        var stack: [String] = []
        // Whether the display opens with its environment: then that one's
        // rows are the display's lines, whatever it is.
        let opening = display.hasPrefix("$$\\begin{") || display.hasPrefix("\\begin{")
        var outermost = true
        func trimEnd() { while out.last == " " { out.removeLast() } }
        func skipSpaces(_ at: inout Int) { while at < characters.count, characters[at] == " " { at += 1 } }
        func name(at start: Int) -> (name: String, end: Int)? {
            guard start < characters.count, characters[start] == "{",
                  let close = characters[start...].firstIndex(of: "}") else { return nil }
            return (String(characters[(start + 1)..<close]), close + 1)
        }
        var at = 0
        while at < characters.count {
            let rest = characters.count - at
            if rest >= 7, String(characters[at..<(at + 7)]) == "\\begin{", let found = name(at: at + 6) {
                let breaks = lined.contains(found.name) || found.name.hasPrefix("equation")
                    || (outermost && opening)
                outermost = false
                stack.append(breaks ? found.name : "")
                out += String(characters[at..<found.end])
                at = found.end
                if breaks { out += "\n"; skipSpaces(&at) }
                continue
            }
            if rest >= 5, String(characters[at..<(at + 5)]) == "\\end{", let found = name(at: at + 4) {
                if let top = stack.popLast(), !top.isEmpty {
                    trimEnd()
                    if out.last != "\n" { out += "\n" }
                }
                out += String(characters[at..<found.end])
                at = found.end
                continue
            }
            if rest >= 2, characters[at] == "\\", characters[at + 1] == "\\" {
                let breaks = stack.last.map { !$0.isEmpty } ?? false
                if breaks { trimEnd() }
                out += "\\\\"
                at += 2
                if breaks {
                    out += "\n"
                    skipSpaces(&at)
                }
                continue
            }
            if characters[at] == "\\", at + 1 < characters.count {
                out.append(characters[at])
                out.append(characters[at + 1])
                at += 2
                continue
            }
            if characters[at] == " ", out.last == "\n" { at += 1; continue }
            if characters[at] == "\n" { at += 1; continue }
            out.append(characters[at])
            at += 1
        }
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }
}
