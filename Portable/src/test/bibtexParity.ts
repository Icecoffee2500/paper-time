/**
 * The same folder exports the same `.bib` on both desktops (`WR13`): keys
 * minted, made unique and kept, and whole entries written under two sets of
 * options — every answer the Mac's own `CitationKey` and `BibTeXWriter`
 * gave (`Scripts/bibtex-fixtures.sh` → `Tests/BibliographyTests/Fixtures/
 * bibtex-cases.json`). Change the format and the fixture is made again, in
 * the same commit on both sides.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { assignKeys, makeKey } from '../shared/citationKey.js'
import { DEFAULT_EXPORT, entryFor, formatEntry, type ExportOptions } from '../shared/bibtex.js'
import { PaperMeta, type CSLItem } from '../shared/model.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Fixture {
  keys: { name: string; csl: CSLItem; fileName: string; key: string }[]
  entries: { name: string; csl: CSLItem; identifiers: Record<string, string>; key: string; options: string; text: string }[]
  assigned: { items: { csl: CSLItem; preferred?: string }[]; keys: string[] }[]
}

const OPTIONS: Record<string, ExportOptions> = {
  default: DEFAULT_EXPORT,
  plain: { ...DEFAULT_EXPORT, preprintStyle: 'arxivPreprintArticle', protectCase: false, abbreviateJournals: true, includeURL: false },
}

export async function bibtexParitySuite(test: Test, suite: (name: string) => void) {
  suite('BibTeX, as the Mac writes it')
  const file = path.join(__dirname, '../../../Tests/BibliographyTests/Fixtures/bibtex-cases.json')
  const fixture = JSON.parse(fs.readFileSync(file, 'utf8')) as Fixture

  await test(`every key is minted as the Mac mints it (${fixture.keys.length} records)`, () => {
    for (const one of fixture.keys) assert.equal(makeKey(one.csl, one.fileName), one.key, one.name)
  })

  await test('keys already given are kept and new ones are made unique, in the Mac’s order', () => {
    for (const group of fixture.assigned) {
      const keys = assignKeys(group.items.map((item, index) => ({ id: String(index), item: item.csl, preferred: item.preferred ?? null })))
      assert.deepEqual(group.items.map((_, index) => keys.get(String(index))), group.keys)
    }
  })

  await test(`every entry is written byte for byte (${fixture.entries.length} entries, two sets of options)`, () => {
    for (const one of fixture.entries) {
      const meta = new PaperMeta({ id: 'X', csl: one.csl, identifiers: one.identifiers, bibKey: one.key, file: { relativePath: 'x.pdf' } })
      assert.equal(formatEntry(entryFor(meta, OPTIONS[one.options], one.key)), one.text, `${one.name} (${one.options})`)
    }
  })
}

/** A fresh record, written as the Mac writes one (`fresh-meta-fixture.sh`). */
export async function freshMetaSuite(test: Test) {
  await test('an export never writes one key twice, and writes its entries in key order', async () => {
    const { formatBibliography } = await import('../shared/bibtex.js')
    const same = { type: 'article-journal', title: 'Deep Nets', author: [{ family: 'Smith' }], issued: { 'date-parts': [[2020]] } }
    const metas = ['A', 'B', 'C'].map((id) => new PaperMeta({ id, csl: same, file: { relativePath: `${id}.pdf`, originalName: `${id}.pdf` } }))
    metas[2].bibKey = 'smith2020deep'
    const text = formatBibliography(metas, { ...DEFAULT_EXPORT, includeHeader: false })
    const keys = [...text.matchAll(/^@\w+\{([^,]+),/gm)].map((match) => match[1])
    assert.deepEqual(keys, ['smith2020deep', 'smith2020deepa', 'smith2020deepb'])
  })

  await test('a PDF just taken in gets the record the Mac would write, byte for byte', async () => {
    const { encodeSwiftJSON } = await import('../shared/coding.js')
    const expected = fs.readFileSync(path.join(__dirname, '../../../Tests/LibraryStoreTests/Fixtures/fresh-meta.json'), 'utf8')
    const meta = PaperMeta.make('3F2504E0-4F89-41D3-9A0C-0305E82C3301', {
      relativePath: 'week 1/Attention Is All You Need.pdf',
      byteSize: 2215244,
      pageCount: 15,
      importDigest: '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
      originalName: 'Attention Is All You Need.pdf',
    }, 'Mac-TEST')
    const at = new Date(1_790_000_000 * 1000)
    meta.addedAt = at
    meta.updatedAt = at
    const raw = meta.encode()
    ;(raw.provenance as Record<string, unknown>).fetchedAt = '2026-09-21T14:13:20Z'
    assert.equal(encodeSwiftJSON(raw), expected)
  })
}
