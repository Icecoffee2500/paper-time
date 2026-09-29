// The answers the Portable build's `shared/noteMath.ts` is held to: the Mac's
// own `NoteMath` on a set of notes — the blocks that span lines, every
// formula of every line, which lines are one displayed formula, and the span
// under the caret at every place a caret can be.
//
//     swiftc -O -parse-as-library \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/NoteMath.swift \
//       Scripts/note-math-fixture.swift -o /tmp/note-math-fixture
//     /tmp/note-math-fixture > Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/note-math.json
//
// Change NoteMath and run this again; both builds' tests read the file.
import Foundation

@main
enum NoteMathFixture {
    static let notes = [
        "before\n$$\n\\frac{a}{b}\n$$\nafter",
        "$$\n\\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned}\n$$",
        "x $$a$$ y\n$$b$$",
        "$$\n\\frac{a}{b}\nprose",
        "$$ a +\nb $$\nrest",
        "the mean $\\bar{x}$ is and $$\\sum_i x_i$$ too",
        "평균 $\\mu$ 예요, 그리고 \\(\\sigma^2\\)도요",
        "\\begin{align}\na &= b \\tag{1} \\\\\nc &= d \\label{eq:c}\n\\end{align}\nSee \\eqref{eq:c}.",
        "  \\begin{equation*}\n\\begin{split}\na &= b\n\\end{split}\n\\end{equation*}",
        "\\begin{align} a &= b \\end{align} on one line",
        "\\begin{itemize}\n\\item a\n\\end{itemize}",
        "\\begin{align}\na\n\\end{aligned}",
        "\\[\n\\sum_i x_i\n\\]\nafter \\[ y \\] and \\[z",
        "a $x$ b \\(y\\) c $$z$$ d \\[w\\] e \\begin{pmatrix} 1 \\end{pmatrix}",
        "\\begin{math} a \\end{math} and \\begin{displaymath} b \\end{displaymath}",
        "\\begin{equation} \\begin{aligned} a &= b \\end{aligned} \\end{equation} x",
        "\\begin{align*} a \\end{align} \\begin{tabular} a \\end{tabular}",
        "> \\begin{align} a &= b \\tag{1} \\\\ c &= d \\tag{2} \\end{align}\n> [p. 3](papertime://anchor?x=1)",
        "Then \\begin{equation} E = mc^2 \\tag{3} \\end{equation} holds.",
        "$$ $$ and $ $ and \\( \\) and \\begin{cases}\\end{cases}",
        "cost \\$5 and $x$ \\\\[2pt] next",
        "\\begin{CD} A @>f>> B \\end{CD}\n\\begin{array}{c|c}\na & b \\\\ \\hline\nc & d\n\\end{array}",
        "- $$x$$\n# $$y$$\n> $$z$$\n  $$w$$  ",
        "\\begin{gather}\na\n\n\\\\\nb\n\\end{gather}",
        "$$\nunclosed\n\\begin{align}\nx\n\\end{align}",
        "\\begin{multline*}\na + b\n\\\\ + c\n\\end{multline*}",
        "",
        "$",
        "\\begin{bmatrix}1&2\\\\3&4\\end{bmatrix}\\begin{vmatrix}a\\end{vmatrix}",
        "By \\eqref{eq:elbo} and \\ref{eq:kl}, $x \\eqref{a}$ holds; not \\\\eqref{b}",
        "\\$5 and \\$10, then $y$ and \\\\(z\\) and \\\\[w\\]",
    ]

    static func main() {
        struct Span: Encodable {
            var from: Int
            var to: Int
            var latex: String
            var display: Bool
            var isBlock: Bool
            init(_ span: NoteMath.Span) {
                from = span.range.location
                to = span.range.location + span.range.length
                latex = span.latex
                display = span.display
                isBlock = span.isBlock
            }
        }
        struct Line: Encodable {
            var from: Int
            var to: Int
            var formulas: [Span]
            var displays: [[Int]]
            var isDisplay: Bool
        }
        struct Note: Encodable {
            var text: String
            var blocks: [[Int]]
            var lines: [Line]
            /// The span under a caret at 0…length, nil where there is none.
            var spans: [Span?]
        }

        let cases = notes.map { text -> Note in
            let whole = text as NSString
            let blocks = NoteMath.blocks(in: text)
            // The lines as a note reads them: a block is one.
            var ranges = NoteMath.lineRanges(of: whole)
            for block in blocks.reversed() {
                guard let first = ranges.firstIndex(where: { $0.location == block.location }),
                      let last = ranges.firstIndex(where: { $0.location + $0.length == block.location + block.length }),
                      last >= first else { continue }
                ranges.replaceSubrange(first...last, with: [block])
            }
            let lines = ranges.map { range -> Line in
                let line = whole.substring(with: range) as NSString
                var found: [Span] = []
                var index = 0
                while index < line.length,
                      let one = NoteMath.firstFormula(in: line, range: NSRange(location: index, length: line.length - index)) {
                    found.append(Span(one))
                    index = one.range.location + max(one.range.length, 1)
                }
                let lineText = line as String
                return Line(
                    from: range.location, to: range.location + range.length, formulas: found,
                    displays: NoteMath.displays(in: lineText).map { [$0.location, $0.location + $0.length] },
                    isDisplay: NoteMath.isDisplay(lineText)
                )
            }
            let spans = (0...whole.length).map { NoteMath.span(at: $0, in: text).map(Span.init) }
            return Note(text: text, blocks: blocks.map { [$0.location, $0.location + $0.length] },
                        lines: lines, spans: spans)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try! encoder.encode(["notes": cases])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
