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
    @MainActor
    static func latex(from selection: PDFSelection) -> String {
        let read = pieces(from: selection)
        guard !read.isEmpty else { return selection.string ?? "" }
        return join(read.map(\.plain))
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

    @MainActor
    static func pieces(from selection: PDFSelection) -> [Piece] {
        skippedFormulas = 0
        var pieces: [Piece] = []
        for (number, page) in selection.pages.enumerated() {
            let pageCharacters = characters(of: page)
            let pageText = (page.string ?? "") as NSString
            MathTranscriber.fallback = characterLookup(for: page)
            defer { MathTranscriber.fallback = nil }
            guard let scanned = scan(page), !scanned.glyphs.isEmpty else {
                if let plain = selection.string, !plain.isEmpty {
                    pieces.append(Piece(kind: .prose, plain: plain, marked: plain))
                }
                continue
            }
            // The page, laid out: every row it was set on, gathered into the
            // things they belong to.
            let layout = layout(of: page, scanned: scanned)
            MathTranscriber.variablesInTextItalic = layout.variablesInTextItalic
            defer { MathTranscriber.variablesInTextItalic = false }
            let boxes = lineBoxes(of: selection, on: page)
            let rules = scanned.rules
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
                boxes.contains { belongs(glyph, to: $0) }
            }

            // What the selection reaches. A formula is two-dimensional — its
            // limits sit under the sign and its numerator over the bar — so
            // touching one means taking all of it.
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
                // relation are the lines of one aligned formula.
                if block.isFormula,
                   let aligned = alignedRun(from: position - 1, in: reached, selected: selected, rules: rules)
                    ?? matrixRun(from: position - 1, in: reached, rules: rules) {
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

    /// Displayed formulas one under another that line up — each has a
    /// relation standing at the same place across the page — as the lines of
    /// one `aligned`: what an `align` or an `aligned` sets, and what a person
    /// copying it wants back, not two formulas that lost their alignment.
    private static func alignedRun(
        from start: Int,
        in reached: [(block: Layout.Block, glyphs: [PDFContentScanner.Glyph])],
        selected: (PDFContentScanner.Glyph) -> Bool,
        rules: [PDFContentScanner.Rule]
    ) -> (end: Int, latex: String, bounds: CGRect, baseline: CGFloat)? {
        struct Line {
            var glyphs: [PDFContentScanner.Glyph]
            var tag: String?
            var relations: [CGFloat]
            var baseline: CGFloat
            var bounds: CGRect
        }
        func line(_ block: Layout.Block, _ glyphs: [PDFContentScanner.Glyph]) -> Line? {
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
            guard let first = standing.first else { return nil }
            let heights = standing.map(\.origin.y).sorted()
            return Line(glyphs: all, tag: tag, relations: standing.map(\.rect.minX).sorted(),
                        baseline: heights[heights.count / 2] == 0 ? first.origin.y : heights[heights.count / 2],
                        bounds: extent(of: all))
        }
        guard let head = line(reached[start].block, reached[start].glyphs) else { return nil }
        var lines = [head]
        var next = start + 1
        while next < reached.count, let candidate = line(reached[next].block, reached[next].glyphs) {
            let previous = lines[lines.count - 1]
            let body = MathTranscriber.ordinarySize(of: previous.glyphs)
            let drop = previous.baseline - candidate.baseline
            guard drop > body * 0.9, drop < body * 3.5,
                  candidate.bounds.maxX > previous.bounds.minX, candidate.bounds.minX < previous.bounds.maxX
            else { break }
            lines.append(candidate)
            next += 1
        }
        guard lines.count >= 2 else { return nil }
        // Where they line up: the first of the first line's relations that
        // every other line has a relation at too.
        guard let column = lines[0].relations.first(where: { x in
            lines.dropFirst().allSatisfy { line in line.relations.contains { abs($0 - x) < 1 } }
        }) else { return nil }
        let tags = lines.compactMap(\.tag)
        var written: [String] = []
        for line in lines {
            let nearby = rules.filter { line.bounds.insetBy(dx: -2, dy: -2).intersects($0.rect) }
            let left = line.glyphs.filter { $0.rect.minX < column - 0.5 }
            let right = line.glyphs.filter { $0.rect.minX >= column - 0.5 }
            let before = left.isEmpty ? "" : MathTranscriber.latex(glyphs: left, rules: nearby)
            var text = (before.isEmpty ? "" : before + " ") + "&" + MathTranscriber.latex(glyphs: right, rules: nearby)
            if tags.count > 1, let tag = line.tag { text += " \\tag{\(tag)}" }
            written.append(text)
        }
        // One number for the whole is the aligned formula's; a number for
        // each line takes `align`, which lets each line keep its own.
        let environment = tags.count > 1 ? "align" : "aligned"
        var latex = "\\begin{\(environment)} " + written.joined(separator: " \\\\ ") + " \\end{\(environment)}"
        if tags.count == 1 { latex += "\\tag{\(tags[0])}" }
        let bounds = lines.dropFirst().reduce(lines[0].bounds) { $0.union($1.bounds) }
        return (next, latex, bounds, lines[0].baseline)
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
        if body.hasPrefix("\\begin{align}") { return body }
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

        func close() {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
            paragraph = ""
        }
        func breakHere() {
            close()
            if lines.last != "" && !lines.isEmpty { lines.append("") }
        }

        for piece in read {
            switch piece.kind {
            case .heading(let level):
                breakHere()
                lines.append(String(repeating: "#", count: level) + " " + piece.marked)
                lines.append("")
                previous = nil

            case .display:
                breakHere()
                lines.append(piece.marked)
                lines.append("")
                previous = nil

            case .inline:
                paragraph += paragraph.isEmpty ? piece.marked : " " + piece.marked

            case .prose:
                // A line that is all mathematics and an equation number is a
                // displayed equation, whatever the row was classified as —
                // "minimize" is a word, and the line it stands on is still an
                // equation. This is the line that used to arrive in the
                // middle of a sentence with its number stuck to it.
                if let equation = displayedEquation(in: piece.marked) {
                    breakHere()
                    lines.append(equation)
                    lines.append("")
                    previous = nil
                    continue
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
                    paragraph = piece.marked
                } else if paragraph.hasSuffix("-") {
                    paragraph.removeLast()
                    paragraph += piece.marked
                } else {
                    paragraph += " " + piece.marked
                }
                previous = piece
            }
        }
        close()
        while lines.last == "" { lines.removeLast() }
        return lines
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
        let offset = page.bounds(for: .cropBox).origin
        var result: [PageCharacter] = []
        for index in text.indices {
            let bounds = page.characterBounds(at: index)
            guard !bounds.isEmpty else { continue }
            result.append(PageCharacter(index: index,
                                        rect: bounds.offsetBy(dx: offset.x, dy: offset.y),
                                        character: text[index]))
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
    private static func belongs(_ glyph: PDFContentScanner.Glyph, to box: CGRect) -> Bool {
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
        let offset = page.bounds(for: .cropBox).origin
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
        return boxes.map {
            CGRect(x: $0.minX + offset.x, y: $0.minY + offset.y,
                   width: $0.width, height: $0.height)
                .insetBy(dx: -1, dy: 0)
        }
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
                    (MathTranscriber.isDelimiter(glyph) || MathTranscriber.spelling(of: glyph).isEmpty)
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
        // How far a row is from the row on its far side — a row of limits
        // belongs to the nearer of the two lines it stands between.
        // A line of prose is not a line a row of limits could belong to.
        func gap(below row: Int) -> CGFloat? {
            unders[row].flatMap { prose[$0] ? nil : baselines[row] - baselines[$0] }
        }
        func gap(above row: Int) -> CGFloat? {
            overs[row].flatMap { prose[$0] ? nil : baselines[$0] - baselines[row] }
        }
        // Two rows of scripts one over the other, each the limits of its own
        // line: under the sums of one line of a derivation and over the sums
        // of the next, the two rows stand closer than a line and joined the
        // lines — every glyph of both came back twice over, interleaved.
        func small(_ index: Int) -> Bool { rows[index].allSatisfy { $0.size < body * 0.8 } }
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
        return words(in: row, body: body).contains { word in
            // Only what is set at the line's own size can be a word of a
            // sentence. "teacher-forcing" written small under an L is a name
            // inside the formula, not prose around it — and reading it as
            // prose is what turns a displayed equation into a line of text.
            let full = word.filter { $0.size >= body * 0.92 }
            guard full.count >= 2, !full.contains(where: isMathish)
            else { return false }
            let spelled = full.map(MathTranscriber.spelling(of:))
            guard spelled.filter({ $0.first?.isLetter == true }).count >= 2 else { return false }
            return !MathTranscriber.isOperatorName(spelled.joined())
        }
    }

    /// Glyphs grouped into the rows they were set on.
    ///
    /// The rows are set by the full-size glyphs. Anything smaller — a
    /// subscript, a superscript — belongs to the row it hangs from rather than
    /// to a row of its own, which is what stops "z_k" from being read as a "z"
    /// on one line and a "k" on the next.
    private static func rows(
        of glyphs: [PDFContentScanner.Glyph], rules: [PDFContentScanner.Rule] = []
    ) -> [[PDFContentScanner.Glyph]] {
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
        // A radical sign is drawn from wherever its font puts its point — the
        // top of the sign, by the rule, in Computer Modern's symbol font and
        // often in the OpenType ones — and it belongs with what it covers,
        // which starts where it ends.
        var radicals: [PDFContentScanner.Glyph] = []
        for glyph in glyphs.filter({ $0.size >= body * 0.9 && !$0.isExtension })
            .sorted(by: { $0.origin.y > $1.origin.y }) {
            if floats(glyph) { floating.append(glyph); continue }
            if MathTranscriber.isRadical(glyph) { radicals.append(glyph); continue }
            if let index = rows.firstIndex(where: {
                abs($0.baseline - glyph.origin.y) < body * 0.6
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
        for glyph in floating {
            let span = glyph.rect.insetBy(dx: -body * 0.9, dy: 0)
            let nearest = rows.indices
                .filter { beside(span, rows[$0].glyphs, body: body) }
                .min { abs(rows[$0].baseline - glyph.origin.y) < abs(rows[$1].baseline - glyph.origin.y) }
            if let nearest, abs(rows[nearest].baseline - glyph.origin.y) < body * 1.3 {
                rows[nearest].glyphs.append(glyph)
            } else if let index = rows.firstIndex(where: { abs($0.baseline - glyph.origin.y) < body * 0.6 }) {
                rows[index].glyphs.append(glyph)
            } else {
                rows.append((glyph.origin.y, [glyph]))
            }
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
                rows[$0].baseline > ink.minY - 1 && rows[$0].baseline < ink.maxY + 1
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
        for glyph in waiting {
            let ink = glyph.rect
            if let nearest = rows.indices.min(by: {
                abs(rows[$0].baseline - ink.midY) < abs(rows[$1].baseline - ink.midY)
            }) {
                rows[nearest].glyphs.append(glyph)
            } else {
                rows.append((ink.midY, [glyph]))
            }
        }

        // Small glyphs hang from the row they are beside, as runs: a script
        // follows what it is on, and a limit is under or over it. Nearness in
        // height alone is not enough — the upper limit of a displayed sum is
        // closer to the line of prose above the display than to the sum, and
        // took itself off to that sentence, a page-width away.
        var unplaced: [(run: [PDFContentScanner.Glyph], level: CGFloat)] = []
        for run in smallRuns(glyphs.filter { $0.size < body * 0.9 && !$0.isExtension }, body: body) {
            let largest = run.map(\.size).max() ?? body
            let levels = run.filter { $0.size >= largest * 0.95 }.map(\.origin.y).sorted()
            let level = levels[levels.count / 2]
            let span = extent(of: run)
            let nearest = rows.indices
                .filter { beside(span, rows[$0].glyphs, body: body) }
                .min { abs(rows[$0].baseline - level) < abs(rows[$1].baseline - level) }
            // Close enough to hang from this row. A glyph further off than
            // this came from the line above or below, clipped by the band.
            if let nearest, abs(rows[nearest].baseline - level) < body * 0.85 {
                rows[nearest].glyphs += run
            } else {
                unplaced.append((run, level))
            }
        }
        // A part stacked over another small part of a row belongs to it a
        // little further off: the numerator of a fraction inside a fraction
        // in a sentence sits most of a line above it.
        for (run, level) in unplaced {
            let span = extent(of: run)
            let middle = span.midX
            let stacked = rows.indices.filter { row in
                let distance = abs(rows[row].baseline - level)
                return (distance < body * 1.05 && rows[row].glyphs.contains {
                    $0.size < body * 0.9 && $0.rect.maxX > span.minX && $0.rect.minX < span.maxX
                })
                    // The script of a tall bracket or a sign that grows,
                    // lifted as high as they are tall.
                    || (distance < body * 1.3 && rows[row].glyphs.contains { glyph in
                        (MathTranscriber.isDelimiter(glyph) || MathTranscriber.isBigOperator(glyph)
                            || glyph.isExtension)
                            && span.minX >= glyph.rect.maxX - 1 && span.minX - glyph.rect.maxX < body * 0.5
                    })
                    // Over a bar the row has something under, or under one it
                    // has something over: a numerator of a fraction inside a
                    // fraction, however far up the page it went.
                    || (distance < body * 1.6 && rules.contains { rule in
                        guard middle > rule.rect.minX, middle < rule.rect.maxX else { return false }
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
            } else if let level = rows.firstIndex(where: { abs($0.baseline - level) < body * 0.25 }) {
                // Nothing to hang from, but a row on the same line: the
                // limits under two sums side by side are one row, as the
                // full-size glyphs of a line are.
                rows[level].glyphs += run
            } else {
                rows.append((level, run))
            }
        }

        let laid = folded(rows.sorted { $0.baseline > $1.baseline }, body: body)
            .map { $0.glyphs.sorted { $0.origin.x < $1.origin.x } }
        return split(laid, atGuttersOf: glyphs)
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
        let gutters = gutters(of: rows, over: glyphs)
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
        _ rows: [(baseline: CGFloat, glyphs: [PDFContentScanner.Glyph])], body: CGFloat
    ) -> [(baseline: CGFloat, glyphs: [PDFContentScanner.Glyph])] {
        guard rows.count > 1 else { return rows }
        var rows = rows
        var index = 0
        while index < rows.count {
            let row = rows[index]
            let span = extent(of: row.glyphs)
            let neighbours = [index - 1, index + 1].filter { rows.indices.contains($0) }
            let host = neighbours.filter { other in
                let theirs = extent(of: rows[other].glyphs)
                // Only a fragment folds, and only into a line it is part of.
                return span.width < theirs.width * 0.75
                    && abs(rows[other].baseline - row.baseline) < body * 0.9
                    && beside(span, rows[other].glyphs, body: body)
                    && !collides(row.glyphs, onOwnLine(rows[other], body: body))
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
        let words = keepingRadicands(words(in: row, body: context.bodySize), rules: rules)
        var pieces: [Word] = []
        func prose(_ word: [PDFContentScanner.Glyph], tight: Bool = false) -> Word {
            let spelled = word.map(MathTranscriber.spelling(of:))
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
        // A name with a script on it — "log₂", "sin²" — is a formula whatever
        // face it is set in.
        let letters = word.filter { $0.size >= body * 0.92 }
        let lead = letters.prefix { MathTranscriber.isUprightLetter($0) }
        if !lead.isEmpty, MathTranscriber.isOperatorName(lead.map(MathTranscriber.spelling(of:)).joined()),
           word.contains(where: { $0.size < body * 0.92 && abs($0.origin.y - context.baseline) > body * 0.08 }) {
            return true
        }
        guard MathTranscriber.variablesInTextItalic,
              word.contains(where: MathTranscriber.isItalicLetter) else { return false }
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
        guard full.count <= 2, full.allSatisfy({ MathTranscriber.spelling(of: $0).first?.isLetter == true }),
              !commonShortWords.contains(marks.joined().lowercased())
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
        while core.count > 1, let last = core.last, textual(last, [".", ",", ";", ":"]) {
            trail.insert(last, at: 0)
            core = core.dropLast()
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
        let ordinary = row.filter {
            !$0.isExtension && !MathTranscriber.isBigOperator($0) && !MathTranscriber.isDelimiter($0)
                && !MathTranscriber.spelling(of: $0).isEmpty
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
                && ((MathTranscriber.isItalicLetter(first) && isFormulaMark(second))
                    || (isFormulaMark(first) && MathTranscriber.isItalicLetter(second))))
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

    /// What a formula set in a text face is held together by: an italic
    /// variable, a bracket, a sign.
    private static func isFormulaMark(_ glyph: PDFContentScanner.Glyph) -> Bool {
        MathTranscriber.isItalicLetter(glyph) || MathTranscriber.isMathFont(glyph)
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
    }

    /// Whether a glyph belongs to a formula by its face alone.
    private static func isMathish(_ glyph: PDFContentScanner.Glyph) -> Bool {
        MathTranscriber.isMathFont(glyph)
            || (MathTranscriber.variablesInTextItalic && MathTranscriber.isItalicLetter(glyph))
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

    @MainActor
    private static func layout(of page: PDFPage, scanned: PDFContentScanner) -> Layout {
        let key = ObjectIdentifier(page)
        if let known = layouts[key], known.page === page { return known.value }
        let rows = rows(of: scanned.glyphs, rules: scanned.rules)
        let body = size(of: scanned.glyphs)
        let italic = variablesInTextItalic(for: page, scanned: scanned)
        MathTranscriber.variablesInTextItalic = italic
        defer { MathTranscriber.variablesInTextItalic = false }
        let grouped = blocks(of: rows, body: body, rules: scanned.rules)
        // Rows stacked closer than a line are a formula's rows — when
        // something in them came from a maths font. Two short lines of a
        // reference list, all digits, stack the same way and are not.
        let laid = Layout(blocks: grouped.map { rows in
            let stacked = rows.count > 1 && rows.contains { $0.contains(where: isMathish) }
            return Layout.Block(rows: rows, isFormula: stacked || isDisplayRow(rows[0]))
        }, variablesInTextItalic: italic)
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

    /// Lines are joined the way a paragraph is, with words broken across a
    /// line put back together.
    private static func join(_ lines: [String]) -> String {
        var result = ""
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0 {
                result = trimmed
            } else if result.hasSuffix("-") {
                result.removeLast()
                result += trimmed
            } else {
                result += " " + trimmed
            }
        }
        return result
    }
}
