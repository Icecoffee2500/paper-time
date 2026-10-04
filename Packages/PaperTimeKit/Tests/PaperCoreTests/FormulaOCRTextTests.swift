import Foundation
import Testing
@testable import PaperCore

/// The OCR model's tokens, tidied into Ultracopy's LaTeX. The same cases
/// stand in `Portable/src/test/formulaOCRText.ts`.
struct FormulaOCRTextTests {
    @Test func tokensCloseUpAndSpelledLabelsBecomeText() {
        let raw = #"\mathbf { m } _ { i } ^ { t } = \alpha \underbrace { \mathbf { W } _ { n n } \left( \sum _ { j \in \mathcal { N } _ { i } } \mathbf { n } _ { j } ^ { t - 1 } \right) } _ { \mathrm { ~ n o d e ~ t o ~ n o d e ~ m e s s a g e } } ,"#
        let tidied = FormulaOCRText.tidy(raw)
        #expect(tidied.body == #"\mathbf{m}_{i}^{t}=\alpha\underbrace{\mathbf{W}_{nn}\left(\sum_{j\in\mathcal{N}_{i}}\mathbf{n}_{j}^{t-1}\right)}_{\text{node to node message}},"#)
        #expect(tidied.tag == nil)
    }

    @Test func theEquationNumberBecomesATag() {
        let raw = #"\boldsymbol { \theta } _ { \mathrm { u } } = \underbrace { \mathbf { m } _ { \mathrm { S } } \odot \boldsymbol { \theta } } _ { \mathrm { s a l i e n t ~ w e i g h t s } } , \qquad \qquad \qquad \mathrm { ( 4 ) }"#
        let tidied = FormulaOCRText.tidy(raw)
        #expect(tidied.body == #"\boldsymbol{\theta}_{\mathrm{u}}=\underbrace{\mathbf{m}_{\mathrm{S}}\odot\boldsymbol{\theta}}_{\text{salient weights}},"#)
        #expect(tidied.tag == "4")
    }

    @Test func aControlWordKeepsItsSpaceBeforeALetter() {
        #expect(FormulaOCRText.tidy(#"\alpha x + \beta y = \frac { 1 } { 2 }"#).body == #"\alpha x+\beta y=\frac{1}{2}"#)
    }

    @Test func shortUprightLettersStayMathrm() {
        #expect(FormulaOCRText.tidy(#"\mathrm { d } x \, \mathrm { d x }"#).body == #"\mathrm{d}x\,\mathrm{dx}"#)
    }

    @Test func aNumberInsideTheFormulaIsNotATag() {
        let tidied = FormulaOCRText.tidy(#"f ( 4 ) + g ( 2 . 5 )"#)
        #expect(tidied.body == #"f(4)+g(2.5)"#)
        #expect(tidied.tag == nil)
    }

    @Test func spelledFunctionsAndLimitsAreWrittenAsTeXWritesThem() {
        #expect(FormulaOCRText.tidy(#"h _ { t } = \operatorname { t a n h } \! \left( W _ { h } h _ { t - 1 } \right)"#).body
                == #"h_{t}=\tanh\!\left(W_{h}h_{t-1}\right)"#)
        #expect(FormulaOCRText.tidy(#"\underset { w \in W } { \operatorname* { m i n } } \, L ( w )"#).body
                == #"\min_{w\in W}\,L(w)"#)
        #expect(FormulaOCRText.tidy(#"\operatorname { a r g } \underset { w } { \operatorname* { m i n } } L"#).body
                == #"\arg\min_{w}L"#)
        #expect(FormulaOCRText.tidy(#"{ \cal L } _ { \mathrm { r e c } } \operatorname { f o o } ( x )"#).body
                == #"\mathcal{L}_{\mathrm{rec}}\operatorname{foo}(x)"#)
        #expect(FormulaOCRText.tidy(#"a \stackrel { \mathrm { d e f } } { = } b"#).body == #"a\overset{\mathrm{def}}{=}b"#)
    }

    @Test func cellsLoseTheirBracesAndTheLastRowItsBreak() {
        #expect(FormulaOCRText.tidy(#"f ( x ) = \begin{cases} { x } & { \mathrm { i f ~ } x \geq 0 } \\ { - x } & { \mathrm { o t h e r w i s e } } \\ \end{cases}"#).body
                == #"f(x)=\begin{cases}x&\text{if }x\geq0\\-x&\mathrm{otherwise}\end{cases}"#)
    }

    @Test func spacingCommandsInALabelAreSpacesAndASingleRowSubstackIsNothing() {
        #expect(FormulaOCRText.tidy(#"\underbrace { x } _ { \substack { \mathrm { n o d e \; t o \; n o d e \; m e s s a g e } } }"#).body
                == #"\underbrace{x}_{\text{node to node message}}"#)
        #expect(FormulaOCRText.tidy(#"\sum _ { \substack { i = 1 \\ i \neq j } } x"#).body == #"\sum_{\substack{i=1\\i\neq j}}x"#)
    }

    @Test func aBareNumberAfterSpacingIsATag() {
        let tidied = FormulaOCRText.tidy(#"x = 1 \qquad ( 12 )"#)
        #expect(tidied.body == #"x=1"#)
        #expect(tidied.tag == "12")
    }
}
