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

    /// The LaTeX for everything drawn inside `region` of a scanned page.
    static func latex(glyphs: [Glyph], rules: [Rule], in region: CGRect) -> String {
        let box = region.insetBy(dx: -1, dy: -1)
        let inside = glyphs.filter { box.intersects($0.rect) }
        let bars = rules.filter { box.intersects($0.rect) }
        return latex(glyphs: inside, rules: bars)
    }

    /// The LaTeX for a set of glyphs that have already been chosen.
    static func latex(glyphs: [Glyph], rules: [Rule], context: Context? = nil) -> String {
        guard !glyphs.isEmpty else { return "" }
        return transcribe(glyphs.sorted { $0.origin.x < $1.origin.x },
                          rules: rules, context: context)
    }

    /// One glyph as plain text — what it spells, with no formula around it.
    /// Prose asks for this; it must not come back with `\mathbf` on it.
    static func spelling(of glyph: Glyph) -> String { token(for: glyph) }

    /// Whether a glyph came from a font that only sets mathematics.
    static func isMathFont(_ glyph: Glyph) -> Bool {
        let family = Self.family(of: glyph)
        return family.hasPrefix("CMMI") || family.hasPrefix("CMSY") || family.hasPrefix("CMEX")
            || family.hasPrefix("MSAM") || family.hasPrefix("MSBM") || family.hasPrefix("CMBSY")
            || family.hasPrefix("EUFM") || family.hasPrefix("RSFS")
            || family.contains("MATH") || family.contains("MATHITALIC")
    }

    private static func family(of glyph: Glyph) -> String {
        (glyph.fontName.split(separator: "+").last.map(String.init) ?? glyph.fontName).uppercased()
    }

    // MARK: - The recursion

    private static func transcribe(
        _ glyphs: [Glyph], rules: [Rule], context: Context? = nil
    ) -> String {
        guard !glyphs.isEmpty else { return "" }
        let body = context?.bodySize ?? size(of: glyphs)

        // A fraction first: it splits everything above the bar from everything
        // below it, and both halves are formulas in their own right.
        if let bar = fractionBar(among: rules, over: glyphs) {
            let left = glyphs.filter { $0.rect.maxX <= bar.rect.minX + 0.5 }
            let right = glyphs.filter { $0.rect.minX >= bar.rect.maxX - 0.5 }
            let over = glyphs.filter {
                $0.origin.x > bar.rect.minX - 0.5 && $0.origin.x < bar.rect.maxX
                    && $0.origin.y > bar.rect.midY
            }
            let under = glyphs.filter {
                $0.origin.x > bar.rect.minX - 0.5 && $0.origin.x < bar.rect.maxX
                    && $0.origin.y <= bar.rect.midY
            }
            let remaining = rules.filter { $0.rect != bar.rect }
            return join([
                transcribe(left, rules: remaining),
                "\\frac{\(transcribe(over, rules: remaining))}{\(transcribe(under, rules: remaining))}",
                transcribe(right, rules: remaining),
            ])
        }

        let baseline = context?.baseline ?? baselineOf(glyphs, bodySize: body)
        var tokens: [String] = []
        var index = 0
        var consumed = Set<Int>()
        /// The glyph a script would hang from: the last one written at full
        /// height.
        var lastBaseSize: CGFloat?
        var lastBaseline: CGFloat?
        var lastGlyphIndex: Int?

        // Big operators are found first. Their limits are set around the sign
        // — stacked over and under it in a displayed formula, beside it in a
        // line of running text — and either way "i=1" arrives before the sign
        // it belongs to, or interleaved with the limit above it.
        var limits: [Int: (above: [Glyph], below: [Glyph])] = [:]
        for (position, glyph) in glyphs.enumerated()
        where TeXGlyphNames.isBigOperator(glyph.glyphName) {
            // Whatever full-size thing comes next is where the limits stop, in
            // both arrangements.
            let stop = glyphs[(position + 1)...]
                .first { $0.size >= body * 0.95 }?.rect.minX ?? .greatestFiniteMagnitude
            var above: [Glyph] = [], below: [Glyph] = []
            for (other, candidate) in glyphs.enumerated() where other != position {
                guard candidate.size < body * 0.95,
                      candidate.rect.midX > glyph.rect.minX - glyph.rect.width * 0.5,
                      candidate.rect.midX < stop
                else { continue }
                // Something entirely to the left of the sign is only a limit
                // if it is centred on it; otherwise it belongs to whatever
                // came before.
                if candidate.rect.maxX <= glyph.rect.minX,
                   abs(candidate.rect.midX - glyph.rect.midX) >= glyph.rect.width * 0.9 {
                    continue
                }
                if candidate.origin.y > baseline + body * 0.12 {
                    above.append(candidate); consumed.insert(other)
                } else if candidate.origin.y < baseline - body * 0.12 {
                    below.append(candidate); consumed.insert(other)
                }
            }
            limits[position] = (above, below)
        }

        while index < glyphs.count {
            if consumed.contains(index) { index += 1; continue }
            let glyph = glyphs[index]

            // A big operator takes what is stacked over and under it.
            if let stacked = limits[index] {
                var token = self.token(for: glyph)
                if let below = group(of: stacked.below, rules: rules) { token += "_" + below }
                if let above = group(of: stacked.above, rules: rules) { token += "^" + above }
                tokens.append(token)
                lastBaseSize = glyph.size
                lastBaseline = baseline
                lastGlyphIndex = index
                index += 1
                continue
            }

            // An accent. TeX does not lift its accents off the baseline —
            // the glyph itself carries the height — so an accent is a mark
            // drawn *on top of* the letter before it, at the same baseline and
            // very nearly the same x. Nothing else in a line of type overlaps
            // like that.
            if let accent = accentName(of: glyph),
               let previous = lastGlyphIndex,
               overlaps(glyph, glyphs[previous]),
               let last = tokens.last, !last.isEmpty {
                tokens[tokens.count - 1] = "\(accent){\(last)}"
                index += 1
                continue
            }
            // The other arrangement: a mark set over the letter that follows.
            if let accent = accentName(of: glyph),
               index + 1 < glyphs.count, overlaps(glyph, glyphs[index + 1]) {
                consumed.insert(index + 1)
                tokens.append("\(accent){\(token(for: glyphs[index + 1]))}")
                lastGlyphIndex = index + 1
                index += 1
                continue
            }

            // A run of small glyphs off the baseline is a script on whatever
            // came before it — and "small" means smaller than that, not
            // smaller than the average of the whole formula. This is asked
            // before anything is read as a bracket, because the "(" of an
            // "x^{(i)}" is a superscript first and a bracket second.
            if !tokens.isEmpty,
               let script = scripts(from: index, in: glyphs, baseline: lastBaseline ?? baseline,
                                    body: lastBaseSize ?? body, consumed: consumed) {
                var token = ""
                if let below = group(of: script.lowered, rules: rules) { token += "_" + below }
                if let above = group(of: script.raised, rules: rules) { token += "^" + above }
                if !token.isEmpty { tokens.append(token) }
                index = script.end
                continue
            }

            // A tall fence or delimiter is drawn as a stack of pieces: one
            // symbol, however many pieces it took to reach that height.
            if let fence = TeXGlyphNames.fence(glyph.glyphName)
                ?? TeXGlyphNames.openingDelimiter(glyph.glyphName)
                ?? TeXGlyphNames.closingDelimiter(glyph.glyphName) {
                var next = index + 1
                while next < glyphs.count,
                      glyphs[next].glyphName == glyph.glyphName,
                      abs(glyphs[next].origin.x - glyph.origin.x) < glyph.size * 0.35 {
                    consumed.insert(next)
                    next += 1
                }
                tokens.append(fence)
                lastBaseSize = glyph.size
                lastBaseline = glyph.isExtension ? baseline : glyph.origin.y
                lastGlyphIndex = index
                index = next
                continue
            }

            // A run of upright letters in a formula is a name, not a product
            // of variables: TeX sets "log" in roman because it is one word.
            if let named = operatorName(
                from: index, in: glyphs, body: body, baseline: baseline, consumed: consumed
            ) {
                var token = named.command
                let under = named.limits.map { glyphs[$0] }.filter { $0.origin.y < baseline }
                let over = named.limits.map { glyphs[$0] }.filter { $0.origin.y >= baseline }
                if let below = group(of: under, rules: rules) { token += "_" + below }
                if let above = group(of: over, rules: rules) { token += "^" + above }
                tokens.append(token)
                for position in named.limits { consumed.insert(position) }
                lastBaseSize = glyph.size
                lastBaseline = glyph.origin.y
                lastGlyphIndex = named.end - 1
                index = named.end
                continue
            }

            // Dots on the line, however many were drawn, are one symbol.
            if let dots = dotRun(from: index, in: glyphs, consumed: consumed) {
                tokens.append(dots.command)
                lastBaseSize = glyph.size
                lastBaseline = glyph.origin.y
                lastGlyphIndex = dots.end - 1
                index = dots.end
                continue
            }

            // A bold face in a formula means a bold symbol — a vector, most
            // often — and that is how a person writing it down would put it.
            if let bold = boldRun(from: index, in: glyphs, consumed: consumed) {
                tokens.append(bold.text)
                lastBaseSize = glyph.size
                lastBaseline = glyph.origin.y
                lastGlyphIndex = bold.end - 1
                index = bold.end
                continue
            }

            let token = self.token(for: glyph)
            if !token.isEmpty {
                tokens.append(token)
                lastBaseSize = glyph.size
                lastBaseline = glyph.isExtension ? baseline : glyph.origin.y
                lastGlyphIndex = index
            }
            index += 1
        }
        return join(tokens)
    }

    /// One script or limit, braced when it is more than a single character.
    private static func group(of glyphs: [Glyph], rules: [Rule]) -> String? {
        guard !glyphs.isEmpty else { return nil }
        var inner = transcribe(glyphs.sorted { $0.origin.x < $1.origin.x }, rules: rules)
        guard !inner.isEmpty else { return nil }
        // A subscript set in an upright text face is a word, not a product of
        // variables: "teacher-forcing", not t·e·a·c·h·e·r.
        if isWord(glyphs), inner.count > 1, !inner.contains("\\") {
            inner = "\\text{\(inner)}"
        }
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

    /// Where the line's own baseline is: the level most of its full-size
    /// glyphs sit on. Extension glyphs are left out of the vote — they are
    /// drawn from a reference point that is not on any baseline.
    private static func baselineOf(_ glyphs: [Glyph], bodySize: CGFloat) -> CGFloat {
        let full = glyphs.filter { $0.size >= bodySize * 0.92 && !$0.isExtension }
        let sample = (full.isEmpty ? glyphs : full).map(\.origin.y).sorted()
        return sample[sample.count / 2]
    }

    /// What this glyph would be as an accent, if it is one.
    private static func accentName(of glyph: Glyph) -> String? {
        if let named = TeXGlyphNames.accent(glyph.glyphName) { return named }
        let drawn = token(for: glyph)
        switch drawn {
        case "^", "\u{02C6}", "\u{0302}": return "\\hat"
        case "~", "\u{02DC}", "\u{0303}": return "\\tilde"
        case "\u{00AF}", "\u{0304}": return "\\bar"
        case "\u{02D9}", "\u{0307}": return "\\dot"
        case "\u{02C7}": return "\\check"
        case "\u{00B4}", "\u{0301}": return "\\acute"
        case "\u{0060}", "\u{0300}": return "\\grave"
        default: return nil
        }
    }

    /// Two glyphs drawn on top of one another: an accent and its letter.
    private static func overlaps(_ mark: Glyph, _ letter: Glyph) -> Bool {
        let reach = max(letter.width, mark.width) * 0.7
        return abs(mark.origin.x - letter.origin.x) < reach
            && abs(mark.origin.y - letter.origin.y) < max(letter.size, 1) * 0.35
    }

    /// Whether a run of glyphs is a word set in an upright text face.
    private static func isWord(_ glyphs: [Glyph]) -> Bool {
        let letters = glyphs.filter { token(for: $0).count == 1 && token(for: $0).first?.isLetter == true }
        guard letters.count >= 2 else { return false }
        return glyphs.allSatisfy { glyph in
            let upper = family(of: glyph)
            return upper.hasPrefix("SF") || upper.hasPrefix("CMR") || upper.hasPrefix("CMSS")
                || upper.hasPrefix("CMB")
        }
    }

    /// The size the formula is mostly set in: the commonest size, rounded to
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
        from start: Int, in glyphs: [Glyph], baseline: CGFloat, body: CGFloat,
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
        var side: Bool?
        while end < glyphs.count, !consumed.contains(end) {
            let glyph = glyphs[end]
            // Base level is always full size, so anything still small is still
            // part of the script. Only the first glyph has to be visibly off
            // the line: a script's own script — the "(l)" of "q_{\phi(z^{(l)})}"
            // — climbs back up to within a hair of the baseline it hangs from,
            // and stopping there cuts the subscript in half.
            guard glyph.size < body * 0.92 else { break }
            let offset = glyph.origin.y - baseline
            if end == start, abs(offset) <= body * 0.12 { break }
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

    /// Whether a run of letters spells one of those names.
    static func isOperatorName(_ spelled: String) -> Bool {
        operatorNames.contains(spelled)
    }

    /// A run of upright letters that spells one of those names, and whatever
    /// is set under it.
    ///
    /// "min" with "w∈W" beneath is one operator with a limit, the same as a
    /// sum with one — and its limit is centred under the word, so its glyphs
    /// arrive shuffled in among the letters. Reading left to right without
    /// knowing that spells "m", then part of the limit, then "i", then more of
    /// the limit, then "n".
    private static func operatorName(
        from start: Int, in glyphs: [Glyph], body: CGFloat, baseline: CGFloat,
        consumed: Set<Int>
    ) -> (end: Int, command: String, limits: [Int])? {
        var end = start
        var spelled = ""
        var limits: [Int] = []
        var lastLetter: Int?
        while end < glyphs.count, !consumed.contains(end) {
            let glyph = glyphs[end]
            // A glyph set smaller than the line, sitting off it, is a limit.
            if glyph.size < body * 0.92, abs(glyph.origin.y - baseline) > body * 0.12,
               lastLetter != nil {
                limits.append(end)
                end += 1
                continue
            }
            let upper = family(of: glyph)
            guard upper.hasPrefix("CMR") || upper.hasPrefix("CMSS") || upper.hasPrefix("CMB")
                    || upper.contains("ROM") || upper.contains("TIMES")
            else { break }
            let letter = token(for: glyph)
            guard letter.count == 1, letter.first?.isLetter == true else { break }
            if let previous = lastLetter,
               glyph.rect.minX - glyphs[previous].rect.maxX > glyph.size * 0.22 { break }
            spelled += letter
            lastLetter = end
            end += 1
        }
        // The whole run has to be the name. "logistic" is not "\log istic".
        guard let last = lastLetter, operatorNames.contains(spelled) else { return nil }
        // Anything gathered past the last letter belongs to whatever follows.
        limits = limits.filter { $0 < last }
        return (last + 1, "\\" + spelled, limits)
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
        let inner = join(glyphs[start..<end].map { token(for: $0) })
        guard !inner.isEmpty else { return nil }
        return (end, "\(command){\(inner)}")
    }

    private static func boldCommand(for glyph: Glyph) -> String? {
        let upper = family(of: glyph)
        if upper.hasPrefix("CMMIB") || upper.hasPrefix("CMBSY") { return "\\boldsymbol" }
        if upper.hasPrefix("CMBX") { return "\\mathbf" }
        return nil
    }

    /// The widest rule with glyphs both above and below it: a fraction bar.
    private static func fractionBar(among rules: [Rule], over glyphs: [Glyph]) -> Rule? {
        rules
            .filter { rule in
                let above = glyphs.contains {
                    $0.origin.y > rule.rect.midY
                        && $0.origin.x > rule.rect.minX - 1 && $0.origin.x < rule.rect.maxX + 1
                }
                let below = glyphs.contains {
                    $0.origin.y < rule.rect.midY
                        && $0.origin.x > rule.rect.minX - 1 && $0.origin.x < rule.rect.maxX + 1
                }
                return above && below
            }
            .max { $0.rect.width < $1.rect.width }
    }

    // MARK: - Glyphs

    /// The characters a maths font draws that LaTeX spells with a command.
    private static let commands: [String: String] = [
        "\u{00B7}": "\\cdot", "\u{00D7}": "\\times", "\u{00F7}": "\\div",
        "\u{00B1}": "\\pm", "\u{2213}": "\\mp", "\u{2212}": "-",
        "\u{2264}": "\\leq", "\u{2265}": "\\geq", "\u{2260}": "\\neq",
        "\u{2248}": "\\approx", "\u{223C}": "\\sim", "\u{2261}": "\\equiv",
        "\u{2208}": "\\in", "\u{2209}": "\\notin", "\u{2282}": "\\subset",
        "\u{2286}": "\\subseteq", "\u{221E}": "\\infty", "\u{2202}": "\\partial",
        "\u{2207}": "\\nabla", "\u{221A}": "\\sqrt", "\u{2192}": "\\to",
        "\u{2190}": "\\leftarrow", "\u{21D2}": "\\Rightarrow", "\u{2200}": "\\forall",
        "\u{2203}": "\\exists", "\u{2225}": "\\|", "\u{2032}": "'",
        // A maths font re-encoded to MacRoman spells its mu with the micro
        // sign, which is the right shape and the wrong character.
        "\u{00B5}": "\\mu", "\u{03BC}": "\\mu", "\u{03B1}": "\\alpha",
        "\u{03B2}": "\\beta", "\u{03B3}": "\\gamma", "\u{03B4}": "\\delta",
        "\u{03B5}": "\\epsilon", "\u{03B6}": "\\zeta", "\u{03B7}": "\\eta",
        "\u{03B8}": "\\theta", "\u{03BB}": "\\lambda", "\u{03BD}": "\\nu",
        "\u{03BE}": "\\xi", "\u{03C0}": "\\pi", "\u{03C1}": "\\rho",
        "\u{03C3}": "\\sigma", "\u{03C4}": "\\tau", "\u{03C6}": "\\phi",
        "\u{03C7}": "\\chi", "\u{03C8}": "\\psi", "\u{03C9}": "\\omega",
        "\u{0394}": "\\Delta", "\u{03A3}": "\\Sigma", "\u{03A9}": "\\Omega",
        "\u{2211}": "\\sum", "\u{220F}": "\\prod", "\u{222B}": "\\int",
        "\u{2299}": "\\odot", "\u{2295}": "\\oplus", "\u{2297}": "\\otimes",
    ]

    private static func token(for glyph: Glyph) -> String {
        if let fence = TeXGlyphNames.fence(glyph.glyphName) { return fence }
        if let opening = TeXGlyphNames.openingDelimiter(glyph.glyphName) { return opening }
        if let closing = TeXGlyphNames.closingDelimiter(glyph.glyphName) { return closing }
        if let latex = TeXGlyphNames.latex(
            name: glyph.glyphName, code: glyph.code,
            fontName: glyph.fontName, unicode: glyph.unicode, isSymbolic: glyph.isSymbolic
        ), !latex.isEmpty {
            // A symbol a maths font drew is written as the command for it.
            // The same character in a sentence is left as it was typed.
            if isMathFont(glyph), let command = commands[latex] { return command }
            return latex
        }
        return fallback?(glyph) ?? ""
    }
}
