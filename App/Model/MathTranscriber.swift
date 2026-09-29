import CoreGraphics
import Foundation

/// Reads a formula off the page the way a person does: by looking at where
/// things are.
///
/// A fraction is a line with something above it and something below. A sum is a
/// big sign with its limits stacked over and under. A subscript is a small
/// glyph that has dropped below the baseline. None of that is written down
/// anywhere in the file — it is only the arrangement — so this works from the
/// arrangement, on the glyphs and rules the scanner found.
///
/// The things that are more than one glyph are found first: fraction bars and
/// what is over and under them, radicals and their roots, the limits of the
/// big operators and of the names that take them, the rules over and under a
/// run, the accents and what they cover, the relations struck through. Then
/// the formula is read from left to right, and each of those is written where
/// its first glyph is.
enum MathTranscriber {
    typealias Glyph = PDFContentScanner.Glyph
    typealias Rule = PDFContentScanner.Rule

    /// What the line around a fragment looks like.
    ///
    /// A word lifted out of a line has to be read against the line it came
    /// from. On its own, a sum with four small glyphs after it looks like a
    /// formula set entirely in seven point, and then nothing is a subscript
    /// because nothing is small.
    struct Context {
        var bodySize: CGFloat
        var baseline: CGFloat
    }

    /// Asked for a glyph this cannot read: the character PDFKit found at that
    /// point on the page, which is right for ordinary text even when the maths
    /// fonts defeat it.
    nonisolated(unsafe) static var fallback: ((Glyph) -> String?)?

    /// Whether the page being read sets its variables in the italic of its
    /// text face — mathptmx, txfonts, pxfonts, mathpazo and fourier all do —
    /// so that an italic letter can be a variable. On a page that has maths
    /// italic letters of its own, an italic letter is prose.
    nonisolated(unsafe) static var variablesInTextItalic = false

    /// The LaTeX for everything drawn inside `region` of a scanned page.
    static func latex(glyphs: [Glyph], rules: [Rule], in region: CGRect) -> String {
        let box = region.insetBy(dx: -1, dy: -1)
        let inside = glyphs.filter { box.intersects($0.rect) }
        let bars = rules.filter { box.intersects($0.rect) }
        return latex(glyphs: inside, rules: bars)
    }

    /// Told of every formula read, with what it was read from — for a probe
    /// that sweeps a corpus looking for formulas read wrong. Nil in the app.
    nonisolated(unsafe) static var observer: ((_ glyphs: [Glyph], _ context: Context?, _ latex: String) -> Void)?

    /// The LaTeX for a set of glyphs that have already been chosen.
    static func latex(glyphs: [Glyph], rules: [Rule], context: Context? = nil) -> String {
        guard !glyphs.isEmpty else { return "" }
        let sorted = byX(glyphs)
        let result = joiningText(transcribe(sorted, rules: rules, context: context))
        observer?(sorted, context, result)
        return result
    }

    /// Glyphs in reading order: left to right, and two at the same place in
    /// the order they were drawn.
    static func byX(_ glyphs: [Glyph]) -> [Glyph] {
        glyphs.enumerated()
            .sorted { $0.element.origin.x != $1.element.origin.x
                ? $0.element.origin.x < $1.element.origin.x : $0.offset < $1.offset }
            .map(\.element)
    }

    /// A glyph that draws a space — Word draws them; TeX does not. Asked of
    /// what the glyph spells, not of its Unicode: TeX's symbol font keeps its
    /// left arrow at code 32, which a declared encoding reads as a space.
    static func isSpace(_ glyph: Glyph) -> Bool {
        let spelled = token(for: glyph)
        return !spelled.isEmpty && spelled.allSatisfy(\.isWhitespace)
    }

    /// Whether a word holds a subscript the way Word sets one: a glyph much
    /// smaller than the one it touches, on that glyph's baseline (see
    /// `scripts`). Such a word is mathematics even in the text face —
    /// "VT (Vi)" is `V_T (V_i)`.
    static func hasWordSubscript(_ word: [Glyph], body: CGFloat) -> Bool {
        guard word.count >= 2 else { return false }
        for (index, glyph) in word.enumerated().dropFirst() {
            let before = word[index - 1]
            if glyph.size <= body * 0.72, before.size >= body * 0.92,
               abs(glyph.origin.y - before.origin.y) <= body * 0.03,
               glyph.rect.minX - before.rect.maxX < body * 0.12,
               !spelling(of: glyph).isEmpty {
                return true
            }
        }
        return false
    }

    /// Words set upright in a formula come out one `\text{}` each; a person
    /// writes the phrase as one — `\text{Fuel Oil Consumption}`.
    static func joiningText(_ latex: String) -> String {
        guard latex.contains("\\text{") else { return latex }
        var result = latex
        while let range = result.range(of: #"\\text\{([^{}]*)\}\s+\\text\{"#, options: .regularExpression) {
            let piece = String(result[range])
            guard let close = piece.firstIndex(of: "}") else { break }
            let inner = piece[piece.index(piece.startIndex, offsetBy: 6)..<close]
            result.replaceSubrange(range, with: "\\text{\(inner) ")
        }
        return result
    }

    /// One glyph as plain text — what it spells, with no formula around it.
    /// Prose asks for this; it must not come back with `\mathbf` on it.
    static func spelling(of glyph: Glyph) -> String { token(for: glyph) }

    /// Whether a glyph came from a font that only sets mathematics.
    ///
    /// Computer Modern's are the ones every TeX paper used to be set with;
    /// the Times and Palatino papers use the tx and px fonts, or newtx and
    /// newpx, IEEE's use MathTime, Libertine has its own, and Word writes
    /// Cambria Math. A paper set in any of these had every formula in its
    /// prose read as words until each family was known here.
    static func isMathFont(_ glyph: Glyph) -> Bool {
        let family = Self.family(of: glyph)
        if family.contains("MATH") { return true }
        return mathFamilies.contains { family.hasPrefix($0) }
    }

    /// The first letters of the maths fonts' names, uppercased. A prefix
    /// covers the sizes and variants: "CMMI" is CMMI5 to CMMI12 and CMMIB.
    private static let mathFamilies: [String] = [
        // Computer Modern and the AMS fonts.
        "CMMI", "CMSY", "CMEX", "CMBSY", "MSAM", "MSBM", "EUFM", "EUFB", "EUSM", "EUSB",
        "EURM", "EURB", "EUEX", "RSFS", "BBOLD", "DSROM", "DSSS", "STMARY", "WASY", "LASY",
        "ESINT", "CALLIGRA",
        // tx and px, and newtx and newpx. txfonts and pxfonts keep their Greek
        // in rtxmi and rpxmi and their upright symbols in rtxr and rpxr, which
        // only a formula uses; their Latin letters are the text face's.
        "TXMI", "TXSY", "TXEX", "TXBMI", "TXBSY", "PXMI", "PXSY", "PXEX", "PXBMI", "PXBSY",
        "NEWTXMI", "NEWTXBMI", "NEWTXSY", "NEWPXMI", "NEWPXBMI", "NEWPXSY",
        "RTXMI", "RTXBMI", "RPXMI", "RPXBMI", "RTXR", "RTXB", "RPXR", "RPXB",
        // MathTime, which IEEE sets with.
        "RMTMI", "MTSY", "MTEX", "MTMI", "BLEX", "MTGU",
        // The Symbol font, which mathptmx draws its Greek and its big
        // operators from.
        "STANDARDSYML",
        // Latin Modern, Libertine, STIX, XITS, Asana and the OpenType maths
        // fonts all have "Math" in their names, and their text faces do not
        // — which is why "STIX" is not a prefix here: STIXTwoText is prose.
    ]

    static func family(of glyph: Glyph) -> String {
        (glyph.fontName.split(separator: "+").last.map(String.init) ?? glyph.fontName).uppercased()
    }

    // MARK: - What a glyph is

    /// A sign that takes limits: ∑, ∏, ∫, ⋃ and their kin, from whatever font.
    static func isBigOperator(_ glyph: Glyph) -> Bool {
        if TeXGlyphNames.isBigOperator(glyph.glyphName) { return true }
        return bigOperators.contains(token(for: glyph))
    }

    private static let bigOperators: Set<String> = [
        "\\sum", "\\prod", "\\coprod", "\\bigcup", "\\bigcap", "\\bigoplus", "\\bigotimes",
        "\\bigodot", "\\biguplus", "\\bigsqcup", "\\bigvee", "\\bigwedge", "\\int", "\\iint",
        "\\iiint", "\\oint", "\\oiint",
    ]

    /// A bracket, a bar or a fence, at any size.
    static func isDelimiter(_ glyph: Glyph) -> Bool {
        opening(glyph) != nil || closing(glyph) != nil
            || TeXGlyphNames.fence(glyph.glyphName) != nil
            || ["|", "\\|"].contains(token(for: glyph))
    }

    /// The opening delimiter a glyph is, if it is one.
    static func opening(_ glyph: Glyph) -> String? {
        if let named = TeXGlyphNames.openingDelimiter(glyph.glyphName) { return named }
        let spelled = token(for: glyph)
        return ["(", "[", "\\{", "\\langle", "\\lfloor", "\\lceil"].contains(spelled) ? spelled : nil
    }

    /// The closing delimiter a glyph is, if it is one.
    static func closing(_ glyph: Glyph) -> String? {
        if let named = TeXGlyphNames.closingDelimiter(glyph.glyphName) { return named }
        let spelled = token(for: glyph)
        return [")", "]", "\\}", "\\rangle", "\\rfloor", "\\rceil"].contains(spelled) ? spelled : nil
    }

    /// The sign of a radical.
    static func isRadical(_ glyph: Glyph) -> Bool { token(for: glyph) == "\\sqrt" }

