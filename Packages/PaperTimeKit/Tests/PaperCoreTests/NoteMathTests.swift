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

    @Test func offsetsAreUTF16() {
        let text = "평균 $\\mu$ 예요"
        let caret = range(text, of: "\\mu").location + 1
        #expect(NoteMath.span(at: caret, in: text)?.latex == "\\mu")
    }
}
