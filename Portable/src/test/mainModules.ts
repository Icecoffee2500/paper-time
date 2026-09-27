/**
 * The main process's modules, each on its own: the journals, the PDF write
 * queue, what a changed path means, the library set, the vocabulary, the
 * record queue (`WR3`). Real folders, made and thrown away.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { Journals } from '../main/journal.js'
import { PDFFlusher, renameHeld, sweepTemporaries, type FlushResult } from '../main/pdfFlush.js'
import { classifyChange } from '../main/folderSync.js'
import { forgetOwnWrites, isOwnWrite, noteOwnWrite } from '../main/ownWrites.js'
import { watchLibrary } from '../main/watcher.js'
import { Library, readJSON, writeJSON } from '../main/library.js'
import { Records } from '../main/records.js'
import { collectionsByFolder, mergeVocabulary, missingVocabulary } from '../main/vocabulary.js'
import * as L from '../main/layout.js'
import type { Journal } from '../shared/markJournal.js'
import type { PageCounter } from '../main/pdfBytes.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))
const temp = (name: string) => fs.mkdtempSync(path.join(os.tmpdir(), `papertime-${name}-`))
const PDF = '%PDF-1.7\ntrailer<<>>\nstartxref\n9\n%%EOF\n'

const mark = (id: string, text = 'words') => ({
  id, kind: 'highlight' as const, quads: [[72, 311, 322, 311, 72, 300, 322, 300]], color: [1, 0.84, 0.25] as [number, number, number], text,
})

export async function mainModulesSuite(test: Test, suite: (name: string) => void) {
  suite('The main process, module by module')

  await test('a journal is written a little after the change, and at once when flushed', async () => {
    const root = temp('journal')
    try {
      const journals = new Journals({ device: 'Win-TEST0001', platformName: 'Windows', writeDelay: 50 })
      const pages = { 0: [mark('A')] }
      assert.ok(await journals.record('P', root, 0, [], pages[0], pages))
      const file = L.marksPath(root, 'P', 'Win-TEST0001')
      assert.ok(!fs.existsSync(file), 'not written yet')
      await wait(120)
      const written = (await readJSON(file)) as unknown as Journal
      assert.equal(written.device, 'Win-TEST0001')
      assert.equal(Object.keys(written.entries).length, 1)
      // A second change waits again; flush does not.
      pages[0] = [mark('A'), mark('B')]
      await journals.record('P', root, 0, [mark('A')], pages[0], pages)
      await journals.flush()
      assert.equal(Object.keys(((await readJSON(file)) as unknown as Journal).entries).length, 2)
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('two marks before the first read of the journal both survive', async () => {
    const root = temp('journal2')
    try {
      const journals = new Journals({ device: 'Win-TEST0002', platformName: 'Windows', writeDelay: 10 })
      // On disk already: a mark from an earlier run.
      await writeJSON(L.marksPath(root, 'P', 'Win-TEST0002'), {
        device: 'Win-TEST0002', name: 'Windows', updated: '2026-09-27T00:00:00Z',
        entries: { OLD: { pageIndex: 0, at: '2026-09-27T00:00:00Z' } },
      })
      const a = journals.record('P', root, 0, [], [mark('A')], { 0: [mark('A')] })
      const b = journals.record('P', root, 1, [], [mark('B')], { 0: [mark('A')], 1: [mark('B')] })
      await Promise.all([a, b])
      await journals.flush()
      const written = (await readJSON(L.marksPath(root, 'P', 'Win-TEST0002'))) as unknown as Journal
      assert.deepEqual(Object.keys(written.entries).sort(), ['A', 'B', 'OLD'])
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('a write the file refused is tried three times, then the reader is told', async () => {
    const events: unknown[] = []
    let tries = 0
    let held = true
    const flusher = new PDFFlusher({
      ownerOf: async () => null,
      journals: new Journals(),
      pageCounter: {} as PageCounter,
      send: (event, payload) => events.push([event, payload]),
      write: async (): Promise<FlushResult> => {
        tries += 1
        return held ? { error: 'EBUSY' } : { written: 1 }
      },
      delays: { write: 5, retry: [5, 5, 5] },
    })
    flusher.schedule('P')
    await wait(120)
    assert.equal(tries, 4)
    assert.deepEqual(events, [['paper:kept', { id: 'P', reason: 'io' }]])
    // The next change starts afresh, and a file let go of takes it.
    held = false
    flusher.schedule('P')
    await wait(30)
    assert.equal(tries, 5)
    flusher.forget('P')
  })

  await test('a file that moved under the save is written again on top', async () => {
    let tries = 0
    const flusher = new PDFFlusher({
      ownerOf: async () => null,
      journals: new Journals(),
      pageCounter: {} as PageCounter,
      send: () => {},
      write: async (): Promise<FlushResult> => {
        tries += 1
        return tries === 1 ? { retry: 'moved' } : { written: 1 }
      },
      delays: { write: 5, retry: [5, 5, 5] },
    })
    flusher.schedule('P')
    await wait(40)
    assert.equal(tries, 2)
  })

  await test('draining writes what is waiting now', async () => {
    let written = 0
    const flusher = new PDFFlusher({
      ownerOf: async () => null,
      journals: new Journals(),
      pageCounter: {} as PageCounter,
      send: () => {},
      write: async (): Promise<FlushResult> => {
        written += 1
        return { written: 1 }
      },
      delays: { write: 10_000, retry: [5] },
    })
    flusher.schedule('A')
    flusher.schedule('B')
    assert.ok(flusher.busy('A'))
    await flusher.drain()
    assert.equal(written, 2)
    assert.ok(!flusher.busy('A'))
  })

  await test('a rename over a held file is tried again', async () => {
    let calls = 0
    await renameHeld('a', 'b', async () => {
      calls += 1
      if (calls < 3) throw Object.assign(new Error('busy'), { code: 'EBUSY' })
    }, [1, 1, 1, 1])
    assert.equal(calls, 3)
    await assert.rejects(renameHeld('a', 'b', async () => {
      throw Object.assign(new Error('no'), { code: 'ENOENT' })
    }, [1]))
  })

  await test('a temporary copy an interrupted write left is swept, a fresh one is not', async () => {
    const root = temp('sweep')
    try {
      const paper = path.join(root, 'a.pdf')
      fs.writeFileSync(paper, PDF)
      const old = path.join(root, 'a.pdf.1234.tmp')
      const fresh = path.join(root, 'a.pdf.1235.tmp')
      fs.writeFileSync(old, 'x')
      fs.writeFileSync(fresh, 'x')
      const past = new Date(Date.now() - 60 * 60_000)
      fs.utimesSync(old, past, past)
      const removed = await sweepTemporaries([paper])
      assert.deepEqual(removed, [old])
      assert.ok(fs.existsSync(fresh))
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('what a changed path means to the library', () => {
    const root = 'D:\\Papers'
    const at = (rest: string) => classifyChange(root, `D:\\Papers\\${rest}`)
    assert.deepEqual(at('x.pdf'), { kind: 'pdf' })
    assert.deepEqual(at('2026\\week 1\\x.pdf'), { kind: 'pdf' })
    assert.deepEqual(at('x.pdf.123.tmp'), { kind: 'ignore' })
    assert.deepEqual(at('x.pdf.part'), { kind: 'ignore' })
    assert.deepEqual(at('.papertime\\papers\\ID\\meta.json'), { kind: 'record', id: 'ID' })
    assert.deepEqual(at('.papertime\\papers\\ID\\marks\\Mac-1.json'), { kind: 'sidecar', id: 'ID', layer: 'marks' })
    assert.deepEqual(at('.papertime\\papers\\ID\\ink\\p0001.json'), { kind: 'sidecar', id: 'ID', layer: 'ink' })
    assert.deepEqual(at('.papertime\\notes\\202609270900.md'), { kind: 'notes' })
    assert.deepEqual(at('.papertime\\library.json'), { kind: 'vocabulary' })
    assert.deepEqual(at('Trash\\x.pdf'), { kind: 'ignore' })
    assert.deepEqual(classifyChange(root, null), { kind: 'unknown' })
  })

  await test('a write of our own is not a change; a stranger\'s is', async () => {
    forgetOwnWrites()
    const root = temp('own')
    try {
      await writeJSON(path.join(root, '.papertime', 'papers', 'ID', 'meta.json'), { id: 'ID' })
      assert.ok(isOwnWrite(path.join(root, '.papertime', 'papers', 'ID', 'meta.json')))
      assert.ok(isOwnWrite(path.join(root, '.papertime/papers/ID/META.json'.replace(/\//g, path.sep))) === (process.platform !== 'linux'))
      assert.ok(!isOwnWrite(path.join(root, 'other.pdf')))
      noteOwnWrite('/x/y.pdf', 0)
      assert.ok(!isOwnWrite('/x/y.pdf'), 'an old note has expired')
    } finally {
      forgetOwnWrites()
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('the watcher says which file changed', async () => {
    const root = temp('watch')
    try {
      const seen: (string | null)[][] = []
      const stop = watchLibrary(root, (changed) => seen.push(changed))
      await wait(100)
      fs.writeFileSync(path.join(root, 'new.pdf'), PDF)
      await wait(700)
      stop()
      assert.ok(seen.length >= 1, 'the change was noticed')
      const named = seen.flat().filter((one): one is string => one !== null)
      assert.ok(named.some((one) => path.basename(one) === 'new.pdf'), JSON.stringify(seen))
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('the vocabulary merges by id and each folder is given what its papers wear', () => {
    const tagA = { id: 'T1', name: 'vla', colorName: 'blue' } as never
    const collection = { id: 'C1', name: 'Reading', symbolName: 'folder', sortIndex: 0 } as never
    const folders = [
      { root: 'A', tags: [tagA], collections: [collection] },
      { root: 'B', tags: [], collections: [] },
    ]
    const merged = mergeVocabulary(folders)
    assert.equal(merged.tags.length, 1)
    assert.equal(merged.collections.length, 1)
    const missing = missingVocabulary([
      { root: 'A', tagIDs: ['T1'], collectionIDs: [] },
      { root: 'B', tagIDs: ['T1'], collectionIDs: ['C1'] },
    ], folders, merged)
    assert.deepEqual(missing.map((one) => [one.root, one.tags.length, one.collections.length]), [['B', 1, 1]])
    // A new collection goes into the folder being looked at.
    const fresh = { id: 'C2', name: 'New', symbolName: 'folder', sortIndex: 1 } as never
    const plan = collectionsByFolder([collection, fresh], [{ root: 'A', ids: new Set(['C1']) }, { root: 'B', ids: new Set() }], 'B')
    assert.deepEqual(plan.map((one) => [one.root, one.collections.map((c: { id: string }) => c.id)]), [['A', ['C1']], ['B', ['C2']]])
    const plainly = collectionsByFolder([collection, fresh], [{ root: 'A', ids: new Set(['C1']) }, { root: 'B', ids: new Set() }], 'nowhere')
    assert.deepEqual(plainly.map((one) => [one.root, one.collections.map((c: { id: string }) => c.id)]), [['A', ['C1', 'C2']]])
  })

  await test('two patches to one record both land, and a guess never stamps it', async () => {
    const root = temp('records')
    try {
      fs.writeFileSync(path.join(root, 'a.pdf'), PDF)
      const library = new Library(root)
      const row = (await library.importPDF(path.join(root, 'a.pdf'), 1))!
      const records = new Records()
      await Promise.all([
        records.state(library, row.id, { isFavorite: true }),
        records.state(library, row.id, { rating: 4 }),
      ])
      const state = (await readJSON(L.statePath(root, row.id)))!
      assert.equal(state.isFavorite, true)
      assert.equal(state.rating, 4)
      const before = (await readJSON(L.metaPath(root, row.id)))!
      const guessed = await records.meta(library, row.id, { guessedKind: 'document' }, { stamp: false })
      assert.equal(guessed?.guessedKind, 'document')
      const after = (await readJSON(L.metaPath(root, row.id)))!
      assert.equal(after.updatedAt, before.updatedAt, 'a guess does not stamp the record')
      // A second guess does not overrule the first.
      await records.meta(library, row.id, { guessedKind: 'paper' }, { stamp: false })
      assert.equal((await readJSON(L.metaPath(root, row.id)))!.guessedKind, 'document')
      // The reader's answer does stamp it — by this device, now.
      await records.meta(library, row.id, { kind: 'book' })
      const answered = (await readJSON(L.metaPath(root, row.id)))!
      assert.equal(answered.kind, 'book')
      assert.ok(String(answered.updatedAt) >= String(before.updatedAt))
      assert.equal(typeof answered.updatedBy, 'string')
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })
}
