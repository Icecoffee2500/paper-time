/**
 * The passages a note quotes, found as the Mac finds them —
 * `quoted-passages.json` is the Mac's own `QuotedPassages`
 * (`Scripts/quoted-passages-fixture.swift`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { QUOTE_WASH, quoteSpan, quotedPassages, quotedPassagesOfPaper } from '../shared/quotedPassages.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Fixture {
  bodies: { body: string; passages: { url: string; page: number; rect: number[]; paper: string | null; link: number[]; quote: number[] }[] }[]
  notes: { paper: string | null; body: string }[]
  papers: { paper: string; passages: [number, string][] }[]
  spans: { quotation: string; text: string; span: [number, number] | null }[]
}

export async function quotedPassagesSuite(test: Test, suite: (name: string) => void) {
  suite('Passages a note quotes, found as the Mac finds them')
  const file = path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures', 'quoted-passages.json')
  const fixture = JSON.parse(fs.readFileSync(file, 'utf8')) as Fixture

  await test(`${fixture.bodies.length} notes: the same links, pages, boxes and quotations`, () => {
    for (const body of fixture.bodies) {
      const found = quotedPassages(body.body)
      assert.equal(found.length, body.passages.length, JSON.stringify(body.body))
      found.forEach((passage, index) => {
        const expected = body.passages[index]
        assert.equal(passage.url, expected.url)
        assert.equal(passage.pageIndex, expected.page)
        assert.deepEqual([passage.rect.x, passage.rect.y, passage.rect.width, passage.rect.height], expected.rect)
        assert.equal(passage.paperID?.toUpperCase() ?? null, expected.paper)
        assert.deepEqual([passage.link.from, passage.link.to], expected.link)
        assert.deepEqual([passage.quote.from, passage.quote.to], expected.quote, JSON.stringify(body.body))
      })
    }
  })

  await test('a paper gets the passages the Mac gives it, from every note', () => {
    for (const paper of fixture.papers) {
      const found: [number, string][] = []
      fixture.notes.forEach((note, index) => {
        for (const passage of quotedPassagesOfPaper({ body: note.body, paperID: note.paper }, paper.paper)) found.push([index, passage.url])
      })
      assert.deepEqual(found, paper.passages, paper.paper)
    }
  })

  await test(`${fixture.spans.length} quotations found in the page's text where the Mac finds them`, () => {
    for (const item of fixture.spans) {
      const span = quoteSpan(item.quotation, item.text)
      assert.deepEqual(span ? [span.from, span.to] : null, item.span, JSON.stringify(item.quotation))
    }
  })

  await test('what the page tints is the passage, and nothing round it', () => {
    const words = (quotation: string, text: string) => {
      const span = quoteSpan(quotation, text)
      return span ? text.slice(span.from, span.to) : null
    }
    assert.equal(words('> per class [3쪽](papertime://anchor?p=2&x=1&y=1&w=1&h=1)', 'few-shot samples per class to create'), 'per class')
    assert.equal(words('> (naïve method $O(n)$)', 'Sample data: O(ln(n)) (na\u00a8 \u0131ve method O(n))'), '(na\u00a8 \u0131ve method O(n))')
    assert.equal(words('> We minimize $\\mathcal{L}(\\theta)$ over the data.', 'Then we minimize L(θ) over the data. Next'), 'we minimize L(θ) over the data.')
    assert.equal(words('> $$\\frac{a}{b}$$', 'completely different words'), null)
    assert.equal(words('> the model is good', 'the model the model is good'), 'the model is good')
  })

  await test('the wash takes as much of the accent as the Mac\'s', () => {
    const css = fs.readFileSync(path.join(process.cwd(), 'src/renderer/style.css'), 'utf8')
    const share = (name: string) => Number(new RegExp(`--${name}: color-mix\\(in srgb, var\\(--accent\\) (\\d+)%, white\\);`).exec(css)?.[1]) / 100
    assert.equal(share('quote-wash'), QUOTE_WASH.rest)
    assert.equal(share('quote-wash-lit'), QUOTE_WASH.lit)
    const swift = fs.readFileSync(path.join(process.cwd(), '..', 'App/Views/Reader/QuoteLinks.swift'), 'utf8')
    const mac = (name: string) => Number(new RegExp(`static let ${name}: CGFloat = ([\\d.]+)`).exec(swift)?.[1])
    assert.equal(mac('rest'), QUOTE_WASH.rest)
    assert.equal(mac('lit'), QUOTE_WASH.lit)
  })
}
