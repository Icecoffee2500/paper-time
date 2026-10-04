import Foundation

/// What the formula OCR model says, tidied into the LaTeX Ultracopy writes.
///
/// The model (pix2text's math formula recogniser, a TrOCR) emits one token
/// per step with a space between — `\mathbf { m } _ { i }` — and spells a
/// word inside `\mathrm` letter by letter with `~` for the spaces between
/// words: `\mathrm { ~ n o d e ~ t o ~ n o d e ~ m e s s a g e }`. A paper's
/// equation number comes along at the end as `\qquad \qquad \mathrm { ( 4 ) }`.
/// Tidied, the tokens close up (a space stays only where a control word
/// would otherwise swallow the letter after it: `\alpha x`), the spelled
/// words become `\text{node to node message}`, and the number becomes the
/// `\tag` the reader writes for a numbered equation.
///
/// The Portable build has the same function (`shared/formulaOCRText.ts`); the
/// cases in `FormulaOCRTextTests` are the contract between them.
public enum FormulaOCRText {
    public struct Tidied: Equatable, Sendable {
        public var body: String
        public var tag: String?
        public init(body: String, tag: String? = nil) {
            self.body = body
            self.tag = tag
        }
    }

    public static func tidy(_ raw: String) -> Tidied {
        var tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        var tag: String?

        // The equation number at the end: `\qquad … \mathrm { ( 4 ) }`, or
        // bare `( 4 )` after the \qquads. Taken off, and written as a tag.
        if let number = trailingNumber(in: tokens) {
            tag = number.tag
            tokens.removeSubrange(number.from...)
            while tokens.last == "\\qquad" || tokens.last == "\\quad" { tokens.removeLast() }
        }

        // Words spelled out letter by letter inside \mathrm, with ~ between;
        // function names spelled out inside \operatorname; an operator's
        // limits written as \underset; cells wrapped in braces.
        tokens = unwrappingSubstacks(tokens)
        tokens = joiningSpelledWords(tokens)
        tokens = namingOperators(tokens)
        tokens = loweringLimits(tokens)
        tokens = unwrappingCells(tokens)

        var body = ""
        var previous = ""
        for token in tokens {
            if isControlWord(previous), let first = token.unicodeScalars.first,
               CharacterSet.letters.contains(first) {
                body += " "
            }
            body += token
            previous = token
        }
        return Tidied(body: body, tag: tag)
    }

    private static func isControlWord(_ token: String) -> Bool {
        guard token.hasPrefix("\\"), token.count > 1 else { return false }
        return token.dropFirst().allSatisfy { $0.isLetter }
    }

    /// `\mathrm { ( 4 ) }` or `( 4 )` at the very end, after any \qquads:
    /// where it starts, and the number inside the parentheses.
    private static func trailingNumber(in tokens: [String]) -> (from: Int, tag: String)? {
        var end = tokens.count
        while end > 0, tokens[end - 1] == "\\qquad" || tokens[end - 1] == "\\quad" { end -= 1 }
        guard end >= 3, tokens[end - 1] == ")" || tokens[end - 1] == "}" else { return nil }
        // `( digits ... )` possibly wrapped in `\mathrm { … }`.
        var close = end - 1
        var wrapped = false
        if tokens[close] == "}" {
            guard close >= 4, tokens[close - 1] == ")" else { return nil }
            wrapped = true
            close -= 1
        }
        var open = close - 1
        var inner: [String] = []
        while open >= 0, tokens[open] != "(" {
            inner.insert(tokens[open], at: 0)
            open -= 1
        }
        guard open >= 0, !inner.isEmpty, inner.allSatisfy({ $0.allSatisfy { $0.isNumber || $0 == "." || $0.isLetter } }),
              inner.contains(where: { $0.contains(where: \.isNumber) }) else { return nil }
        var from = open
        if wrapped {
            guard open >= 2, tokens[open - 1] == "{", tokens[open - 2] == "\\mathrm" else { return nil }
            from = open - 2
        }
        // Only at the end of a formula, after some spacing — a `(4)` that
        // is part of the formula (`f(4)`) follows a letter directly.
        guard from > 0, tokens[from - 1] == "\\qquad" || tokens[from - 1] == "\\quad" || tokens[from - 1] == "," || tokens[from - 1] == "." else {
            return nil
        }
        return (from, inner.joined())
    }

