/**
 * Search, held to the Mac.
 *
 * The fold is compared against strings folded by the real Swift code
 * (`fixtures/macSearch.json`, written by `tools/generate-fold-table.mjs`),
 * the ranking against the Mac's `SearchIndex` ladder case by case, and the
 * text index against a real PDF read by pdf.js — where a word broken across
 * two lines is found, where its first letter sits on the page, and what
 * happens to the kept text when the file changes or the paper goes away.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { foldText, foldTitle, foldWithMap, snippetAround } from '../shared/textFold.js'
import {
  displayName, jaroWinkler, matchScore, noteTitle, paperHaystack, prepare, rank,
  type RankWords, type SearchablePaper,
} from '../shared/searchRank.js'
import { TextIndex, type ReadText, type TextSource } from '../main/textIndex.js'
import { extractPages } from '../main/textExtract.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Fixture {
  fold: { input: string; text: string; map: number[] }[]
  title: { input: string; output: string }[]
  jaroWinkler: { a: string; b: string; value: number }[]
}

const WORDS: RankWords = {
  showAll: (query) => `Show All Results for “${query}”`,
  paperCount: (count) => `${count} papers`,
  note: 'Note',
  collection: 'Collection',
  smartCollection: 'Smart Collection',
  tag: 'Tag',
  action: 'Action',
}

/**
 * A one-page PDF that says 강화학습 in a Korean font it does not embed, by the
 * predefined UniKS-UCS2-H encoding — the kind of file whose text pdf.js can
 * only read with the character maps. Written out by hand, offsets and all.
 */
function koreanPDF(): Uint8Array {
  const content = 'BT /F1 24 Tf 20 100 Td <AC15D654D559C2B5> Tj ET'
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type0 /BaseFont /HYSMyeongJo-Medium /Encoding /UniKS-UCS2-H /DescendantFonts [6 0 R] >>',
    `<< /Length ${content.length} >>\nstream\n${content}\nendstream`,
    '<< /Type /Font /Subtype /CIDFontType0 /BaseFont /HYSMyeongJo-Medium'
      + ' /CIDSystemInfo << /Registry (Adobe) /Ordering (Korea1) /Supplement 1 >> /FontDescriptor 7 0 R >>',
    '<< /Type /FontDescriptor /FontName /HYSMyeongJo-Medium /Flags 6 /FontBBox [0 -200 1000 900]'
      + ' /ItalicAngle 0 /Ascent 880 /Descent -120 /CapHeight 700 /StemV 80 >>',
  ]
  let body = '%PDF-1.4\n'
  const offsets: number[] = []
  for (const [index, object] of objects.entries()) {
    offsets.push(body.length)
    body += `${index + 1} 0 obj\n${object}\nendobj\n`
  }
  const xref = body.length
  body += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`
  for (const offset of offsets) body += `${String(offset).padStart(10, '0')} 00000 n \n`
  body += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`
  return new TextEncoder().encode(body)
}

function paper(id: string, title: string, extra: Partial<SearchablePaper> = {}): SearchablePaper {
  return { id, title, authors: [], displayAuthors: '', bibKey: '', originalName: '', ...extra }
}

