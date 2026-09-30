/**
 * MathReader, against the Mac: the pages in
 * `Tests/PaperCoreTests/Fixtures/mathreader-cases.json.gz` were read by the
 * Mac's own `PDFContentScanner` and `MathReader`
 * (`Scripts/mathreader-fixtures.sh`), and the port is given the same glyphs,
 * rules, line boxes and characters and has to say the same thing — piece for
 * piece, line for line. Twenty are pages of papers; the rest are the
 * bench's (`Scripts/ultracopy-bench/`): one formula a page, set twenty ways,
 * held here one setup at a time. Ultracopy's LaTeX is compared too, and it is
 * laid out as the page is: a display on a line of its own, its rows a line
 * each.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import zlib from 'node:zlib'
import { latex, leftOutFormulas, pieces, spread, structured, type PageInput, type PieceKind } from '../shared/mathReader/reader.js'
import { latex as glyphLatex } from '../shared/mathReader/texGlyphNames.js'
import { holes, imageMask, PLAIN_HOLES } from '../main/mathScanner.js'
import type { Glyph } from '../shared/mathReader/glyph.js'
import { MathScanner } from '../main/mathScanner.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Case {
  name: string
  source: { page: number; corpus?: string; bench?: string }
  cropBox: number[]
  fonts: string[]
  glyphs: [number, number, string | null, string | null, number, number, number, number][]
  rules: number[][]
  lineBoxes: number[][]
  pageText: string
  characters: [number, number, number, number, number, string][]
  selectionString: string
  italicElsewhere: [boolean, boolean]
  pieces: { kind: string; plain: string; marked: string; left: number; right: number; baseline: number; scale: number }[]
  skipped: number
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
    italicElsewhere: { ownLetters: one.italicElsewhere[0], evidence: one.italicElsewhere[1] },
  }
}

const kindName = (kind: PieceKind) => (typeof kind === 'object' ? `heading${kind.heading}` : kind)

/** What the port reads off one page, beside what the Mac read. */
function compare(one: Case) {
  const page = pageFromFixture(one)
  const mine = pieces([page]).map((piece) => ({
    kind: kindName(piece.kind), plain: piece.plain, marked: piece.marked,
    left: piece.left, right: piece.right, baseline: piece.baseline, scale: piece.scale,
  }))
  const skipped = leftOutFormulas()
  const theirs = one.pieces.map(({ kind, plain, marked, left, right, baseline, scale }) => ({ kind, plain, marked, left, right, baseline, scale }))
  assert.deepEqual(mine, theirs)
  assert.equal(skipped, one.skipped, 'as many formulas left out')
  assert.deepEqual(structured([page]), one.structured)
  assert.equal(latex([page]), one.latex)
}

/** The page's glyphs and rules as the port's scanner reads the same bytes. */
function compareScan(one: Case, scanner: MathScanner) {
  const scanned = scanner.page(one.source.page - 1)!
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
  const elsewhere = scanner.italicElsewhere(one.source.page - 1)
  assert.deepEqual([elsewhere.ownLetters, elsewhere.evidence], one.italicElsewhere, 'what the other first pages say about variables')
}

/** Every page of a group, the first few that differ told in full. */
function every(cases: Case[], each: (one: Case) => void) {
  const failures: string[] = []
  for (const one of cases) {
    try {
      each(one)
    } catch (error) {
      failures.push(`${one.name}: ${String((error as Error).message ?? error)}`)
    }
  }
  if (failures.length > 0) {
    assert.fail(`${failures.length} of ${cases.length} pages differ\n${failures.slice(0, 3).join('\n')}`)
  }
}

