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
        let sorted = byX(joiningArrows(joiningEllipses(glyphs)))
        let result = mergingScripts(joiningText(transcribe(sorted, rules: rules, context: context)))
        observer?(sorted, context, result)
        return result
    }

    /// Three full stops drawn up a line or down a diagonal, as the one sign
    /// they make. TeX builds \vdots and \ddots of three full stops, a glyph
    /// each, and sets nothing else that way; an OpenType font draws either as
    /// one glyph, and here the three become that one. It stands where TeX
    /// stands the sign — on the line of the lowest dot, which is the line's
    /// own for \vdots and a point under it for \ddots — so the row of ⋮ ⋱ ⋮
    /// in a matrix is one row of the matrix, not three rows too close to be
    /// any, and not three dots in the rows round it.
    static func joiningEllipses(_ glyphs: [Glyph]) -> [Glyph] {
        let dots = glyphs.indices.filter { token(for: glyphs[$0]) == "." }
        guard dots.count >= 3 else { return glyphs }
        var used = Set<Int>()
        var made: [Glyph] = []
        func next(after one: Int, by step: CGVector?, vertical: Bool) -> Int? {
            let from = glyphs[one]
            let size = from.size
            return dots.filter { other in
                guard !used.contains(other), other != one, abs(glyphs[other].size - size) < 0.5 else { return false }
                let dx = glyphs[other].origin.x - from.origin.x
                let dy = glyphs[other].origin.y - from.origin.y
                if let step {
                    return abs(dx - step.dx) < size * 0.1 && abs(dy - step.dy) < size * 0.1
                }
                return vertical
                    ? abs(dx) < size * 0.15 && dy > size * 0.25 && dy < size * 0.6
                    : dx > size * 0.2 && dx < size * 0.7 && -dy > size * 0.15 && -dy < size * 0.45
            }.min { abs(glyphs[$0].origin.x - from.origin.x) + abs(glyphs[$0].origin.y - from.origin.y)
                < abs(glyphs[$1].origin.x - from.origin.x) + abs(glyphs[$1].origin.y - from.origin.y) }
        }
        for first in dots.sorted(by: { glyphs[$0].origin.y < glyphs[$1].origin.y }) where !used.contains(first) {
            for vertical in [true, false] {
                guard let second = next(after: first, by: nil, vertical: vertical) else { continue }
                let step = CGVector(dx: glyphs[second].origin.x - glyphs[first].origin.x,
                                    dy: glyphs[second].origin.y - glyphs[first].origin.y)
                guard let third = next(after: second, by: step, vertical: vertical) else { continue }
                var sign = glyphs[first]
                sign.code = -1
                if vertical {
                    sign.unicode = "\u{22EE}"
                    sign.glyphName = "ellipsisvertical"
                } else {
                    let last = glyphs[third]
                    sign.unicode = "\u{22F1}"
                    sign.glyphName = "ellipsisdiagonal"
                    sign.origin.y = last.origin.y - last.size * 0.1
                    sign.width = last.origin.x + last.width - sign.origin.x
                }
                made.append(sign)
                used.formUnion([first, second, third])
                break
            }
        }
        guard !made.isEmpty else { return glyphs }
        return glyphs.indices.filter { !used.contains($0) }.map { glyphs[$0] } + made
    }

    /// The arrows TeX builds out of pieces, as the one arrow each makes.
    ///
    /// Computer Modern has one arrow of each kind and no long ones, so
    /// `\longrightarrow` is a minus with the arrow pulled 3mu into it,
    /// `\Longrightarrow` an equals sign and ⇒, `\iff` ⇐ and ⇒, `\mapsto` the
    /// arrow with a zero-width bar at its tail, and `\xrightarrow` as many
    /// minuses as its label is long, overlapping, and the arrow on the end.
    /// Nothing else is drawn overlapping on one line: two relations side by
    /// side stand a thick space apart. Read piece by piece, `a \iff b` came
    /// back as `a \Leftarrow\Rightarrow b` and `\xrightarrow{p}` as
    /// `\rightarrow-^p`.
    ///
    /// An arrow stretched to hold a label — more than one shaft, or a shaft
    /// inside the arrow's own length — is named "arrowxright" or
    /// "arrowxleft", so the label can be written the way it was set.
    static func joiningArrows(_ glyphs: [Glyph]) -> [Glyph] {
        enum Piece: Equatable { case shaft, doubleShaft, right, left, doubleRight, doubleLeft, tail, hookLeft, hookRight, bar }
        func piece(_ glyph: Glyph) -> Piece? {
            let name = glyph.glyphName.map(TeXGlyphNames.stripped)
            if name == "hookleft" { return .hookLeft }
            if name == "hookright" { return .hookRight }
            // STIX's shaft piece, which its encoding puts at the code of a
            // comma; and the tail of a \mapsto, which Fourier's puts at a 7.
            if name == "horizontal" { return .shaft }
            if name == "mapstochar", glyph.width < glyph.size * 0.1 { return .tail }
            switch token(for: glyph) {
            case "-", "\u{2212}": return .shaft
            case "=": return .doubleShaft
            case "\\rightarrow": return .right
            case "\\leftarrow": return .left
            case "\\Rightarrow": return .doubleRight
            case "\\Leftarrow": return .doubleLeft
            case "|", "\\mid": return .bar
            case "\\mapsto" where glyph.width < glyph.size * 0.1: return .tail
            default: return nil
            }
        }
        let pieces = glyphs.indices.compactMap { index in piece(glyphs[index]).map { (index, $0) } }
        guard pieces.count >= 2 else { return glyphs }
        let ordered = pieces.sorted {
            glyphs[$0.0].rect.minX != glyphs[$1.0].rect.minX
                ? glyphs[$0.0].rect.minX < glyphs[$1.0].rect.minX : $0.0 < $1.0
        }
        var used = Set<Int>()
        var made: [Glyph] = []
        for (at, start) in ordered.enumerated() where !used.contains(start.0) {
            // The pieces that run into one another, on one line at one size.
            // Whatever else stands among them — the little → of the n → ∞
            // under an \xrightarrow — is stepped over, not taken.
            let first = glyphs[start.0]
            var chain = [start]
            var reach = first.rect.maxX
            for next in ordered[(at + 1)...] {
                let glyph = glyphs[next.0]
                // Touching: the tail of a \mapsto has no width, and stands a
                // hair before the shaft it starts.
                if glyph.rect.minX > reach + first.size * 0.05 { break }
                guard !used.contains(next.0), abs(glyph.size - first.size) < first.size * 0.05,
                      abs(glyph.origin.y - first.origin.y) < first.size * 0.05 else { continue }
                chain.append(next)
                reach = max(reach, glyph.rect.maxX)
            }
            guard chain.count >= 2 else { continue }
            let kinds = chain.map(\.1)
            let boxes = chain.map { glyphs[$0.0].rect }
            let left = boxes.map(\.minX).min() ?? 0, right = boxes.map(\.maxX).max() ?? 0
            func has(_ kind: Piece) -> Bool { kinds.contains(kind) }
            func count(_ kind: Piece) -> Int { kinds.filter { $0 == kind }.count }
            func head(_ kind: Piece) -> CGRect? { chain.first { $0.1 == kind }.map { glyphs[$0.0].rect } }
            // A head stands at its end of the arrow.
            let rightEnd = { (kind: Piece) in head(kind).map { $0.maxX > right - 0.5 } ?? false }
            let leftEnd = { (kind: Piece) in head(kind).map { $0.minX < left + 0.5 } ?? false }
            var arrow: String?
            var stretched = false
            let single = kinds.allSatisfy { [.shaft, .right, .left, .tail].contains($0) }
            let double = kinds.allSatisfy { [.doubleShaft, .doubleRight, .doubleLeft].contains($0) }
            // \longrightarrow is one shaft and the arrow, a minus's width and
            // an arrow's less 3mu: 1.6 em in Computer Modern, 1.56 in
            // Fourier. Anything else built of the two was stretched to hold
            // a label — an \xrightarrow{p} is the arrow's own length.
            let stretches = { () -> Bool in
                let width = (right - left) / glyphs[chain[0].0].size
                return count(.shaft) != 1 || abs(width - 1.6) > 0.15
            }
            if single, count(.right) == 1, count(.left) == 0, rightEnd(.right) {
                if has(.tail) {
                    arrow = has(.shaft) ? "\u{27FC}" : "\u{21A6}"
                } else if has(.shaft) {
                    arrow = "\u{27F6}"
                    stretched = stretches()
                }
            } else if single, count(.left) == 1, count(.right) == 0, !has(.tail), has(.shaft), leftEnd(.left) {
                arrow = "\u{27F5}"
                stretched = stretches()
            } else if single, count(.left) == 1, count(.right) == 1, !has(.tail), leftEnd(.left), rightEnd(.right) {
                arrow = "\u{27F7}"
            } else if double, count(.doubleRight) == 1, count(.doubleLeft) == 0, has(.doubleShaft), rightEnd(.doubleRight) {
                arrow = "\u{27F9}"
            } else if double, count(.doubleLeft) == 1, count(.doubleRight) == 0, has(.doubleShaft), leftEnd(.doubleLeft) {
                arrow = "\u{27F8}"
            } else if double, count(.doubleLeft) == 1, count(.doubleRight) == 1, leftEnd(.doubleLeft), rightEnd(.doubleRight) {
                arrow = "\u{27FA}"
            } else if kinds == [.hookLeft, .right] {
                arrow = "\u{21AA}"
            } else if kinds == [.left, .hookRight] {
                arrow = "\u{21A9}"
            } else if kinds == [.bar, .doubleShaft], boxes[1].minX < boxes[0].maxX - 0.3 {
                arrow = "\u{22A8}"
            }
            guard let arrow else { continue }
            let headKind: Piece = kinds.contains(.right) ? .right : kinds.contains(.left) ? .left
                : kinds.contains(.doubleRight) ? .doubleRight : kinds.contains(.doubleLeft) ? .doubleLeft : kinds[0]
            var sign = glyphs[chain.first { $0.1 == headKind }!.0]
            sign.code = -1
            sign.unicode = arrow
            sign.glyphName = stretched ? (arrow == "\u{27F6}" ? "arrowxright" : "arrowxleft") : nil
            sign.origin.x = left
            sign.width = right - left
            made.append(sign)
            used.formUnion(chain.map(\.0))
        }
        guard !made.isEmpty else { return glyphs }
        return glyphs.indices.filter { !used.contains($0) }.map { glyphs[$0] } + made
    }

    /// Glyphs in reading order: left to right, and two at the same place in
    /// the order they were drawn.
    static func byX(_ glyphs: [Glyph]) -> [Glyph] {
        glyphs.enumerated()
            .sorted { $0.element.origin.x != $1.element.origin.x
                ? $0.element.origin.x < $1.element.origin.x : $0.offset < $1.offset }
            .map(\.element)
    }

    /// No base carries two superscripts or two subscripts: `x^a_b^c` is one
    /// script read in two pieces round the other — the "−" and the "1" of
    /// G_t^{-1} either side of the t — and LaTeX refuses it outright ("Double
    /// superscript"), so Overleaf and a note show nothing. The pieces of each
    /// side are one script, in the order they were read: x^{ac}_b. A chain
    /// with no side twice is left exactly as it was written.
    static func mergingScripts(_ latex: String) -> String {
        guard latex.contains("^") || latex.contains("_") else { return latex }
        let characters = Array(latex)
        func isLetter(_ character: Character) -> Bool { character.isASCII && character.isLetter }
        // Where the argument of a script that starts at `start` ends: a group,
        // a command with the groups it takes, or one character.
        func argumentEnd(from start: Int) -> Int {
            guard start < characters.count else { return start }
            var at = start
            if characters[at] == "{" {
                var depth = 0
                while at < characters.count {
                    if characters[at] == "\\" { at += 2; continue }
                    if characters[at] == "{" { depth += 1 }
                    if characters[at] == "}" {
                        depth -= 1
                        if depth == 0 { return at + 1 }
                    }
                    at += 1
                }
                return characters.count
            }
            if characters[at] == "\\" {
                at += 1
                if at < characters.count, isLetter(characters[at]) {
                    while at < characters.count, isLetter(characters[at]) { at += 1 }
                    while at < characters.count, characters[at] == "{" { at = argumentEnd(from: at) }
                } else {
                    at += 1
                }
                return min(at, characters.count)
            }
            return at + 1
        }
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                let end = min(index + 2, characters.count)
                result += String(characters[index..<end])
                index = end
                continue
            }
            guard character == "^" || character == "_" else {
                result.append(character)
                index += 1
                continue
            }
            var pieces: [(marker: Character, content: String)] = []
            var at = index
            while true {
                var look = at
                while look < characters.count, characters[look] == " " { look += 1 }
                guard look < characters.count, characters[look] == "^" || characters[look] == "_" else { break }
                var start = look + 1
                while start < characters.count, characters[start] == " " { start += 1 }
                let end = argumentEnd(from: start)
                guard end > start else { break }
                var content = String(characters[start..<end])
                if characters[start] == "{", characters[end - 1] == "}" {
                    content = String(content.dropFirst().dropLast())
                }
                pieces.append((characters[look], content))
                at = end
            }
            guard !pieces.isEmpty else {
                result.append(character)
                index += 1
                continue
            }
            let sides = pieces.map(\.marker)
            if Set(sides).count == sides.count {
                result += String(characters[index..<at])
            } else {
                var order: [Character] = []
                var merged: [Character: String] = [:]
                for piece in pieces {
                    if let known = merged[piece.marker] {
                        merged[piece.marker] = join([known, piece.content])
                    } else {
                        order.append(piece.marker)
                        merged[piece.marker] = piece.content
                    }
                }
                for marker in order { result += "\(marker){\(merged[marker] ?? "")}" }
            }
            index = at
        }
        return result
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
        while let range = result.range(of: #"\\text\{([^{}]*)\}\s*\\text\{"#, options: .regularExpression) {
            let piece = String(result[range])
            guard let close = piece.firstIndex(of: "}") else { break }
            var inner = String(piece[piece.index(piece.startIndex, offsetBy: 6)..<close])
            // Apart on the page is a space between them, and one is enough.
            var spaced = piece[piece.index(after: close)...].first?.isWhitespace == true || inner.hasSuffix(" ")
            while inner.hasSuffix(" ") { inner.removeLast() }
            var end = range.upperBound
            while end < result.endIndex, result[end] == " " {
                spaced = true
                end = result.index(after: end)
            }
            result.replaceSubrange(range.lowerBound..<end, with: "\\text{" + inner + (spaced ? " " : ""))
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
        remembered(\.mathFonts, glyph.fontName) {
            let family = Self.family(of: glyph)
            if family.contains("MATH") { return true }
            return mathFamilies.contains { family.hasPrefix($0) }
        }
    }

    /// What was worked out from a font's or a glyph's name, kept: reading a
    /// page asks the same few dozen names the same questions some hundred
    /// thousand times — split the subset tag off, upper-case, look up — and
    /// that was most of the time a page took.
    private struct Memo {
        var families: [String: String] = [:]
        var mathFonts: [String: Bool] = [:]
        var tokens: [TokenKey: String] = [:]
        var silent: [TokenKey: Bool] = [:]
    }

    private struct TokenKey: Hashable {
        var fontName: String
        var glyphName: String?
        var code: Int
        var unicode: String?
        var isSymbolic: Bool
        var wideSigma: Bool
    }

    nonisolated(unsafe) private static var memo = Memo()
    private static let memoLock = NSLock()

    private static func remembered<Value>(
        _ table: WritableKeyPath<Memo, [String: Value]>, _ key: String, _ work: () -> Value
    ) -> Value {
        memoLock.lock()
        if let known = memo[keyPath: table][key] { memoLock.unlock(); return known }
        memoLock.unlock()
        let value = work()
        memoLock.lock()
        memo[keyPath: table][key] = value
        memoLock.unlock()
        return value
    }

    /// The first letters of the maths fonts' names, uppercased. A prefix
    /// covers the sizes and variants: "CMMI" is CMMI5 to CMMI12 and CMMIB.
    private static let mathFamilies: [String] = [
        // Computer Modern and the AMS fonts.
        "CMMI", "CMSY", "CMEX", "CMBSY", "MSAM", "MSBM", "EUFM", "EUFB", "EUSM", "EUSB",
        "EURM", "EURB", "EUEX", "RSFS", "BBOLD", "DSROM", "DSSS", "STMARY", "WASY", "LASY",
        "ESINT", "CALLIGRA",
        // bbm, and any bitmap font the scanner saw draw double-struck letters
        // (`PDFContentScanner.doubleStruckType3`).
        "BBM",
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
        remembered(\.families, glyph.fontName) {
            (glyph.fontName.split(separator: "+").last.map(String.init) ?? glyph.fontName).uppercased()
        }
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
        // A larger size is drawn at the size of the line; a bracket in a
        // script is a script's own — the [s,t] under the n of an exponent,
        // with the exponent's own exponent over it, is not a matrix.
        guard !bracket.isExtension, bracket.size >= body * 0.9,
              isUnicodeMathFont(family(of: bracket)) else { return false }
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
        // A brace's fill is a bar to `fractionBars` alone: to every other
        // pass — the grids, the radicals, the lines over and under runs — it
        // is nothing.
        let braces = rules.filter(\.brace)
        let rules = rules.filter { !$0.brace }
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
        let found = fractionBars(among: rules + braces, in: free)
        // The bars were found among the glyphs the grids left; their members
        // are counted in the whole formula's numbers.
        let positions = glyphs.indices.filter { !gridded.contains($0) }
        let bars = found.map { bar in
            Bar(rule: bar.rule, over: bar.over.map { positions[$0] }, under: bar.under.map { positions[$0] },
                brace: bar.brace)
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
        var strokes: [Int: Int] = [:]
        let struck = negations(in: glyphs, owned: owner, consumed: &consumed, strokes: &strokes)
        // The strokes read already, which a script steps over.
        let stepped = Set(strokes.values)
        let labelled = stackedLabels(in: glyphs, body: body, owned: owner,
                                     named: Set(names.values.flatMap(\.letters)), consumed: &consumed)

        var tokens: [String] = []
        var base: Base?
        var index = 0
        // The brackets built taller than \Bigg, to be paired at the end.
        var built: [(token: Int, fence: String, opens: Bool, middle: CGFloat, height: CGFloat)] = []

        // (The braces go along to what is read inside a bar: a braced term
        // in a numerator is braced there.)
        func others(than rule: Rule) -> [Rule] { (rules + braces).filter { $0.rect != rule.rect } }
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
                // A brace's label is the smaller side: under an \underbrace,
                // over an \overbrace.
                let overSize = bar.over.map { glyphs[$0].size }.max() ?? body
                let underSize = bar.under.map { glyphs[$0].size }.max() ?? body
                let labelUnder = bar.rule.brace ? bar.rule.braceLabelBelow : underSize <= overSize
                // A label set in two lines — "Object Region" over
                // "Proposal" — reads letter by letter across both lines
                // along x; each line is read on its own, in a \substack.
                // The lines are where the label's largest glyphs stand;
                // its scripts go with the nearest line.
                func label(_ members: [Int]) -> String {
                    let size = members.map { glyphs[$0].size }.max() ?? body
                    var lines: [CGFloat] = []
                    for y in members.filter({ glyphs[$0].size >= size * 0.9 }).map({ glyphs[$0].origin.y }).sorted(by: >)
                    where lines.last.map({ $0 - y > size * 0.5 }) ?? true {
                        lines.append(y)
                    }
                    guard lines.count > 1 else { return transcribe(part(members), rules: rest, line: line) }
                    let read = lines.map { y in
                        transcribe(part(members.filter { member in
                            lines.min { abs($0 - glyphs[member].origin.y) < abs($1 - glyphs[member].origin.y) } == y
                        }), rules: rest, line: line)
                    }
                    return "\\substack{\(read.joined(separator: " \\\\ "))}"
                }
                let over = bar.brace && !labelUnder ? label(bar.over) : transcribe(part(bar.over), rules: rest, line: line)
                let under = bar.brace && labelUnder ? label(bar.under) : transcribe(part(bar.under), rules: rest, line: line)
                var token = bar.brace
                    ? (labelUnder ? "\\underbrace{\(over)}_{\(under)}" : "\\overbrace{\(under)}^{\(over)}")
                    : "\\frac{\(over)}{\(under)}"
                let parts = (bar.over + bar.under).map { glyphs[$0].size }.max() ?? body
                var scripted = false
                // Nothing is a script of an opening bracket.
                let opened = base.map { opening(glyphs[$0.index]) != nil } ?? false
                if !bar.brace, let base, !tokens.isEmpty, !opened, parts < base.size * 0.8 {
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
                if let below = written(limit(of: stacked.below.map { glyphs[$0] }, rules: rules, line: line)) {
                    token += "_" + below
                }
                if let above = written(limit(of: stacked.above.map { glyphs[$0] }, rules: rules, line: line)) {
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
                if let below = written(limit(of: named.below.map { glyphs[$0] }, rules: rules, line: line)) {
                    token += "_" + below
                }
                if let above = written(limit(of: named.above.map { glyphs[$0] }, rules: rules, line: line)) {
                    token += "^" + above
                }
                tokens.append(token)
                consumed.formUnion(named.letters)
                let last = named.letters.last ?? index
                base = Base(size: glyphs[last].size, baseline: glyphs[last].origin.y, index: last)
                index += 1
                continue
            }

            // A sign with a label stacked on it: \overset{iid}{\sim}, and an
            // arrow stretched to hold what is written over it.
            if let stack = labelled[index] {
                consumed.formUnion(stack.base)
                let letters = stack.base.map { Self.token(for: glyphs[$0]) }.joined()
                let sign = stack.base.count == 1 ? mathToken(for: glyph)
                    : Self.names(in: letters).map { $0.map { twoWordNames[$0] ?? "\\" + $0 }.joined() }
                        ?? "\\mathrm{\(letters)}"
                let over = stack.above.isEmpty ? "" : transcribe(part(stack.above), rules: rules, line: line)
                let under = stack.below.isEmpty ? "" : transcribe(part(stack.below), rules: rules, line: line)
                var written = sign
                if stack.base.count == 1, let arrow = glyph.glyphName, arrow == "arrowxright" || arrow == "arrowxleft" {
                    // What an optional argument holds cannot have a "]" in it.
                    let optional = under.isEmpty ? "" : under.contains("]") ? "[{\(under)}]" : "[\(under)]"
                    written = (arrow == "arrowxright" ? "\\xrightarrow" : "\\xleftarrow") + optional + "{\(over)}"
                } else {
                    if !over.isEmpty { written = "\\overset{\(over)}{\(written)}" }
                    if !under.isEmpty { written = "\\underset{\(under)}{\(written)}" }
                }
                tokens.append(written)
                let last = stack.base.last ?? index
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
            // all of them. One in a script is the script's, and read with
            // it: the Ŵ under the F of F^i_{\hat{W}} came back as F\hat{W}i.
            if let mark = accented[index],
               !(base.map { base in mark.covered.allSatisfy { glyphs[$0].size < base.size * 0.92 } } ?? false)
                   || scripts(from: index, in: glyphs, baseline: base?.baseline ?? baseline,
                              body: base?.size ?? body, line: line, consumed: consumed, stepping: stepped,
                              bars: bars) == nil {
                consumed.formUnion(mark.covered)
                var inside = mark.covered.count == 1
                    ? mathToken(for: glyphs[mark.covered[0]])
                    : transcribe(part(mark.covered), rules: rules,
                                 context: Context(bodySize: body, baseline: baseline), line: line)
                // One letter under the mark keeps its weight: ŝ in bold is
                // \hat{\boldsymbol{s}}, not \hat{s}.
                if mark.covered.count == 1, let bold = boldCommand(for: glyphs[mark.covered[0]]), !inside.isEmpty {
                    inside = "\(bold){\(inside)}"
                }
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
               var script = scripts(from: index, in: glyphs, baseline: base.baseline,
                                    body: base.size, line: line, consumed: consumed, stepping: stepped,
                                    bars: bars) {
                // An accent on a letter of the script is the script's: its
                // mark, read already, goes where the letter went.
                for accent in accented.values where !accent.covered.isEmpty
                    && accent.covered.allSatisfy({ (index..<script.end).contains($0) }) {
                    let letter = glyphs[accent.covered[0]]
                    let isLetter = { (glyph: Glyph) in glyph.origin == letter.origin && glyph.code == letter.code }
                    if script.lowered.contains(where: isLetter) {
                        script.lowered.append(glyphs[accent.mark])
                    } else if script.raised.contains(where: isLetter) {
                        script.raised.append(glyphs[accent.mark])
                    }
                }
                // So does the stroke through a relation of the script: the
                // ≠ of "j≠i" under \max in a sentence came back as "=".
                for member in index..<script.end {
                    guard let stroke = strokes[member] else { continue }
                    let relation = glyphs[member]
                    let isRelation = { (glyph: Glyph) in glyph.origin == relation.origin && glyph.code == relation.code }
                    if script.lowered.contains(where: isRelation) {
                        script.lowered.append(glyphs[stroke])
                    } else if script.raised.contains(where: isRelation) {
                        script.raised.append(glyphs[stroke])
                    }
                }
                var token = ""
                // A prime is raised like a superscript and written like a
                // mark: "t'" and never "t^{'}".
                if let primes = primes(script.raised) {
                    token += primes
                } else if let above = written(limit(of: script.raised, rules: rules, line: line, asScript: true)) {
                    token += "^" + above
                }
                // A \substack is a script too, beside \max in a sentence.
                if let below = written(limit(of: script.lowered, rules: rules, line: line, asScript: true)) {
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
                // What the formula goes on with after the cases stands a
                // \quad off, as the page set it: "∀i ∈ [0, |θ|]" ran into the
                // last case.
                let edge = grid.members.map { glyphs[$0].rect.maxX }.max() ?? glyph.rect.maxX
                if let next = glyphs.indices.filter({ !consumed.contains($0) && glyphs[$0].rect.minX >= edge - 0.5 })
                    .min(by: { glyphs[$0].rect.minX < glyphs[$1].rect.minX }),
                   glyphs[next].rect.minX - edge >= body * 0.8,
                   !token(for: glyphs[next]).isEmpty, ![",", ".", ";"].contains(token(for: glyphs[next])) {
                    tokens.append("\\quad")
                }
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
            // A bar an OpenType font draws as a character, its | or its ∣,
            // stacked into a tall one out of several of itself, is one too.
            // (An OpenType font's two | for a \big| stand an eighth of an
            // em apart: anything but the one place is a stack.)
            func stacked(_ one: Glyph, _ other: Glyph) -> Bool {
                other.isExtension == one.isExtension
                    && abs(other.origin.x - one.origin.x) < one.size * 0.2
                    && abs(other.origin.y - one.origin.y) > one.size * 0.05
            }
            let drawnBar = struck[index] == nil && index + 1 < glyphs.count && !consumed.contains(index + 1)
                && barToken(glyph) != nil && barToken(glyphs[index + 1]) == barToken(glyph)
                && stacked(glyph, glyphs[index + 1])
            func kind(_ one: Glyph) -> String? {
                if drawnBar { return barToken(one) }
                return TeXGlyphNames.fence(one.glyphName) ?? opening(one) ?? closing(one)
            }
            if let fence = kind(glyph) {
                var next = index + 1
                // The pieces stand one on another; two brackets side by side
                // — the "))" that closes two things at once — are two.
                while next < glyphs.count, !consumed.contains(next),
                      kind(glyphs[next]) == fence || TeXGlyphNames.isDecoration(glyphs[next].glyphName),
                      stacked(glyph, glyphs[next]) {
                    consumed.insert(next)
                    next += 1
                }
                let sized = sizedDelimiter(fence, glyph: glyph, pieces: Array(glyphs[index..<next]))
                if sized.built {
                    let box = glyphs[index..<next].dropFirst().reduce(glyph.rect) { $0.union($1.rect) }
                    let bar = fence == "|" || fence == "\\|"
                    built.append((tokens.count, fence, bar || opening(glyph) != nil, box.midY, box.height))
                }
                tokens.append(sized.text)
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
                // A bracket or a bar set larger than the line — an OpenType
                // font's | stacked for a \big| — is on the line, at the
                // line's size: the r after it is not its script.
                let tall = isDelimiter(glyph) && glyph.size > body * 1.1
                let drawnOffLine = glyph.isExtension || isBigOperator(glyph) || tall
                base = Base(size: tall ? body : glyph.size, baseline: drawnOffLine ? baseline : glyph.origin.y,
                            index: index)
            }
            index += 1
        }
        if !built.isEmpty { pairingBuilt(&tokens, built) }
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

    /// A limit, braced as a script is — or, set in rows one under another,
    /// the `\substack` it was written as. "i=s₁+1" over "i∉S≤t" under a
    /// product, read left to right as one row, came back as "ii=∉sS…": the
    /// glyphs of the two rows interleaved.
    /// A script or a limit with something in it. The small glyphs of a
    /// figure's labels, from a font that names nothing, read as nothing, and
    /// came back as "^{}_{}^{}" — scripts of nothing on nothing.
    private static func written(_ script: String?) -> String? {
        guard let script, !script.isEmpty, script != "{}" else { return nil }
        return script
    }

    private static func limit(of glyphs: [Glyph], rules: [Rule], line: CGFloat, asScript: Bool = false) -> String? {
        var rows = limitRows(glyphs, rules: rules)
        // A script is read as rows only when they look like a \substack's:
        // short rows of two glyphs or more, centred on one another. Captions
        // and the words of figures stand where scripts do when a page's lines
        // run into each other, and are none of that.
        if asScript, rows.count > 1, let largest = glyphs.map(\.size).max() {
            let spans = rows.map { extent($0) }
            let widest = spans.map(\.width).max() ?? 0
            let stacked = rows.allSatisfy { row in row.filter { !token(for: $0).isEmpty }.count >= 2 }
                && widest <= largest * 12 && !glyphs.contains(where: { isBigOperator($0) || $0.isExtension })
                && zip(spans, spans.dropFirst()).allSatisfy { abs($0.midX - $1.midX) < widest * 0.2 + 1 }
            if !stacked { rows = [glyphs] }
        }
        guard rows.count > 1 else { return group(of: glyphs, rules: rules, line: line) }
        let written = rows.map { transcribe(byX($0), rules: rules, line: line) }.filter { !$0.isEmpty }
        guard written.count > 1 else { return group(of: glyphs, rules: rules, line: line) }
        return "{\\substack{" + written.joined(separator: " \\\\ ") + "}}"
    }

    /// The rows a limit was set in, top to bottom: the levels its largest
    /// glyphs stand on, most of a line of script apart, and each glyph on the
    /// nearest. A script inside a limit — the n of "sₙ" — is a size down and
    /// makes no row; nor do a fraction's numerator and denominator, which
    /// have the bar between them.
    static func limitRows(_ glyphs: [Glyph], rules: [Rule]) -> [[Glyph]] {
        guard glyphs.count >= 2, let largest = glyphs.map(\.size).max() else { return [glyphs] }
        // A glyph of an extension font is set from the top of its ink and
        // has no baseline to make a row with.
        let levels = glyphs.filter { $0.size >= largest * 0.95 && !isAccent($0) && !$0.isExtension }
            .map(\.origin.y).sorted(by: >)
        var rows: [CGFloat] = []
        for level in levels where rows.isEmpty || rows[rows.count - 1] - level >= largest * 0.6 {
            rows.append(level)
        }
        guard rows.count > 1 else { return [glyphs] }
        // A line of script apart and no more: rows further off are no stack.
        for at in 1..<rows.count where rows[at - 1] - rows[at] > largest * 1.6 { return [glyphs] }
        let span = extent(glyphs)
        if rules.contains(where: { rule in
            rule.rect.midY < rows[0] && rule.rect.midY > rows[rows.count - 1]
                && rule.rect.maxX > span.minX && rule.rect.minX < span.maxX
        }) { return [glyphs] }
        var grouped = rows.map { _ in [Glyph]() }
        for glyph in glyphs {
            let level = glyph.isExtension ? glyph.rect.midY : glyph.origin.y
            var nearest = 0
            for at in 1..<rows.count where abs(rows[at] - level) < abs(rows[nearest] - level) {
                nearest = at
            }
            // A mark stands over its letter, and its row is the one under it.
            if isAccent(glyph), let under = rows.firstIndex(where: { $0 <= glyph.origin.y + 0.5 }) {
                nearest = under
            }
            grouped[nearest].append(glyph)
        }
        return grouped
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
        // A bar built up out of several of one glyph stands no piece on
        // the line (the \big| of four "bar.x" pieces in a display).
        func stackedBar(_ glyph: Glyph) -> Bool {
            guard let token = barToken(glyph) else { return false }
            return glyphs.contains { other in
                other.origin != glyph.origin && barToken(other) == token
                    && abs(other.origin.x - glyph.origin.x) < glyph.size * 0.2
                    && abs(other.origin.y - glyph.origin.y) < glyph.size * 0.8
            }
        }
        let voters = glyphs.indices.filter { index in
            let glyph = glyphs[index]
            // Nor a bracket or a bar set larger than the line: set to the
            // height of what it holds, it stands where that is tallest — the
            // two OpenType | glyphs stacked for the \big| round r_{ij} in an
            // exponent outvoted the r, and the r became their superscript.
            // One at the line's size stands on the line, and votes: the "["
            // and "]" of a sub-subscript held its baseline against the
            // scripts under it.
            return glyph.size >= bodySize * 0.92 && !glyph.isExtension && !isBigOperator(glyph)
                && !isRadical(glyph) && !(isDelimiter(glyph) && (glyph.size > bodySize * 1.1 || stackedBar(glyph)))
                && !barred.contains(index)
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
        consumed: Set<Int>, stepping stepped: Set<Int> = [], bars: [Bar] = []
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
        // How far right the script has reached — both its sides, a stepped-
        // over mark aside. The subscript of G_t^{-1} starts where the
        // superscript does and ends before it; measured from the t, the 1
        // stood off on its own and was a script of its own: G^-_t^1.
        var reached = -CGFloat.greatestFiniteMagnitude
        // The glyphs at the run's own size, each with the side it went to.
        var held: [(glyph: Glyph, raised: Bool)] = []
        // The brackets the script has opened, each as the one that closes it,
        // and where the last one taken stands — its other pieces stand there.
        var opened: [String] = []
        var bracketX: CGFloat?
        while end < glyphs.count {
            // A combining mark already read into the accent it makes can
            // stand among the scripts — OpenType fonts set the hat of ŝ
            // after the subscript of ŝ_{y_j} — and it is stepped over; the
            // script goes on past it. Anything else read already ends it.
            // So can the stroke through one of its relations, read already
            // into the relation it negates.
            if consumed.contains(end) {
                if end > start, glyphs[end].width < 0.01 || stepped.contains(end) { end += 1; continue }
                break
            }
            let glyph = glyphs[end]
            var offset = glyph.origin.y - baseline
            // A fraction's numerator and denominator go with their bar. One
            // set on the line — its axis a quarter of an em over the
            // baseline, the numerator above and the denominator below — is
            // the line's and ends the run: read glyph by glyph, the ½ after
            // ∇_{ω^t} went up as the 1 and down as the 2, and came back as
            // ∇^{1}_{ω^t 2}. One lifted or dropped whole is the script's,
            // on the bar's side whichever side each of its glyphs stands.
            if let bar = bars.first(where: { $0.over.contains(end) || $0.under.contains(end) }) {
                // A braced formula and its label stand on the line, whatever
                // the brace's fill is level with: never a script's.
                if bar.brace { break }
                let level = bar.rule.rect.midY - baseline
                guard level > body * 0.42 || level < body * 0.1 else { break }
                offset = level - body * 0.25
            }
            // Base level is always full size, so anything still small is still
            // part of the script. Only the first glyph has to be visibly off
            // the line: a script's own script — the "(l)" of "q_{\phi(z^{(l)})}"
            // — climbs back up to within a hair of the baseline it hangs from,
            // and stopping there cuts the subscript in half.
            let small = glyph.size < body * 0.92
            let asSmall = smallest && glyph.size <= body * 1.02 && abs(offset) >= body * 0.2
            // A sign drawn from an extension font is not a script as such: the
            // brace of \left\{ at a smaller size than the line is still the
            // brace. Inside a script it is the script's — the ∑ in the
            // exponent of e^{-∑…}, the √ and the \big| (TeX draws \big at the
            // text's size) — when it stands well off the line, on the
            // script's side; the brace stands on the line's axis.
            let grows = glyph.isExtension || isDelimiter(glyph) || barToken(glyph) != nil || isRadical(glyph)
            // Where it stands: an extension font's glyph by its ink, and a bar
            // built tall out of pieces by the ink of all of them — each piece
            // of the \big| after r_{ij} stood off r's line, and the bar
            // became r's superscript; any other glyph by where it was set,
            // since its box is only its size — the ")" after σ² stood half an
            // em up by it, and went into the superscript.
            let centre = !grows ? 0
                : glyph.isExtension ? inkOfStack(end, in: glyphs).midY - baseline : glyph.origin.y - baseline
            // A sum or a radical in a script is set at the script's own size,
            // as the − before the ∑ of e^{-∑…} is; one at the line's size
            // after a superscript — a²√(x²+y²), the displayed ∫ after "=" in
            // mathptmx, a point smaller than the text — is the line's,
            // whatever its ink is guessed to reach.
            // Or at the line's size, where the fonts do not shrink — Latin
            // Modern's and Fourier's ∑ in an exponent is its text size — with
            // all of its ink off the line: one on the line reaches across it.
            let ink = glyph.isExtension ? inkOfStack(end, in: glyphs) : glyph.rect
            let clear = centre > 0 ? ink.minY > baseline + body * 0.02 : ink.maxY < baseline - body * 0.02
            let sized = !(isBigOperator(glyph) || isRadical(glyph)) || glyph.size <= primary * 1.1
                || (glyph.isExtension && clear)
            // A bracket or a bar is the script's only round some of it: what
            // comes right after it is small and on the script's side, or it
            // closes one the script opened — \big|r_{ij}\big| in an exponent.
            // One after the script, round what is on the line — the ")" of
            // (…g^t_u), the "]" of [𝕀^𝒜] — is the line's.
            let bracket = grows && !(isBigOperator(glyph) || isRadical(glyph))
            var opens: String?
            var closes = false
            var holds = !bracket
            if bracket {
                let kind = barToken(glyph) ?? closing(glyph) ?? opening(glyph)
                if let x = bracketX, abs(glyph.origin.x - x) < glyph.size * 0.2 {
                    holds = true
                } else if let kind, opened.last == kind {
                    holds = true
                    closes = true
                } else if let kind, barToken(glyph) != nil || opening(glyph) != nil {
                    var after = end + 1
                    while after < glyphs.count, abs(glyphs[after].origin.x - glyph.origin.x) < glyph.size * 0.2 {
                        after += 1
                    }
                    if after < glyphs.count {
                        let next = glyphs[after]
                        let lift = next.origin.y - baseline
                        holds = next.size < body * 0.92 && abs(lift) > body * 0.1 && (lift > 0) == (centre > 0)
                    }
                    // One at the line's size from an ordinary font stands on
                    // the script's own baseline, as the script's other glyphs
                    // do: an OpenType \big| in an exponent does. The ‖ of a
                    // line read a row too high for it stood a point and a half
                    // off the r it followed, and went into its superscript
                    // with the ² after it.
                    // One built up out of several of the one glyph — STIX's
                    // "bar.x" four times over for a \big|, an OpenType font's
                    // two | glyphs a point apart — stands no piece on that
                    // baseline: it is centred on the script's axis, a quarter
                    // of an em over it.
                    let stackedBar = !glyph.isExtension && barToken(glyph) != nil && glyphs.contains { other in
                        other.origin != glyph.origin && barToken(other) == barToken(glyph)
                            && abs(other.origin.x - glyph.origin.x) < glyph.size * 0.2
                            && abs(other.origin.y - glyph.origin.y) < glyph.size * 0.8
                    }
                    func centredOnScript() -> Bool {
                        let column = glyphs.filter {
                            barToken($0) == barToken(glyph) && abs($0.origin.x - glyph.origin.x) < glyph.size * 0.2
                                && abs($0.origin.y - glyph.origin.y) < glyph.size * 1.6
                        }
                        let low = column.map(\.origin.y).min() ?? glyph.origin.y
                        let high = column.map(\.origin.y).max() ?? glyph.origin.y
                        let centre = (low - glyph.size * 0.2 + high + glyph.size * 0.8) / 2
                        return held.contains { one in
                            !one.glyph.isExtension && abs(centre - one.glyph.origin.y - one.glyph.size * 0.25) < one.glyph.size * 0.6
                        }
                    }
                    if !glyph.isExtension, !small, !held.contains(where: {
                        !$0.glyph.isExtension && abs($0.glyph.origin.y - glyph.origin.y) < body * 0.1
                    }), !(stackedBar && centredOnScript()) {
                        holds = false
                    }
                    let pairs = ["(": ")", "[": "]", "\\{": "\\}", "\\langle": "\\rangle",
                                 "\\lfloor": "\\rfloor", "\\lceil": "\\rceil"]
                    opens = barToken(glyph) ?? pairs[kind] ?? kind
                }
            }
            // A bracket built up out of pieces stands taller than a line, and
            // none of it is a script's: the foot of the "(" round a displayed
            // sum, left on the line when its top went to another, stood as far
            // below it as a subscript does and became W's.
            let builtUp = bracket && isPiece(glyph) && barToken(glyph) == nil
            let inScript = grows && sized && holds && !builtUp && end > start && abs(centre) > body * 0.3
                && side.map { $0 == (centre > 0) } ?? false
            guard (small || asSmall) && !glyph.isExtension || inScript, !isSpace(glyph) else { break }
            if inScript, bracket {
                if closes { opened.removeLast() } else if let opens { opened.append(opens) }
                bracketX = glyph.origin.x
            }
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
                // Word's subscripts follow a letter or a digit. What follows a
                // bar on its line is what the bar holds — the r of \big|r_{ij}|
                // in an exponent, the bar drawn at the text's size.
                let before = glyphs[start - 1]
                let holds = isDelimiter(before) || barToken(before) != nil || isBigOperator(before)
                guard glyph.size <= body * 0.72, touching, !holds,
                      glyphs[start - 1].size >= body * 0.92 else { break }
                var run = start
                while run < glyphs.count, !consumed.contains(run), glyphs[run].size <= body * 0.72,
                      abs(glyphs[run].origin.y - baseline) <= body * 0.03,
                      run == start || glyphs[run].rect.minX - glyphs[run - 1].rect.maxX < body * 0.12 {
                    run += 1
                }
                return (run, [], Array(glyphs[start..<run]))
            }
            // A sign in a script stands a thin space off what comes before it.
            if end > start, glyph.rect.minX - reached > body * (inScript ? 0.45 : 0.25) { break }
            let deeper = glyph.size < primary * 0.92
            // A script of a script goes with the script it hangs from — the
            // one ending just before it, at about its height: the l of
            // F^i_{W^l} is the W's, though the i was read after the W.
            let host = deeper ? held.filter { $0.glyph.rect.maxX <= glyph.rect.minX + glyph.size * 0.5 }
                .min(by: { one, other in
                    let a = max(0, glyph.rect.minX - one.glyph.rect.maxX) + abs(glyph.origin.y - one.glyph.origin.y)
                    let b = max(0, glyph.rect.minX - other.glyph.rect.maxX) + abs(glyph.origin.y - other.glyph.origin.y)
                    return a < b
                }) : nil
            // A sign that grows is on the side its ink is: an extension font's
            // hangs from a point at its top, above the line whatever side it
            // is on.
            let raisedHere = deeper ? (host?.raised ?? side ?? (offset > 0)) : inScript ? centre > 0 : offset > 0
            if !deeper {
                side = raisedHere
                held.append((glyph, raisedHere))
            }
            if raisedHere { raised.append(glyph) } else { lowered.append(glyph) }
            reached = max(reached, glyph.rect.maxX)
            end += 1
        }
        return end > start ? (end, raised, lowered) : nil
    }

    /// The ink of a glyph and the pieces stacked with it at its place — a
    /// bar or a bracket built up tall.
    private static func inkOfStack(_ index: Int, in glyphs: [Glyph]) -> CGRect {
        let glyph = glyphs[index]
        func kind(_ one: Glyph) -> String? { barToken(one) ?? (one.isExtension ? "extension" : nil) }
        guard let token = kind(glyph) else { return glyph.rect }
        var box = glyph.rect
        var taken: Set<Int> = [index]
        var grew = true
        while grew {
            grew = false
            for (other, one) in glyphs.enumerated() where !taken.contains(other)
                && abs(one.origin.x - glyph.origin.x) < glyph.size * 0.2 && kind(one) == token
                && one.rect.maxY > box.minY - glyph.size * 0.3 && one.rect.minY < box.maxY + glyph.size * 0.3 {
                box = box.union(one.rect)
                taken.insert(other)
                grew = true
            }
        }
        return box
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
            // A bold italic text face is what \boldsymbol draws a letter with
            // in the Times, Palatino and Utopia papers: \mathbf is upright.
            let italic = upper.contains("ITAL") || upper.contains("OBLIQUE") || upper.hasSuffix("-BI")
            return italic ? "\\boldsymbol" : "\\mathbf"
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
        if style == "\\mathrm", !hyphenated, let names = names(in: letters), !names.isEmpty {
            return (end, names.map { twoWordNames[$0] ?? "\\" + $0 }.joined())
        }
        // A word of the sentence's in a formula — "if", "otherwise", "and"
        // in a system of cases — stands a word's space from the letter or the
        // digit next to it, which \mathrm{if}x takes away: "ifx". The space
        // goes inside \text{}, where TeX keeps it.
        let spaced = letters.count >= 2 && (style == "\\mathrm" || hyphenated)
            ? wordSpaces(around: start..<end, in: glyphs) : (before: false, after: false)
        if hyphenated || spaced.before || spaced.after {
            return (end, "\\text{" + (spaced.before ? " " : "") + letters + (spaced.after ? " " : "") + "}")
        }
        return (end, "\(style){\(letters)}")
    }

    /// Whether a word in a formula has a word's space before it and after it,
    /// from an ordinary symbol on its line — a relation or an operator brings
    /// its own space, which is the formula's and not a sentence's.
    private static func wordSpaces(around run: Range<Int>, in glyphs: [Glyph]) -> (before: Bool, after: Bool) {
        let first = glyphs[run.lowerBound], last = glyphs[run.upperBound - 1]
        let size = first.size
        func ordinary(_ glyph: Glyph) -> Bool {
            let spelled = mathToken(for: glyph)
            guard !spelled.isEmpty, !isBigOperator(glyph) else { return false }
            return !spacedSymbols.contains(spelled)
        }
        // Whatever stands across the line beside it: a script, and a bracket
        // drawn from an extension font, whose point is not on the line.
        func onLine(_ glyph: Glyph) -> Bool {
            glyph.rect.maxY > first.origin.y - size * 0.25 && glyph.rect.minY < first.origin.y + size * 0.75
        }
        // A label stacked on the sign beside it is the sign's: the "iid"
        // over the ∼ of "∼ Exp(1)" runs a little past the ∼, and measured
        // from its "d" the word stood a word's space off — \text{ Exp}.
        func beside(_ candidates: [Glyph], nearest: (Glyph, Glyph) -> Bool) -> Glyph? {
            guard let found = candidates.max(by: nearest) else { return nil }
            guard found.size < size * 0.92 else { return found }
            return candidates.first { full in
                full.size >= size * 0.92
                    && min(full.rect.maxX, found.rect.maxX) - max(full.rect.minX, found.rect.minX) > found.width * 0.5
                    && abs(full.origin.y - found.origin.y) > size * 0.35
            } ?? found
        }
        let previous = beside(glyphs[..<run.lowerBound].filter { onLine($0) && $0.rect.maxX <= first.rect.minX + 0.5 }) {
            $0.rect.maxX < $1.rect.maxX
        }
        let next = beside(glyphs[run.upperBound...].filter { onLine($0) && $0.rect.minX >= last.rect.maxX - 0.5 }) {
            $0.rect.minX > $1.rect.minX
        }
        // Inside a bracket is no place for a space; a bracket's own margin
        // is not one — [\mathrm{Bias}[ stood a sixth of an em from both.
        let before = previous.map {
            ordinary($0) && opening($0) == nil && first.rect.minX - $0.rect.maxX >= size * 0.2
        } ?? false
        let after = next.map {
            ordinary($0) && closing($0) == nil && $0.rect.minX - last.rect.maxX >= size * 0.2
        } ?? false
        return (before, after)
    }

    /// The symbols TeX spaces for themselves: relations, the binary
    /// operators, and punctuation.
    private static let spacedSymbols: Set<String> = [
        "=", "<", ">", "+", "-", ",", ";", ":", ".", "|", "\\mid", "\\leq", "\\geq", "\\neq", "\\le", "\\ge",
        "\\ne", "\\in", "\\notin", "\\ni", "\\subset", "\\subseteq", "\\supset", "\\supseteq", "\\times",
        "\\cdot", "\\pm", "\\mp", "\\to", "\\rightarrow", "\\leftarrow", "\\Rightarrow", "\\Leftarrow",
        "\\Leftrightarrow", "\\leftrightarrow", "\\mapsto", "\\approx", "\\sim", "\\simeq", "\\equiv",
        "\\propto", "\\cong", "\\ll", "\\gg", "\\prec", "\\succ", "\\preceq", "\\succeq", "\\cup", "\\cap",
        "\\setminus", "\\wedge", "\\vee", "\\oplus", "\\otimes", "\\circ", "\\ast", "\\star", "\\div",
        "\\coloneqq", "\\triangleq", "\\iff", "\\implies", "\\lor", "\\land",
    ]

    // MARK: - Structures

    /// A fraction bar, and which glyphs are over it and under it.
    private struct Bar {
        var rule: Rule
        var over: [Int]
        var under: [Int]
        /// An \underbrace or \overbrace rather than a fraction: the rule is
        /// the brace's fill, what stands over it the braced formula or its
        /// label, and under it the other.
        var brace = false
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
        where rule.rect.width > 1 && rule.rect.height < rule.rect.width && !isVinculum(rule, in: glyphs) {
            // The fill of an \underbrace has a formula over it and a label
            // under, everything a fraction bar has — and is written as the
            // brace, with the label where TeX puts it.
            let brace = rule.brace || isBraceFill(rule, in: glyphs)
            var inside = glyphs.indices.filter { !owned.contains($0) && spans(rule, glyphs[$0]) }
            var over = inside.filter { glyphs[$0].origin.y > rule.rect.midY }
            var under = inside.filter { glyphs[$0].origin.y <= rule.rect.midY }
            guard !over.isEmpty, !under.isEmpty else { continue }
            // A brace's label is centred on the brace and may be wider than
            // it — "loss for B" under ℓ_B(θ) — so the label side takes in
            // what runs on along its baseline, letter after letter.
            let labelUnder = brace && (rule.brace ? rule.braceLabelBelow
                : (under.map { glyphs[$0].size }.max() ?? 0) <= (over.map { glyphs[$0].size }.max() ?? 0))
            if brace {
                var label = labelUnder ? under : over
                let size = label.map { glyphs[$0].size }.max() ?? 1
                let levels = label.map { glyphs[$0].origin.y }.sorted()
                let level = levels[levels.count / 2]
                // No further than halfway to the next brace on the level:
                // two labels set side by side run into each other with a
                // space between, and the first took the second's words.
                let beside = rules.filter { $0.brace && $0.rect != rule.rect && abs($0.rect.midY - rule.rect.midY) < 1 }
                let leftBound = beside.filter { $0.rect.maxX <= rule.rect.minX }.map { ($0.rect.maxX + rule.rect.minX) / 2 }.max()
                    ?? -CGFloat.greatestFiniteMagnitude
                let rightBound = beside.filter { $0.rect.minX >= rule.rect.maxX }.map { ($0.rect.minX + rule.rect.maxX) / 2 }.min()
                    ?? CGFloat.greatestFiniteMagnitude
                var grew = true
                while grew {
                    grew = false
                    let span = extent(label.map { glyphs[$0] })
                    for index in glyphs.indices
                    where !owned.contains(index) && !inside.contains(index) && !glyphs[index].isExtension {
                        let glyph = glyphs[index]
                        guard glyph.size <= size * 1.05, abs(glyph.origin.y - level) < size * 0.15,
                              glyph.rect.minX < span.maxX + size * 0.35, glyph.rect.maxX > span.minX - size * 0.35,
                              glyph.rect.midX > leftBound, glyph.rect.midX < rightBound
                        else { continue }
                        label.append(index)
                        inside.append(index)
                        grew = true
                    }
                }
                if labelUnder { under = label } else { over = label }
            }
            // The denominator is the line nearest under the bar, with its
            // scripts: what stands a line further down and happens to reach
            // under the bar is something else's — the wide second row of the
            // limits under the sum after 1/N_t ran back under that bar, and
            // the τ of it made the denominator N_{tτ}. A glyph that far down
            // is the denominator's only with a bar of its own between (a
            // fraction in the denominator) or a sign of the denominator's
            // over it (the limits of a sum there).
            // The denominator's line is where its largest glyphs stand — not
            // its highest script, which would put the j of ∑_j a line down.
            let largest = under.filter { !glyphs[$0].isExtension }.map { glyphs[$0].size }.max() ?? 0
            let lines = under.filter { glyphs[$0].size >= largest * 0.9 && !glyphs[$0].isExtension }
                .map { glyphs[$0].origin.y }.sorted()
            let nearest = lines.isEmpty ? rule.rect.midY : lines[lines.count / 2]
            let far = under.filter { glyphs[$0].origin.y < nearest - glyphs[$0].size * 1.0 && !glyphs[$0].isExtension }
            // (A brace's label is all the label's, in as many lines as it
            // is set — "Relationship" over "Proposal" under one brace.)
            if !far.isEmpty, !labelUnder {
                let stays = Set(far.filter { index in
                    let glyph = glyphs[index]
                    let between = rules.contains { other in
                        other.rect.midY > glyph.origin.y && other.rect.midY < nearest
                            && other.rect.minX < glyph.rect.midX && other.rect.maxX > glyph.rect.midX
                    }
                    let overIt = under.contains { other in
                        other != index && !far.contains(other) && isBigOperator(glyphs[other])
                            && glyphs[other].rect.minX < glyph.rect.midX + 1 && glyphs[other].rect.maxX > glyph.rect.midX - 1
                    }
                    return between || overIt
                })
                let dropped = Set(far).subtracting(stays)
                under.removeAll { dropped.contains($0) }
                inside.removeAll { dropped.contains($0) }
            }
            let parts = extent(inside.map { glyphs[$0] })
            guard rule.rect.minX > parts.minX - 4, rule.rect.maxX < parts.maxX + 4 else { continue }
            bars.append(Bar(rule: rule, over: over, under: under, brace: brace))
            owned.formUnion(inside)
        }
        return bars
    }

    /// Whether a rule is the fill of an \underbrace or \overbrace: TeX
    /// draws the brace as its tips and a rule between them (\downbracefill),
    /// and the rule has the formula over it and the brace's label under —
    /// everything a fraction bar has, and the formula came back divided by
    /// its own label.
    static func isBraceFill(_ rule: Rule, in glyphs: [Glyph]) -> Bool {
        let tips = glyphs.filter { $0.glyphName?.hasPrefix("bracehtip") == true }
        guard !tips.isEmpty else { return false }
        let slack = max(2, rule.rect.height * 4)
        return tips.contains { tip in
            tip.rect.minY < rule.rect.maxY + slack && tip.rect.maxY > rule.rect.minY - slack
                && (abs(tip.rect.maxX - rule.rect.minX) < slack || abs(tip.rect.minX - rule.rect.maxX) < slack)
        }
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
        // A sign set inside a script — the ∑ in an exponent, smaller than the
        // line and well off it — has its limits read with the script, round
        // the script's own line; read round this one, the lower limits of
        // e^{-∑ᵢ∑ⱼ…} were upper ones.
        // A script is set at seven tenths of its line; mathptmx's displayed
        // ∫, a point smaller than the text, is still the line's.
        func insideScript(_ sign: Glyph) -> Bool {
            let lift = sign.rect.midY - baseline
            // Or at the line's size in the fonts that do not shrink it, with
            // all of its ink off the line.
            let clear = sign.isExtension && (lift > 0 ? sign.rect.minY > baseline + body * 0.02
                : sign.rect.maxY < baseline - body * 0.02)
            return (sign.size < body * 0.8 || clear) && abs(lift) > body * 0.3
        }
        for (position, sign) in glyphs.enumerated()
        where isBigOperator(sign) && owned[position] == nil && !consumed.contains(position) && !insideScript(sign) {
            // Whatever full-size thing comes next is where the limits stop, in
            // both arrangements.
            var stop = CGFloat.greatestFiniteMagnitude
            // Another sign with limits of its own right after this one: the
            // limits stacked under the two run into each other — "i=1" and
            // "j∈Bᵢ" under ∑∑ are one row of small glyphs — and are parted
            // between the signs, which takes seeing the other sign's limits
            // as far as they go. Limits set beside a sign, in a sentence, run
            // on towards the next one and are not cut; nor are an integral's,
            // which sit off its tail.
            // The other's go as far as the next full-size thing after it — or
            // halfway to it, when that is a sign with limits too, whose own
            // reach out under the other: a product's wide "r∉S≤tₖ" after
            // ∑∑ took the "1" of the first sum's "a=1" for the second.
            func takesLimits(_ glyph: Glyph) -> Bool {
                isBigOperator(glyph) && !token(for: glyph).contains("int")
            }
            var partner: Glyph?
            var reach = stop
            for next in (position + 1)..<glyphs.count
            where !consumed.contains(next) && glyphs[next].size >= body * 0.95 {
                if let partner {
                    reach = takesLimits(glyphs[next])
                        ? (partner.rect.maxX + glyphs[next].rect.minX) / 2 : glyphs[next].rect.minX
                    break
                }
                stop = glyphs[next].rect.minX
                reach = stop
                guard takesLimits(glyphs[next]) else { break }
                partner = glyphs[next]
                reach = .greatestFiniteMagnitude
            }
            // A limit set wider than its sign (\smashoperator) goes on under
            // what comes next, far off the line, as far as the next sign
            // with limits: the "1" ending "τ=min S≤t+1" stood under the β
            // after the sum and went to the β.
            var far = reach
            if partner == nil {
                far = .greatestFiniteMagnitude
                for next in (position + 1)..<glyphs.count
                where !consumed.contains(next) && glyphs[next].size >= body * 0.95 && takesLimits(glyphs[next]) {
                    far = glyphs[next].rect.minX
                    break
                }
            }
            // The script of the glyph before the sign is that glyph's — the 3
            // of "C₃∑", which a limit reaching out under it took for its own:
            // it starts where that glyph ends, within a script's reach of the
            // line.
            let before = glyphs.filter {
                $0.size >= body * 0.95 && !isBigOperator($0) && $0.rect.maxX <= sign.rect.minX + 1
            }
            func scriptOfAnother(_ glyph: Glyph) -> Bool {
                abs(glyph.origin.y - baseline) < body * 0.6
                    && before.contains { abs(glyph.rect.minX - $0.rect.maxX) < body * 0.12 }
            }
            let candidates = glyphs.indices.filter { other in
                let glyph = glyphs[other]
                let offLine = abs(glyph.origin.y - baseline) > body * 0.75
                return other != position && !consumed.contains(other) && owned[other] == nil
                    && glyph.size < body * 0.95 && !glyph.isExtension
                    && (glyph.rect.midX < reach || (offLine && glyph.rect.midX < far))
                    && glyph.rect.maxX > sign.rect.minX - body * 3
                    && !scriptOfAnother(glyph)
            }
            // What stands under the sign is what is centred on it. Another's
            // limit that runs into this one's — the w∈W under the min of
            // "arg min ∑" — is cut off at the space between them, when what is
            // left is centred on the sign and the whole is not.
            func centred(_ run: [Int]) -> [Int] {
                guard run.count > 1 else { return run }
                let boxes = run.map { glyphs[$0].rect }
                func miss(_ part: [Int]) -> CGFloat { abs(extent(part.map { glyphs[$0] }).midX - sign.rect.midX) }
                let whole = miss(run)
                guard whole > body * 0.3 else { return run }
                // Points of clear space, a point wide or more, with glyphs on both sides.
                let cuts = boxes.map(\.maxX).filter { cut in
                    boxes.contains { $0.minX >= cut + body * 0.1 }
                        && !boxes.contains { $0.minX < cut + body * 0.1 && $0.maxX > cut + 0.01 }
                }
                var best = run
                var least = whole
                for left in [CGFloat?.none] + cuts.filter({ $0 <= sign.rect.midX }).map(Optional.some) {
                    for right in [CGFloat?.none] + cuts.filter({ $0 >= sign.rect.midX }).map(Optional.some) {
                        let part = run.filter { index in
                            let box = glyphs[index].rect
                            return (left.map { box.minX > $0 } ?? true) && (right.map { box.maxX <= $0 + 0.01 } ?? true)
                        }
                        guard !part.isEmpty else { continue }
                        let missed = miss(part)
                        if missed < least { best = part; least = missed }
                    }
                }
                return least < whole * 0.5 ? best : run
            }
            func take(_ side: [Int]) -> [Int] {
                for run in runs(of: side, in: glyphs, gap: body * 0.4) {
                    let span = extent(run.map { glyphs[$0] })
                    let stacked = span.minX < sign.rect.maxX && span.maxX > sign.rect.minX
                        && abs(span.midX - sign.rect.midX) < max(span.width, sign.rect.width) * 0.5 + 1
                    // An integral's lower limit tucks in under its tail.
                    let beside = span.minX >= sign.rect.midX
                        && span.minX - sign.rect.maxX < body * 0.5
                    if stacked, let partner {
                        let cut = parting(run, in: glyphs, between: sign, and: partner)
                        return centred(run.filter { glyphs[$0].rect.midX < cut })
                    }
                    if stacked { return centred(run) }
                    if beside { return run.filter { glyphs[$0].rect.midX < stop } }
                }
                return []
            }
            // A \substack beside a sign, in a sentence, stands its first row
            // within a point of the line — too near it to count as under it
            // — over the row that does: what stands over the limit taken,
            // under the line and a line of script from it, is that limit too.
            func withRowsOver(_ run: [Int]) -> [Int] {
                guard let largest = run.map({ glyphs[$0].size }).max(),
                      let top = run.map({ glyphs[$0].origin.y }).max() else { return run }
                let span = extent(run.map { glyphs[$0] })
                return run + candidates.filter { other in
                    let glyph = glyphs[other]
                    return !run.contains(other) && glyph.origin.y > top && glyph.origin.y < baseline
                        && glyph.origin.y - top < largest * 1.6 && glyph.size <= largest * 1.05
                        && glyph.rect.midX < stop
                        && glyph.rect.maxX > span.minX - largest * 0.3 && glyph.rect.minX < span.maxX + largest * 0.3
                }
            }
            let above = take(candidates.filter { glyphs[$0].origin.y > baseline + body * 0.12 })
            var below = take(candidates.filter { glyphs[$0].origin.y < baseline - body * 0.12 })
            if let first = below.first, glyphs[first].rect.minX >= sign.rect.midX { below = withRowsOver(below) }
            consumed.formUnion(above + below)
            limits[position] = (above, below)
        }
        return limits
    }

    /// Where the limits under two signs side by side part: at a gap in them
    /// that nothing crosses, between the signs' middles, where what falls on
    /// each side is best centred on its own sign — TeX centres each limit on
    /// its sign. Halfway between the signs, the "i" of an "i=sⱼ+1" under a
    /// product went to the "j=1" of the sum beside it. Halfway it is when
    /// there is no such gap.
    private static func parting(
        _ run: [Int], in glyphs: [Glyph], between sign: Glyph, and partner: Glyph
    ) -> CGFloat {
        let left = sign.rect.midX, right = partner.rect.midX
        let boxes = run.map { glyphs[$0].rect }
        func miss(_ part: [CGRect], _ middle: CGFloat) -> CGFloat {
            guard let first = part.first else { return 0 }
            return abs(part.dropFirst().reduce(first) { $0.union($1) }.midX - middle)
        }
        var best: (cut: CGFloat, miss: CGFloat)?
        for cut in boxes.map(\.maxX) where cut > left && cut < right
            && !boxes.contains(where: { $0.minX < cut - 0.01 && $0.maxX > cut + 0.01 }) {
            let total = miss(boxes.filter { $0.midX < cut }, left) + miss(boxes.filter { $0.midX >= cut }, right)
            if best.map({ total < $0.miss }) ?? true { best = (cut, total) }
        }
        return best?.cut ?? (sign.rect.maxX + partner.rect.minX) / 2
    }

    /// A label set right over or under a sign, and the sign — what
    /// `\overset`, `\underset` and `\stackrel` make, and an `\xrightarrow`
    /// with its label.
    private struct Stacked {
        /// The sign: one glyph, or the letters of a word — "minimize" with
        /// the variable under it.
        var base: [Int]
        var above: [Int]
        var below: [Int]
    }

    /// The labels stacked on signs that are not operators with limits,
    /// keyed by the sign's first glyph — found before anything is read,
    /// because a label wider than its sign starts before it.
    ///
    /// Stacked is centred on the sign, and off its line by more than a
    /// script is: TeX sets a label the way it sets the limits of a sum,
    /// centred over the sign, and a script starts where its base ends. Read
    /// as scripts, the "ind" over the ∼ of "ℓ ∼ ℙ" (the first letter of it
    /// begins before the ∼ does) came back as `\ell^i\sim^{nd}`.
    private static func stackedLabels(
        in glyphs: [Glyph], body: CGFloat, owned: [Int: Int], named: Set<Int>,
        consumed: inout Set<Int>
    ) -> [Int: Stacked] {
        var found: [Int: Stacked] = [:]
        func free(_ index: Int) -> Bool {
            !consumed.contains(index) && owned[index] == nil && !named.contains(index)
        }
        // What can carry a label: a sign at the line's size that is not a
        // letter, a digit, a bracket or a mark of punctuation — a relation,
        // an arrow, an operator — or a word set upright.
        func sign(_ index: Int) -> Bool {
            let glyph = glyphs[index]
            guard free(index), glyph.size >= body * 0.92, !glyph.isExtension else { return false }
            let spelled = mathToken(for: glyph)
            guard !spelled.isEmpty, !isBigOperator(glyph), !isDelimiter(glyph), !isAccent(glyph),
                  !isRadical(glyph), ![",", ".", ";", ":", "!", "?", "'"].contains(spelled)
            else { return false }
            if spelled.count == 1, let character = spelled.first, character.isLetter || character.isNumber {
                return false
            }
            return !(spelled.hasPrefix("\\math") || spelled.hasPrefix("\\boldsymbol") || letterCommands.contains(spelled))
        }
        func uprightLetter(_ index: Int) -> Bool {
            free(index) && glyphs[index].size >= body * 0.92 && isUprightLetter(glyphs[index])
                && uprightStyle(glyphs[index]) == "\\mathrm"
        }
        var bases: [[Int]] = []
        var index = 0
        while index < glyphs.count {
            if sign(index) { bases.append([index]); index += 1; continue }
            guard uprightLetter(index) else { index += 1; continue }
            var word = [index]
            var next = index + 1
            while next < glyphs.count {
                if !free(next) || glyphs[next].size < body * 0.92 { next += 1; continue }
                guard uprightLetter(next),
                      glyphs[next].rect.minX - glyphs[word[word.count - 1]].rect.maxX <= glyphs[next].size * 0.22
                else { break }
                word.append(next)
                next += 1
            }
            if word.count >= 2 { bases.append(word) }
            index = word[word.count - 1] + 1
        }
        for base in bases {
            let span = extent(base.map { glyphs[$0] })
            let first = glyphs[base[0]]
            let size = first.size
            let candidates = glyphs.indices.filter { other in
                let glyph = glyphs[other]
                return !base.contains(other) && free(other) && glyph.size < size * 0.92 && !glyph.isExtension
                    && glyph.rect.maxX > span.minX - body * 3 && glyph.rect.minX < span.maxX + body * 3
            }
            func take(_ side: [Int]) -> [Int] {
                for run in runs(of: side, in: glyphs, gap: body * 0.4) {
                    let label = extent(run.map { glyphs[$0] })
                    // Across the sign and centred on it; a script of the
                    // sign starts where the sign ends, and one of the glyph
                    // before it ends before the sign begins.
                    let centred = label.minX < span.maxX && label.maxX > span.minX
                        && label.minX < span.midX && label.maxX > span.midX
                        && abs(label.midX - span.midX) < max(label.width, span.width) * 0.2 + size * 0.1
                    // A label says something: a stray prime or comma is not one.
                    let says = run.contains { !["", ",", ".", "'", ";", ":"].contains(mathToken(for: glyphs[$0])) }
                    // And it hangs from nothing: a run that starts where a
                    // larger glyph on its own level ends is that glyph's
                    // script — the ≤t of S_{≤t} in the second line of a
                    // \substack, which happened to stand under a + above it.
                    let start = run.min { glyphs[$0].rect.minX < glyphs[$1].rect.minX }.map { glyphs[$0] }
                    let hangs = start.map { lead in
                        glyphs.indices.contains { other in
                            let glyph = glyphs[other]
                            let gap = lead.rect.minX - glyph.rect.maxX
                            return !run.contains(other) && !base.contains(other) && glyph.size > lead.size * 1.1
                                && abs(glyph.origin.y - lead.origin.y) < glyph.size * 0.6
                                && gap > -glyph.size * 0.05 && gap < glyph.size * 0.12
                        }
                    } ?? false
                    if centred, says, !hangs { return run }
                }
                return []
            }
            let above = take(candidates.filter { glyphs[$0].origin.y > first.origin.y + size * 0.35 })
            let below = take(candidates.filter { glyphs[$0].origin.y < first.origin.y - size * 0.35 })
            // A word takes only what is under it: over a word is a line
            // above, not a label.
            guard !below.isEmpty || (!above.isEmpty && base.count == 1) else { continue }
            let kept = base.count == 1 ? above : []
            consumed.formUnion(kept + below)
            found[base[0]] = Stacked(base: base, above: kept, below: below)
        }
        return found
    }

    /// The letters written as commands, which carry accents and scripts but
    /// never a label.
    private static let letterCommands: Set<String> = [
        "\\alpha", "\\beta", "\\gamma", "\\delta", "\\epsilon", "\\varepsilon", "\\zeta", "\\eta",
        "\\theta", "\\vartheta", "\\iota", "\\kappa", "\\varkappa", "\\lambda", "\\mu", "\\nu", "\\xi",
        "\\pi", "\\varpi", "\\rho", "\\varrho", "\\sigma", "\\varsigma", "\\tau", "\\upsilon", "\\phi",
        "\\varphi", "\\chi", "\\psi", "\\omega", "\\Gamma", "\\Delta", "\\Theta", "\\Lambda", "\\Xi",
        "\\Pi", "\\Sigma", "\\Upsilon", "\\Phi", "\\Psi", "\\Omega", "\\ell", "\\imath", "\\jmath",
        "\\hbar", "\\hslash", "\\partial", "\\nabla", "\\infty", "\\aleph", "\\wp", "\\Re", "\\Im",
    ]

    /// A bracket at the size the page drew it.
    ///
    /// TeX's \big, \Big, \bigg and \Bigg are glyphs of their own in the
    /// extension fonts, named for their size — "parenleftBig" — and a bar
    /// that tall is a stack of its pieces, three fifths of an em each, so
    /// two of them are \big and five \Bigg. Written plain, the \bigg( round
    /// a radical over a fraction came back as a "(" a third as tall.
    /// Taller than \Bigg is a bracket built of its top, its bottom and what
    /// fills between them, which only \left and \right draw: that is marked
    /// here, and paired once the whole formula is read.
    static func sizedDelimiter(_ fence: String, glyph: Glyph, pieces: [Glyph]) -> (text: String, built: Bool) {
        let name = glyph.glyphName.map(TeXGlyphNames.stripped) ?? ""
        var level = 0
        if name.hasSuffix("Bigg") { level = 4 } else if name.hasSuffix("bigg") { level = 3 }
        else if name.hasSuffix("Big") { level = 2 } else if name.hasSuffix("big") { level = 1 }
        let bar = fence == "|" || fence == "\\|"
        if level == 0, pieces.count >= 2 {
            guard bar else { return (fence, true) }
            // As tall as its pieces reach, and one piece more: \big is 1.2
            // em, and each size three fifths of an em taller.
            let heights = pieces.map(\.origin.y).sorted()
            let steps = zip(heights, heights.dropFirst()).map { $1 - $0 }.sorted()
            let tall = (heights[heights.count - 1] - heights[0] + steps[steps.count / 2]) / glyph.size
            guard tall < 3.3 else { return (fence, true) }
            level = tall < 1.5 ? 1 : tall < 2.1 ? 2 : tall < 2.7 ? 3 : 4
        }
        guard level > 0 else { return (fence, false) }
        let command = ["\\big", "\\Big", "\\bigg", "\\Bigg"][level - 1]
        if bar { return (command + fence, false) }
        return (command + (opening(glyph) != nil ? "l" : "r") + fence, false)
    }

    /// The bar a glyph draws as a character, as a fence: `|` for | and ∣.
    static func barToken(_ glyph: Glyph) -> String? {
        switch token(for: glyph) {
        case "|", "\\mid", "\u{2223}": return "|"
        case "\\|", "\u{2016}", "\u{2225}": return "\\|"
        default: return nil
        }
    }

    /// Brackets built taller than \Bigg, as the pairs they are: an opening
    /// one and the closing one of its kind at its height are `\left` and
    /// `\right`, and a bar between two bars `\left|` … `\right|`. One with no
    /// partner is written \Bigg — the tallest a bracket can be without one.
    private static func pairingBuilt(
        _ tokens: inout [String], _ built: [(token: Int, fence: String, opens: Bool, middle: CGFloat, height: CGFloat)]
    ) {
        let partners: [String: String] = ["(": ")", "[": "]", "\\{": "\\}", "\\langle": "\\rangle",
                                          "\\lfloor": "\\rfloor", "\\lceil": "\\rceil", "|": "|", "\\|": "\\|"]
        var paired = Set<Int>()
        for (position, one) in built.enumerated() where one.opens && !paired.contains(position) {
            guard let partner = partners[one.fence] else { continue }
            let match = built.indices.first { other in
                other > position && !paired.contains(other) && built[other].fence == partner
                    && (partner == one.fence || !built[other].opens)
                    && abs(built[other].middle - one.middle) < one.height * 0.15
            }
            guard let match else { continue }
            paired.formUnion([position, match])
            tokens[one.token] = "\\left" + one.fence
            tokens[built[match].token] = "\\right" + built[match].fence
        }
        for (position, one) in built.enumerated() where !paired.contains(position) {
            let bar = one.fence == "|" || one.fence == "\\|"
            tokens[one.token] = "\\Bigg" + (bar ? "" : one.opens ? "l" : "r") + one.fence
        }
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
            && !used.contains(rule.rect) && !isVinculum(rule, in: glyphs) && !rule.brace && !isBraceFill(rule, in: glyphs) {
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
        /// The mark itself.
        var mark: Int
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
                        // A wide letter runs on past its accent: OpenType
                        // puts the hat of a W at its top, short of its end.
                        && glyph.rect.minX < mark.origin.x
                        && glyph.rect.maxX <= mark.origin.x + max(mark.size * 0.1, glyph.width * 0.5)
                        && glyph.rect.maxX > mark.origin.x - mark.size * 0.6
                }
                covered = before.max { glyphs[$0].rect.maxX < glyphs[$1].rect.maxX }.map { [$0] } ?? []
            } else {
                let under = glyphs.indices.filter { other in
                    let glyph = glyphs[other]
                    return other != index && !consumed.contains(other) && owned[other] == nil
                        && accentName(of: glyph) == nil && !isSpace(glyph)
                        && abs(glyph.origin.y - mark.origin.y) < max(glyph.size, 1) * 0.35
                }
                // A mark grown wide — an OpenType font's \widehat over three
                // letters is one glyph an em across — covers the letters at
                // its ends too, which it lies over by less than half of
                // themselves. A mark the width of a letter covers that one.
                let middle = under.first { glyphs[$0].rect.minX <= mark.rect.midX && glyphs[$0].rect.maxX >= mark.rect.midX }
                let wide = mark.width >= mark.size * 0.75 && middle.map { mark.width >= glyphs[$0].width * 1.5 } ?? true
                covered = under.filter { other in
                    let glyph = glyphs[other]
                    let overlap = min(glyph.rect.maxX, mark.rect.maxX) - max(glyph.rect.minX, mark.rect.minX)
                    return overlap > min(glyph.width, mark.width) * (wide ? 0.3 : 0.5)
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
            found[first] = Accent(command: written, covered: covered, mark: index)
        }
        return found
    }

    /// Relations struck through — `\not` over `=`, a slash across `\in` —
    /// written as the one relation they make, keyed by the relation.
    private static func negations(
        in glyphs: [Glyph], owned: [Int: Int], consumed: inout Set<Int>, strokes: inout [Int: Int]
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
                strokes[other] = index
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
    /// Whether a glyph is one piece of a sign built up tall: ⎛ ⎜ ⎝ and their
    /// kind in OpenType, the halves of a ∫ (⌠ ⌡), "parenlefttp" and
    /// "parenleftex" in TeX's extension fonts, "parenlefttpA" in newtx's. A
    /// whole bracket — a "(" of any size — is none.
    static func isPiece(_ glyph: Glyph) -> Bool {
        if isSilentPiece(glyph) { return true }
        if let unicode = glyph.unicode, unicode.unicodeScalars.count == 1,
           let scalar = unicode.unicodeScalars.first,
           (0x239B...0x23B3).contains(scalar.value) || (0x2320...0x2321).contains(scalar.value) { return true }
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
                // An extension font's pieces are boxed as they are drawn, and
                // one bracket's pieces touch — a filler's height apart at most,
                // should the filler be missed: the bottom of the brace of one
                // system of cases stood 17 points over the top of the next
                // one's, with 8 points of paper between their ink.
                if glyphs[other].isExtension, members.allSatisfy({ glyphs[$0].isExtension }),
                   !members.contains(where: { member in
                       let one = glyphs[member].rect, two = glyphs[other].rect
                       return max(one.minY, two.minY) - min(one.maxY, two.maxY) < size * 0.65
                   }) { continue }
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
        var content = glyphs.indices.filter { other in
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
        // A script is four fifths of its line in some OpenType fonts (LeJEPA's
        // 7.27 points on 8.97): the ∂² over a fraction between bars was a line.
        // The comma after \end{cases} is no line of theirs: it stands on the
        // line the brace does, halfway between two cases.
        func isPunctuation(_ other: Int) -> Bool { [",", ".", ";"].contains(token(for: glyphs[other])) }
        let full = content.filter {
            glyphs[$0].size >= largest * 0.85 && !isBigOperator(glyphs[$0])
                && !isRadical(glyphs[$0]) && !glyphs[$0].isExtension && !isPunctuation($0)
        }
        func lines(at heights: [CGFloat]) -> [CGFloat] {
            var result: [CGFloat] = []
            for height in heights.sorted(by: >) {
                if let last = result.last, last - height < largest * 0.45 { continue }
                result.append(height)
            }
            return result
        }
        var levels = lines(at: full.map { glyphs[$0].origin.y })
        // A displayed fraction in a line — a \dfrac, or cases set in display
        // style — has a numerator and a denominator as large as the line,
        // over and under its bar, and they are that line's, not two more: the
        // line stands on the bar's axis, a quarter of a size under it. Each
        // case of such a system read as three lines, too close to be any.
        // A bar whose line would stand where no line is, too near one to be
        // another, is not a fraction's — an \overline under the line above.
        let bars = rules.filter { rule in
            rule.rect.width > 1 && rule.rect.height < rule.rect.width
                && rule.rect.minX > open.rect.maxX - 1 && rule.rect.maxX < right + 1
                && rule.rect.midY > reach.minY - body && rule.rect.midY < reach.maxY
        }
        func over(_ bar: Rule, _ other: Int) -> Bool {
            let glyph = glyphs[other]
            return glyph.rect.midX > bar.rect.minX - 1 && glyph.rect.midX < bar.rect.maxX + 1
                && glyph.origin.y > bar.rect.midY && glyph.origin.y - bar.rect.midY < largest * 0.75
        }
        func under(_ bar: Rule, _ other: Int) -> Bool {
            let glyph = glyphs[other]
            return glyph.rect.midX > bar.rect.minX - 1 && glyph.rect.midX < bar.rect.maxX + 1
                && glyph.origin.y < bar.rect.midY && bar.rect.midY - glyph.origin.y < largest * 1.3
        }
        var fractions: [(axis: CGFloat, bar: Rule, members: [Int])] = bars.compactMap { bar in
            let members = full.filter { over(bar, $0) || under(bar, $0) }
            guard members.contains(where: { over(bar, $0) }), members.contains(where: { under(bar, $0) })
            else { return nil }
            return (bar.rect.midY - largest * 0.25, bar, members)
        }
        while !fractions.isEmpty {
            let taken = Set(fractions.flatMap(\.members))
            let rest = lines(at: full.filter { !taken.contains($0) }.map { glyphs[$0].origin.y })
            let misplaced = fractions.indices.filter { index in
                let axis = fractions[index].axis
                return !rest.contains { abs($0 - axis) < largest * 0.45 }
                    && rest.contains { abs($0 - axis) < largest * 0.9 }
            }
            if misplaced.isEmpty {
                levels = lines(at: rest + fractions.map(\.axis))
                break
            }
            for index in misplaced.reversed() { fractions.remove(at: index) }
        }
        // What follows the cases on the line the brace stands on — the
        // "∀i ∈ [0, |θ|]" after \end{cases} — is the formula's and no case:
        // it stands right of all of them, where no case reaches.
        if close == nil, levels.count >= 3 {
            let lettered = Set(full)
            for level in levels where abs(level + largest * 0.25 - reach.midY) < largest * 0.3 {
                let beside = content.filter { lettered.contains($0) && abs(glyphs[$0].origin.y - level) < largest * 0.45 }
                let cases = full.filter { abs(glyphs[$0].origin.y - level) >= largest * 0.45 }
                guard let first = beside.map({ glyphs[$0].rect.minX }).min(),
                      let last = cases.map({ glyphs[$0].rect.maxX }).max(),
                      first > last + largest * 0.5 else { continue }
                content.removeAll { glyphs[$0].rect.minX >= first - 0.5 }
                levels.removeAll { $0 == level }
            }
        }
        content.removeAll { other in
            isPunctuation(other) && !levels.contains { abs($0 - glyphs[other].origin.y) < largest * 0.45 }
        }
        guard levels.count >= 2 else { return nil }
        for (upper, lower) in zip(levels, levels.dropFirst()) where upper - lower < largest * 0.9 {
            return nil
        }
        // A bar between two of the lines makes them a fraction's numerator
        // and denominator, whatever brackets stand round them. A fraction in
        // a line has its bar on that line's axis, a quarter of a size over
        // its baseline — under the line above, but no numerator of it: every
        // fraction in the lower case of a system of cases read the two cases
        // as one line, their glyphs interleaved.
        // A fraction inside the numerator or the denominator of a line's own
        // is that fraction's, however high it stands.
        let span = extent(content.map { glyphs[$0] })
        func onAxis(_ rule: Rule) -> Bool {
            levels.contains { rule.rect.midY > $0 && rule.rect.midY - $0 < largest * 0.45 }
        }
        let axial = bars.filter(onAxis)
        if rules.contains(where: { rule in
            rule.rect.width > 1 && rule.rect.height < rule.rect.width
                && rule.rect.maxX > span.minX && rule.rect.minX < span.maxX
                && rule.rect.midY < levels[0] && rule.rect.midY > levels[levels.count - 1]
                && rule.rect.minX > open.rect.minX - 1 && rule.rect.maxX < right + 1
                && !onAxis(rule) && !isVinculum(rule, in: glyphs)
                && !axial.contains { bar in
                    rule.rect.minX > bar.rect.minX - 1 && rule.rect.maxX < bar.rect.maxX + 1
                        && abs(rule.rect.midY - bar.rect.midY) < largest * 0.9
                }
        }) { return nil }
        // The glyphs of a line's own fractions go with the line: within the
        // bar's width, over it as far as a numerator stands and under it as
        // far as a denominator hangs — from the bar or from a fraction inside
        // it — and to the nearest such bar, measured so. Between two cases
        // the denominator of the upper case's fraction and the numerator of
        // the lower one's are the same height: a λ over an N in the lower
        // numerator went up to the case above, and the μ of the upper
        // denominator down to the case below. A displayed fraction — as large
        // as its line — stands further off both ways than a text one.
        var placed: [Int: CGFloat] = [:]
        let displayed = Set(fractions.map { $0.bar.rect.midY })
        for other in content {
            let glyph = glyphs[other]
            let x = glyph.rect.midX, y = glyph.origin.y
            var best: (level: CGFloat, distance: CGFloat)?
            var runnerUp = CGFloat.infinity
            for bar in axial where x > bar.rect.minX - 1 && x < bar.rect.maxX + 1 {
                guard let level = levels.first(where: { bar.rect.midY > $0 && bar.rect.midY - $0 < largest * 0.45 })
                else { continue }
                let reach = displayed.contains(bar.rect.midY) ? (up: 0.9, down: 1.3) : (up: 0.6, down: 0.8)
                let inner = rules.filter { rule in
                    rule.rect.width > 1 && rule.rect.height < rule.rect.width
                        && rule.rect.minX > bar.rect.minX - 1 && rule.rect.maxX < bar.rect.maxX + 1
                        && abs(rule.rect.midY - bar.rect.midY) < largest * 0.9
                }
                var distance = CGFloat.infinity
                for rule in inner where x > rule.rect.minX - 1 && x < rule.rect.maxX + 1 {
                    let apart = y > rule.rect.midY
                        ? (y - rule.rect.midY) / (largest * reach.up) : (rule.rect.midY - y) / (largest * reach.down)
                    distance = min(distance, apart)
                }
                guard distance <= 1 else { continue }
                if let known = best, known.level == level {
                    best = (level, min(known.distance, distance))
                } else if distance < best?.distance ?? .infinity {
                    runnerUp = best?.distance ?? .infinity
                    best = (level, distance)
                } else {
                    runnerUp = min(runnerUp, distance)
                }
            }
            // As far from one fraction as from the other — the subscript of
            // an α in the upper denominator, over the λ of the lower
            // numerator — is for the glyph it hangs from to say.
            if let best, runnerUp - best.distance > 0.2 { placed[other] = best.level }
        }
        // Each glyph goes to the line nearest it — or, a script about as near
        // one line as the other, to the line of the glyph it hangs from. The
        // superscript of a superscript stands as high over its own line as
        // under the line above when the lines are close: the k of n^k in the
        // exponent of a lower case was 8.34 points from the upper case and
        // 8.37 from its own, and went up.
        var lineOf: [Int: Int] = [:]
        func line(of other: Int, depth: Int = 0) -> Int {
            if let known = lineOf[other] { return known }
            let glyph = glyphs[other]
            // A sign drawn from an extension font hangs from its top: a tall
            // radical or \Big parenthesis of the lower case stood where the
            // upper case is. Its middle is on its line's axis.
            let height = placed[other] ?? (glyph.isExtension ? glyph.rect.midY - largest * 0.25 : glyph.origin.y)
            let order = levels.indices.sorted { abs(levels[$0] - height) < abs(levels[$1] - height) }
            var answer = order.first ?? 0
            if placed[other] == nil, glyph.size < largest * 0.85, order.count > 1, depth < 8,
               abs(levels[order[1]] - height) - abs(levels[order[0]] - height) < largest * 0.3,
               let anchor = content.filter({ candidate in
                   let rect = glyphs[candidate].rect
                   return candidate != other && rect.minX < glyph.rect.minX
                       && rect.maxX < glyph.rect.minX + glyph.size * 0.3
                       && glyph.rect.minX - rect.maxX < largest
               }).min(by: { abs(glyphs[$0].origin.y - glyph.origin.y) < abs(glyphs[$1].origin.y - glyph.origin.y) }) {
                answer = line(of: anchor, depth: depth + 1)
            }
            lineOf[other] = answer
            return answer
        }
        var rows: [[Int]] = Array(repeating: [], count: levels.count)
        for other in content { rows[line(of: other)].append(other) }
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
        let key = TokenKey(fontName: glyph.fontName, glyphName: glyph.glyphName, code: glyph.code,
                           unicode: glyph.unicode, isSymbolic: glyph.isSymbolic,
                           wideSigma: glyph.unicode == "\u{1D70D}" && glyph.width > glyph.size * 0.52)
        memoLock.lock()
        let known = memo.tokens[key]
        let quiet = memo.silent[key]
        memoLock.unlock()
        let spelled: String
        let silent: Bool
        if let known, let quiet {
            spelled = known
            silent = quiet
        } else {
            spelled = named(glyph)
            // A piece of a tall sign spells nothing whatever the page's text
            // says is there: PDFKit read a brace's filler as a full stop, and
            // the brace lost the piece that held it together.
            silent = isPiece(glyph)
            memoLock.lock()
            memo.tokens[key] = spelled
            memo.silent[key] = silent
            memoLock.unlock()
        }
        // What the page's own text says is asked for last, and not kept: it
        // is about where the glyph is, not what it is.
        return spelled.isEmpty && !silent ? fallback?(glyph) ?? "" : spelled
    }

    /// What a glyph spells by its font and its name alone.
    private static func named(_ glyph: Glyph) -> String {
        if isSilentPiece(glyph) { return "" }
        // A piece of a drawing — the tips and the middle of a horizontal
        // brace, the shaft of a tall arrow — spells nothing: txexs's tips
        // of an \underbrace sit at the codes of "|", "{" and "z", and came
        // back as those.
        if TeXGlyphNames.isDecoration(glyph.glyphName) { return "" }
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
        return ""
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