    /// `\mathrm { ~ n o d e ~ t o ~ n o d e }` → `\text{node to node}`: the
    /// letters close up and the ties become spaces. A `\mathrm` without a
    /// tie — one word, `\mathrm { r e c }`, `\mathrm { d x }` — closes up and
    /// stays upright letters, which is how the reader writes a label.
    private static func joiningSpelledWords(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            if tokens[index] == "\\mathrm", index + 1 < tokens.count, tokens[index + 1] == "{",
               let close = closingBrace(in: tokens, from: index + 1) {
                // The space between words is a tie, or a spacing command —
                // the model writes `\;` between the words of a label too.
                let inner = Array(tokens[(index + 2)..<close]).map { Self.ties.contains($0) ? "~" : $0 }
                let spelled = inner.allSatisfy { $0 == "~" || $0 == "-" || $0 == "." || $0.count == 1 && ($0.first!.isLetter || $0.first!.isNumber) }
                if spelled, inner.contains("~") {
                    // A tie at the end is the space before the formula goes
                    // on (`\text{if }x`); one at the start is the model's.
                    let words = String(inner.map { $0 == "~" ? " " : $0 }.joined().drop(while: \.isWhitespace))
                    out.append("\\text{\(words)}")
                    index = close + 1
                    continue
                }
                if spelled, !inner.isEmpty {
                    out.append("\\mathrm{\(inner.joined())}")
                    index = close + 1
                    continue
                }
            }
            out.append(tokens[index])
            index += 1
        }
        return out
    }

    /// The functions TeX names with a control word of their own: the model
    /// spells them out as `\operatorname { s i n }` (or `\operatorname*`).
    private static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
        "log", "ln", "lg", "exp", "det", "dim", "ker", "deg", "gcd", "hom", "arg", "Pr",
        "max", "min", "sup", "inf", "lim", "limsup", "liminf", "argmax", "argmin",
    ]
    /// The ones whose limits go under them in a display.
    private static let limited: Set<String> = ["max", "min", "sup", "inf", "lim", "limsup", "liminf", "argmax", "argmin"]

    /// `\operatorname { t a n h }` → `\tanh`; a name TeX has no word for stays
    /// `\operatorname{name}`. `{ \cal L }` → `\mathcal{L}`, `\stackrel` →
    /// `\overset`.
    private static func namingOperators(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "\\operatorname" || token == "\\operatorname*", index + 1 < tokens.count, tokens[index + 1] == "{",
               let close = closingBrace(in: tokens, from: index + 1) {
                let inner = tokens[(index + 2)..<close]
                if inner.allSatisfy({ $0.count == 1 && $0.first!.isLetter }) {
                    let name = inner.joined()
                    out.append(functions.contains(name) ? "\\\(name)" : "\\operatorname{\(name)}")
                    index = close + 1
                    continue
                }
            }
            if token == "{", index + 3 < tokens.count, tokens[index + 1] == "\\cal", tokens[index + 3] == "}",
               tokens[index + 2].count == 1 {
                out.append("\\mathcal{\(tokens[index + 2])}")
                index += 4
                continue
            }
            out.append(token == "\\stackrel" ? "\\overset" : token)
            index += 1
        }
        return out
    }

    /// `\underset { w } { \min }` → `\min _ { w }`: the way the reader writes
    /// a limit under an operator. (Only for the operators that take limits;
    /// `\underset` under anything else is what it says.)
    private static func loweringLimits(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            if tokens[index] == "\\underset", index + 1 < tokens.count, tokens[index + 1] == "{",
               let underClose = closingBrace(in: tokens, from: index + 1),
               underClose + 1 < tokens.count, tokens[underClose + 1] == "{",
               let overClose = closingBrace(in: tokens, from: underClose + 1),
               overClose - underClose == 3,
               tokens[underClose + 2].hasPrefix("\\"), limited.contains(String(tokens[underClose + 2].dropFirst())) {
                out.append(tokens[underClose + 2])
                out.append("_")
                out.append(contentsOf: tokens[(index + 1)...underClose])
                index = overClose + 1
                continue
            }
            out.append(tokens[index])
            index += 1
        }
        return out
    }

    /// `\begin{cases} { x } & { y } \\ \end{cases}` → `\begin{cases} x & y \end{cases}`:
    /// the model wraps every cell in braces and ends the last row with `\\`;
    /// the reader writes neither.
    private static func unwrappingCells(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        var inside = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("\\begin{") { inside += 1 }
            if token.hasPrefix("\\end{") {
                inside -= 1
                // A row break right before the end is the model's habit.
                if out.last == "\\\\" { out.removeLast() }
            }
            if inside > 0, token == "{", let close = closingBrace(in: tokens, from: index),
               index > 0, ["&", "\\\\"].contains(tokens[index - 1]) || tokens[index - 1].hasPrefix("\\begin{"),
               close + 1 < tokens.count, ["&", "\\\\"].contains(tokens[close + 1]) || tokens[close + 1].hasPrefix("\\end{") {
                out.append(contentsOf: tokens[(index + 1)..<close])
                index = close + 1
                continue
            }
            out.append(token)
            index += 1
        }
        return out
    }

    /// What stands for a space inside a spelled label.
    private static let ties: Set<String> = ["~", "\\;", "\\,", "\\:", "\\ ", "\\quad", "\\qquad"]

    /// `\substack { X }` with one row is just `X`: the model wraps a brace's
    /// label in one for no reason.
    private static func unwrappingSubstacks(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            if tokens[index] == "\\substack", index + 1 < tokens.count, tokens[index + 1] == "{",
               let close = closingBrace(in: tokens, from: index + 1),
               !tokens[(index + 2)..<close].contains("\\\\") {
                // Alone inside a group — `_ { \substack { … } }` — its own
                // braces go too, or the group is braced twice.
                let alone = out.last == "{" && close + 1 < tokens.count && tokens[close + 1] == "}"
                out.append(contentsOf: alone ? tokens[(index + 2)..<close] : tokens[(index + 1)...close])
                index = close + 1
                continue
            }
            out.append(tokens[index])
            index += 1
        }
        return out
    }

    private static func closingBrace(in tokens: [String], from open: Int) -> Int? {
        var depth = 0
        for index in open..<tokens.count {
            if tokens[index] == "{" { depth += 1 }
            if tokens[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }
}
