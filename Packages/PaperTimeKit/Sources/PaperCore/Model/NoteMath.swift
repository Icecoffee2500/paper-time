import Foundation

/// Where the mathematics is in a note.
///
/// A note's formulas are written the way a paper's source writes them: `$…$`
/// and `\(…\)` in a sentence, `$$…$$` and `\[…\]` on a line of their own, and
/// amsmath's environments — `\begin{align}…\end{align}` and the rest — bare,
/// as they stand in a LaTeX file. The displayed ones may run over several
/// lines — the shape Latex Suite's `dm` leaves behind, and the shape anybody
/// writes an `align` in:
///
///     $$
///     \frac{a}{b}
///     $$
///
/// The note is otherwise read a line at a time, and a formula that spans
/// lines is the one thing a line-at-a-time reading cannot see. This finds
/// those blocks so the renderer can read them as one line, finds each formula
/// in a line (`firstFormula`), and finds the one under a caret so a card can
/// show what is being typed. Offsets are UTF-16, the text system's own.
public enum NoteMath {
    /// One formula: where it is, delimiters included, and what is inside.
    public struct Span: Equatable, Sendable {
        public var range: NSRange
        /// The LaTeX, with the space around it taken off. An environment is
        /// its whole self, `\begin` to `\end`: that is what sets it.
        public var latex: String
        public var display: Bool
        /// Set for a formula that opens on one line and closes on a later one.
        public var isBlock: Bool

        public init(range: NSRange, latex: String, display: Bool, isBlock: Bool) {
            self.range = range
            self.latex = latex
            self.display = display
            self.isBlock = isBlock
        }
    }

    /// The environments set as a formula when they stand bare in a note: the
    /// ones MathJax sets on their own. `displaymath` and `math` are LaTeX's
    /// spelling of `\[…\]` and `\(…\)`, and are set as those.
    public static let environments = [
        "equation", "align", "alignat", "gather", "multline", "flalign", "eqnarray",
        "xalignat", "xxalignat", "aligned", "alignedat", "gathered", "lgathered", "rgathered",
        "split", "multlined", "cases", "dcases", "rcases", "drcases", "numcases",
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix",
        "psmallmatrix", "bsmallmatrix", "Bsmallmatrix", "vsmallmatrix", "Vsmallmatrix",
        "array", "subarray", "CD", "displaymath", "math",
    ]

    /// A formula in a line: `$$…$$`, `$…$`, `\[…\]`, `\(…\)`, an
    /// environment from `\begin` to its own `\end`, or a reference to a
    /// numbered one — `\eqref{…}` is written in a sentence, as LaTeX writes
    /// it. None of them opens after a backslash: `\$` is a dollar, and `\\[`
    /// is a line break. Groups: 1 `$$`, 2 `$`, 3 `\[`, 4 `\(`, 5 the
    /// environment's name, 6 its star, 7 its body, 8 the reference's label.
    static let formulaPattern = try! NSRegularExpression(
        pattern: #"(?<!\\)\$\$([^$]+)\$\$|(?<!\\)\$([^$\n]+)\$|(?<!\\)\\\[([\s\S]+?)\\\]"#
            + #"|(?<!\\)\\\(([^\n]+?)\\\)|(?<!\\)\\begin\{("#
            + environments.joined(separator: "|")
            + #")(\*?)\}([\s\S]*?)\\end\{\5\6\}|(?<!\\)\\(?:eq)?ref\{([^{}\n]*)\}"#
    )

    /// The environment that opens a line, when one does: `\begin{align}`.
    private static let openerPattern = try! NSRegularExpression(
        pattern: #"^\\begin\{("# + environments.joined(separator: "|") + #")(\*?)\}"#
    )

    /// The first formula in `range` of `text`, with what sets it.
    public static func firstFormula(in text: NSString, range: NSRange) -> Span? {
        guard let match = formulaPattern.firstMatch(in: text as String, range: range) else { return nil }
        return span(of: match, in: text, isBlock: false)
    }

