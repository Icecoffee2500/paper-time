import Foundation
import Testing
@testable import PaperCore

/// Where a note's mathematics is, as the renderer and the typing card read it.
struct NoteMathTests {
    private func range(_ text: String, of piece: String) -> NSRange {
        (text as NSString).range(of: piece)
    }

    // MARK: Blocks

    @Test func aFormulaOnItsOwnLinesIsOneBlock() {
        let text = "before\n$$\n\\frac{a}{b}\n$$\nafter"
        let blocks = NoteMath.blocks(in: text)
        #expect(blocks == [range(text, of: "$$\n\\frac{a}{b}\n$$")])
    }

    @Test func aBlockMayHoldSeveralLines() {
        let text = "$$\n\\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned}\n$$"
        #expect(NoteMath.blocks(in: text) == [NSRange(location: 0, length: (text as NSString).length)])
    }

    @Test func aDisplayFormulaOnOneLineIsNotABlock() {
        #expect(NoteMath.blocks(in: "$$\\frac{a}{b}$$").isEmpty)
        #expect(NoteMath.blocks(in: "x $$a$$ y\n$$b$$").isEmpty)
    }

    @Test func anOpenerNothingClosesIsNotABlock() {
        #expect(NoteMath.blocks(in: "$$\n\\frac{a}{b}\nprose").isEmpty)
    }

    @Test func theOpenerAndCloserMayCarryLatex() {
        let text = "$$ a +\nb $$\nrest"
        #expect(NoteMath.blocks(in: text) == [range(text, of: "$$ a +\nb $$")])
    }

    @Test func twoBlocksAreTwo() {
        let text = "$$\na\n$$\n\n$$\nb\n$$"
        #expect(NoteMath.blocks(in: text).count == 2)
    }

    @Test func anEnvironmentOnItsOwnLinesIsOneBlock() {
        let text = "before\n\\begin{align}\na &= b \\\\\nc &= d\n\\end{align}\nafter"
        #expect(NoteMath.blocks(in: text) == [range(text, of: "\\begin{align}\na &= b \\\\\nc &= d\n\\end{align}")])
        // Starred, indented, and holding another environment.
        let nested = "  \\begin{equation*}\n\\begin{split}\na &= b\n\\end{split}\n\\end{equation*}"
        #expect(NoteMath.blocks(in: nested) == [NSRange(location: 0, length: (nested as NSString).length)])
    }

    @Test func anEnvironmentOnOneLineIsNotABlock() {
        #expect(NoteMath.blocks(in: "\\begin{align} a &= b \\end{align}").isEmpty)
        // Not a mathematics environment: left to be prose.
        #expect(NoteMath.blocks(in: "\\begin{itemize}\n\\item a\n\\end{itemize}").isEmpty)
        // Closed by its own end only.
        #expect(NoteMath.blocks(in: "\\begin{align}\na\n\\end{aligned}").isEmpty)
    }

    @Test func squareBracketsOnTheirOwnLinesAreOneBlock() {
        let text = "\\[\n\\sum_i x_i\n\\]\nafter"
        #expect(NoteMath.blocks(in: text) == [range(text, of: "\\[\n\\sum_i x_i\n\\]")])
        #expect(NoteMath.blocks(in: "\\[ x \\]").isEmpty)
    }

    // MARK: Formulas in a line

    private func formulas(_ line: String) -> [NoteMath.Span] {
        let text = line as NSString
        var found: [NoteMath.Span] = []
        var index = 0
        while index < text.length,
              let one = NoteMath.firstFormula(in: text, range: NSRange(location: index, length: text.length - index)) {
            found.append(one)
            index = one.range.location + one.range.length
        }
        return found
    }

    @Test func everyWayLaTeXWritesAFormula() {
        let found = formulas("a $x$ b \\(y\\) c $$z$$ d \\[w\\] e \\begin{pmatrix} 1 \\end{pmatrix}")
        #expect(found.map(\.latex) == ["x", "y", "z", "w", "\\begin{pmatrix} 1 \\end{pmatrix}"])
        #expect(found.map(\.display) == [false, false, true, true, true])
    }

    @Test func latexsOwnNamesForTheDelimitersAreThoseDelimiters() {
        let found = formulas("\\begin{math} a \\end{math} and \\begin{displaymath} b \\end{displaymath}")
        #expect(found.map(\.latex) == ["a", "b"])
        #expect(found.map(\.display) == [false, true])
    }

