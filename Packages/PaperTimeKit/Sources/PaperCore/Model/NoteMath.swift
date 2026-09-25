import Foundation

/// Where the mathematics is in a note.
///
/// A note's formulas are `$…$` on a line and `$$…$$` either on a line or
/// across several — the shape Latex Suite's `dm` leaves behind:
///
///     $$
///     \frac{a}{b}
///     $$
///
/// The note is otherwise read a line at a time, and a formula that spans
/// lines is the one thing a line-at-a-time reading cannot see. This finds
/// those blocks so the renderer can read them as one line, and finds the
/// span under a caret so a card can show what is being typed. Offsets are
/// UTF-16, the text system's own.
public enum NoteMath {
    /// One formula: where it is, delimiters included, and what is inside.
    public struct Span: Equatable, Sendable {
        public var range: NSRange
        /// The LaTeX, with the space around it taken off.
        public var latex: String
        public var display: Bool
        /// Set for a `$$` that opens on one line and closes on a later one.
        public var isBlock: Bool

        public init(range: NSRange, latex: String, display: Bool, isBlock: Bool) {
            self.range = range
            self.latex = latex
            self.display = display
            self.isBlock = isBlock
        }
    }

    /// The `$$` blocks that span lines, each as one range from the start of
    /// the line that opens it to the end of the line that closes it.
    ///
    /// A line opens a block when it begins with `$$` and does not close it
    /// again on the same line; the block closes at the first later line that
    /// ends with `$$`. A `$$x$$` on one line is not a block — the line reader
    /// already sets that — and neither is a `$$` that nothing closes.
    public static func blocks(in text: String) -> [NSRange] {
        let whole = text as NSString
        let lines = lineRanges(of: whole)
        var result: [NSRange] = []
        var index = 0
        while index < lines.count {
            let line = trimmed(whole.substring(with: lines[index]))
            guard line.hasPrefix("$$"), !line.dropFirst(2).contains("$$") else {
                index += 1
                continue
            }
            var closer: Int?
            var next = index + 1
            while next < lines.count {
                if trimmed(whole.substring(with: lines[next])).hasSuffix("$$") {
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
            let inner = NSRange(location: block.location + 2, length: block.length - 4)
            guard inner.length >= 0, caret >= inner.location,
                  caret <= inner.location + inner.length else { return nil }
            return Span(range: block, latex: trimmed(whole.substring(with: inner)),
                        display: true, isBlock: true)
        }
        let line = whole.lineRange(for: NSRange(location: caret, length: 0))
        let content = whole.substring(with: line)
        for match in inlinePattern.matches(in: content, range: NSRange(location: 0, length: line.length)) {
            let display = match.range(at: 1).location != NSNotFound
            let body = display ? match.range(at: 1) : match.range(at: 2)
            let inner = NSRange(location: line.location + body.location, length: body.length)
            guard caret >= inner.location, caret <= inner.location + inner.length else { continue }
            let range = NSRange(location: line.location + match.range.location, length: match.range.length)
            return Span(range: range, latex: trimmed((content as NSString).substring(with: body)),
                        display: display, isBlock: false)
        }
        return nil
    }

    /// `$$…$$` first, then `$…$`, neither crossing a line.
    private static let inlinePattern = try! NSRegularExpression(
        pattern: #"\$\$([^$\n]+)\$\$|\$([^$\n]+)\$"#
    )

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
