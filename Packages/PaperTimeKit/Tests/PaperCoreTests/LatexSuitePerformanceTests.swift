import Foundation
import Testing
@testable import PaperCore

/// The engine runs on every keystroke, so it is timed on the kind of note it
/// will meet: long, mostly prose, with math near the end.
extension LatexSuiteTests {
    @Suite("Timing")
    struct Timing {
        let engine = LatexSuite.Engine()

        /// A note of just over 20,000 characters: headings, paragraphs that
        /// are one long line each (notes wrap softly), inline and display
        /// math, lists, fenced code — and a last paragraph whose inline
        /// equation the caret is in. `paragraph: 0` is the hardest shape: the
        /// whole note one paragraph, one line, the equation at its end.
        static func note(paragraph: Int) -> (text: String, caret: Int) {
            let sentence = "The posterior $p(\\theta \\mid x)$ follows from Bayes' rule, and the evidence costs a sum over every $z$. "
            if paragraph == 0 {
                var text = ""
                while (text as NSString).length < 20_000 { text += sentence }
                text += "Finally the bound is $\\frac{a}{b} + q"
                let caret = (text as NSString).length
                return (text + " + y$ which closes the note.\n", caret)
            }
            var text = ""
            var section = 0
            while (text as NSString).length < 20_000 {
                section += 1
                text += "## Section \(section)\n\n"
                var body = ""
                while (body as NSString).length < paragraph { body += sentence }
                text += body + "\n\n"
                text += "$$\n\\mathcal{L}(\\theta) = \\sum_{i=1}^{N} \\log p(x_i \\mid \\theta)\n$$\n\n"
                text += "- a point with $x^{2}$ in it\n- another with `code $not math$`\n\n"
                if section % 3 == 0 { text += "```python\nprice = \"$5\"\nprint(price)\n```\n\n" }
            }
            text += "Finally the bound is $\\frac{a}{b} + q"
            let caret = (text as NSString).length
            text += " + y$ which closes the note.\n"
            return (text, caret)
        }

        /// Median and 95th percentile of `runs` calls, in milliseconds.
        static func time(runs: Int, _ body: () -> Void) -> (median: Double, p95: Double) {
            body() // the first call loads the snippet file
            let clock = ContinuousClock()
            var samples: [Double] = []
            for _ in 0..<runs {
                let d = clock.measure(body)
                samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            }
            samples.sort()
            return (samples[samples.count / 2], samples[samples.count * 95 / 100])
        }

        /// What a keystroke may cost. The installed app is a Release build,
        /// and that is where "well under a millisecond" is held (measured:
        /// at most 0.23 ms median, 0.27 ms p95, the worst being `/` at the end
        /// of a 20,000-character paragraph, which parses the note twice). A
        /// Debug build runs the same code ten to twenty times slower — every
        /// subscript and range step is a call there — so it only gets a net
        /// for gross mistakes, like reading the whole note once per snippet.
        #if DEBUG
        static let medianLimit = 8.0
        static let p95Limit = 12.0
        #else
        static let medianLimit = 0.3
        static let p95Limit = 0.6
        #endif

        @Test("A keystroke in a 20,000-character note takes well under a millisecond",
              arguments: [600, 5_000, 20_000, 0])
        func keystroke(_ paragraph: Int) {
            let (text, caret) = Self.note(paragraph: paragraph)
            let atCaret = [NSRange(location: caret, length: 0)]
            #expect((text as NSString).length > 20_000)
            // Sanity: the caret is in math, and the keys below do what they should.
            #expect(engine.handle(.text("x"), text: text, selection: atCaret) == nil)
            #expect(engine.handle(.text("/"), text: text, selection: atCaret) != nil)

            let withAt = (text as NSString).replacingCharacters(in: atCaret[0], with: "@")
            let afterAt = [NSRange(location: caret + 1, length: 0)]
            let cases: [(String, LatexSuite.Input, String, [NSRange])] = [
                ("letter", .text("x"), text, atCaret),
                ("autofraction", .text("/"), text, atCaret),
                ("snippet @a", .text("a"), withAt, afterAt),
                ("Tab", .tab, text, atCaret),
                ("Enter", .enter, text, atCaret),
                ("letter in prose", .text("x"), text, [NSRange(location: 200, length: 0)]),
            ]
            var report: [String] = []
            for (name, input, doc, selection) in cases {
                let (median, p95) = Self.time(runs: 200) { _ = engine.handle(input, text: doc, selection: selection) }
                report.append("\(name) \(String(format: "%.3f", median))/\(String(format: "%.3f", p95))")
                #expect(median < Self.medianLimit, "\(name): median \(median) ms")
                #expect(p95 < Self.p95Limit, "\(name): p95 \(p95) ms")
            }
            print("Latex Suite keystroke, paragraphs of \(paragraph) (median/p95 ms):", report.joined(separator: ", "))
        }
    }
}