    /// Whether a bracket from an OpenType maths font is one of its larger
    /// sizes, grown to hold more than a line. The file does not say how tall
    /// a glyph is; it says where it stands and how wide it is. A larger size
    /// stands off the line of what follows it, or is far wider than the
    /// bracket of a line — LM Math's "(" is 0.39 em and its two-line one
    /// 0.60; its "[" 0.28 and 0.53.
    static func isTallVariant(_ bracket: Glyph, among glyphs: [Glyph], body: CGFloat) -> Bool {
        guard !bracket.isExtension, isUnicodeMathFont(family(of: bracket)) else { return false }
        let spelled = token(for: bracket)
        let wide: [String: CGFloat] = [
            "(": 0.5, ")": 0.5, "[": 0.45, "]": 0.45, "\\{": 0.62, "\\}": 0.62,
            "\\langle": 0.5, "\\rangle": 0.5, "\\lfloor": 0.5, "\\rfloor": 0.5,
            "\\lceil": 0.5, "\\rceil": 0.5,
        ]
        if let ratio = wide[spelled], bracket.width > bracket.size * ratio { return true }
        // What it holds: after an opening bracket, before a closing one.
        let near = glyphs.filter {
            abs($0.origin.y - bracket.origin.y) < body * 1.2 && !isDelimiter($0) && !token(for: $0).isEmpty
        }
        let after = near.filter {
            $0.rect.minX >= bracket.rect.maxX - 0.5 && $0.rect.minX - bracket.rect.maxX < body
        }.min { $0.rect.minX < $1.rect.minX }
        let before = near.filter {
            $0.rect.maxX <= bracket.rect.minX + 0.5 && bracket.rect.minX - $0.rect.maxX < body
        }.max { $0.rect.maxX < $1.rect.maxX }
        let held = closing(bracket) != nil ? (before ?? after) : (after ?? before)
        guard let held else { return false }
        return abs(held.origin.y - bracket.origin.y) > body * 0.1
    }

    /// Whether a font is an italic or slanted face.
    static func isItalicFace(_ family: String) -> Bool {
        family.contains("ITAL") || family.contains("OBLIQUE") || family.contains("SLANT")
            || family.hasPrefix("CMTI") || family.hasPrefix("CMSL") || family.hasPrefix("CMBXTI")
            || family.hasPrefix("CMBXSL") || family.hasPrefix("SFTI") || family.hasPrefix("SFSL")
            || family.hasPrefix("SFBI") || family.hasSuffix("-IT") || family.hasSuffix("-BI")
            || family.hasSuffix("-BOLDIT")
            || (family.hasPrefix("LINLIBERTINE") && family.hasSuffix("I"))
    }

    /// A letter from the italic of a text face — which, on a page that sets
    /// its variables that way, is a variable.
    static func isItalicLetter(_ glyph: Glyph) -> Bool {
        guard !isMathFont(glyph), isItalicFace(family(of: glyph)) else { return false }
        let spelled = token(for: glyph)
        return spelled.count == 1 && spelled.first?.isLetter == true
    }

    /// Whether a Latin letter in a formula is set upright: from a roman or
    /// sans or typewriter text face, or — in a Unicode maths font, which
    /// writes its italic letters as the Mathematical Alphanumeric Symbols —
    /// as the plain letter itself.
    static func isUprightLetter(_ glyph: Glyph) -> Bool {
        let spelled = token(for: glyph)
        guard spelled.count == 1, let letter = spelled.first, letter.isASCII, letter.isLetter,
              boldCommand(for: glyph) == nil
        else { return false }
        let upper = family(of: glyph)
        if isMathFont(glyph) {
            guard isUnicodeMathFont(upper) else { return false }
            if let name = glyph.glyphName, TeXGlyphNames.unicodeName(name) != nil { return false }
            guard let unicode = glyph.unicode, !unicode.isEmpty else { return glyph.glyphName == spelled }
            return unicode == spelled
        }
        return !isItalicFace(upper)
    }

    /// The OpenType maths fonts, and STIX's own for pdfTeX: fonts in which a
    /// plain letter is an upright letter, because the italic ones have code
    /// points of their own.
    static func isUnicodeMathFont(_ upper: String) -> Bool {
        let unicodeFaces = ["LATINMODERNMATH", "STIXTWOMATH", "STIXMATH", "XITSMATH",
                            "LIBERTINUSMATH", "CAMBRIAMATH", "ASANAMATH", "FIRAMATH",
                            "GARAMONDMATH", "GARAMOND-MATH", "NEWCMMATH", "DEJAVUMATH",
                            "LUCIDABRIGHTMATH", "EULERMATH", "KPMATH", "STIXGENERAL"]
        if unicodeFaces.contains(where: { upper.contains($0) }) { return true }
        return upper.hasPrefix("TEXGYRE") && upper.contains("MATH")
    }

    /// How an upright run of letters is written: in roman, sans or
    /// typewriter, as the face it was set in.
    static func uprightStyle(_ glyph: Glyph) -> String {
        let upper = family(of: glyph)
        let sans = ["CMSS", "SFSS", "LMSANS", "HELVETICA", "NIMBUSSAN", "HEROS", "BIOLINUM",
                    "ARIAL", "SANS"]
        if sans.contains(where: { upper.hasPrefix($0) || upper.contains($0) }) { return "\\mathsf" }
        let mono = ["CMTT", "SFTT", "LMMONO", "TXTT", "T1XTT", "COURIER", "NIMBUSMON", "CURSOR",
                    "MONO"]
        if mono.contains(where: { upper.hasPrefix($0) || upper.contains($0) }) { return "\\mathtt" }
        return "\\mathrm"
    }

    /// The size a formula is set in: the largest of its ordinary glyphs.
    /// Nothing in a formula is set larger than its line — scripts and limits
    /// are smaller — except the signs that grow to fit: the big operators,
    /// the tall delimiters and the radicals, which are left out. Taking the
    /// commonest size instead read a display with four scripts in it as a
    /// formula set in seven point, and then nothing in it was a script.
    static func ordinarySize(of glyphs: [Glyph]) -> CGFloat {
        let ordinary = glyphs.filter {
            !$0.isExtension && !isBigOperator($0) && !isDelimiter($0) && !isRadical($0)
        }
        if let size = ordinary.map(\.size).max() { return size }
        return glyphs.filter { !$0.isExtension }.map(\.size).max() ?? glyphs.map(\.size).max() ?? 10
    }

    // MARK: - The recursion

    /// What a script hangs from: the last thing written at full height.
    private struct Base {
        var size: CGFloat
        var baseline: CGFloat
        var index: Int
    }