export async function mathReaderSuite(test: Test, suite: (name: string) => void) {
  suite('Reading a page with its mathematics, as the Mac reads it')
  const file = path.resolve(process.cwd(), '..', 'Tests/PaperCoreTests/Fixtures/mathreader-cases.json.gz')
  const cases = JSON.parse(zlib.gunzipSync(fs.readFileSync(file)).toString('utf8')) as Case[]
  const corpus = cases.filter((one) => one.source.corpus !== undefined)
  const setups = new Map<string, Case[]>()
  for (const one of cases) {
    if (one.source.bench === undefined) continue
    setups.set(one.source.bench, [...(setups.get(one.source.bench) ?? []), one])
  }
  for (const one of corpus) {
    await test(`${one.name}: the same pieces, Markdown and Ultracopy's LaTeX`, () => compare(one))
  }
  for (const [setup, pages] of setups) {
    await test(`the bench set in ${setup}, ${pages.length} pages: the same pieces, Markdown and Ultracopy's LaTeX`, () => every(pages, compare))
  }

  await test('a display of several rows is written a row a line; one row stays on one line', () => {
    assert.equal(spread('$$a=b$$'), '$$a=b$$')
    assert.equal(spread('$$\\begin{aligned} &a=b, \\\\ &c=d. \\end{aligned}$$'),
      '$$\\begin{aligned}\n&a=b,\\\\\n&c=d.\n\\end{aligned}$$')
    assert.equal(spread('\\begin{equation} \\begin{aligned} &u=v, \\\\ &w=t. \\end{aligned}\\tag{1} \\end{equation}'),
      '\\begin{equation}\n\\begin{aligned}\n&u=v,\\\\\n&w=t.\n\\end{aligned}\\tag{1}\n\\end{equation}')
    // A system of cases inside a row keeps its rows in that row.
    assert.equal(spread('$$f=\\begin{cases} 1 & x \\\\ 0 & y \\end{cases}$$'), '$$f=\\begin{cases} 1 & x \\\\ 0 & y \\end{cases}$$')
  })

  await test('a bitmap letter with a hollow stem is double-struck; a plain one is not', () => {
    // pdfTeX's picture of a glyph: an unfiltered image mask, one bit a pixel.
    const picture = (rows: string[]) => {
      const width = rows[0].length
      const rowBytes = Math.ceil(width / 8)
      const bits = new Uint8Array(rowBytes * rows.length)
      rows.forEach((row, y) => [...row].forEach((pixel, x) => {
        if (pixel === '#') bits[y * rowBytes + (x >> 3)] |= 0x80 >> (x & 7)
      }))
      const head = Buffer.from(`q ${width} 0 0 ${rows.length} 0 0 cm\nBI\n/W ${width}\n/H ${rows.length}\n/IM true\n/BPC 1\n/D [1 0]\nID `, 'latin1')
      return new Uint8Array([...head, ...bits, ...Buffer.from('\nEI\nQ\n', 'latin1')])
    }
    const plainI = imageMask(picture(['##########', '...####...', '...####...', '...####...', '...####...', '...####...', '##########']))!
    const hollowI = imageMask(picture(['##########', '..#....#..', '..#....#..', '..#....#..', '..#....#..', '..#....#..', '##########']))!
    assert.equal(holes(plainI), PLAIN_HOLES.get(0x49))
    assert.ok(holes(hollowI) > PLAIN_HOLES.get(0x49)!)
    // A double-struck font's letters and digits both take \mathbb.
    assert.equal(glyphLatex('a80', 80, 'Type3+BBM', null), '\\mathbb{P}')
    assert.equal(glyphLatex('a49', 49, 'Type3+BBM', null), '\\mathbb{1}')
  })

  // The scanner, against the Mac's reading of the same bytes — only where the
  // PDFs are on this machine (they never enter the repository): the corpus
  // in PAPERTIME_CORPUS, the bench's PDFs (`make.sh`) in PAPERTIME_BENCH.
  const corpusFolder = process.env.PAPERTIME_CORPUS
  if (corpusFolder) {
    for (const one of corpus) {
      const pdf = path.join(corpusFolder, one.source.corpus!)
      if (!fs.existsSync(pdf)) continue
      await test(`${one.name}: the page's glyphs and rules read as the Mac reads them`, () =>
        compareScan(one, new MathScanner(new Uint8Array(fs.readFileSync(pdf)))))
    }
  }
  const benchFolder = process.env.PAPERTIME_BENCH
  if (benchFolder) {
    for (const [setup, pages] of setups) {
      const pdf = path.join(benchFolder, `${setup}.pdf`)
      if (!fs.existsSync(pdf)) continue
      await test(`the bench set in ${setup}: every page's glyphs and rules read as the Mac reads them`, () => {
        const scanner = new MathScanner(new Uint8Array(fs.readFileSync(pdf)))
        every(pages, (one) => compareScan(one, scanner))
      })
    }
  }
}
