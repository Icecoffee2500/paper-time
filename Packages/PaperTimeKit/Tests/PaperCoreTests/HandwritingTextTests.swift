import Testing
@testable import PaperCore

/// What the handwriting model answered for crops of real lecture notes, and
/// what Ultracopy should copy of it.
struct HandwritingTextTests {
    @Test func spacedFormulasCloseUp() {
        #expect(HandwritingText.tidy("$$P ( \\bigcup _ { 1 } ^ { \\infty } A _ { i } ) = P ( \\bigcup _ { 1 } ^ { \\infty } B _ { i } )$$")
            == "$$P(\\bigcup_{1}^{\\infty}A_{i})=P(\\bigcup_{1}^{\\infty}B_{i})$$")
        #expect(HandwritingText.tidy("$$= \\operatorname* { l i m } _ { n \\rightarrow \\infty } P ( A _ { n } )$$")
            == "$$=\\lim_{n\\rightarrow\\infty}P(A_{n})$$")
        #expect(HandwritingText.tidy("$$x _ { n } ^ { + } = \\operatorname* { s u p } _ { k \\geq n } x _ { k }$$")
            == "$$x_{n}^{+}=\\sup_{k\\geq n}x_{k}$$")
    }

    @Test func formulasWrittenAsLaTeXStayAsWritten() {
        let line = "pf) we have $S = A \\cup A^c$ and $A \\cap A^c = \\emptyset$."
        #expect(HandwritingText.tidy(line) == line)
        #expect(HandwritingText.tidy("$\\{x_n\\}$: seq. of real $\\#$s & $\\{x_n\\}$: bounded")
            == "$\\{x_n\\}$: seq. of real $\\#$s & $\\{x_n\\}$: bounded")
    }

    @Test func compactOperatorNamesAreTeXs() {
        #expect(HandwritingText.tidy("$\\operatorname*{lim}_{n\\to\\infty} a_n$") == "$\\lim_{n\\to\\infty} a_n$")
        #expect(HandwritingText.tidy("$\\operatorname{argmax}_x f$") == "$\\arg\\max_x f$")
    }

    @Test func fencesAndParenthesesBecomeDollars() {
        #expect(HandwritingText.tidy("```latex\n$$x^2$$\n```") == "$$x^2$$")
        #expect(HandwritingText.tidy("Note that \\(P(A^c) \\geq 0\\) by A1.") == "Note that $P(A^c) \\geq 0$ by A1.")
        #expect(HandwritingText.tidy("\\[ y = x \\]") == "$$y = x$$")
    }

    @Test func linesKeepTheirShape() {
        #expect(HandwritingText.tidy("c. $P(A^c) = 1 - P(A)$.  \n\n\n\npf) we have $S$.\n\n")
            == "c. $P(A^c) = 1 - P(A)$.\n\npf) we have $S$.")
    }

    @Test func anUnclosedDollarIsLeftAlone() {
        #expect(HandwritingText.tidy("costs $5 and more") == "costs $5 and more")
    }
}
