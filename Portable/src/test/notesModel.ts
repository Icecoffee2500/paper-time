/**
 * The slip-box as the window keeps it (`renderer/notesModel.ts`), with the
 * main process stood in for (`setInvoke`): notes are replaced rather than
 * changed in place, an empty note let go of leaves the box, and what is in
 * hand survives a reading.
 */
import assert from 'node:assert/strict'
import { setInvoke } from '../renderer/bridge.js'
import { adoptNotes, createNote, flushNote, updateNote } from '../renderer/notesModel.js'
import { noteByID, store } from '../renderer/state.js'
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

  setInvoke(() => Promise.reject(new Error('No window to ask.')))
}
