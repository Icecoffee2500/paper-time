/**
 * The library's errands (`WR11`): a record written on two devices at once
 * resolved the Mac's way, the fields the window may patch, a batch import
 * that says what it did, the folders offered on the first screen, and the
 * export's options written the way `BibTeXWriter` writes them.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { PaperMeta } from '../shared/model.js'
import { acceptedMetaPatch } from '../main/records.js'
import { Library } from '../main/library.js'
import { suggestedFolders } from '../main/suggestions.js'
import { DEFAULT_EXPORT, entryFor, formatBibliography, formatEntry } from '../shared/bibtex.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

function meta(confidence: string, updatedAt: string, title = 'x'): PaperMeta {
  return new PaperMeta({ id: 'A', csl: { title }, confidence, updatedAt, addedAt: updatedAt, file: {} })
}

function preprint(): PaperMeta {
  return new PaperMeta({
    id: 'P',
    bibKey: 'chen2024',
    csl: {
      type: 'manuscript', title: 'Diffusion Policy', author: [{ family: 'Chen', given: 'Yi' }],
      issued: { 'date-parts': [[2024, 3]] }, note: 'arXiv:2403.18293 [cs.RO]',
      'container-title': 'Robotics', 'container-title-short': 'Robot.',
    },
    identifiers: { arxiv: '2403.18293', doi: '10.48550/arXiv.2403.18293' },
    confidence: 'verified',
    file: { relativePath: 'p.pdf' },
  })
}

export async function librarySuite(test: Test, suite: (name: string) => void) {
  suite('The library’s errands')

  await test('two writes at once: a hand edit wins, then the surer record, then the newer', () => {
    const early = '2026-01-01T00:00:00Z'
    const late = '2026-06-01T00:00:00Z'
    assert.equal(PaperMeta.resolve(meta('manual', early, 'mine'), meta('verified', late)).csl.title, 'mine')
    assert.equal(PaperMeta.resolve(meta('verified', late), meta('manual', early, 'theirs')).csl.title, 'theirs')
    assert.equal(PaperMeta.resolve(meta('needsReview', late), meta('verified', early, 'surer')).csl.title, 'surer')
    assert.equal(PaperMeta.resolve(meta('unparsed', early), meta('unparsed', late, 'newer')).csl.title, 'newer')
  })

  await test('a record saved over another device’s write is resolved, not overwritten', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-resolve-'))
    try {
      const library = await Library.open(root)
      fs.writeFileSync(path.join(root, 'a.pdf'), '%PDF-1.7\n% a\n')
      const row = (await library.importPDF(path.join(root, 'a.pdf'), 1)).row!
      const baseline = row.meta
      // Another device corrects the title by hand in the meantime.
      const theirs = new PaperMeta(baseline)
      theirs.csl = { ...theirs.csl, title: 'Corrected by hand' }
      theirs.confidence = 'manual'
      await library.saveMeta(theirs)
      // This one, having started from the baseline, writes an automatic result.
      const mine = new PaperMeta(baseline)
      mine.csl = { ...mine.csl, title: 'Guessed' }
      mine.confidence = 'needsReview'
      const written = await library.saveMeta(mine, { baseline })
      assert.equal(written.csl.title, 'Corrected by hand')
      assert.equal((await library.paper(row.id))?.meta.csl && (new PaperMeta((await library.paper(row.id))!.meta)).csl.title, 'Corrected by hand')
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('the window may patch the fields a reader edits, and nothing else', () => {
    const patch = acceptedMetaPatch({
      csl: { title: 't' }, bibKey: 'k', confidence: 'manual', kind: 'book', tagIDs: ['a'], parentID: null,
      file: { relativePath: '../../etc' }, id: 'other', addedAt: 'x', confidence2: 1, collectionIDs: [3],
    })
    assert.deepEqual(Object.keys(patch).sort(), ['bibKey', 'confidence', 'csl', 'kind', 'parentID', 'tagIDs'])
    assert.deepEqual(acceptedMetaPatch({ kind: 'spaceship', confidence: 'certain' }), {})
  })

  await test('a batch of PDFs is read once and says what it did', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-batch-'))
    const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-outside-'))
    try {
      const library = await Library.open(root)
      fs.writeFileSync(path.join(outside, 'one.pdf'), '%PDF-1.7\n% one\n')
      fs.writeFileSync(path.join(outside, 'two.pdf'), '%PDF-1.7\n% two\n')
      fs.copyFileSync(path.join(outside, 'one.pdf'), path.join(outside, 'one again.pdf'))
      const papers = (await library.read()).papers
      const outcomes = []
      for (const name of ['one.pdf', 'two.pdf', 'one again.pdf']) {
        outcomes.push((await library.importPDF(path.join(outside, name), 1, { papers })).outcome)
      }
      assert.deepEqual(outcomes, ['imported', 'imported', 'duplicate'])
      assert.equal(papers.length, 2, 'the batch’s own list kept up to date')
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
      fs.rmSync(outside, { recursive: true, force: true })
    }
  })

  await test('the walk names every folder, the empty ones too, and skips the app’s own', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-walk-'))
    try {
      const library = await Library.open(root)
      for (const name of ['2026/Week 1', '2026/Week 2', 'Empty', 'Trash/old', '.hidden/x']) {
        fs.mkdirSync(path.join(root, name), { recursive: true })
      }
      fs.writeFileSync(path.join(root, '2026/Week 1/a.pdf'), '%PDF-1.7\n% a\n')
      const walked = await library.walkFolder()
      const base = root.replace(/\\/g, '/')
      assert.deepEqual(walked.folders.map((one) => one.slice(base.length + 1)), ['2026', '2026/Week 1', '2026/Week 2', 'Empty'])
      assert.deepEqual(walked.documents.map((one) => path.basename(one)), ['a.pdf'])
      const unclaimed = await library.unclaimedWalk(new Set(['2026/Week 1/a.pdf']))
      assert.deepEqual(unclaimed.files, [])
      assert.deepEqual(unclaimed.folders, walked.folders)
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('the first screen offers the cloud folders this machine keeps', () => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-home-'))
    try {
      for (const name of ['OneDrive - Acme', 'Dropbox', 'Documents', 'Google Drive']) fs.mkdirSync(path.join(home, name))
      const found = suggestedFolders(home, 'win32').map((one) => `${path.basename(one.path)}:${one.provider}`).sort()
      assert.deepEqual(found, ['Dropbox:dropbox', 'Google Drive:googleDrive', 'OneDrive - Acme:oneDrive'])
      fs.mkdirSync(path.join(home, 'Library/CloudStorage/GoogleDrive-me@example.org'), { recursive: true })
      const mac = suggestedFolders(home, 'darwin').map((one) => one.provider)
      assert.deepEqual(mac, ['googleDrive'])
    } finally {
      fs.rmSync(home, { recursive: true, force: true })
    }
  })

  await test('a preprint is written the way the Mac’s options say', () => {
    const eprint = formatEntry(entryFor(preprint()))
    assert.match(eprint, /^@misc\{chen2024,/)
    assert.match(eprint, /eprint {8}= \{2403\.18293\}/)
    assert.match(eprint, /archivePrefix = \{arXiv\}/)
    assert.match(eprint, /primaryClass {2}= \{cs\.RO\}/)
    assert.ok(eprint.includes('= {https://doi.org/10.48550/arXiv.2403.18293}'), 'the DOI as its URL')
    const article = entryFor(preprint(), { ...DEFAULT_EXPORT, preprintStyle: 'arxivPreprintArticle', includeURL: false })
    assert.equal(article.type, 'article')
    assert.equal(article.fields.find((one) => one.name === 'journal')?.value, 'arXiv preprint arXiv:2403.18293')
    assert.equal(article.fields.find((one) => one.name === 'url'), undefined)
    assert.equal(article.fields.find((one) => one.name === 'eprint'), undefined)
    const plain = formatBibliography([preprint()], { ...DEFAULT_EXPORT, includeHeader: false })
    assert.ok(plain.startsWith('@misc'), 'no header when asked for none')
  })
}