export async function searchSuite(test: Test, suite: (name: string) => void) {
  const fixture = JSON.parse(fs.readFileSync(
    path.join(__dirname, '../../src/test/fixtures/macSearch.json'), 'utf8')) as Fixture

  suite('Folding text the way the Mac does')

  await test(`every one of ${fixture.fold.length} strings folds to what PaperTextIndex.fold wrote`, () => {
    const wrong: string[] = []
    for (const { input, text, map } of fixture.fold) {
      const folded = foldWithMap(input)
      if (folded.text !== text || foldText(input) !== text) wrong.push(`${JSON.stringify(input)} → ${JSON.stringify(folded.text)}, Mac ${JSON.stringify(text)}`)
      else if (folded.map.length !== map.length || folded.map.some((at, index) => at !== map[index])) {
        wrong.push(`${JSON.stringify(input)}: map ${JSON.stringify([...folded.map])}, Mac ${JSON.stringify(map)}`)
      }
    }
    assert.deepEqual(wrong.slice(0, 5), [])
  })

  await test(`every one of ${fixture.title.length} titles folds to what TextNormalization.foldedTitle wrote`, () => {
    const wrong = fixture.title
      .filter(({ input, output }) => foldTitle(input) !== output)
      .map(({ input, output }) => `${JSON.stringify(input)} → ${JSON.stringify(foldTitle(input))}, Mac ${JSON.stringify(output)}`)
    assert.deepEqual(wrong.slice(0, 5), [])
  })

  await test('a word broken at the end of a line is one word, and its letters point back at the page', () => {
    const page = 'Machine un-\nlearning removes'
    const folded = foldWithMap(page)
    assert.equal(folded.text, 'machine unlearning removes')
    const at = folded.text.indexOf('unlearning')
    // "u" is where it was written; the "l" after the join is on the next line.
    assert.equal(folded.map[at], page.indexOf('un-'))
    assert.equal(folded.map[at + 2], page.indexOf('learning'))
  })

  await test('a fold stopped early agrees with the whole fold as far as it went', () => {
    const page = `${'Élan vital, un-\nlearning — and ﬁnally Straße. '.repeat(40)}`
    const whole = foldWithMap(page)
    for (const until of [0, 1, 17, 200, 999]) {
      const part = foldWithMap(page, until)
      assert.ok(part.map.length > until, `map reaches ${until}`)
      for (let index = 0; index <= until; index += 1) assert.equal(part.map[index], whole.map[index])
    }
  })

  await test('the snippet is the sentence around the match, with whole words at its ends', () => {
    const text = `${'x '.repeat(50)}the definition of catastrophic forgetting is given in the section below ${'y '.repeat(50)}`
    const at = text.indexOf('catastrophic')
    const snippet = snippetAround(text, at, 'catastrophic forgetting'.length)
    assert.ok(snippet.startsWith('…') && snippet.endsWith('…'))
    assert.ok(snippet.includes('catastrophic forgetting'))
    assert.ok(!snippet.includes('  '))
  })

  suite('Ranking the palette the way the Mac does')

  await test(`Jaro–Winkler gives the Mac's number for ${fixture.jaroWinkler.length} pairs`, () => {
    for (const { a, b, value } of fixture.jaroWinkler) {
      assert.ok(Math.abs(jaroWinkler(a, b) - value) < 1e-12, `${a} / ${b}: ${jaroWinkler(a, b)} vs ${value}`)
    }
  })

  await test('the ladder: a title prefix, then a word, then anywhere, then a typo', () => {
    const q = (text: string) => ({ text: foldTitle(text) })
    const f = (text: string) => ({ text: foldTitle(text) })
    assert.equal(matchScore(q('unlearning'), f('Unlearning in the Wild')), 1)
    assert.equal(matchScore(q('unlearning'), f('Representation Unlearning: Forgetting')), 0.9)
    assert.equal(matchScore(q('learning'), f('Representation Unlearning')), 0.75)
    const typo = matchScore(q('Wassersten'), f('Wasserstein'))
    assert.ok(typo !== null && typo > 0.82 && typo < 0.75 + 0.25)
    assert.equal(matchScore(q('entirely different'), f('Wasserstein')), null)
    // Case, accents and punctuation do not count.
    assert.equal(matchScore(q('almudevar'), f('Almudévar, A.')), 1)
  })

  await test('a title match beats an author match, and the author still counts', () => {
    const prepared = prepare({
      papers: [
        paper('a', 'Learning to Forget', { authors: [{ given: 'Yann', family: 'LeCun' }], displayAuthors: 'LeCun' }),
        paper('b', 'LeCun on Convolutions'),
      ],
      notes: [], collections: [], tags: [], actions: [],
    })
    const results = rank('lecun', prepared, WORDS)
    assert.deepEqual(results.map((one) => one.kind), [
      { type: 'showAll', query: 'lecun' },
      { type: 'paper', id: 'b' },
      { type: 'paper', id: 'a' },
    ])
    assert.equal(results[0].score, 2)
    assert.equal(results[1].score, 1)
    assert.equal(results[2].score, 0.6)
    assert.equal(results[0].subtitle, '2 papers')
  })

  await test('the year and the file name find a paper; the paper opened this week comes first', () => {
    const now = Date.parse('2026-09-25T00:00:00Z')
    const prepared = prepare({
      papers: [
        paper('old', 'Adaptation at Test Time', { year: 2024, originalName: 'Karmanov_CVPR_2024.pdf' }),
        paper('new', 'Adaptation Without Labels', { year: 2024, lastOpenedAt: new Date(now - 2 * 86_400_000) }),
      ],
      notes: [], collections: [], tags: [], actions: [],
    })
    assert.deepEqual(rank('karmanov', prepared, WORDS, now).map((one) => one.kind), [{ type: 'paper', id: 'old' }])
    const both = rank('adaptation', prepared, WORDS, now).filter((one) => one.kind.type === 'paper')
    assert.equal(both[0].kind.type === 'paper' && both[0].kind.id, 'new')
    // 1 for the prefix, and 0.15 less a thirtieth of it a day for the two days.
    assert.ok(Math.abs(both[0].score - (1 + 0.15 - 0.15 * 2 / 30)) < 1e-9)
    assert.equal(rank('2024', prepared, WORDS, now).filter((one) => one.kind.type === 'paper').length, 2)
  })

  await test('notes rank a hair below the same match in a title; collections, tags and actions by name', () => {
    const prepared = prepare({
      papers: [paper('p', 'Forgetting Curves')],
      notes: [{ paperID: 'p', title: noteTitle('# Forgetting curves\nread again in a week'), preview: 'read again', paperTitle: 'Forgetting Curves' }],
      collections: [{ id: 'c', name: 'Forgetting', smart: true }],
      tags: [{ id: 't', name: 'forgetting' }],
      actions: [{ name: 'exportBibTeX', title: 'Export BibTeX…' }],
    })
    const results = rank('forgetting', prepared, WORDS)
    const byType = Object.fromEntries(results.map((one) => [one.kind.type, one]))
    assert.equal(byType.paper.score, 1)
    assert.equal(byType.note.score, 0.95)
    assert.equal(byType.note.title, 'Forgetting curves')
    assert.equal(byType.note.subtitle, 'Note · Forgetting Curves')
    assert.equal(byType.collection.subtitle, 'Smart Collection')
    assert.equal(byType.tag.score, 1)
    assert.deepEqual(rank('export', prepared, WORDS).map((one) => one.kind), [{ type: 'action', name: 'exportBibTeX' }])
  })

  await test('ties go to the title in alphabetical order, and there are never more than twenty', () => {
    const papers = Array.from({ length: 30 }, (_, index) =>
      paper(`p${index}`, `Graph ${String.fromCharCode(90 - (index % 26))}${index}`))
    const results = rank('graph', prepare({ papers, notes: [], collections: [], tags: [], actions: [] }), WORDS)
    assert.equal(results.length, 20)
    assert.equal(results[0].kind.type, 'showAll')
    const titles = results.slice(1).map((one) => one.title)
    assert.deepEqual(titles, [...titles].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'accent' })))
  })

  await test('an author is found in both orders, as the list does', () => {
    const entry = paper('a', 'X', { authors: [{ given: 'Yann', family: 'LeCun' }] })
    assert.ok(paperHaystack(entry).includes(foldTitle('Yann LeCun')))
    assert.ok(paperHaystack(entry).includes(foldTitle('LeCun Yann')))
    assert.equal(displayName({ given: 'Ludwig', family: 'Beethoven', 'non-dropping-particle': 'van' }), 'Ludwig van Beethoven')
    assert.equal(displayName({ literal: 'The ACL Committee' }), 'The ACL Committee')
  })

  suite('The text index')

  const folder = await fsp.mkdtemp(path.join(os.tmpdir(), 'papertime-text-'))
  const cache = path.join(folder, 'cache')
  const assets = {
    cmap: async (name: string) => new Uint8Array(await fsp.readFile(path.join(__dirname, '../../node_modules/pdfjs-dist/cmaps', `${name}.bcmap`))),
    font: async (name: string) => new Uint8Array(await fsp.readFile(path.join(__dirname, '../../node_modules/pdfjs-dist/standard_fonts', name))),
  }
  let reads = 0
  const extract = async (source: TextSource): Promise<ReadText> => {
    reads += 1
    const pages = await extractPages(new Uint8Array(await fsp.readFile(source.file)), assets)
    return { pages, folded: pages.map(foldText) }
  }

  // A two-page paper, the word broken across a line on the second page.
  const { PDFDocument, StandardFonts } = await import('pdf-lib')
  const pdf = await PDFDocument.create()
  const font = await pdf.embedFont(StandardFonts.Helvetica)
  pdf.addPage([400, 400]).drawText('Nothing to see on the first page.', { x: 40, y: 340, size: 12, font })
  const second = pdf.addPage([400, 400])
  second.drawText('Machine un-', { x: 40, y: 340, size: 12, font })
  second.drawText('learning is what this page is about.', { x: 40, y: 324, size: 12, font })
  const file = path.join(folder, 'paper.pdf')
  await fsp.writeFile(file, await pdf.save())
  const source: TextSource = { id: 'PAPER-1', file, title: 'A Paper' }

  await test('finds a word broken across two lines, on the page it is on, from the first letter', async () => {
    const index = new TextIndex({ directory: cache, extract })
    const hits: string[] = []
    let found: { pageIndex: number; location: number; length: number } | null = null
    await index.search('unlearning', [source], {
      cancelled: () => false,
      emit: (batch) => {
        for (const hit of batch) {
          hits.push(hit.snippet)
          found = hit.passage
        }
      },
    })
    assert.equal(hits.length, 1)
    const text = (await index.load(source))!.pages[1]
    assert.ok(found)
    const passage = found as { pageIndex: number; location: number; length: number }
    assert.equal(passage.pageIndex, 1)
    // The characters the passage covers, as written: the break and all.
    assert.equal(text.slice(passage.location, passage.location + passage.length).replace(/-\s+/, ''), 'unlearning')
  })

  await test('the text is read once, kept outside the library, and good until the file changes', async () => {
    reads = 0
    const first = new TextIndex({ directory: cache, extract })
    await first.load(source)
    assert.equal(reads, 0, 'the first test left it in the cache')
    assert.ok(fs.existsSync(path.join(cache, 'PAPER-1.json')))
    assert.ok(!fs.readdirSync(folder).some((name) => name.endsWith('.json')), 'nothing next to the PDF')

    // The same bytes, touched: a new time is a new file as far as a stat can
    // tell, and the text is read again.
    const later = new Date(Date.now() + 5000)
    await fsp.utimes(file, later, later)
    const second = new TextIndex({ directory: cache, extract })
    await second.load(source)
    assert.equal(reads, 1)
    // …and written down again, so the next session reads the cache.
    const third = new TextIndex({ directory: cache, extract })
    await third.load(source)
    assert.equal(reads, 1)
  })

  await test('a file changed while the index is open is read again after revalidating', async () => {
    reads = 0
    const index = new TextIndex({ directory: cache, extract })
    await index.load(source)
    const bigger = await PDFDocument.load(await fsp.readFile(file))
    bigger.addPage([400, 400]).drawText('A third page about forgetting.', { x: 40, y: 340, size: 12, font })
    await fsp.writeFile(file, await bigger.save())
    assert.equal(await index.revalidate([source]), 1)
    const text = await index.load(source)
    assert.equal(text?.pages.length, 3)
    assert.equal(reads, 1)
  })

  await test('what is kept for a paper that is gone is taken out, and nothing else', async () => {
    const index = new TextIndex({ directory: cache, extract })
    // A paper in another folder that is only disconnected: its file is there.
    const elsewhere = await fsp.mkdtemp(path.join(os.tmpdir(), 'papertime-elsewhere-'))
    const other = path.join(elsewhere, 'other.pdf')
    await fsp.copyFile(file, other)
    await index.load({ id: 'OTHER', file: other, title: 'Other' })
    // A paper whose file was deleted.
    const doomed = path.join(folder, 'doomed.pdf')
    await fsp.copyFile(file, doomed)
    await index.load({ id: 'DOOMED', file: doomed, title: 'Doomed' })
    await fsp.rm(doomed)
    // A paper in the open folder that has left the library.
    const left = path.join(folder, 'left.pdf')
    await fsp.copyFile(file, left)
    await index.load({ id: 'LEFT', file: left, title: 'Left' })

    const removed = await index.cleanup(new Set(['PAPER-1']), [path.join(folder, 'a-folder-that-is-not-open')])
    assert.equal(removed, 1, 'only the paper whose file is gone, while its folder is not open')
    assert.ok(fs.existsSync(path.join(cache, 'OTHER.json')))
    assert.ok(fs.existsSync(path.join(cache, 'LEFT.json')))
    assert.ok(!fs.existsSync(path.join(cache, 'DOOMED.json')))

    // With its folder open, a paper that left the library goes too — but not
    // one in a folder that is not open.
    assert.equal(await index.cleanup(new Set(['PAPER-1']), [folder]), 1)
    assert.ok(fs.existsSync(path.join(cache, 'PAPER-1.json')))
    assert.ok(fs.existsSync(path.join(cache, 'OTHER.json')))
    assert.ok(!fs.existsSync(path.join(cache, 'LEFT.json')))
    await fsp.rm(elsewhere, { recursive: true, force: true })
  })

  await test('a Korean paper in a font the file does not carry is read through the character maps', async () => {
    const asked: string[] = []
    const pages = await extractPages(koreanPDF(), {
      cmap: async (name) => {
        asked.push(name)
        return assets.cmap(name)
      },
      font: assets.font,
    })
    assert.equal(pages.length, 1)
    assert.ok(foldText(pages[0]).includes(foldText('강화학습')), JSON.stringify(pages[0]))
    // The two maps a predefined Korean encoding needs, asked for by name and
    // handed over by whoever called — never read from a path pdf.js made up.
    assert.ok(asked.includes('UniKS-UCS2-H'), asked.join(', '))
  })

  await test('a query of one letter searches nothing, as on the Mac', async () => {
    const index = new TextIndex({ directory: cache, extract })
    const result = await index.search('u', [source], { cancelled: () => false, emit: () => assert.fail('no hits') })
    assert.deepEqual(result, { searched: 0, found: 0 })
  })

  await fsp.rm(folder, { recursive: true, force: true })
}
