/**
 * The document «Export as PDF…» prints (`ui/note/noteHTML.ts`), with a
 * stand-in for MathJax: the same plan the editor draws from, as markup.
 */
import assert from 'node:assert/strict'
import { fitNumbered, noteBodyHTML, noteHTML } from '../renderer/ui/note/noteHTML.js'
import type { MathSetter } from '../shared/mathJax.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

/** A typesetter that draws every formula as its own LaTeX, and counts. */
const stub: MathSetter['set'] = (latex, display, start = 0) => ({
  svg: `<svg data-latex="${latex.replace(/"/g, '&quot;')}" data-display="${display}" data-start="${start}"></svg>`,
  next: start + (latex.includes('\\begin{equation}') ? 1 : 0),
  labels: {},
})

/** One that sets nothing, as MathJax does with a formula half typed. */
const refuses: MathSetter['set'] = () => null

export async function noteHTMLSuite(test: Test, suite: (name: string) => void) {
  suite('A note as the document its PDF is printed from')

  await test('a title, headings as h1–h6, and the body in one document', () => {
    const html = noteHTML('My <Note>', '# Top\n## Second\n###### Sixth\nwords', { set: stub, lang: 'ko' })
    assert.ok(html.startsWith('<!doctype html>\n<html lang="ko">'))
    assert.ok(html.includes('<title>My &lt;Note&gt;</title>'))
    assert.ok(html.includes('<h1 class="note-title">My &lt;Note&gt;</h1>'))
    assert.ok(html.includes('<h1 class="nm-line nm-h nm-h1">Top</h1>'))
    assert.ok(html.includes('<h2 class="nm-line nm-h nm-h2">Second</h2>'))
    assert.ok(html.includes('<h6 class="nm-line nm-h nm-h6">Sixth</h6>'))
    assert.ok(html.includes('<div class="nm-line">words</div>'))
    assert.ok(html.includes('<style>'), 'carries its own style')
  })

  await test('nested bullets and numbers carry the markers the editor shows, and their depth', () => {
    const body = noteBodyHTML('- one\n  - two\n    - three\n1. first\n  2. second\n    3. third\n- [x] done\n- [ ] open', { set: stub })
    const lines = body.split('\n')
    assert.equal(lines[0], '<div class="nm-line nm-list nm-indent-0"><span class="nm-marker">•</span>one</div>')
    assert.equal(lines[1], '<div class="nm-line nm-list nm-indent-1"><span class="nm-marker">◦</span>two</div>')
    assert.equal(lines[2], '<div class="nm-line nm-list nm-indent-2"><span class="nm-marker">▪</span>three</div>')
    assert.equal(lines[3], '<div class="nm-line nm-list nm-indent-0"><span class="nm-marker nm-marker-wide">1.</span>first</div>')
    assert.equal(lines[4], '<div class="nm-line nm-list nm-indent-1"><span class="nm-marker nm-marker-wide">b.</span>second</div>')
    assert.equal(lines[5], '<div class="nm-line nm-list nm-indent-2"><span class="nm-marker nm-marker-wide">iii.</span>third</div>')
    assert.equal(lines[6], '<div class="nm-line nm-list nm-indent-0"><span class="nm-marker nm-marker-wide nm-marker-done">☑</span><span class="nm-done">done</span></div>')
    assert.equal(lines[7], '<div class="nm-line nm-list nm-indent-0"><span class="nm-marker nm-marker-wide">☐</span>open</div>')
  })

  await test('emphasis without its marks, a quotation with its edges, links as words', () => {
    const body = noteBodyHTML('say **bold** and *it* and `code`\n> quoted\n> more\nsee [[202609281200|Entropy]] and [a note](papertime://anchor?p=0&x=1.00&y=1.00&w=1.00&h=1.00)', { set: stub })
    const lines = body.split('\n')
    assert.equal(lines[0], '<div class="nm-line">say <strong class="nm-bold">bold</strong> and <em class="nm-italic">it</em> and <code class="nm-mono">code</code></div>')
    assert.equal(lines[1], '<div class="nm-line nm-quote nm-q-open"><span class="nm-quote-words">quoted</span></div>')
    assert.equal(lines[2], '<div class="nm-line nm-quote nm-q-close"><span class="nm-quote-words">more</span></div>')
    assert.equal(lines[3], '<div class="nm-line">see <span class="nm-note-link">Entropy</span> and <span class="nm-chip">a note</span></div>')
    assert.ok(!body.includes('data-anchor') && !body.includes('data-note'), 'nothing to press on paper')
  })

  await test('a table is a table', () => {
    const body = noteBodyHTML('| a | b |\n|:--|--:|\n| **1** | 2 |\n| 3 | 4 |\nafter', { set: stub })
    const lines = body.split('\n')
    assert.equal(lines[0], '<div class="nm-table"><table><thead><tr><th style="text-align:left">a</th><th style="text-align:right">b</th></tr></thead>'
      + '<tbody><tr><td style="text-align:left">1</td><td style="text-align:right">2</td></tr><tr><td style="text-align:left">3</td><td style="text-align:right">4</td></tr></tbody></table></div>')
    assert.equal(lines[1], '<div class="nm-line">after</div>')
  })

  await test('formulas are set inline, as a block across lines, and counted from the top', () => {
    const body = noteBodyHTML('in $x$ line\n$$\ny\n$$\n\\begin{equation}a\\end{equation}\n\\begin{equation}b\\end{equation}', { set: stub })
    const lines = body.split('\n')
    assert.equal(lines[0], '<div class="nm-line">in <span class="nm-math"><svg data-latex="x" data-display="false" data-start="0"></svg></span> line</div>')
    assert.equal(lines[1], '<div class="nm-line nm-display-line"><div class="nm-math nm-math-block"><svg data-latex="y" data-display="true" data-start="0"></svg></div></div>')
    assert.ok(lines[2].includes('data-start="0"'), lines[2])
    assert.ok(lines[3].includes('data-start="1"'), 'the second equation starts after the first')
    assert.ok(lines[2].includes('nm-math-alone') && lines[2].includes('nm-display-line'), 'a formula alone on its line is set across it')
  })

  await test('a formula that does not set is shown as written', () => {
    const body = noteBodyHTML('in $x +$ here', { set: refuses })
    assert.equal(body, '<div class="nm-line">in <span class="nm-math nm-math-raw">$x +$</span> here</div>')
  })

  await test('a numbered formula laid out for any page is given the page', () => {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="3ex" style="min-width: 20ex; vertical-align: 0"><g/></svg>'
    const fitted = fitNumbered(svg, 700)
    assert.ok(fitted.startsWith('<svg viewBox="0 0 700 24"'), fitted)
    assert.ok(!fitted.includes('min-width'))
    assert.ok(fitted.includes('<g/>'))
    // A formula wider than the page keeps its own width, and is set smaller by the style.
    assert.ok(fitNumbered(svg, 100).startsWith('<svg viewBox="0 0 160 24"'))
    const plain = '<svg width="5ex" height="2ex"><g/></svg>'
    assert.equal(fitNumbered(plain, 700), plain)
  })
}
