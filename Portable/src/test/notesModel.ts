/**
 * The slip-box as the window keeps it (`renderer/notesModel.ts`), with the
 * main process stood in for (`setInvoke`): notes are replaced rather than
 * changed in place, an empty note let go of leaves the box, and what is in
 * hand survives a reading.
 */
import assert from 'node:assert/strict'
import { setInvoke } from '../renderer/bridge.js'
import {
  adoptNotes, createNote, flushNote, linkedFrom, moveNoteToArea, noteAreas, noteSuggestions, noteTagCounts, onNoteWriteFailed,
  removeArea, renameArea, slipBoxList, slipBoxShows, updateNote,
} from '../renderer/notesModel.js'
import { latestNoteForPaper, noteByID, notesForPaper, store } from '../renderer/state.js'
import type { NoteDTO } from '../shared/api.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

export async function notesModelSuite(test: Test, suite: (name: string) => void) {
  suite('The window’s slip-box')
  const saved: NoteDTO[] = []
  setInvoke(async (name, args) => {
    if (name === 'notes:save') {
      const note = (args as { note: NoteDTO }).note
      saved.push(note)
      return { ...note, box: '/lib' }
    }
    return null
  })

  await test('an edit replaces the list, and the note is written with the box it went into', async () => {
    store.notes = []
    const note = createNote('P1')
    const before = store.notes
    updateNote({ ...note, title: 'Idea', body: 'A thought.' })
    assert.notEqual(store.notes, before, 'the list is a new array')
    assert.equal(before.find((one) => one.id === note.id)?.title, '', 'the old array still says what it said')
    await flushNote(note.id)
    assert.equal(saved.at(-1)?.title, 'Idea')
    assert.equal(noteByID(note.id)?.box, '/lib')
  })

  await test('an empty note let go of leaves the box', async () => {
    store.notes = []
    const note = createNote(null)
    assert.ok(noteByID(note.id))
    await flushNote(note.id)
    assert.equal(noteByID(note.id), undefined)
  })

  await test('what is typed and not yet written survives a reading of the folders', async () => {
    store.notes = []
    const note = createNote('P2')
    updateNote({ ...note, body: 'Still typing' })
    // The folder is read before the write: the disk does not have it yet.
    adoptNotes([], undefined)
    assert.equal(noteByID(note.id)?.body, 'Still typing')
    await flushNote(note.id)
    adoptNotes([], undefined)
    assert.equal(noteByID(note.id), undefined, 'written, it is the disk’s to say')
  })

  await test('links and tags are kept as indexes that follow each edit', async () => {
    store.notes = []
    const a = createNote(null)
    const b = createNote(null)
    updateNote({ ...noteByID(a.id)!, title: 'A', body: 'about #ml' })
    updateNote({ ...noteByID(b.id)!, title: 'B', body: `see [[${a.id}|A]] #ml #rl` })
    assert.deepEqual(linkedFrom(a.id).map((one) => one.id), [b.id])
    assert.deepEqual(noteTagCounts(), [{ tag: 'ml', count: 2 }, { tag: 'rl', count: 1 }])
    updateNote({ ...noteByID(b.id)!, body: 'no link now #rl' })
    assert.deepEqual(linkedFrom(a.id), [])
    assert.deepEqual(noteTagCounts(), [{ tag: 'ml', count: 1 }, { tag: 'rl', count: 1 }])
    // The box replaced from outside is read again.
    adoptNotes([], undefined)
    store.notes = store.notes.filter((one) => one.id !== b.id)
    assert.deepEqual(noteTagCounts(), [{ tag: 'ml', count: 1 }])
    await flushNote(a.id)
    await flushNote(b.id)
  })

  await test('a [[ offers the notes whose title or identifier holds the words, never the one being written', () => {
    store.notes = []
    const one = createNote(null)
    const two = createNote(null)
    updateNote({ ...noteByID(one.id)!, title: 'Entropy and forgetting' })
    updateNote({ ...noteByID(two.id)!, title: 'Orthogonal gradients' })
    assert.deepEqual(noteSuggestions('entropy', null).map((note) => note.id), [one.id])
    assert.deepEqual(noteSuggestions('', one.id).map((note) => note.id), [two.id])
    assert.deepEqual(noteSuggestions(two.id, null).map((note) => note.id), [two.id])
  })

  await test('⌘L carries on with the note last written in, and the tab lists them as written', () => {
    store.notes = []
    const first = createNote('P9')
    const second = createNote('P9')
    updateNote({ ...noteByID(second.id)!, body: 'second' })
    updateNote({ ...noteByID(first.id)!, body: 'first, edited later' })
    assert.deepEqual(notesForPaper('P9').map((note) => note.id), [first.id, second.id])
    assert.equal(latestNoteForPaper('P9')?.id, first.id)
  })

  await test('a write the disk refuses keeps the note in hand and is said once', async () => {
    store.notes = []
    const told: string[] = []
    onNoteWriteFailed((id) => told.push(id))
    setInvoke(async (name) => {
      if (name === 'notes:save') throw new Error('EPERM: operation not permitted, rename')
      return null
    })
    const note = createNote('P3')
    updateNote({ ...note, body: 'Kept' })
    await flushNote(note.id)
    updateNote({ ...noteByID(note.id)!, body: 'Kept, and more' })
    await flushNote(note.id)
    assert.deepEqual(told, [note.id], 'said once, not once a save')
    adoptNotes([], undefined)
    assert.equal(noteByID(note.id)?.body, 'Kept, and more', 'still in hand after a reading')
    onNoteWriteFailed(() => undefined)
  })

  await test('a note is filed in an area, the editor never decides where, and each place lists what it holds', async () => {
    store.notes = []
    store.slipBox.query = ''
    store.slipBox.tag = null
    store.settings.literatureNoteKind = ''
    store.settings.slipBoxNoteOrder = 'edited'
    store.notesFolder = { loose: '/box', chosen: false, chosenPath: null, appFolder: '/box', away: false, leftBehind: [], areas: ['통계'] }
    const written: NoteDTO[] = []
    setInvoke(async (name, args) => {
      if (name === 'notes:save') {
        const note = (args as { note: NoteDTO }).note
        written.push(note)
        return { ...note, box: '/box' }
      }
      if (name === 'notes:renameArea') return { area: 'Stats', notesFolder: { ...store.notesFolder!, areas: ['Stats'] } }
      if (name === 'notes:removeArea') {
        const last = written.at(-1)!
        return { moved: 1, notes: [{ ...last, area: '' }], notesFolder: { ...store.notesFolder!, areas: [] } }
      }
      return null
    })
    const mine = createNote(null, 'note', '통계')
    assert.equal(mine.area, '통계')
    const literature = createNote('P-not-here', 'note', '통계')
    assert.equal(literature.area, '', 'a literature note lives beside its paper, in no area')
    updateNote({ ...noteByID(mine.id)!, body: 'Bayes' })
    await flushNote(mine.id)
    assert.equal(written.at(-1)?.area, '통계')
    await moveNoteToArea(mine.id, '')
    assert.equal(written.at(-1)?.area, '')
    // The editor still holds the note as it was opened; its copy does not move it back.
    updateNote({ ...mine, body: 'Bayes, edited' })
    await flushNote(mine.id)
    assert.equal(written.at(-1)?.area, '')
    await moveNoteToArea(mine.id, '통계')
    // The places: 지식 in an area and all of it, 문헌 노트 by the source's kind.
    assert.deepEqual(slipBoxList({ kind: 'knowledge', area: '통계' }).map((note) => note.id), [mine.id])
    assert.deepEqual(slipBoxList({ kind: 'knowledge', area: '' }).map((note) => note.id), [])
    assert.deepEqual(slipBoxList({ kind: 'notes' }).map((note) => note.id), [literature.id])
    store.settings.literatureNoteKind = 'book'
    assert.deepEqual(slipBoxList({ kind: 'notes' }), [], 'a paper no longer here counts as a paper')
    assert.equal(slipBoxShows({ kind: 'notes' }, noteByID(literature.id), { narrowed: true }), false)
    assert.equal(slipBoxShows({ kind: 'notes' }, noteByID(literature.id), { narrowed: false }), true)
    store.settings.literatureNoteKind = ''
    assert.equal(slipBoxShows({ kind: 'knowledge', area: null }, noteByID(mine.id), { narrowed: false }), true)
    assert.equal(slipBoxShows({ kind: 'notes' }, noteByID(mine.id), { narrowed: false }), false)
    // Renamed: the note's area follows, and so does the list of areas.
    await renameArea('통계', 'Stats')
    assert.equal(noteByID(mine.id)?.area, 'Stats')
    assert.deepEqual(noteAreas(), ['Stats'])
    // Taken away: the note goes up a level, never away.
    await removeArea('Stats')
    assert.equal(noteByID(mine.id)?.area, '')
    assert.deepEqual(noteAreas(), [])
    store.notesFolder = null
  })

  setInvoke(() => Promise.reject(new Error('No window to ask.')))
}