    private static func span(of match: NSTextCheckingResult, in text: NSString, isBlock: Bool) -> Span? {
        func group(_ index: Int) -> NSRange? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : range
        }
        let whole = match.range
        if let body = group(1) {
            return Span(range: whole, latex: trimmed(text.substring(with: body)), display: true, isBlock: isBlock)
        }
        if let body = group(2) {
            return Span(range: whole, latex: trimmed(text.substring(with: body)), display: false, isBlock: isBlock)
        }
        if let body = group(3) {
            return Span(range: whole, latex: trimmed(text.substring(with: body)), display: true, isBlock: isBlock)
        }
        if let body = group(4) {
            return Span(range: whole, latex: trimmed(text.substring(with: body)), display: false, isBlock: isBlock)
        }
        if group(8) != nil {
            return Span(range: whole, latex: text.substring(with: whole), display: false, isBlock: isBlock)
        }
        if let name = group(5), let body = group(7) {
            // LaTeX's own names for the two delimiters are set as those.
            switch text.substring(with: name) {
            case "displaymath":
                return Span(range: whole, latex: trimmed(text.substring(with: body)), display: true, isBlock: isBlock)
            case "math":
                return Span(range: whole, latex: trimmed(text.substring(with: body)), display: false, isBlock: isBlock)
            default:
                return Span(range: whole, latex: trimmed(text.substring(with: whole)), display: true, isBlock: isBlock)
            }
        }
        return nil
    }

    /// Where a formula's LaTeX is between its delimiters — the caret inside
    /// it is typing it.
    private static func inside(_ match: NSTextCheckingResult) -> NSRange {
        for index in [1, 2, 3, 4, 7, 8] where match.range(at: index).location != NSNotFound {
            return match.range(at: index)
        }
        return match.range
    }

    /// The displayed formulas in a text, in order: what a quotation puts on
    /// lines of their own.
    public static func displays(in text: String) -> [NSRange] {
        let whole = text as NSString
        return formulaPattern.matches(in: text, range: NSRange(location: 0, length: whole.length))
            .compactMap { match in span(of: match, in: whole, isBlock: false)?.display == true ? match.range : nil }
    }

    /// Whether a line is one displayed formula and nothing else.
    public static func isDisplay(_ line: String) -> Bool {
        let text = trimmed(line)
        let whole = text as NSString
        guard let first = displays(in: text).first else { return false }
        return first.location == 0 && first.length == whole.length
    }

    /// The displayed formulas that span lines, each as one range from the
    /// start of the line that opens it to the end of the line that closes it.
    ///
    /// A line opens a block when it begins with `$$`, `\[` or an environment's
    /// `\begin` and does not close it again on the same line. A `$$` or a
    /// `\[` closes at the first later line that ends with its closer; an
    /// environment at the first later line that holds its own `\end`. A
    /// formula on one line is not a block — the line reader already sets
    /// that — and neither is an opener that nothing closes.
    public static func blocks(in text: String) -> [NSRange] {
        let whole = text as NSString
        let lines = lineRanges(of: whole)
        var result: [NSRange] = []
        var index = 0
        while index < lines.count {
            let line = trimmed(whole.substring(with: lines[index]))
            let closes: (String) -> Bool
            if line.hasPrefix("$$"), !line.dropFirst(2).contains("$$") {
                closes = { $0.hasSuffix("$$") }
            } else if line.hasPrefix("\\["), !line.dropFirst(2).contains("\\]") {
                closes = { $0.hasSuffix("\\]") }
            } else if let opener = openerPattern.firstMatch(
                in: line, range: NSRange(location: 0, length: (line as NSString).length)
            ) {
                let name = (line as NSString).substring(with: opener.range(at: 1))
                    + (line as NSString).substring(with: opener.range(at: 2))
                let end = "\\end{\(name)}"
                guard !(line as NSString).substring(from: opener.range.length).contains(end) else {
                    index += 1
                    continue
                }
                closes = { $0.contains(end) }
            } else {
                index += 1
                continue
            }
            var closer: Int?
            var next = index + 1
            while next < lines.count {
                if closes(trimmed(whole.substring(with: lines[next]))) {
                    closer = next
                    break
                }
                next += 1
            }
            guard let closer else {
                index += 1
                continue
            }
            let start = lines[index].location
            let end = lines[closer].location + lines[closer].length
            result.append(NSRange(location: start, length: end - start))
            index = closer + 1
        }
        return result
    }

    /// The formula the caret is inside, if it is inside one: between the
    /// delimiters, so a caret just before a `$` or just after one is not in
    /// the formula it borders.
    public static func span(at caret: Int, in text: String) -> Span? {
        let whole = text as NSString
        guard caret >= 0, caret <= whole.length else { return nil }
        for block in blocks(in: text) where block.contains(caret) || block.location + block.length == caret {
            // The block's formula, from its opener to its closer; the words
            // round it on the first and last lines are not in it.
            guard let match = formulaPattern.firstMatch(in: text, range: block),
                  let found = self.span(of: match, in: whole, isBlock: true)
            else { return nil }
            let body = inside(match)
            guard caret >= body.location, caret <= body.location + body.length,
                  !found.latex.isEmpty else { return nil }
            return found
        }
        let line = whole.lineRange(for: NSRange(location: caret, length: 0))
        let content = NSRange(location: line.location, length: line.length)
        for match in formulaPattern.matches(in: text, range: content) {
            // A formula that runs past the line is a block's, and a block
            // was not found here.
            guard match.range.location + match.range.length <= line.location + line.length else { continue }
            let body = inside(match)
            guard caret >= body.location, caret <= body.location + body.length,
                  let found = self.span(of: match, in: whole, isBlock: false), !found.latex.isEmpty
            else { continue }
            if whole.substring(with: match.range).contains("\n") { continue }
            return found
        }
        return nil
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every line of the text, a range each, the last one even when empty.
    static func lineRanges(of text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var start = 0
        while start <= text.length {
            let rest = NSRange(location: start, length: text.length - start)
            let newline = text.range(of: "\n", range: rest)
            if newline.location == NSNotFound {
                result.append(rest)
                break
            }
            result.append(NSRange(location: start, length: newline.location - start))
            start = newline.location + 1
            if start == text.length {
                result.append(NSRange(location: start, length: 0))
                break
            }
        }
        return result
    }
}
