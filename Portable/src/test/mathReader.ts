/**
 * MathReader, against the Mac: the pages in
 * `Tests/PaperCoreTests/Fixtures/mathreader-cases.json.gz` were read by the
 * Mac's own `PDFContentScanner` and `MathReader`
 * (`Scripts/mathreader-fixtures.sh`), and the port is given the same glyphs,
 * rules, line boxes and characters and has to say the same thing — piece for
 * piece, line for line.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import zlib from 'node:zlib'
import { latex, pieces, structured, type PageInput, type PieceKind } from '../shared/mathReader/reader.js'
import type { Glyph } from '../shared/mathReader/glyph.js'
import { MathScanner } from '../main/mathScanner.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Case {
  name: string
  cropBox: number[]
  fonts: string[]
  glyphs: [number, number, string | null, string | null, number, number, number, number][]
  rules: number[][]
  lineBoxes: number[][]
  pageText: string
  characters: [number, number, number, number, number, string][]
  selectionString: string
  pieces: { kind: string; plain: string; marked: string; left: number; right: number; baseline: number; scale: number }[]
  structured: string[]
  latex: string
}

const box = (r: number[]) => ({ x: r[0], y: r[1], width: r[2], height: r[3] })

export function pageFromFixture(one: Case): PageInput {
  const glyphs: Glyph[] = one.glyphs.map(([code, font, unicode, glyphName, size, x, y, width]) => ({
    code, fontName: one.fonts[font].slice(1), isSymbolic: one.fonts[font][0] === '1', unicode, glyphName, size, x, y, width,
  }))
  return {
    glyphs,
    rules: one.rules.map((rule) => ({ rect: box(rule) })),
    lineBoxes: one.lineBoxes.map(box),
    characters: one.characters.map(([index, x, y, width, height, character]) => ({ index, rect: { x, y, width, height }, character })),
    pageText: one.pageText,
    selectionString: one.selectionString,
    cropBox: box(one.cropBox),
  }
}

const kindName = (kind: PieceKind) => (typeof kind === 'object' ? `heading${kind.heading}` : kind)

export async function mathReaderSuite(test: Test, suite: (name: string) => void) {
  suite('Reading a page with its mathematics, as the Mac reads it')
  const file = path.resolve(process.cwd(), '..', 'Tests/PaperCoreTests/Fixtures/mathreader-cases.json.gz')
  const cases = JSON.parse(zlib.gunzipSync(fs.readFileSync(file)).toString('utf8')) as Case[]
  for (const one of cases) {
    await test(`${one.name}: the same pieces, Markdown and one-line LaTeX`, () => {
      const page = pageFromFixture(one)
      const mine = pieces([page]).map((piece) => ({
        kind: kindName(piece.kind), plain: piece.plain, marked: piece.marked,
        left: piece.left, right: piece.right, baseline: piece.baseline, scale: piece.scale,
      }))
      const theirs = one.pieces.map(({ kind, plain, marked, left, right, baseline, scale }) => ({ kind, plain, marked, left, right, baseline, scale }))
      assert.deepEqual(mine, theirs)
      assert.deepEqual(structured([page]), one.structured)
      assert.equal(latex([page]), one.latex)
    })
  }

  // The scanner, against the Mac's reading of the same bytes — only where the
  // corpus is on this machine (it never enters the repository).
  const corpus = process.env.PAPERTIME_CORPUS
  if (!corpus) return
  for (const one of cases) {
    const match = /^(.*) p(\d+)$/.exec(one.name)
    if (!match) continue
    const file = path.join(corpus, match[1])
    if (!fs.existsSync(file)) continue
    await test(`${one.name}: the page's glyphs and rules read as the Mac reads them`, () => {
      const scanned = new MathScanner(new Uint8Array(fs.readFileSync(file))).page(Number(match[2]) - 1)!
      const expected = pageFromFixture(one)
      assert.equal(scanned.glyphs.length, expected.glyphs.length, 'as many glyphs')
      const close = (a: number, b: number) => Math.abs(a - b) < 1e-6
      scanned.glyphs.forEach((glyph, index) => {
        const theirs = expected.glyphs[index]
        const same = glyph.code === theirs.code && glyph.fontName === theirs.fontName && glyph.unicode === theirs.unicode
          && glyph.glyphName === theirs.glyphName && glyph.isSymbolic === theirs.isSymbolic
          && close(glyph.size, theirs.size) && close(glyph.x, theirs.x) && close(glyph.y, theirs.y) && close(glyph.width, theirs.width)
        if (!same) assert.fail(`glyph ${index}: ${JSON.stringify(glyph)} ≠ ${JSON.stringify(theirs)}`)
      })
      assert.equal(scanned.rules.length, expected.rules.length, 'as many rules')
      scanned.rules.forEach((rule, index) => {
        const theirs = expected.rules[index].rect
        if (![rule.rect.x - theirs.x, rule.rect.y - theirs.y, rule.rect.width - theirs.width, rule.rect.height - theirs.height].every((d) => Math.abs(d) < 1e-6)) {
          assert.fail(`rule ${index}: ${JSON.stringify(rule.rect)} ≠ ${JSON.stringify(theirs)}`)
        }
      })
    })
  }

}
