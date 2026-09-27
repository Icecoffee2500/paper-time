/**
 * The Info tab's parts without a window (`WR12`): what a PDF is guessed to
 * be — the Mac's six cases and the course words — a supplement's parent,
 * names parsed as the Mac parses them, citation keys minted as the Mac mints
 * them, a rename's every answer, and where the file stands against the one
 * imported.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { guessKind, isCitable, isLookedUp, namesACourse } from '../shared/documentKind.js'
import { looksLikeSupplement, suggestedParent } from '../shared/attachmentSearch.js'
import { parseName, parseNames, PaperMeta } from '../shared/model.js'
import { assignKeys, firstSignificantWord, makeKey, sanitise, uniqued } from '../shared/citationKey.js'
import { Library, classifyFile } from '../main/library.js'
import { createHash } from 'node:crypto'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

export async function inspectorSuite(test: Test, suite: (name: string) => void) {
  suite('The Info tab')

  await test('what a PDF is, guessed the Mac’s six ways', () => {
    assert.deepEqual(guessKind({ identifier: true, abstract: false, references: false }), { kind: 'paper', reason: 'identifier' })
    assert.equal(guessKind({ identifier: false, abstract: true, references: true }).kind, 'paper')
    assert.equal(guessKind({ identifier: false, abstract: true, references: false }).kind, 'document')
    assert.equal(guessKind({ identifier: false, abstract: false, references: true }).kind, 'document')
    assert.deepEqual(guessKind({ identifier: false, abstract: false, references: true, pageCount: 548 }), { kind: 'book', reason: 'length' })
    assert.equal(guessKind({ identifier: false, abstract: false, references: false, pageCount: 548 }).kind, 'document')
    assert.equal(guessKind({ identifier: false, abstract: false, references: true, pageCount: 12 }).kind, 'document')
    assert.equal(guessKind({ identifier: true, abstract: true, references: true, pageCount: 548 }).kind, 'paper')
    assert.deepEqual(guessKind({ identifier: false, abstract: false, references: false }), { kind: 'document', reason: 'nothingFound' })
    assert.ok(isCitable('paper') && isCitable('book') && !isCitable('document') && !isCitable('lecture'))
    assert.ok(isLookedUp('paper') && !isLookedUp('book') && !isLookedUp('document'))
    assert.ok(namesACourse('STA 512 lecture notes'))
    assert.ok(namesACourse('lecture06.pdf'))
    assert.ok(namesACourse('3주차 강의자료'))
    assert.equal(namesACourse('Attention Is All You Need'), false)
  })

  await test('a supplement is offered its paper only when it says it is one', () => {
    const shelf = [
      { id: 'A', title: 'Attention Is All You Need' },
      { id: 'B', title: 'Scene Graph Generation by Iterative Message Passing' },
      { id: 'C', title: 'Deep Residual Learning for Image Recognition' },
    ]
    assert.ok(looksLikeSupplement('Karmanov_CVPR_2024_supplemental.pdf', ''))
    assert.equal(suggestedParent({ id: 'X', title: '', fileName: 'Attention Is All You Need supplementary.pdf' }, shelf), 'A')
    assert.equal(suggestedParent({
      id: 'Y', title: 'Scene-Graph ViT: End-to-End Open-Vocabulary Visual Relationship Detection', fileName: 'scene_graph_vit.pdf',
    }, shelf), null, 'two titles that begin alike are not a supplement and its paper')
  })

  await test('names are read the way the Mac reads them', () => {
    assert.deepEqual(parseName('LeCun, Yann'), { family: 'LeCun', given: 'Yann' })
    assert.deepEqual(parseName('King, Martin, Jr.'), { family: 'King', given: 'Martin', suffix: 'Jr.' })
    assert.deepEqual(parseName('Yann LeCun'), { family: 'LeCun', given: 'Yann' })
    assert.deepEqual(parseName('Plato'), { family: 'Plato' })
    assert.deepEqual(parseNames('Ashish Vaswani and Noam Shazeer; Niki Parmar').map((one) => one.family), ['Vaswani', 'Shazeer', 'Parmar'])
  })

  await test('citation keys are minted the Mac’s way', () => {
    assert.equal(firstSignificantWord('Learning to Learn by Gradient Descent'), 'learn', '«learning» is a stop word, «learn» is not')
    assert.equal(makeKey({ title: 'Attention Is All You Need', author: [{ family: 'Vaswani', given: 'A' }], issued: { 'date-parts': [[2017]] } }), 'vaswani2017attention')
    assert.equal(makeKey({ title: 'Über Wärme', author: [{ family: 'Müller' }], issued: { 'date-parts': [[1905]] } }), 'muller1905uber')
    assert.equal(makeKey({}, 'My File.pdf'), 'myfilepdf')
    const taken = new Set(['smith2020deep'])
    assert.equal(uniqued('smith2020deep', taken), 'smith2020deepa')
    assert.equal(uniqued('smith2020deep', taken), 'smith2020deepb')
    assert.equal(sanitise('-key:1 é'), 'key:1')
    const keys = assignKeys([
      { id: '1', item: { title: 'Deep Nets', author: [{ family: 'Smith' }], issued: { 'date-parts': [[2020]] } } },
      { id: '2', item: {}, preferred: 'smith2020deep' },
    ])
    assert.equal(keys.get('2'), 'smith2020deep', 'a key already given is kept')
    assert.equal(keys.get('1'), 'smith2020deepa')
  })

  await test('a rename says every answer, keeps the extension and writes a forward slash', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-rename-'))
    try {
      fs.mkdirSync(path.join(root, 'week 1'))
      fs.writeFileSync(path.join(root, 'week 1', 'a.pdf'), '%PDF-1.7\n% a\n')
      fs.writeFileSync(path.join(root, 'week 1', 'taken.pdf'), '%PDF-1.7\n% b\n')
      const library = await Library.open(root)
      const row = (await library.importPDF(path.join(root, 'week 1', 'a.pdf'), 1)).row!
      assert.deepEqual(await library.rename(row.id, '  '), { error: 'empty' })
      assert.deepEqual(await library.rename(row.id, 'a/b'), { error: 'notAName' })
      assert.deepEqual(await library.rename(row.id, 'taken'), { error: 'taken' })
      const renamed = await library.rename(row.id, 'Diffusion Policy')
      assert.ok(!('error' in renamed))
      const meta = new PaperMeta((await library.paper(row.id))!.meta)
      assert.equal(meta.file.relativePath, 'week 1/Diffusion Policy.pdf')
      fs.rmSync(path.join(root, 'week 1', 'Diffusion Policy.pdf'))
      assert.deepEqual(await library.rename(row.id, 'Other'), { error: 'missing' })
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('where a file stands: as imported, appended to, or written again', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-provenance-'))
    try {
      const file = path.join(root, 'p.pdf')
      const original = Buffer.from('%PDF-1.7\n% the original bytes\n%%EOF\n')
      fs.writeFileSync(file, original)
      const digest = createHash('sha256').update(original).digest('hex')
      assert.equal(await classifyFile(file, digest, original.length), 'pristine')
      fs.appendFileSync(file, '% an update\n%%EOF\n')
      assert.equal(await classifyFile(file, digest, original.length), 'appended')
      fs.writeFileSync(file, '%PDF-1.7\n% somebody else wrote this\n')
      assert.equal(await classifyFile(file, digest, original.length), 'rewritten')
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })
}
