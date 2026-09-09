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
        var pieces: [String] = []
        for page in selection.pages {
            let pageCharacters = characters(of: page)
            let pageText = (page.string ?? "") as NSString
            MathTranscriber.fallback = characterLookup(for: page)
            defer { MathTranscriber.fallback = nil }
            guard let scanned = scan(page), !scanned.glyphs.isEmpty else {
                if let plain = selection.string, !plain.isEmpty { pieces.append(plain) }
                continue
            }
            // The page, laid out: every row it was set on, gathered into the
            // things they belong to.
            let layout = layout(of: page, scanned: scanned)
            let boxes = lineBoxes(of: selection, on: page)
            let rules = scanned.rules

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

            for (block, glyphs) in reached {
                guard block.isFormula else {
                    let whole = block.rows[0].count
                    if wantsFormula, glyphs.count * 10 < whole * 9 { continue }
                    let band = glyphs.dropFirst().reduce(glyphs[0].rect) { $0.union($1.rect) }
                    let text = read(
                        glyphs,
                        rules: rules.filter { band.insetBy(dx: -2, dy: -2).intersects($0.rect) },
                        characters: pageCharacters, text: pageText
                    )
                    if !text.isEmpty { pieces.append(text) }
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

                let bounds = all.dropFirst().reduce(all[0].rect) { $0.union($1.rect) }
                var body = MathTranscriber.latex(
                    glyphs: all.sorted { $0.origin.x < $1.origin.x },
                    rules: rules.filter { bounds.insetBy(dx: -2, dy: -2).intersects($0.rect) }
                )
                if let tag { body += tag }
                if !body.isEmpty {
                    pieces.append(all.count > 3 ? "$$\(body)$$" : "$\(body)$")
                }
            }
        }

        guard !pieces.isEmpty else { return selection.string ?? "" }
        return join(pieces)
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
        if let known = characterBoxes[key] { return known }
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
        characterBoxes[key] = result
        return result
    }

    /// Asking PDFKit where each character sits means asking it once per
    /// character, which is most of the cost of a copy. A page is asked once.
    @MainActor
    private static var characterBoxes: [ObjectIdentifier: [PageCharacter]] = [:]

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
    /// The rows of a displayed formula are closer than that and carry none,
    /// because the numerator, the sign and the denominator are one thing
    /// written on three levels.
    private static func blocks(
        of rows: [[PDFContentScanner.Glyph]], body: CGFloat
    ) -> [[[PDFContentScanner.Glyph]]] {
        var blocks: [[[PDFContentScanner.Glyph]]] = []
        var lastBaseline: CGFloat?
        var lastWasProse = true
        for row in rows {
            let baseline = context(of: row).baseline
            let prose = containsProse(row)
            let close = lastBaseline.map { $0 - baseline < body } ?? false
            if !prose, !lastWasProse, close, !blocks.isEmpty {
                blocks[blocks.count - 1].append(row)
            } else {
                blocks.append([row])
            }
            lastBaseline = baseline
            lastWasProse = prose
        }
        return blocks
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
        // Words settle it first. A sentence can hold a sum without being a
        // formula — a paper is full of lines like "is the sum over the
        // marginal likelihoods" — and a line that says "is:" before the
        // formula and "where" after it is a sentence however much of it is
        // symbols.
        if containsProse(row) { return false }

        // Then the letters, and only the letters set at the line's own size.
        // Brackets, commas and digits read the same in a sentence as in a
        // formula, and a word set small is part of the formula whatever it
        // spells — counting those buries the evidence. "L(φ) := L_teacher-
        // forcing(φ) + L_rollout(φ), (4)" is mostly brackets and a subscript,
        // and every letter in it at full size is mathematics.
        let body = context(of: row).bodySize
        let deciding = row.filter { glyph in
            guard glyph.size >= body * 0.92 else { return false }
            let token = MathTranscriber.spelling(of: glyph)
            return token.count > 1 || token.first?.isLetter == true
        }
        guard !deciding.isEmpty else { return false }
        let mathish = deciding.filter(MathTranscriber.isMathFont).count
        if deciding.count <= 4 { return mathish > 0 }
        if row.contains(where: { TeXGlyphNames.isBigOperator($0.glyphName) }) {
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
            guard full.count >= 2, !full.contains(where: MathTranscriber.isMathFont)
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
    private static func rows(of glyphs: [PDFContentScanner.Glyph]) -> [[PDFContentScanner.Glyph]] {
        guard !glyphs.isEmpty else { return [] }
        let sizes = glyphs.map(\.size).sorted()
        let body = sizes[Int(Double(sizes.count) * 0.75)]

        var rows: [(baseline: CGFloat, glyphs: [PDFContentScanner.Glyph])] = []
        for glyph in glyphs.filter({ $0.size >= body * 0.9 && !$0.isExtension })
            .sorted(by: { $0.origin.y > $1.origin.y }) {
            if let index = rows.firstIndex(where: {
                abs($0.baseline - glyph.origin.y) < body * 0.6
            }) {
                rows[index].glyphs.append(glyph)
            } else {
                rows.append((glyph.origin.y, [glyph]))
            }
        }

        for glyph in glyphs.filter({ $0.size < body * 0.9 && !$0.isExtension }) {
            let nearest = rows.indices.min {
                abs(rows[$0].baseline - glyph.origin.y) < abs(rows[$1].baseline - glyph.origin.y)
            }
            // Close enough to hang from this row. A glyph further off than
            // this came from the line above or below, clipped by the band.
            if let nearest, abs(rows[nearest].baseline - glyph.origin.y) < body * 0.85 {
                rows[nearest].glyphs.append(glyph)
            } else {
                rows.append((glyph.origin.y, [glyph]))
            }
        }

        // A big operator, or a piece of a tall delimiter, hangs from a point
        // above its own ink, so where it was *placed* is not the line it was
        // set on. It joins the row whose baseline runs through it.
        for glyph in glyphs.filter(\.isExtension) {
            let ink = glyph.rect
            let through = rows.indices.filter {
                rows[$0].baseline > ink.minY - 1 && rows[$0].baseline < ink.maxY + 1
            }
            let candidates = through.isEmpty ? Array(rows.indices) : through
            if let nearest = candidates.min(by: {
                abs(rows[$0].baseline - ink.midY) < abs(rows[$1].baseline - ink.midY)
            }) {
                rows[nearest].glyphs.append(glyph)
            } else {
                rows.append((ink.midY, [glyph]))
            }
        }

        let laid = folded(rows.sorted { $0.baseline > $1.baseline }, body: body)
            .map { $0.glyphs.sorted { $0.origin.x < $1.origin.x } }
        return split(laid, atGuttersOf: glyphs)
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
        var pieces: [(isMath: Bool, text: String)] = []
        for word in words(in: row, body: context.bodySize) {
            if word.contains(where: MathTranscriber.isMathFont) {
                let latex = MathTranscriber.latex(glyphs: word, rules: rules, context: context)
                if !latex.isEmpty { pieces.append((true, latex)) }
                continue
            }
            let spelled = word.map(MathTranscriber.spelling(of:))
            if spelled.contains(where: \.isEmpty),
               let borrowed = spelling(of: word, from: characters, text: text) {
                pieces.append((false, borrowed))
            } else {
                pieces.append((false, composed(spelled.joined())))
            }
        }
        return assemble(merged(pieces))
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
        let ordinary = row.filter { !$0.isExtension }
        let body = ordinary.map(\.size).max() ?? row.map(\.size).max() ?? 10
        let full = ordinary.filter { $0.size >= body * 0.92 }
        let sample = (full.isEmpty ? row : full).map(\.origin.y).sorted()
        return MathTranscriber.Context(bodySize: body, baseline: sample[sample.count / 2])
    }

    /// The relations and operators a formula is held together by. A line of
    /// prose does not open with one, so finding one between two formulas
    /// means the three were one formula all along.
    private static let joiners: Set<String> = [
        "=", "+", "-", "<", ">", "\\leq", "\\geq", "\\neq", "\\approx",
        "\\sim", "\\equiv", "\\to", "\\in", "\\cdot", "\\times", "\\pm",
    ]

    /// Puts a formula back together where the spaces cut it up. TeX sets thin
    /// spaces around a relation, which look exactly like word spaces, so
    /// "x = y" arrives as three words and has to be rejoined.
    private static func merged(
        _ pieces: [(isMath: Bool, text: String)]
    ) -> [(isMath: Bool, text: String)] {
        var result: [(isMath: Bool, text: String)] = []
        for piece in pieces {
            if piece.isMath, result.count >= 2,
               joiners.contains(result[result.count - 1].text),
               result[result.count - 2].isMath {
                let joiner = result.removeLast().text
                let first = result.removeLast().text
                result.append((true, "\(first) \(joiner) \(piece.text)"))
            } else if piece.isMath, let last = result.last, last.isMath {
                result.removeLast()
                result.append((true, last.text + spacer(after: last.text, before: piece.text)
                                   + piece.text))
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

    private static func assemble(_ pieces: [(isMath: Bool, text: String)]) -> String {
        pieces.map { $0.isMath ? "$\($0.text)$" : $0.text }.joined(separator: " ")
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
        for glyph in row {
            if let last = words.last?.last, !isGap(between: last, and: glyph, body: body) {
                words[words.count - 1].append(glyph)
            } else {
                words.append([glyph])
            }
        }
        return words
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
        // Anything set smaller than the line is a script, and a script has no
        // words in it: the small gaps between the pieces of "q_{\phi}(z^{(l)})"
        // are not spaces, however wide they look next to a five-point paren.
        let formula = min(first.size, second.size) < body * 0.92
            || MathTranscriber.isMathFont(first) || MathTranscriber.isMathFont(second)
        return width > body * (formula ? 0.22 : 0.09)
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
    }

    @MainActor
    private static var layouts: [ObjectIdentifier: Layout] = [:]

    @MainActor
    private static func layout(of page: PDFPage, scanned: PDFContentScanner) -> Layout {
        let key = ObjectIdentifier(page)
        if let known = layouts[key] { return known }
        let grouped = blocks(of: rows(of: scanned.glyphs), body: size(of: scanned.glyphs))
        let laid = Layout(blocks: grouped.map {
            Layout.Block(rows: $0, isFormula: $0.count > 1 || isDisplayRow($0[0]))
        })
        if layouts.count > 12 { layouts.removeAll() }
        layouts[key] = laid
        return laid
    }

    /// Reading a page costs something, and a selection usually covers one page
    /// several times over, so each page is read once.
    @MainActor
    private static var scans: [ObjectIdentifier: PDFContentScanner] = [:]

    @MainActor
    private static func scan(_ page: PDFPage) -> PDFContentScanner? {
        let key = ObjectIdentifier(page)
        if let scanned = scans[key] { return scanned }
        guard let reference = page.pageRef else { return nil }
        let scanned = PDFContentScanner.scan(page: reference)
        if scans.count > 12 { scans.removeAll(); layouts.removeAll(); characterBoxes.removeAll() }
        scans[key] = scanned
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