    private static func transcribe(
        _ glyphs: [Glyph], rules: [Rule], context: Context? = nil, line: CGFloat? = nil
    ) -> String {
        guard !glyphs.isEmpty else { return "" }
        let body = context?.bodySize ?? ordinarySize(of: glyphs)
        // The size of the line the whole formula is set on, which the smallest
        // scripts are measured against.
        let line = line ?? body
        // Matrices and cases first: a fraction in a cell is the cell's, and
        // a bar in the first row of a matrix would otherwise take the row
        // under it for its denominator.
        var grids: [Int: Grid] = [:]
        var gridded = Set<Int>()
        for index in glyphs.indices where !gridded.contains(index) {
            guard let found = grid(from: index, in: glyphs, rules: rules, body: body, consumed: gridded)
            else { continue }
            grids[index] = found
            gridded.formUnion(found.members)
        }
        let free = gridded.isEmpty ? glyphs : glyphs.indices.filter { !gridded.contains($0) }.map { glyphs[$0] }
        let found = fractionBars(among: rules, in: free)
        // The bars were found among the glyphs the grids left; their members
        // are counted in the whole formula's numbers.
        let positions = glyphs.indices.filter { !gridded.contains($0) }
        let bars = found.map { bar in
            Bar(rule: bar.rule, over: bar.over.map { positions[$0] }, under: bar.under.map { positions[$0] })
        }
        let baseline = context?.baseline ?? baselineOf(glyphs, bodySize: body, bars: bars)

        var owner: [Int: Int] = [:]
        for (number, bar) in bars.enumerated() {
            for member in bar.over + bar.under { owner[member] = number }
        }
        // What the grids hold is theirs; nothing found up front may take it.
        var consumed = gridded
        let roots = radicals(in: glyphs, rules: rules, body: body, baseline: baseline,
                             owned: owner, consumed: &consumed)
        let limits = operatorLimits(in: glyphs, body: body, baseline: baseline,
                                    owned: owner, consumed: &consumed)
        let names = operatorNames(in: glyphs, body: body, baseline: baseline,
                                  owned: owner, consumed: &consumed)
        let ruled = overlines(among: rules, in: glyphs, body: body, bars: bars, roots: roots,
                              owned: owner, consumed: consumed)
        let accented = accents(in: glyphs, owned: owner, consumed: &consumed)
        let struck = negations(in: glyphs, owned: owner, consumed: &consumed)

        var tokens: [String] = []
        var base: Base?
        var index = 0

        func others(than rule: Rule) -> [Rule] { rules.filter { $0.rect != rule.rect } }
        func part(_ members: [Int]) -> [Glyph] { byX(members.map { glyphs[$0] }) }

        while index < glyphs.count {
            if consumed.contains(index), grids[index] == nil { index += 1; continue }
            let glyph = glyphs[index]

            // A fraction: the bar and everything over and under it, as one
            // thing, written where its first glyph is. Set small and lifted
            // well off the line it is a superscript — e^{\frac{1}{2}} — and
            // set small and dropped, a subscript; otherwise it is on the line.
            if let number = owner[index] {
                let bar = bars[number]
                consumed.formUnion(bar.over + bar.under)
                let rest = others(than: bar.rule)
                var token = "\\frac{\(transcribe(part(bar.over), rules: rest, line: line))}"
                    + "{\(transcribe(part(bar.under), rules: rest, line: line))}"
                let parts = (bar.over + bar.under).map { glyphs[$0].size }.max() ?? body
                var scripted = false
                // Nothing is a script of an opening bracket.
                let opened = base.map { opening(glyphs[$0.index]) != nil } ?? false
                if let base, !tokens.isEmpty, !opened, parts < base.size * 0.8 {
                    let level = bar.rule.rect.midY - base.baseline
                    if level > base.size * 0.42 {
                        token = "^{\(token)}"
                        scripted = true
                    } else if level < base.size * 0.1 {
                        token = "_{\(token)}"
                        scripted = true
                    }
                }
                tokens.append(token)
                if !scripted { base = Base(size: body, baseline: baseline, index: index) }
                index += 1
                continue
            }

            // A big operator takes what is stacked over and under it.
            if let stacked = limits[index] {
                var token = mathToken(for: glyph)
                if let below = group(of: stacked.below.map { glyphs[$0] }, rules: rules, line: line) {
                    token += "_" + below
                }
                if let above = group(of: stacked.above.map { glyphs[$0] }, rules: rules, line: line) {
                    token += "^" + above
                }
                tokens.append(token)
                base = Base(size: body, baseline: baseline, index: index)
                index += 1
                continue
            }

            // A radical: the sign, the rule over what it takes, and the root
            // set in its crook.
            if let root = roots[index] {
                consumed.formUnion(root.radicand)
                let rest = others(than: root.vinculum)
                let inside = transcribe(part(root.radicand), rules: rest,
                                        context: Context(bodySize: body, baseline: baseline),
                                        line: line)
                let degree = root.degree.isEmpty ? ""
                    : transcribe(part(root.degree), rules: rest, line: line)
                tokens.append(degree.isEmpty ? "\\sqrt{\(inside)}" : "\\sqrt[\(degree)]{\(inside)}")
                base = Base(size: body, baseline: baseline, index: index)
                index += 1
                continue
            }

            // A name that takes limits, with them — "lim" with "n→∞" under it.
            if let named = names[index] {
                var token = named.command
                if let below = group(of: named.below.map { glyphs[$0] }, rules: rules, line: line) {
                    token += "_" + below
                }
                if let above = group(of: named.above.map { glyphs[$0] }, rules: rules, line: line) {
                    token += "^" + above
                }
                tokens.append(token)
                consumed.formUnion(named.letters)
                let last = named.letters.last ?? index
                base = Base(size: glyphs[last].size, baseline: glyphs[last].origin.y, index: last)
                index += 1
                continue
            }

            // A rule over a run, or under it.
            if let stroke = ruled[index] {
                consumed.formUnion(stroke.covered)
                let inside = transcribe(part(stroke.covered), rules: others(than: stroke.rule),
                                        context: Context(bodySize: body, baseline: baseline),
                                        line: line)
                tokens.append(stroke.over ? "\\overline{\(inside)}" : "\\underline{\(inside)}")
                base = Base(size: body, baseline: baseline, index: index)
                index += 1
                continue
            }

            // An accent and what it covers: one letter, or — a wide accent —
            // all of them.
            if let mark = accented[index] {
                consumed.formUnion(mark.covered)
                let inside = mark.covered.count == 1
                    ? mathToken(for: glyphs[mark.covered[0]])
                    : transcribe(part(mark.covered), rules: rules,
                                 context: Context(bodySize: body, baseline: baseline), line: line)
                tokens.append("\(mark.command){\(inside)}")
                let last = mark.covered.max() ?? index
                base = Base(size: glyphs[last].size, baseline: glyphs[last].origin.y, index: last)
                index += 1
                continue
            }

            // A run of small glyphs off the baseline is a script on whatever
            // came before it — and "small" means smaller than that, not
            // smaller than the average of the whole formula. This is asked
            // before anything is read as a bracket, because the "(" of an
            // "x^{(i)}" is a superscript first and a bracket second.
            if let base, !tokens.isEmpty,
               let script = scripts(from: index, in: glyphs, baseline: base.baseline,
                                    body: base.size, line: line, consumed: consumed) {
                var token = ""
                // A prime is raised like a superscript and written like a
                // mark: "t'" and never "t^{'}".
                if let primes = primes(script.raised) {
                    token += primes
                } else if let above = group(of: script.raised, rules: rules, line: line) {
                    token += "^" + above
                }
                if let below = group(of: script.lowered, rules: rules, line: line) {
                    token += "_" + below
                }
                if !token.isEmpty { tokens.append(token) }
                for member in index..<script.end { consumed.insert(member) }
                index = script.end
                continue
            }

            // A matrix, or a system of cases: rows of cells between tall
            // brackets, or after a tall brace that nothing closes.
            if let grid = grids[index] {
                consumed.formUnion(grid.members)
                let rows = grid.cells.enumerated().map { level, row in
                    row.map { cell in
                        cell.isEmpty ? "" : transcribe(
                            part(cell), rules: rules,
                            context: Context(bodySize: body, baseline: grid.baselines[level]), line: line)
                    }.joined(separator: " & ")
                }
                tokens.append("\\begin{\(grid.environment)} " + rows.joined(separator: " \\\\ ")
                              + " \\end{\(grid.environment)}")
                base = Base(size: body, baseline: baseline, index: grid.close ?? index)
                index += 1
                continue
            }

            // Two things stacked in parentheses with no bar between them.
            if let stack = binomial(from: index, in: glyphs, owned: owner, consumed: consumed) {
                consumed.formUnion(stack.top + stack.bottom)
                consumed.insert(stack.close)
                let top = transcribe(part(stack.top), rules: rules, line: line)
                let bottom = transcribe(part(stack.bottom), rules: rules, line: line)
                tokens.append("\\binom{\(top)}{\(bottom)}")
                base = Base(size: body, baseline: baseline, index: stack.close)
                index += 1
                continue
            }

            // A tall fence or delimiter is drawn as a stack of pieces: one
            // symbol, however many pieces it took to reach that height.
            if let fence = TeXGlyphNames.fence(glyph.glyphName) ?? opening(glyph) ?? closing(glyph) {
                var next = index + 1
                // The pieces stand one on another; two brackets side by side
                // — the "))" that closes two things at once — are two.
                while next < glyphs.count, !consumed.contains(next),
                      (TeXGlyphNames.fence(glyphs[next].glyphName) ?? opening(glyphs[next])
                        ?? closing(glyphs[next])) == fence
                        || TeXGlyphNames.isDecoration(glyphs[next].glyphName),
                      glyphs[next].isExtension == glyph.isExtension,
                      abs(glyphs[next].origin.x - glyph.origin.x) < glyph.size * 0.2,
                      abs(glyphs[next].origin.y - glyph.origin.y) > glyph.size * 0.2 {
                    consumed.insert(next)
                    next += 1
                }
                tokens.append(fence)
                // A bracket drawn from a point off the line — an extension
                // font's, or one of STIX's larger sizes — has its scripts
                // measured from the formula's own baseline.
                let offLine = glyph.isExtension || abs(glyph.origin.y - baseline) > body * 0.25
                base = Base(size: body, baseline: offLine ? baseline : glyph.origin.y, index: index)
                index = next
                continue
            }

            // Dots on the line, however many were drawn, are one symbol.
            if let dots = dotRun(from: index, in: glyphs, consumed: consumed) {
                tokens.append(dots.command)
                base = Base(size: glyph.size, baseline: glyph.origin.y, index: dots.end - 1)
                index = dots.end
                continue
            }

            // A bold face in a formula means a bold symbol — a vector, most
            // often — and that is how a person writing it down would put it.
            if let bold = boldRun(from: index, in: glyphs, consumed: consumed) {
                tokens.append(bold.text)
                base = Base(size: glyph.size, baseline: glyph.origin.y, index: bold.end - 1)
                index = bold.end
                continue
            }

            // Upright letters in a formula are a word, and a word is written
            // as one: "softmax" is \mathrm{softmax}, not s·o·f·t·\max.
            if let word = uprightRun(from: index, in: glyphs, consumed: consumed) {
                tokens.append(word.text)
                base = Base(size: glyph.size, baseline: glyph.origin.y, index: word.end - 1)
                index = word.end
                continue
            }

            let token = struck[index] ?? mathToken(for: glyph)
            if !token.isEmpty {
                tokens.append(token)
                let drawnOffLine = glyph.isExtension || isBigOperator(glyph)
                base = Base(size: glyph.size, baseline: drawnOffLine ? baseline : glyph.origin.y,
                            index: index)
            }
            index += 1
        }
        return join(tokens)
    }

    /// A glyph as it is written inside a formula.
    ///
    /// The same as `token`, except that what LaTeX cannot take as a character
    /// in mathematics is written as its command — whichever font drew it. A
    /// brace from a text font is `\{` in a formula, or the formula does not
    /// compile; MathTime draws set minus as a backslash, and a lone backslash
    /// is the start of a command that never comes; a Greek letter from Times
    /// is `\alpha` all the same. In a sentence all of these stay as they were
    /// typed, which is why this is not `token`.
    static func mathToken(for glyph: Glyph) -> String {
        let raw = token(for: glyph)
        if raw.count == 1 || raw.unicodeScalars.count == 1 {
            if let command = TeXGlyphNames.unicodeCommands[raw] { return command }
            if raw == "\\" { return "\\setminus" }
            if raw == "$" { return "\\$" }
        }
        return raw
    }

