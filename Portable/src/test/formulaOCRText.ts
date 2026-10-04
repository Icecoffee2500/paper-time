/**
 * The OCR model's tokens, tidied into Ultracopy's LaTeX — the Mac's
 * `FormulaOCRTextTests`, case for case: the contract between the two
 * builds' `tidy`. And the picture the model takes (`formulaOCRInput`).
 */
import assert from 'node:assert/strict'
import { tidy } from '../shared/formulaOCRText.js'
import { OCR_SHAPE, OCR_SIDE, isBlankPicture, paddedForOCR, pictureSize, pixelValues, stretchTarget } from '../shared/formulaOCRInput.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

export async function formulaOCRTextSuite(test: Test, suite: (name: string) => void) {
  suite('Formula OCR: the tokens tidied as the Mac tidies them')

  await test('tokens close up and spelled labels become text', () => {
    const raw = String.raw`\mathbf { m } _ { i } ^ { t } = \alpha \underbrace { \mathbf { W } _ { n n } \left( \sum _ { j \in \mathcal { N } _ { i } } \mathbf { n } _ { j } ^ { t - 1 } \right) } _ { \mathrm { ~ n o d e ~ t o ~ n o d e ~ m e s s a g e } } ,`
    const tidied = tidy(raw)
    assert.equal(tidied.body, String.raw`\mathbf{m}_{i}^{t}=\alpha\underbrace{\mathbf{W}_{nn}\left(\sum_{j\in\mathcal{N}_{i}}\mathbf{n}_{j}^{t-1}\right)}_{\text{node to node message}},`)
    assert.equal(tidied.tag, null)
  })

  await test('the equation number becomes a tag', () => {
    const raw = String.raw`\boldsymbol { \theta } _ { \mathrm { u } } = \underbrace { \mathbf { m } _ { \mathrm { S } } \odot \boldsymbol { \theta } } _ { \mathrm { s a l i e n t ~ w e i g h t s } } , \qquad \qquad \qquad \mathrm { ( 4 ) }`
    const tidied = tidy(raw)
    assert.equal(tidied.body, String.raw`\boldsymbol{\theta}_{\mathrm{u}}=\underbrace{\mathbf{m}_{\mathrm{S}}\odot\boldsymbol{\theta}}_{\text{salient weights}},`)
    assert.equal(tidied.tag, '4')
  })

  await test('a control word keeps its space before a letter', () => {
    assert.equal(tidy(String.raw`\alpha x + \beta y = \frac { 1 } { 2 }`).body, String.raw`\alpha x+\beta y=\frac{1}{2}`)
  })

  await test('short upright letters stay mathrm', () => {
    assert.equal(tidy(String.raw`\mathrm { d } x \, \mathrm { d x }`).body, String.raw`\mathrm{d}x\,\mathrm{dx}`)
  })

  await test('a number inside the formula is not a tag', () => {
    const tidied = tidy(String.raw`f ( 4 ) + g ( 2 . 5 )`)
    assert.equal(tidied.body, String.raw`f(4)+g(2.5)`)
    assert.equal(tidied.tag, null)
  })

  await test('spelled functions and limits are written as TeX writes them', () => {
    assert.equal(tidy(String.raw`h _ { t } = \operatorname { t a n h } \! \left( W _ { h } h _ { t - 1 } \right)`).body,
      String.raw`h_{t}=\tanh\!\left(W_{h}h_{t-1}\right)`)
    assert.equal(tidy(String.raw`\underset { w \in W } { \operatorname* { m i n } } \, L ( w )`).body,
      String.raw`\min_{w\in W}\,L(w)`)
    assert.equal(tidy(String.raw`\operatorname { a r g } \underset { w } { \operatorname* { m i n } } L`).body,
      String.raw`\arg\min_{w}L`)
    assert.equal(tidy(String.raw`{ \cal L } _ { \mathrm { r e c } } \operatorname { f o o } ( x )`).body,
      String.raw`\mathcal{L}_{\mathrm{rec}}\operatorname{foo}(x)`)
    assert.equal(tidy(String.raw`a \stackrel { \mathrm { d e f } } { = } b`).body, String.raw`a\overset{\mathrm{def}}{=}b`)
  })

  await test('cells lose their braces and the last row its break', () => {
    assert.equal(tidy(String.raw`f ( x ) = \begin{cases} { x } & { \mathrm { i f ~ } x \geq 0 } \\ { - x } & { \mathrm { o t h e r w i s e } } \\ \end{cases}`).body,
      String.raw`f(x)=\begin{cases}x&\text{if }x\geq0\\-x&\mathrm{otherwise}\end{cases}`)
  })

  await test('spacing commands in a label are spaces, and a single-row substack is nothing', () => {
    assert.equal(tidy(String.raw`\underbrace { x } _ { \substack { \mathrm { n o d e \; t o \; n o d e \; m e s s a g e } } }`).body,
      String.raw`\underbrace{x}_{\text{node to node message}}`)
    assert.equal(tidy(String.raw`\sum _ { \substack { i = 1 \\ i \neq j } } x`).body, String.raw`\sum_{\substack{i=1\\i\neq j}}x`)
  })

  await test('a bare number after spacing is a tag', () => {
    const tidied = tidy(String.raw`x = 1 \qquad ( 12 )`)
    assert.equal(tidied.body, String.raw`x=1`)
    assert.equal(tidied.tag, '12')
  })

  suite('Formula OCR: the picture the model takes')

  await test('the picture is the model\'s square, whatever the rectangle', () => {
    assert.deepEqual([...OCR_SHAPE], [1, 3, 384, 384])
    assert.deepEqual(stretchTarget(), { x: 0, y: 0, width: 384, height: 384 })
    assert.deepEqual(pictureSize({ x: 0, y: 0, width: 220, height: 60 }), { width: 660, height: 180 })
    assert.deepEqual(pictureSize({ x: 0, y: 0, width: 0.1, height: 0.1 }), { width: 1, height: 1 })
  })

  await test('the rectangle is padded 6 across and 5 down, inside the page', () => {
    const page = { x: 0, y: 0, width: 612, height: 792 }
    assert.deepEqual(paddedForOCR({ x: 60, y: 262, width: 220, height: 60 }, page), { x: 54, y: 257, width: 232, height: 70 })
    assert.deepEqual(paddedForOCR({ x: 2, y: 1, width: 609, height: 790 }, page), { x: 0, y: 0, width: 612, height: 792 })
  })

  await test('a 2×2 picture stretched to the square is 384×384 of the same constants, planes CHW', () => {
    // A 2×2 picture of one colour, stretched to 384×384, is that colour
    // everywhere; the planes come out red, green, blue, each the whole square.
    const side = OCR_SIDE
    const plane = side * side
    const rgba = new Uint8ClampedArray(plane * 4)
    for (let i = 0; i < plane; i += 1) {
      rgba[i * 4] = 255
      rgba[i * 4 + 1] = 0
      rgba[i * 4 + 2] = 128
      rgba[i * 4 + 3] = 255
    }
    const values = pixelValues(rgba)
    assert.equal(values.length, 3 * plane)
    assert.equal(values[0], 1)
    assert.equal(values[plane - 1], 1)
    assert.equal(values[plane], -1)
    assert.equal(values[2 * plane - 1], -1)
    assert.ok(Math.abs(values[2 * plane] - (128 / 255 - 0.5) / 0.5) < 1e-6)
    assert.ok(Math.abs(values[3 * plane - 1] - (128 / 255 - 0.5) / 0.5) < 1e-6)
    // White is 1 in every plane; black is −1.
    assert.equal(pixelValues(new Uint8ClampedArray(16).fill(255), 2)[11], 1)
    assert.equal(pixelValues(new Uint8ClampedArray(16).fill(0), 2)[0], -1)
    assert.throws(() => pixelValues(new Uint8ClampedArray(8), 2))
  })

  await test('blank paper is known before the model is asked', () => {
    const plane = OCR_SIDE * OCR_SIDE
    const white = new Float32Array(3 * plane).fill(1)
    assert.equal(isBlankPicture(white), true)
    // A few grey specks — scanner noise — are still blank; a stroke is not.
    for (let i = 0; i < 20; i += 1) white[i * 997] = 0.5
    assert.equal(isBlankPicture(white), true)
    for (let i = 0; i < 200; i += 1) white[plane + i] = -1
    assert.equal(isBlankPicture(white), false)
  })
}
