/**
 * The slip-box, as the window keeps it — the Mac's `NotesModel`, the half
 * that is not about files.
 *
 * The notes come with the library (`adoptNotes`), and go back through the
 * main process a note at a time, a moment after the typing stops. What was
 * typed and has not reached the disk yet is newer than what the disk says,
 * and a note that has never been written is not on it at all — read back,
 * it would vanish from under the hand typing it — so those are kept here
 * across a reading (`unwritten`), the way the Mac keeps them.
 */
import type { NoteDTO, NotesFolderDTO } from '../shared/api.js'
import {
  makeZettelID, trimWhitespaceAndNewlines, zettelDisplayTitle, zettelIsEmpty, zettelLinks, zettelTags, type ZettelKind,
} from '../shared/zettel.js'
import { call } from './bridge.js'
import { changed, noteByID, noteDTO, noteFromDTO, store, type Note } from './state.js'

/** Notes changed here and not yet written, by id. */
const unwritten = new Map<string, Note>()
const saveTimers = new Map<string, ReturnType<typeof setTimeout>>()
const SAVE_AFTER_MS = 600

/** In the order they were written, and staying there. */
function sorted(notes: Note[]): Note[] {
  return notes.slice().sort((a, b) =>
    a.created.getTime() === b.created.getTime() ? (a.id < b.id ? -1 : a.id > b.id ? 1 : 0) : a.created.getTime() - b.created.getTime())
}

/** The slip-box as the folders were just read, with what is still in hand laid over it. */
export function adoptNotes(dtos: NoteDTO[] | undefined, folder: NotesFolderDTO | undefined) {
  if (!dtos) return
  const loaded = new Map(dtos.map((dto) => [dto.id, noteFromDTO(dto)]))
  for (const [id, mine] of unwritten) {
    const known = loaded.get(id)
    loaded.set(id, known ? { ...mine, box: known.box } : mine)
  }
  store.notes = sorted([...loaded.values()])
  if (folder) store.notesFolder = folder
}

/** A new note, in hand and not yet on the disk: nobody has typed into it. */
export function createNote(paperID: string | null, kind: ZettelKind = 'note'): Note {
  const now = new Date()
  const note: Note = {
    id: makeZettelID(now, new Set(store.notes.map((one) => one.id))),
    kind, title: '', body: '', paperID, created: now, modified: now, box: '',
  }
  unwritten.set(note.id, note)
  store.notes = sorted([...store.notes, note])
  changed('notes')
  return note
}

/** One note, changed: kept in hand now, written a moment after the typing stops. */
export function updateNote(note: Note) {
  const edited = { ...note, modified: new Date() }
  const at = store.notes.findIndex((one) => one.id === note.id)
  if (at >= 0) store.notes[at] = edited
  else store.notes = sorted([...store.notes, edited])
  unwritten.set(edited.id, edited)
  const waiting = saveTimers.get(edited.id)
  if (waiting) clearTimeout(waiting)
  saveTimers.set(edited.id, setTimeout(() => void write(edited.id), SAVE_AFTER_MS))
  changed('notes')
}

/** Writes a note out now, without waiting for the pause in typing. */
export async function flushNote(id: string) {
  const waiting = saveTimers.get(id)
  if (waiting) clearTimeout(waiting)
  saveTimers.delete(id)
  await write(id)
  // The editor lets go of a note by flushing it, and an empty note let go
  // of is a note nobody wrote: the next reading may drop it, as it always has.
  const note = noteByID(id)
  if (note && zettelIsEmpty(note)) unwritten.delete(id)
}

async function write(id: string) {
  saveTimers.delete(id)
  const note = noteByID(id)
  if (!note) return
  const saved = await call('notes:save', { note: noteDTO(note) })
  const current = noteByID(id)
  if (current) current.box = saved.box
  // Still the same words: what is in hand has reached the disk. An empty
  // note stays in hand — its file went away, and it is still open.
  const held = unwritten.get(id)
  if (held && held.title === note.title && held.body === note.body && !zettelIsEmpty(note)) unwritten.delete(id)
}

export function deleteNote(id: string) {
  const waiting = saveTimers.get(id)
  if (waiting) clearTimeout(waiting)
  saveTimers.delete(id)
  unwritten.delete(id)
  store.notes = store.notes.filter((one) => one.id !== id)
  if (store.noteOpenID === id) store.noteOpenID = null
  if (store.slipBox.openID === id) store.slipBox.openID = null
  void call('notes:delete', { id })
  changed('notes')
}

/** Puts a note on a map — or into a draft — under its last heading. */
export function addToMap(id: string, mapID: string) {
  const map = noteByID(mapID)
  const note = noteByID(id)
  if (!map || !note || map.kind === 'note') return
  if (zettelLinks(map.body).includes(id)) return
  const separator = map.body.length === 0 || map.body.endsWith('\n') ? '' : '\n'
  updateNote({ ...map, body: `${map.body}${separator}- [[${id}|${zettelDisplayTitle(note)}]]\n` })
}

// MARK: - Reading the box

/** What the slip-box browser shows: the box, narrowed by the search field and the chosen tag. */
export function visibleNotes(): Note[] {
  let result = store.notes
  const tag = store.slipBox.tag
  if (tag) result = result.filter((note) => zettelTags(note.body).includes(tag))
  const terms = trimWhitespaceAndNewlines(store.slipBox.query).toLowerCase()
  if (!terms) return result
  return result.filter((note) =>
    zettelDisplayTitle(note).toLowerCase().includes(terms)
    || note.body.toLowerCase().includes(terms)
    || note.id.includes(terms))
}

/** How many notes wear each tag, most worn first. */
export function noteTagCounts(): { tag: string; count: number }[] {
  const counts = new Map<string, number>()
  for (const note of store.notes) {
    for (const tag of zettelTags(note.body)) counts.set(tag, (counts.get(tag) ?? 0) + 1)
  }
  return [...counts]
    .map(([tag, count]) => ({ tag, count }))
    .sort((a, b) => (a.count === b.count ? (a.tag < b.tag ? -1 : 1) : b.count - a.count))
}

/** The notes pointing at this one, newest first. */
export function linkedFrom(id: string): Note[] {
  return store.notes
    .filter((note) => note.id !== id && zettelLinks(note.body).includes(id))
    .sort((a, b) => b.modified.getTime() - a.modified.getTime())
}

/** The notes this one points at, in the order they are mentioned. */
export function linksOut(id: string): Note[] {
  const note = noteByID(id)
  if (!note) return []
  return zettelLinks(note.body).map(noteByID).filter((one): one is Note => Boolean(one))
}

export const maps = (): Note[] => store.notes.filter((note) => note.kind === 'map')
export const drafts = (): Note[] => store.notes.filter((note) => note.kind === 'draft')