    /// The primes a raised run is, when that is all it is: one or more.
    private static func primes(_ glyphs: [Glyph]) -> String? {
        let marks = glyphs.map { token(for: $0) }
        guard !marks.isEmpty, marks.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "'" } })
        else { return nil }
        return marks.joined()
    }

    /// One script or limit, braced when it is more than a single symbol.
    private static func group(of glyphs: [Glyph], rules: [Rule], line: CGFloat) -> String? {
        guard !glyphs.isEmpty else { return nil }
        let inner = transcribe(byX(glyphs), rules: rules, line: line)
        guard !inner.isEmpty else { return nil }
        return inner.count > 1 ? "{\(inner)}" : inner
    }

    /// Joins tokens, putting a space only where LaTeX needs one: after a
    /// command whose name would otherwise run into the next letter.
    private static func join(_ tokens: [String]) -> String {
        var result = ""
        for token in tokens where !token.isEmpty {
            let next = token.first
            let needsSpace = (endsInCommand(result) && (next?.isLetter == true || next?.isNumber == true))
                // "^Lf" is read by LaTeX as "^{L}f", but nobody writes it that
                // way, and the copied formula is meant to be edited by hand.
                || (endsInBareScript(result) && (next?.isLetter == true || next?.isNumber == true))
            if needsSpace { result += " " }
            result += token
        }
        return result
    }

    /// Whether the text ends in a one-character script — "^L", "_i" — which
    /// the next letter would sit against.
    private static func endsInBareScript(_ text: String) -> Bool {
        guard text.count >= 2 else { return false }
        let last = text[text.index(before: text.endIndex)]
        guard last.isLetter || last.isNumber else { return false }
        let mark = text[text.index(text.endIndex, offsetBy: -2)]
        return mark == "^" || mark == "_"
    }

    /// Whether what has been built so far ends in a command name like
    /// `\alpha`, which the next letter would otherwise join.
    private static func endsInCommand(_ text: String) -> Bool {
        guard text.contains("\\") else { return false }
        let letters = text.reversed().prefix { $0.isLetter }
        guard !letters.isEmpty else { return false }
        let index = text.index(text.endIndex, offsetBy: -letters.count)
        return index > text.startIndex && text[text.index(before: index)] == "\\"
    }

    /// Where the formula's own baseline is: the level most of its full-size
    /// glyphs sit on. What is not on it is left out of the vote — the signs
    /// drawn from a point that is not on any baseline, the big operators,
    /// and whatever is over or under a fraction bar. A formula with nothing
    /// else in it is on the maths axis, a quarter of an em under the bar.
    private static func baselineOf(_ glyphs: [Glyph], bodySize: CGFloat, bars: [Bar]) -> CGFloat {
        let barred = Set(bars.flatMap { $0.over + $0.under })
        let voters = glyphs.indices.filter { index in
            let glyph = glyphs[index]
            return glyph.size >= bodySize * 0.92 && !glyph.isExtension && !isBigOperator(glyph)
                && !isRadical(glyph) && !barred.contains(index)
        }.map { glyphs[$0].origin.y }.sorted()
        if !voters.isEmpty { return voters[voters.count / 2] }
        if let bar = bars.first { return bar.rule.rect.midY - bodySize * 0.25 }
        let full = glyphs.filter { $0.size >= bodySize * 0.92 && !$0.isExtension }
        let sample = (full.isEmpty ? glyphs : full).map(\.origin.y).sorted()
        return sample[sample.count / 2]
    }

    /// Whether a glyph is an accent mark.
    static func isAccent(_ glyph: Glyph) -> Bool { accentName(of: glyph) != nil }

    /// What this glyph would be as an accent, if it is one.
    private static func accentName(of glyph: Glyph) -> String? {
        if let named = TeXGlyphNames.accent(glyph.glyphName) { return named }
        let drawn = token(for: glyph)
        switch drawn {
        case "^", "\u{02C6}", "\u{0302}": return "\\hat"
        case "~", "\u{02DC}", "\u{0303}": return "\\tilde"
        case "\u{00AF}", "\u{0304}", "\u{0305}": return "\\bar"
        case "\u{02D9}", "\u{0307}": return "\\dot"
        case "\u{00A8}", "\u{0308}": return "\\ddot"
        case "\u{02C7}", "\u{030C}": return "\\check"
        case "\u{02D8}", "\u{0306}": return "\\breve"
        case "\u{00B4}", "\u{0301}": return "\\acute"
        case "\u{0060}", "\u{0300}": return "\\grave"
        case "\u{20D7}": return "\\vec"
        default: return nil
        }
    }

    /// The size a formula is mostly set in: the commonest size, rounded to
    /// the nearest half point, so a cluster of small subscripts does not make
    /// the body look small.
    static func size(of glyphs: [Glyph]) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        for glyph in glyphs { counts[(glyph.size * 2).rounded() / 2, default: 0] += 1 }
        let common = counts.filter { $0.value >= max(2, glyphs.count / 8) }
        return common.keys.max() ?? glyphs.map(\.size).max() ?? 10
    }

    /// The scripts hanging from whatever came before: a run of small glyphs
    /// off the baseline.
    ///
    /// A subscript and a superscript are one arrangement, not two. TeX sets
    /// them in the same place, one over the other, so they arrive interleaved
    /// in reading order and have to be told apart by height instead.
    private static func scripts(
        from start: Int, in glyphs: [Glyph], baseline: CGFloat, body: CGFloat, line: CGFloat,
        consumed: Set<Int>
    ) -> (end: Int, raised: [Glyph], lowered: [Glyph])? {
        guard start > 0 else { return nil }
        var end = start
        var raised: [Glyph] = [], lowered: [Glyph] = []
        // The run may be nested: the "2" of "E_{N(z;\mu,\sigma^2)}" is a
        // superscript inside a subscript, and it climbs back above the line it
        // hangs from. Only glyphs at the run's own size decide a side; smaller
        // ones go wherever the last of those went, and the recursion works out
        // where they sit inside it.
        let primary = glyphs[start].size
        // TeX has three sizes and no fourth: a script on a script's script is
        // set as small as the script it hangs from, and only its place says
        // what it is — the "k" of x_{i_{j_k}}, the "i" of e^{z_i} in the
        // numerator of a fraction in a sentence.
        let smallest = body <= line * 0.62
        var side: Bool?
        while end < glyphs.count, !consumed.contains(end) {
            let glyph = glyphs[end]
            let offset = glyph.origin.y - baseline
            // Base level is always full size, so anything still small is still
            // part of the script. Only the first glyph has to be visibly off
            // the line: a script's own script — the "(l)" of "q_{\phi(z^{(l)})}"
            // — climbs back up to within a hair of the baseline it hangs from,
            // and stopping there cuts the subscript in half.
            let small = glyph.size < body * 0.92
            let asSmall = smallest && glyph.size <= body * 1.02 && abs(offset) >= body * 0.2
            // A sign drawn from an extension font is never a script: the brace
            // of \left\{ at a smaller size than the line is still the brace.
            guard small || asSmall, !isSpace(glyph), !glyph.isExtension else { break }
            // Word sets a subscript small and leaves it *on* the line —
            // "CO₂(Vᵢ)" in an MDPI paper is a 6 pt "2" and "i" at the 9.96 pt
            // text's own baseline. TeX never does that: its scripts are
            // always off the line — though by as little as a point at nine
            // point, which is a ninth of the body. (A rule that a script had
            // to be a tenth of the body off the line read "D_r" as "Dr" in
            // every nine-point paper.) So a glyph much smaller than the one
            // it touches, on that glyph's baseline, is its subscript, and a
            // small glyph anywhere off the line is a script on whichever
            // side it sits.
            if end == start, abs(offset) <= body * 0.03 {
                let touching = glyph.rect.minX - glyphs[start - 1].rect.maxX < body * 0.12
                guard glyph.size <= body * 0.72, touching,
                      glyphs[start - 1].size >= body * 0.92 else { break }
                var run = start
                while run < glyphs.count, !consumed.contains(run), glyphs[run].size <= body * 0.72,
                      abs(glyphs[run].origin.y - baseline) <= body * 0.03,
                      run == start || glyphs[run].rect.minX - glyphs[run - 1].rect.maxX < body * 0.12 {
                    run += 1
                }
                return (run, [], Array(glyphs[start..<run]))
            }
            if end > start,
               glyph.rect.minX - glyphs[end - 1].rect.maxX > body * 0.25 { break }
            let deeper = glyph.size < primary * 0.92
            let raisedHere = deeper ? (side ?? (offset > 0)) : offset > 0
            if !deeper { side = raisedHere }
            if raisedHere { raised.append(glyph) } else { lowered.append(glyph) }
            end += 1
        }
        return end > start ? (end, raised, lowered) : nil
    }

    /// The names TeX sets in roman inside a formula, because each is a word.
    private static let operatorNames: Set<String> = [
        "log", "ln", "lg", "exp", "sin", "cos", "tan", "cot", "sec", "csc",
        "sinh", "cosh", "tanh", "coth", "arcsin", "arccos", "arctan",
        "min", "max", "inf", "sup", "lim", "det", "dim", "ker", "deg",
        "gcd", "hom", "arg", "Pr",
    ]

    /// The names written as two words, which a thin space joins on the page.
    private static let twoWordNames: [String: String] = [
        "argmin": "\\arg\\min", "argmax": "\\arg\\max", "limsup": "\\limsup",
        "liminf": "\\liminf",
    ]

    /// The names that take limits under them in a display, as a sum does.
    private static let namesWithLimits: Set<String> = [
        "min", "max", "inf", "sup", "lim", "det", "gcd", "Pr", "argmin", "argmax", "limsup",
        "liminf",
    ]

    /// Whether a run of letters spells one of those names.
    static func isOperatorName(_ spelled: String) -> Bool {
        operatorNames.contains(spelled) || twoWordNames[spelled] != nil
    }

    /// Dots in a row: three centred ones are `\cdots`, three on the line are
    /// `\ldots`, and one on its own is a product.
    private static func dotRun(
        from start: Int, in glyphs: [Glyph], consumed: Set<Int>
    ) -> (end: Int, command: String)? {
        let first = token(for: glyphs[start])
        let centred = (first == "\u{00B7}" || first == "\\cdot")
        guard centred || first == "." else { return nil }
        var end = start + 1
        while end < glyphs.count, !consumed.contains(end),
              token(for: glyphs[end]) == first,
              glyphs[end].rect.minX - glyphs[end - 1].rect.maxX < glyphs[end].size * 0.6 {
            end += 1
        }
        if end - start >= 2 { return (end, centred ? "\\cdots" : "\\ldots") }
        return centred ? (end, "\\cdot") : nil
    }

    /// A run of glyphs from a bold face, wrapped once rather than letter by
    /// letter.
    private static func boldRun(
        from start: Int, in glyphs: [Glyph], consumed: Set<Int>
    ) -> (end: Int, text: String)? {
        guard let command = boldCommand(for: glyphs[start]) else { return nil }
        var end = start + 1
        while end < glyphs.count, !consumed.contains(end),
              boldCommand(for: glyphs[end]) == command,
              abs(glyphs[end].origin.y - glyphs[start].origin.y) < 0.01,
              glyphs[end].rect.minX - glyphs[end - 1].rect.maxX < glyphs[end].size * 0.22 {
            end += 1
        }
        let inner = join(glyphs[start..<end].map { mathToken(for: $0) })
        guard !inner.isEmpty else { return nil }
        return (end, "\(command){\(inner)}")
    }

    static func boldCommand(for glyph: Glyph) -> String? {
        // A glyph named by its code point carries its own weight and style
        // (`TeXGlyphNames.mathAlphanumeric`); wrapping it again would give
        // \boldsymbol{\boldsymbol{x}}.
        if let name = glyph.glyphName, TeXGlyphNames.unicodeName(name) != nil { return nil }
        // An alphabet of its own — mathpazo's bold blackboard — is that
        // alphabet, not bold: \mathbb{E}, never \boldsymbol{\mathbb{E}}.
        if TeXGlyphNames.letterStyle(fontName: glyph.fontName) != nil { return nil }
        let upper = family(of: glyph)
        // The bold maths italics: Computer Modern's, Latin Modern's, the tx
        // and px families', MathTime's.
        if upper.hasPrefix("CMMIB") || upper.hasPrefix("CMBSY") || upper.hasPrefix("RMTMIB")
            || upper.contains("BMI") || upper.contains("BSY") || upper.hasPrefix("EURB")
            || (upper.contains("MATH") && (upper.contains("BOLD") || upper.hasSuffix("-B"))) {
            return "\\boldsymbol"
        }
        // The bold text faces, which is what \mathbf draws with.
        // Libertine's bold faces are LinLibertineTB and, for \mathbf, the
        // semibold LinLibertineTZ.
        if upper.hasPrefix("LINLIBERTINET"), upper.dropFirst(13).hasPrefix("B")
            || upper.dropFirst(13).hasPrefix("Z") {
            return upper.hasSuffix("I") ? "\\boldsymbol" : "\\mathbf"
        }
        if upper.hasPrefix("CMBX") || upper.hasPrefix("SFBX") || upper.contains("-BOLD")
            || upper.hasSuffix("-BD") || upper.contains("-MEDI") || upper.hasSuffix("-B")
            || upper.hasSuffix("BOLD") || upper.hasSuffix("-BOL") || upper.hasPrefix("CMB10")
            || upper.hasPrefix("RTXB") || upper.hasPrefix("RPXB") {
            return "\\mathbf"
        }
        return nil
    }

    /// Upright letters set touching, as one word: \mathrm{softmax},
    /// \mathrm{d}, \mathsf{T}. Nil when the glyph is not an upright letter.
    private static func uprightRun(
        from start: Int, in glyphs: [Glyph], consumed: Set<Int>
    ) -> (end: Int, text: String)? {
        let first = glyphs[start]
        // A ligature is letters too: Libertine sets the "ft" of "softmax" as
        // one glyph.
        func isUprightLetter(_ glyph: Glyph) -> Bool {
            if Self.isUprightLetter(glyph) { return true }
            let spelled = token(for: glyph)
            return (2...3).contains(spelled.count) && spelled.allSatisfy { $0.isASCII && $0.isLetter }
                && !isMathFont(glyph) && !isItalicFace(family(of: glyph)) && boldCommand(for: glyph) == nil
        }
        guard isUprightLetter(first) else { return nil }
        let style = uprightStyle(first)
        func continues(_ at: Int) -> Bool {
            let glyph = glyphs[at]
            return !consumed.contains(at) && uprightStyle(glyph) == style
                && abs(glyph.origin.y - first.origin.y) < first.size * 0.1
                && abs(glyph.size - first.size) < first.size * 0.1
                && glyph.rect.minX - glyphs[at - 1].rect.maxX < glyph.size * 0.22
        }
        var end = start + 1
        var hyphenated = false
        while end < glyphs.count, continues(end) {
            if isUprightLetter(glyphs[end]) {
                end += 1
                continue
            }
            // A hyphen between two letters is part of the word:
            // "teacher-forcing" under an L is one name, not two and a minus.
            guard !isMathFont(glyphs[end]), token(for: glyphs[end]) == "-",
                  end + 1 < glyphs.count, isUprightLetter(glyphs[end + 1]), continues(end + 1)
            else { break }
            hyphenated = true
            end += 2
        }
        let letters = glyphs[start..<end].map { token(for: $0) }.joined()
        if hyphenated { return (end, "\\text{\(letters)}") }
        if style == "\\mathrm", let names = names(in: letters), !names.isEmpty {
            return (end, names.map { twoWordNames[$0] ?? "\\" + $0 }.joined())
        }
        return (end, "\(style){\(letters)}")
    }

    // MARK: - Structures

    /// A fraction bar, and which glyphs are over it and under it.
    private struct Bar {
        var rule: Rule
        var over: [Int]
        var under: [Int]
    }

    /// Whether a glyph is across the width of a rule.
    private static func spans(_ rule: Rule, _ glyph: Glyph) -> Bool {
        let middle = glyph.rect.midX
        return middle > rule.rect.minX - 0.5 && middle < rule.rect.maxX + 0.5
    }

    private static func extent(_ glyphs: [Glyph]) -> CGRect {
        guard let first = glyphs.first else { return .null }
        return glyphs.dropFirst().reduce(first.rect) { $0.union($1.rect) }
    }

    /// The fraction bars: rules with something over them and something under,
    /// each owning what is across its width — the widest first, so that a
    /// fraction inside a fraction belongs to the numerator it is in.
    ///
    /// A bar is as wide as what it divides, and a hair more. A rule running
    /// well past it — a table's \hline over a row of cells — is not one.
    private static func fractionBars(among rules: [Rule], in glyphs: [Glyph]) -> [Bar] {
        var bars: [Bar] = []
        var owned = Set<Int>()
        for rule in rules.sorted(by: { $0.rect.width > $1.rect.width })
        where rule.rect.width > 1 && rule.rect.height < rule.rect.width
            && !isVinculum(rule, in: glyphs) {
            let inside = glyphs.indices.filter { !owned.contains($0) && spans(rule, glyphs[$0]) }
            let over = inside.filter { glyphs[$0].origin.y > rule.rect.midY }
            let under = inside.filter { glyphs[$0].origin.y <= rule.rect.midY }
            guard !over.isEmpty, !under.isEmpty else { continue }
            let parts = extent(inside.map { glyphs[$0] })
            guard rule.rect.minX > parts.minX - 4, rule.rect.maxX < parts.maxX + 4 else { continue }
            bars.append(Bar(rule: rule, over: over, under: under))
            owned.formUnion(inside)
        }
        return bars
    }

    /// Whether a rule is the roof of a radical: it starts where a radical
    /// sign ends, at the sign's top.
    private static func isVinculum(_ rule: Rule, in glyphs: [Glyph]) -> Bool {
        glyphs.contains { isVinculum(rule, of: $0) }
    }

    private static func isVinculum(_ rule: Rule, of sign: Glyph) -> Bool {
        guard isRadical(sign) else { return false }
        return abs(rule.rect.minX - sign.rect.maxX) < max(1, sign.size * 0.15)
            && rule.rect.midY > sign.origin.y - sign.size * 3
            && rule.rect.midY < sign.origin.y + sign.size * 2.5
    }

    /// A radical, what its rule covers, and the root in its crook.
    private struct Root {
        var vinculum: Rule
        var radicand: [Int]
        var degree: [Int]
    }

    /// The radicals, keyed by their sign; their roots are taken up front,
    /// because a root is written before its sign when it is wider than the
    /// crook, and would be read as a superscript on whatever came before.
    private static func radicals(
        in glyphs: [Glyph], rules: [Rule], body: CGFloat, baseline: CGFloat,
        owned: [Int: Int], consumed: inout Set<Int>
    ) -> [Int: Root] {
        var found: [Int: Root] = [:]
        for (index, sign) in glyphs.enumerated()
        where isRadical(sign) && owned[index] == nil && !consumed.contains(index) {
            guard let vinculum = rules.filter({ isVinculum($0, of: sign) })
                .min(by: { abs($0.rect.minX - sign.rect.maxX) < abs($1.rect.minX - sign.rect.maxX) })
            else { continue }
            let radicand = glyphs.indices.filter {
                $0 != index && !consumed.contains($0) && spans(vinculum, glyphs[$0])
                    && glyphs[$0].origin.y < vinculum.rect.midY
            }
            let full = radicand.map { glyphs[$0] }.filter { $0.size >= body * 0.92 && !$0.isExtension }
            let floor = full.isEmpty ? baseline : full.map(\.origin.y).sorted()[full.count / 2]
            let degree = glyphs.indices.filter { other in
                let glyph = glyphs[other]
                return other != index && !consumed.contains(other) && !radicand.contains(other)
                    && owned[other] == nil && glyph.size < body * 0.8
                    && glyph.rect.maxX <= vinculum.rect.minX + 0.5
                    && glyph.rect.maxX > sign.rect.minX + 1
                    && glyph.rect.minX > sign.rect.minX - body * 1.5
                    && glyph.origin.y > floor + body * 0.25
            }
            consumed.formUnion(degree)
            found[index] = Root(vinculum: vinculum, radicand: radicand, degree: degree)
        }
        return found
    }

    /// Glyphs that follow one another closely, as runs.
    private static func runs(of members: [Int], in glyphs: [Glyph], gap: CGFloat) -> [[Int]] {
        let ordered = members.sorted {
            glyphs[$0].rect.minX != glyphs[$1].rect.minX
                ? glyphs[$0].rect.minX < glyphs[$1].rect.minX : $0 < $1
        }
        var runs: [[Int]] = []
        for member in ordered {
            if let last = runs.last?.last,
               glyphs[member].rect.minX - glyphs[last].rect.maxX < gap {
                runs[runs.count - 1].append(member)
            } else {
                runs.append([member])
            }
        }
        return runs
    }

    /// The limits of each big operator, found before anything else is read.
    ///
    /// Their limits are set around the sign — stacked over and under it in a
    /// displayed formula, beside it in a line of running text — and either
    /// way "i=1" arrives before the sign it belongs to, or interleaved with
    /// the limit above it. Each operator takes, on each side, the run of
    /// small glyphs that is centred on it or starts at its right edge; what
    /// one operator took, the next cannot.
    private static func operatorLimits(
        in glyphs: [Glyph], body: CGFloat, baseline: CGFloat,
        owned: [Int: Int], consumed: inout Set<Int>
    ) -> [Int: (above: [Int], below: [Int])] {
        var limits: [Int: (above: [Int], below: [Int])] = [:]
        for (position, sign) in glyphs.enumerated()
        where isBigOperator(sign) && owned[position] == nil && !consumed.contains(position) {
            // Whatever full-size thing comes next is where the limits stop, in
            // both arrangements.
            var stop = CGFloat.greatestFiniteMagnitude
            for next in (position + 1)..<glyphs.count
            where !consumed.contains(next) && glyphs[next].size >= body * 0.95 {
                stop = glyphs[next].rect.minX
                break
            }
            let candidates = glyphs.indices.filter { other in
                let glyph = glyphs[other]
                return other != position && !consumed.contains(other) && owned[other] == nil
                    && glyph.size < body * 0.95 && glyph.rect.midX < stop && !glyph.isExtension
                    && glyph.rect.maxX > sign.rect.minX - body * 3
            }
            func take(_ side: [Int]) -> [Int] {
                for run in runs(of: side, in: glyphs, gap: body * 0.4) {
                    let span = extent(run.map { glyphs[$0] })
                    let stacked = span.minX < sign.rect.maxX && span.maxX > sign.rect.minX
                        && abs(span.midX - sign.rect.midX) < max(span.width, sign.rect.width) * 0.5 + 1
                    // An integral's lower limit tucks in under its tail.
                    let beside = span.minX >= sign.rect.midX
                        && span.minX - sign.rect.maxX < body * 0.5
                    if stacked || beside { return run }
                }
                return []
            }
            let above = take(candidates.filter { glyphs[$0].origin.y > baseline + body * 0.12 })
            let below = take(candidates.filter { glyphs[$0].origin.y < baseline - body * 0.12 })
            consumed.formUnion(above + below)
            limits[position] = (above, below)
        }
        return limits
    }

    /// A name set in roman that takes limits under it in a display, and them.
    private struct Named {
        var letters: [Int]
        var command: String
        var below: [Int]
        var above: [Int]
    }

    /// The names that take limits — "lim", "max", "arg min" — found with
    /// the limits under them before anything is read. A limit centred under
    /// a word arrives shuffled in among its letters, and it starts to the left
    /// of the first of them when it is the wider of the two: "n→∞" under
    /// "lim" was read as an "n" before the name and an arrow after it.
    private static func operatorNames(
        in glyphs: [Glyph], body: CGFloat, baseline: CGFloat,
        owned: [Int: Int], consumed: inout Set<Int>
    ) -> [Int: Named] {
        var found: [Int: Named] = [:]
        func letter(_ index: Int) -> Bool {
            let glyph = glyphs[index]
            return !consumed.contains(index) && owned[index] == nil && glyph.size >= body * 0.92
                && isUprightLetter(glyph) && uprightStyle(glyph) == "\\mathrm"
        }
        func limited(name: String, letters: [Int]) -> Named? {
            guard namesWithLimits.contains(name) else { return nil }
            let command = twoWordNames[name] ?? "\\" + name
            let span = extent(letters.map { glyphs[$0] })
            let candidates = glyphs.indices.filter { other in
                let glyph = glyphs[other]
                return !consumed.contains(other) && owned[other] == nil && glyph.size < body * 0.92
                    && !glyph.isExtension
                    && glyph.rect.maxX > span.minX - body * 3 && glyph.rect.minX < span.maxX + body * 3
            }
            // Only a limit stacked under the name: a subscript beside it is
            // a script, which the reading after this finds as one.
            var below: [Int] = []
            for run in runs(of: candidates.filter { glyphs[$0].origin.y < baseline - body * 0.3 },
                            in: glyphs, gap: body * 0.4) {
                let under = extent(run.map { glyphs[$0] })
                if under.minX < span.maxX, under.maxX > span.minX,
                   abs(under.midX - span.midX) < max(under.width, span.width) * 0.5 + 1 {
                    below = run
                    break
                }
            }
            guard !below.isEmpty else { return nil }
            consumed.formUnion(below)
            return Named(letters: letters, command: command, below: below, above: [])
        }
        var index = 0
        while index < glyphs.count {
            guard letter(index) else { index += 1; continue }
            var letters = [index]
            var next = index + 1
            while next < glyphs.count {
                let glyph = glyphs[next]
                if consumed.contains(next) || glyph.size < body * 0.92 { next += 1; continue }
                guard letter(next),
                      glyph.rect.minX - glyphs[letters[letters.count - 1]].rect.maxX <= glyph.size * 0.22
                else { break }
                letters.append(next)
                next += 1
            }
            index = letters[letters.count - 1] + 1
            // Two names set side by side — \min_G\max_D — are one run of
            // letters with a thin space in it; each takes its own limit.
            let spelled = letters.map { token(for: glyphs[$0]) }.joined()
            guard let names = names(in: spelled) else { continue }
            var offset = 0
            for name in names {
                let own = Array(letters[offset..<(offset + name.count)])
                offset += name.count
                if let named = limited(name: name, letters: own) { found[own[0]] = named }
            }
        }
        return found
    }

    /// A run of letters as the names it spells one after another — "minmax"
    /// is min and max — or nil when it is not only names.
    static func names(in spelled: String) -> [String]? {
        if spelled.isEmpty { return [] }
        let known = operatorNames.union(twoWordNames.keys)
        for length in stride(from: min(spelled.count, 6), through: 2, by: -1) {
            let head = String(spelled.prefix(length))
            guard known.contains(head), let rest = names(in: String(spelled.dropFirst(length)))
            else { continue }
            return [head] + rest
        }
        return nil
    }

    /// A rule over a run of glyphs, or under it.
    private struct Ruled {
        var rule: Rule
        var covered: [Int]
        var over: Bool
    }

    /// The rules that are not fraction bars and not the roofs of radicals —
    /// \overline and \underline — keyed by the first glyph they cover. Such a
    /// rule is as wide as what it covers and close to it.
    private static func overlines(
        among rules: [Rule], in glyphs: [Glyph], body: CGFloat, bars: [Bar], roots: [Int: Root],
        owned: [Int: Int], consumed: Set<Int>
    ) -> [Int: Ruled] {
        var found: [Int: Ruled] = [:]
        var taken = Set<Int>()
        let used = bars.map(\.rule.rect) + roots.values.map(\.vinculum.rect)
        for rule in rules.sorted(by: { $0.rect.width > $1.rect.width })
        where rule.rect.width > 1 && rule.rect.height < rule.rect.width
            && !used.contains(rule.rect) && !isVinculum(rule, in: glyphs) {
            let inside = glyphs.indices.filter {
                !consumed.contains($0) && !taken.contains($0) && owned[$0] == nil
                    && spans(rule, glyphs[$0])
            }
            guard !inside.isEmpty else { continue }
            let under = inside.filter { glyphs[$0].origin.y < rule.rect.midY }
            let over = inside.filter { glyphs[$0].origin.y >= rule.rect.midY }
            guard under.isEmpty != over.isEmpty else { continue }
            let span = extent(inside.map { glyphs[$0] })
            guard rule.rect.minX > span.minX - 2, rule.rect.maxX < span.maxX + 2 else { continue }
            let isOver = !under.isEmpty
            let heights = inside.map { glyphs[$0].origin.y }
            let near = isOver
                ? rule.rect.midY - (heights.max() ?? 0) < body * 1.3
                : (heights.min() ?? 0) - rule.rect.midY < body * 0.6
            guard near, let first = inside.min() else { continue }
            found[first] = Ruled(rule: rule, covered: inside, over: isOver)
            taken.formUnion(inside)
        }
        return found
    }

    /// An accent and the glyphs under it.
    private struct Accent {
        var command: String
        var covered: [Int]
    }

    /// The accents, keyed by the first glyph each covers.
    ///
    /// TeX does not lift an accent off the baseline — the glyph carries its
    /// own height — so an accent is a mark drawn *on top of* what it
    /// accents, at nearly the same baseline. It covers each glyph it lies
    /// across for at least half of the narrower of the two: one letter for
    /// \hat, all three for \widehat{xyz}.
    private static func accents(
        in glyphs: [Glyph], owned: [Int: Int], consumed: inout Set<Int>
    ) -> [Int: Accent] {
        var found: [Int: Accent] = [:]
        for (index, mark) in glyphs.enumerated()
        where !consumed.contains(index) && owned[index] == nil {
            guard let command = accentName(of: mark) else { continue }
            var covered: [Int]
            if mark.width < 0.05 {
                // A combining mark takes no room: its ink hangs to the left
                // of where it is drawn, over the glyph it follows — the full
                // size one, not the subscript that has crept under it.
                let before = glyphs.indices.filter { other in
                    let glyph = glyphs[other]
                    return other != index && !consumed.contains(other) && owned[other] == nil
                        && accentName(of: glyph) == nil && !isSpace(glyph)
                        && glyph.size >= mark.size * 0.9
                        && abs(glyph.origin.y - mark.origin.y) < max(glyph.size, 1) * 0.35
                        && glyph.rect.maxX <= mark.origin.x + mark.size * 0.1
                        && glyph.rect.maxX > mark.origin.x - mark.size * 0.6
                }
                covered = before.max { glyphs[$0].rect.maxX < glyphs[$1].rect.maxX }.map { [$0] } ?? []
            } else {
                covered = glyphs.indices.filter { other in
                    let glyph = glyphs[other]
                    guard other != index, !consumed.contains(other), owned[other] == nil,
                          accentName(of: glyph) == nil, !isSpace(glyph),
                          abs(glyph.origin.y - mark.origin.y) < max(glyph.size, 1) * 0.35
                    else { return false }
                    let overlap = min(glyph.rect.maxX, mark.rect.maxX) - max(glyph.rect.minX, mark.rect.minX)
                    return overlap > min(glyph.width, mark.width) * 0.5
                }
            }
            guard let first = covered.min() else {
                // A combining mark with nothing under it is dropped: written
                // out, it would sit on whatever came before.
                if mark.width < 0.05, token(for: mark).unicodeScalars.allSatisfy({ $0.properties.generalCategory == .nonspacingMark }) {
                    consumed.insert(index)
                }
                continue
            }
            let wide = TeXGlyphNames.isWideAccent(mark.glyphName) || covered.count > 1
            let written = !wide ? command
                : command == "\\tilde" ? "\\widetilde" : command == "\\hat" ? "\\widehat" : command
            consumed.insert(index)
            found[first] = Accent(command: written, covered: covered)
        }
        return found
    }

    /// Relations struck through — `\not` over `=`, a slash across `\in` —
    /// written as the one relation they make, keyed by the relation.
    private static func negations(
        in glyphs: [Glyph], owned: [Int: Int], consumed: inout Set<Int>
    ) -> [Int: String] {
        var found: [Int: String] = [:]
        for (index, stroke) in glyphs.enumerated()
        where !consumed.contains(index) && owned[index] == nil {
            let drawn = token(for: stroke)
            guard drawn == "\\not" || drawn == "/" else { continue }
            for other in [index + 1, index - 1] where glyphs.indices.contains(other) {
                let relation = glyphs[other]
                guard !consumed.contains(other), owned[other] == nil, found[other] == nil,
                      abs(relation.origin.y - stroke.origin.y) < relation.size * 0.2
                else { continue }
                let crossed: Bool
                if drawn == "\\not" {
                    crossed = abs(relation.origin.x - stroke.origin.x) < relation.size * 0.3
                } else {
                    let overlap = min(relation.rect.maxX, stroke.rect.maxX)
                        - max(relation.rect.minX, stroke.rect.minX)
                    crossed = overlap > min(relation.width, stroke.width) * 0.7
                }
                guard crossed, let negated = negated(mathToken(for: relation), with: drawn)
                else { continue }
                found[other] = negated
                consumed.insert(index)
                break
            }
        }
        return found
    }

    /// The relation `\not` makes of another, as a person would write it.
    private static func negated(_ relation: String, with stroke: String) -> String? {
        let known: [String: String] = [
            "=": "\\neq", "\\in": "\\notin", "<": "\\nless", ">": "\\ngtr",
            "\\leq": "\\nleq", "\\geq": "\\ngeq", "\\sim": "\\nsim", "\\cong": "\\ncong",
            "\\subseteq": "\\nsubseteq", "\\supseteq": "\\nsupseteq", "\\mid": "\\nmid",
            "|": "\\nmid", "\\parallel": "\\nparallel", "\\|": "\\nparallel",
            "\\exists": "\\nexists", "\\equiv": "\\not\\equiv", "\\subset": "\\not\\subset",
            "\\supset": "\\not\\supset", "\\approx": "\\not\\approx", "\\ni": "\\not\\ni",
            "\\prec": "\\nprec", "\\succ": "\\nsucc", "\\vdash": "\\nvdash",
        ]
        if let named = known[relation] { return named }
        // A slash is only a negation across a relation; across anything else
        // it is the slash it looks like.
        return stroke == "\\not" && !relation.isEmpty ? "\\not" + relation : nil
    }

    /// Rows of cells: a matrix between tall brackets, or cases after a tall
    /// brace. What the brackets hold is two lines or more, a line apart —
    /// not a superscript and a subscript, which are less than a line apart
    /// and small — and a line breaks into cells where TeX put a column's
    /// space, an em or more, which nothing inside a cell is spaced by.
    /// Whether a glyph is one piece of a bracket built up tall: ⎛ ⎜ ⎝ and
    /// their kind in OpenType, "parenlefttp" and "parenleftex" in TeX's
    /// extension fonts, "parenlefttpA" in newtx's. A whole bracket — a "("
    /// of any size — is none.
    static func isPiece(_ glyph: Glyph) -> Bool {
        if isSilentPiece(glyph) { return true }
        if let unicode = glyph.unicode, unicode.unicodeScalars.count == 1,
           let scalar = unicode.unicodeScalars.first, (0x239B...0x23B3).contains(scalar.value) { return true }
        guard var name = glyph.glyphName else { return false }
        if let dot = name.firstIndex(of: ".") { name = String(name[..<dot]) }
        if TeXGlyphNames.isDecoration(name) { return true }
        if ["tpA", "btA", "exA", "midA"].contains(where: { name.hasSuffix($0) }) { name.removeLast() }
        let bracket = ["paren", "bracket", "brace", "floor", "ceiling", "angle", "bar", "vextend"]
            .contains { name.hasPrefix($0) }
        return bracket && ["tp", "bt", "ex", "mid"].contains { name.hasSuffix($0) }
    }

    /// The pieces of one bracket, grown out from one of them through the
    /// ones above and below it: the bracket's box, and which glyphs it took.
    /// `candidates` stand where it does and spell what it spells, or nothing.
    ///
    /// Two ways a glyph is the same bracket. A bracket's own segments are set
    /// closer than a line — a tall bar is one glyph repeated, 0.3 to 0.6 of
    /// a size apart — and two brackets on two lines are a line apart at
    /// least. And a named piece (`isPiece`) belongs to its neighbours two
    /// lines away, as far as TeX sets a bracket's top from its bottom.
    /// Joining everything at the same place took the "(" of one line and the
    /// "(" of a line further down the page for one bracket as tall as the
    /// lines between them, and those lines for its matrix. A piece's box is
    /// not its ink — newtx's and OpenType's pieces are drawn from their point
    /// up by more than a size — so nearness is between their points.
    static func stack(from start: Int, in glyphs: [Glyph], candidates: [Int]) -> (box: CGRect, members: [Int]) {
        var box = glyphs[start].rect
        var members = [start]
        let size = glyphs[start].size
        var grew = true
        while grew {
            grew = false
            for other in candidates where !members.contains(other) {
                let distance = members.map { abs(glyphs[$0].origin.y - glyphs[other].origin.y) }.min() ?? .infinity
                guard distance < size * 0.8 || (isPiece(glyphs[other]) && distance < size * 2.2) else { continue }
                box = box.union(glyphs[other].rect)
                members.append(other)
                grew = true
            }
        }
        return (box, members)
    }

    private struct Grid {
        var environment: String
        var cells: [[[Int]]]
        var baselines: [CGFloat]
        var members: Set<Int>
        var close: Int?
    }

    private static let matrices: [String: (close: String, environment: String)] = [
        "(": (")", "pmatrix"), "[": ("]", "bmatrix"), "\\{": ("\\}", "Bmatrix"),
        "|": ("|", "vmatrix"), "\\|": ("\\|", "Vmatrix"), "\\mid": ("\\mid", "vmatrix"),
    ]

    private static func grid(
        from start: Int, in glyphs: [Glyph], rules: [Rule], body: CGFloat, consumed: Set<Int>
    ) -> Grid? {
        let open = glyphs[start]
        let opener = opening(open) ?? TeXGlyphNames.fence(open.glyphName)
            ?? (["|", "\\|", "\\mid"].contains(token(for: open)) ? token(for: open) : nil)
        guard let opener, let kind = matrices[opener] else { return nil }
        func same(_ other: Glyph) -> Bool {
            other.isExtension == open.isExtension && abs(other.size - open.size) < 0.5
                && abs(other.origin.y - open.origin.y) < max(1, open.size * 0.15)
        }
        func closes(_ other: Glyph) -> Bool {
            (closing(other) ?? TeXGlyphNames.fence(other.glyphName) ?? token(for: other)) == kind.close
        }
        let close = glyphs.indices.first { $0 > start && !consumed.contains($0) && closes(glyphs[$0]) && same(glyphs[$0]) }
        // A bracket is drawn in pieces one over another; the ones below the
        // top are the bracket too.
        func pieces(at x: CGFloat) -> [Int] {
            glyphs.indices.filter { other in
                !consumed.contains(other) && abs(glyphs[other].origin.x - x) < open.size * 0.2
                    && (TeXGlyphNames.isDecoration(glyphs[other].glyphName) || token(for: glyphs[other]).isEmpty
                        || opening(glyphs[other]) == opener || closing(glyphs[other]) == kind.close
                        || token(for: glyphs[other]) == opener || token(for: glyphs[other]) == kind.close)
            }
        }
        // Only this bracket's own pieces: another bracket at the same place
        // on another line is not this one (`stack`).
        let frame = stack(from: start, in: glyphs, candidates: pieces(at: open.origin.x)).members
            + (close.map { stack(from: $0, in: glyphs, candidates: pieces(at: glyphs[$0].origin.x)).members } ?? [])
        var reach = frame.map { glyphs[$0].rect }.reduce(open.rect) { $0.union($1) }
        // One OpenType glyph, of a size the file does not give: as tall as
        // two lines either side of it, when it is one of its larger sizes.
        if frame.count <= 2, isTallVariant(open, among: glyphs, body: body) {
            reach = reach.union(CGRect(x: open.rect.minX, y: open.origin.y - body * 2.2,
                                       width: open.rect.width, height: body * 4.4))
        }
        let right = close.map { glyphs[$0].rect.minX + 0.5 } ?? .greatestFiniteMagnitude
        // Cases has no closing brace; what it holds is what is beside it,
        // as high as it reaches.
        if close == nil, opener != "\\{" { return nil }
        // Between the brackets, and as high as they reach — a little lower,
        // since the last line's descenders and subscripts hang below them.
        let content = glyphs.indices.filter { other in
            let glyph = glyphs[other]
            return other != start && !consumed.contains(other) && !frame.contains(other)
                && glyph.rect.minX >= open.rect.maxX - 0.5 && glyph.rect.maxX <= right
                && glyph.origin.y > reach.minY - body * 1.0 && glyph.origin.y < reach.maxY + body * 0.3
                && !token(for: glyph).isEmpty
        }
        guard content.count >= 2 else { return nil }
        let largest = content.map { glyphs[$0].size }.max() ?? body
        // Brackets that hold two lines are as tall as two lines. A bracket of
        // the size of the letters beside it holds a fraction or a script —
        // `softmax(QKᵀ/√d)`, `1/|𝓑|` — however its contents stand.
        guard reach.height >= largest * 1.7 else { return nil }
        // The lines, by where the glyphs at the content's own size sit. A
        // radical hangs from where it stands, so where it stands is not a line.
        var levels: [CGFloat] = []
        for other in content.sorted(by: { glyphs[$0].origin.y > glyphs[$1].origin.y })
        where glyphs[other].size >= largest * 0.8 && !isBigOperator(glyphs[other])
            && !isRadical(glyphs[other]) && !glyphs[other].isExtension {
            let height = glyphs[other].origin.y
            if let last = levels.last, last - height < largest * 0.45 { continue }
            levels.append(height)
        }
        guard levels.count >= 2 else { return nil }
        for (upper, lower) in zip(levels, levels.dropFirst()) where upper - lower < largest * 0.9 {
            return nil
        }
        // A bar between two of the lines makes them a fraction's numerator
        // and denominator, whatever brackets stand round them.
        let span = extent(content.map { glyphs[$0] })
        if rules.contains(where: { rule in
            rule.rect.width > 1 && rule.rect.height < rule.rect.width
                && rule.rect.maxX > span.minX && rule.rect.minX < span.maxX
                && rule.rect.midY < levels[0] && rule.rect.midY > levels[levels.count - 1]
                && rule.rect.minX > open.rect.minX - 1 && rule.rect.maxX < right + 1
        }) { return nil }
        var rows: [[Int]] = Array(repeating: [], count: levels.count)
        for other in content {
            let height = glyphs[other].origin.y
            let nearest = levels.indices.min { abs(levels[$0] - height) < abs(levels[$1] - height) } ?? 0
            rows[nearest].append(other)
        }
        // A line's cells, where a column's space cuts it.
        var cells: [[(members: [Int], span: CGRect)]] = rows.map { row in
            var result: [(members: [Int], span: CGRect)] = []
            for other in row.sorted(by: { glyphs[$0].rect.minX < glyphs[$1].rect.minX }) {
                let rect = glyphs[other].rect
                if let last = result.last, rect.minX - last.span.maxX < body * 0.6 {
                    result[result.count - 1].members.append(other)
                    result[result.count - 1].span = last.span.union(rect)
                } else {
                    result.append(([other], rect))
                }
            }
            return result
        }
        // The columns, from where the cells of all the lines stand.
        var columns: [CGRect] = []
        for cell in cells.flatMap({ $0 }).sorted(by: { $0.span.minX < $1.span.minX }) {
            if let at = columns.firstIndex(where: { $0.maxX > cell.span.minX && $0.minX < cell.span.maxX }) {
                columns[at] = columns[at].union(cell.span)
            } else {
                columns.append(cell.span)
            }
        }
        columns.sort { $0.minX < $1.minX }
        // Two things over each other in parentheses, set as far apart as
        // \binom sets them, with nothing beside them, are a \binom.
        if kind.environment == "pmatrix", levels.count == 2, columns.count == 1,
           largest < body * 0.8 || levels[0] - levels[1] >= largest * 1.28 {
            return nil
        }
        let environment = close == nil ? "cases" : kind.environment
        var table: [[[Int]]] = []
        for row in cells.indices {
            var line: [[Int]] = Array(repeating: [], count: columns.count)
            for cell in cells[row] {
                let column = columns.firstIndex { $0.maxX > cell.span.minX && $0.minX < cell.span.maxX } ?? 0
                line[column] += cell.members
            }
            // Cells after the last one written are not written at all.
            while line.count > 1, line.last?.isEmpty == true { line.removeLast() }
            table.append(line)
        }
        cells = []
        var members = Set(content).union(frame)
        members.insert(start)
        if let close { members.insert(close) }
        return Grid(environment: environment, cells: table, baselines: levels, members: members, close: close)
    }

    /// Two things stacked in parentheses with no bar between them — \binom,
    /// which sets its two halves where \frac would and draws no rule.
    private static func binomial(
        from start: Int, in glyphs: [Glyph], owned: [Int: Int], consumed: Set<Int>
    ) -> (top: [Int], bottom: [Int], close: Int)? {
        let open = glyphs[start]
        guard opening(open) == "(" else { return nil }
        guard let close = glyphs.indices.first(where: {
            $0 > start && !consumed.contains($0) && closing(glyphs[$0]) == ")"
                && abs(glyphs[$0].size - open.size) < 0.5
                && abs(glyphs[$0].origin.y - open.origin.y) < max(1, open.size * 0.1)
                && glyphs[$0].isExtension == open.isExtension
        }) else { return nil }
        // The pieces of the brackets that draw nothing — OpenType's middle and
        // bottom pieces — are not part of what they hold.
        let inside = (start + 1..<close).filter { !consumed.contains($0) && !token(for: glyphs[$0]).isEmpty }
        guard inside.count >= 2, inside.allSatisfy({
            owned[$0] == nil && !isBigOperator(glyphs[$0]) && !isRadical(glyphs[$0])
                && !isDelimiter(glyphs[$0])
        }) else { return nil }
        let heights = inside.map { glyphs[$0].origin.y }.sorted()
        var gap: CGFloat = 0, cut: CGFloat = 0
        for (low, high) in zip(heights, heights.dropFirst()) where high - low > gap {
            gap = high - low
            cut = (low + high) / 2
        }
        let size = inside.map { glyphs[$0].size }.max() ?? open.size
        guard gap > size * 0.6 else { return nil }
        let top = inside.filter { glyphs[$0].origin.y > cut }
        let bottom = inside.filter { glyphs[$0].origin.y < cut }
        let over = extent(top.map { glyphs[$0] }), under = extent(bottom.map { glyphs[$0] })
        guard over.minX < under.maxX, under.minX < over.maxX,
              abs(over.midX - under.midX) < max(over.width, under.width) * 0.35 + 1
        else { return nil }
        return (top, bottom, close)
    }

    // MARK: - Glyphs

    /// Whether a glyph is a piece of a tall bracket that draws nothing of its
    /// own — the middle and lower pieces of OpenType's ⎛ ⎜ ⎝ — known by its
    /// code point, or by a name that is one. Such a piece spells nothing and
    /// is not unreadable: nothing is to be borrowed for it from the page.
    static func isSilentPiece(_ glyph: Glyph) -> Bool {
        if let unicode = glyph.unicode, TeXGlyphNames.unicodeCommands[unicode] == "" { return true }
        guard let name = glyph.glyphName, let scalars = TeXGlyphNames.unicodeName(name),
              scalars.count == 1, let scalar = Unicode.Scalar(scalars[0]) else { return false }
        return TeXGlyphNames.unicodeCommands[String(Character(scalar))] == ""
    }

    private static func token(for glyph: Glyph) -> String {
        if isSilentPiece(glyph) { return "" }
        // STIX Two Math, set by LuaTeX, labels the script-size σ as the final
        // sigma ς. The ς is the narrower of the two by far.
        if glyph.unicode == "\u{1D70D}", glyph.width > glyph.size * 0.52,
           family(of: glyph).contains("STIXTWOMATH") {
            return "\\sigma"
        }
        if let fence = TeXGlyphNames.fence(glyph.glyphName) { return fence }
        if let opening = TeXGlyphNames.openingDelimiter(glyph.glyphName) { return opening }
        if let closing = TeXGlyphNames.closingDelimiter(glyph.glyphName) { return closing }
        if let latex = TeXGlyphNames.latex(
            name: glyph.glyphName, code: glyph.code,
            fontName: glyph.fontName, unicode: glyph.unicode, isSymbolic: glyph.isSymbolic
        ), !latex.isEmpty {
            // A symbol a maths font drew is written as the command for it.
            // The same character in a sentence is left as it was typed.
            if isMathFont(glyph), let command = TeXGlyphNames.unicodeCommands[latex] { return command }
            return latex
        }
        return fallback?(glyph) ?? ""
    }

    /// Whether a glyph is one this cannot read at all: it spells nothing, and
    /// is neither a space nor a piece of a drawing. A formula made mostly of
    /// these is left out rather than written down wrong.
    ///
    /// An accent is not one of them: newtx names its dot "dotacc" and says
    /// nothing else about it, and counted as unreadable it was half of "ẋ",
    /// which left the formula out.
    static func isUnreadable(_ glyph: Glyph) -> Bool {
        spelling(of: glyph).isEmpty && !isSpace(glyph) && !TeXGlyphNames.isDecoration(glyph.glyphName)
            && !TeXGlyphNames.isWideAccent(glyph.glyphName) && TeXGlyphNames.accent(glyph.glyphName) == nil
            && !isSilentPiece(glyph)
    }
}
