/**
 * The passages a note quotes, found as the Mac finds them —
 * `quoted-passages.json` is the Mac's own `QuotedPassages`
 * (`Scripts/quoted-passages-fixture.swift`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { quotedPassages, quotedPassagesOfPaper } from '../shared/quotedPassages.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Fixture {
  bodies: { body: string; passages: { url: string; page: number; rect: number[]; paper: string | null; link: number[]; quote: number[] }[] }[]
  notes: { paper: string | null; body: string }[]
  papers: { paper: string; passages: [number, string][] }[]
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
}
