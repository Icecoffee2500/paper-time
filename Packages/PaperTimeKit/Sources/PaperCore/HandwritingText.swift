import Foundation

/// What the handwriting model says, tidied into what Ultracopy copies.
///
/// The model (Qwen3.5, read on this Mac — `HandwritingReader`) answers in
/// Markdown: the words as words, the mathematics between `$` and `$`, a line
/// that is only a formula between `$$` and `$$`. Two habits are left over
/// from the data it learned from. It sometimes writes a formula a token at a
/// time with a space between — `P ( \bigcup _ { 1 } ^ { \infty } A _ { i } )`,
/// `\operatorname* { l i m }` — which is the formula OCR's habit too, and
/// `FormulaOCRText` already closes that up. And it sometimes wraps its whole
/// answer in a code fence, or writes `\(…\)` and `\[…\]` where a note wants
/// dollars.
///
/// Only the mathematics is touched, and only when it is written spaced out:
/// a formula already written as LaTeX is written as its author would, and
/// the words around it keep their spaces.
public enum HandwritingText {
    public static func tidy(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = unfenced(text)
        text = text.replacingOccurrences(of: "\\[", with: "$$").replacingOccurrences(of: "\\]", with: "$$")
        text = text.replacingOccurrences(of: "\\(", with: "$").replacingOccurrences(of: "\\)", with: "$")
        text = mappingMath(in: text) { formula, displayed in
            var body = formula.trimmingCharacters(in: .whitespacesAndNewlines)
            if isSpacedOut(body) {
                let tidied = FormulaOCRText.tidy(body)
                body = tidied.body
                if let tag = tidied.tag { body += displayed ? "\\tag{\(tag)}" : " (\(tag))" }
            }
            return namingOperators(body)
        }
        // Lines as the note has them: no trailing spaces, one blank line at most.
        let lines = text.components(separatedBy: "\n").map { line in
            var line = line
            while line.last == " " || line.last == "\t" { line.removeLast() }
            return line
        }
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) {
            kept.append(line)
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    /// The answer without a code fence round it: ```` ```latex … ``` ````.
    static func unfenced(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a formula is written a token at a time: a script's brace with
    /// a space inside it, or a name spelled out letter by letter.
    static func isSpacedOut(_ formula: String) -> Bool {
        formula.contains("_ {") || formula.contains("^ {") || formula.contains("\\operatorname {")
            || formula.contains("\\operatorname* {") || formula.contains("\\mathrm {") || formula.contains("\\frac {")
    }

    /// `\operatorname*{lim}` and the like are the operators TeX has names for.
    static func namingOperators(_ formula: String) -> String {
        let names = ["lim", "liminf", "limsup", "sup", "inf", "max", "min", "log", "ln", "exp", "sin", "cos",
                     "tan", "det", "arg", "dim", "ker", "deg", "gcd", "Pr", "argmax", "argmin"]
        var out = formula
        for name in names {
            for spelled in ["\\operatorname*{\(name)}", "\\operatorname{\(name)}"] {
                let replacement: String
                switch name {
                case "argmax": replacement = "\\arg\\max"
                case "argmin": replacement = "\\arg\\min"
                default: replacement = "\\" + name
                }
                out = out.replacingOccurrences(of: spelled, with: replacement)
            }
        }
        return out
    }

    /// Each formula in the text, `$$…$$` and `$…$`, through `transform`.
    /// An unclosed dollar is left as it is.
    static func mappingMath(in text: String, _ transform: (String, Bool) -> String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "$") {
            out += rest[..<open]
            let displayed = rest[open...].hasPrefix("$$")
            let delimiter = displayed ? "$$" : "$"
            let bodyStart = rest.index(open, offsetBy: delimiter.count)
            guard let close = rest[bodyStart...].range(of: delimiter) else {
                out += rest[open...]
                rest = ""
                break
            }
            out += delimiter + transform(String(rest[bodyStart..<close.lowerBound]), displayed) + delimiter
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }
}