    @Test func anEnvironmentEndsAtItsOwnEnd() {
        let found = formulas("\\begin{equation} \\begin{aligned} a &= b \\end{aligned} \\end{equation} x")
        #expect(found.map(\.latex) == ["\\begin{equation} \\begin{aligned} a &= b \\end{aligned} \\end{equation}"])
        #expect(formulas("\\begin{align*} a \\end{align}").isEmpty)
        #expect(formulas("\\begin{tabular} a \\end{tabular}").isEmpty)
    }

    @Test func displayedLinesAreKnown() {
        #expect(NoteMath.isDisplay("  $$x$$ "))
        #expect(NoteMath.isDisplay("\\begin{align} a &= b \\tag{1} \\end{align}"))
        #expect(NoteMath.isDisplay("\\[x\\]"))
        #expect(!NoteMath.isDisplay("$x$"))
        #expect(!NoteMath.isDisplay("so $$x$$"))
        let text = "Then \\begin{equation} E = mc^2 \\tag{3} \\end{equation} holds."
        #expect(NoteMath.displays(in: text) == [range(text, of: "\\begin{equation} E = mc^2 \\tag{3} \\end{equation}")])
    }

    // MARK: The span under the caret

    @Test func aCaretInsideInlineMathFindsIt() {
        let text = "the mean $\\bar{x}$ is"
        let caret = range(text, of: "\\bar").location + 2
        let span = NoteMath.span(at: caret, in: text)
        #expect(span == NoteMath.Span(range: range(text, of: "$\\bar{x}$"), latex: "\\bar{x}",
                                      display: false, isBlock: false))
    }

    @Test func aCaretOutsideTheDelimitersIsNotInside() {
        let text = "a $x$ b"
        #expect(NoteMath.span(at: 2, in: text) == nil)   // before the $
        #expect(NoteMath.span(at: 3, in: text) != nil)   // just after it
        #expect(NoteMath.span(at: 4, in: text) != nil)   // just before the closer
        #expect(NoteMath.span(at: 5, in: text) == nil)   // after the closer
        #expect(NoteMath.span(at: 0, in: "plain") == nil)
    }

    @Test func aCaretInDisplayMathOnOneLine() {
        let text = "$$\\frac{a}{b}$$"
        let span = NoteMath.span(at: 5, in: text)
        #expect(span?.display == true)
        #expect(span?.isBlock == false)
        #expect(span?.latex == "\\frac{a}{b}")
    }

    @Test func aCaretInsideABlockFindsTheWholeBlock() {
        let text = "p\n$$\n\\frac{a}{b}\n$$\nq"
        let caret = range(text, of: "{b}").location
        let span = NoteMath.span(at: caret, in: text)
        #expect(span == NoteMath.Span(range: range(text, of: "$$\n\\frac{a}{b}\n$$"),
                                      latex: "\\frac{a}{b}", display: true, isBlock: true))
        // On the closer's own line, before its `$$`: still inside.
        #expect(NoteMath.span(at: range(text, of: "\n$$\nq").location + 1, in: text)?.isBlock == true)
        // After the closer: outside.
        #expect(NoteMath.span(at: range(text, of: "q").location, in: text) == nil)
    }

    @Test func anEmptyFormulaHasNoSpan() {
        // `mk` leaves `$|$`: nothing to set until something is typed.
        #expect(NoteMath.span(at: 1, in: "$$") == nil)
    }

    @Test func aCaretInsideAnEnvironmentFindsTheWholeEnvironment() {
        let text = "p\n\\begin{align}\na &= b\n\\end{align}\nq"
        let caret = range(text, of: "&=").location
        let span = NoteMath.span(at: caret, in: text)
        #expect(span == NoteMath.Span(range: range(text, of: "\\begin{align}\na &= b\n\\end{align}"),
                                      latex: "\\begin{align}\na &= b\n\\end{align}", display: true, isBlock: true))
        // On the \\begin itself: not yet inside.
        #expect(NoteMath.span(at: range(text, of: "\\begin").location + 2, in: text) == nil)
        let line = "so \\(a+b\\) and \\begin{cases} x \\end{cases}"
        #expect(NoteMath.span(at: range(line, of: "a+b").location + 1, in: line)?.latex == "a+b")
        #expect(NoteMath.span(at: range(line, of: " x ").location + 1, in: line)?.latex
                == "\\begin{cases} x \\end{cases}")
    }

    @Test func offsetsAreUTF16() {
        let text = "평균 $\\mu$ 예요"
        let caret = range(text, of: "\\mu").location + 1
        #expect(NoteMath.span(at: caret, in: text)?.latex == "\\mu")
    }
}
