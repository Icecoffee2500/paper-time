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
import type { NoteDTO, NotesFolderDTO, RequestResult } from '../shared/api.js'
import {
  makeZettelID, trimWhitespace, trimWhitespaceAndNewlines, zettelDisplayTitle, zettelIsEmpty, zettelLinks, zettelTags, type ZettelKind,
} from '../shared/zettel.js'
import { call } from './bridge.js'
import { changed, noteByID, noteDTO, noteFromDTO, store, type Note } from './state.js'

/** Notes changed here and not yet written, by id. */
const unwritten = new Map<string, Note>()
const saveTimers = new Map<string, ReturnType<typeof setTimeout>>()
const SAVE_AFTER_MS = 600

/** Told once per note when a write fails — the window says so; the note stays in hand. */
let writeFailed: (id: string, reason: unknown) => void = () => {}
const failedOnce = new Set<string>()
export function onNoteWriteFailed(report: (id: string, reason: unknown) => void) {
  writeFailed = report
}

// MARK: - Indexes

/**
 * Who links to whom and how many notes wear each tag, kept rather than read
 * off every note on every draw (`NotesModel.backlinks`, `tagCounts`): a note
 * being typed changes its words many times a second and its links and tags
 * almost never.
 */
let indexedFor: Note[] | null = null
const linksOf = new Map<string, string[]>()
const tagsOf = new Map<string, string[]>()
let backlinks = new Map<string, Set<string>>()
let tagCounts = new Map<string, number>()

function rebuildIndexes() {
  linksOf.clear()
  tagsOf.clear()
  backlinks = new Map()
  tagCounts = new Map()
  for (const note of store.notes) {
    const links = zettelLinks(note.body)
    const tags = zettelTags(note.body)
    linksOf.set(note.id, links)
    tagsOf.set(note.id, tags)
    for (const target of links) {
      let from = backlinks.get(target)
      if (!from) backlinks.set(target, (from = new Set()))
      from.add(note.id)
    }
    for (const tag of new Set(tags)) tagCounts.set(tag, (tagCounts.get(tag) ?? 0) + 1)
  }
  indexedFor = store.notes
}

/** The indexes, current for `store.notes` — rebuilt only when the box itself was replaced from outside. */
function indexes() {
  if (indexedFor !== store.notes) rebuildIndexes()
  return { backlinks, tagCounts }
}

/** One note's words changed: its links and tags follow only if they did. */
function reindex(before: Note | undefined, after: Note) {
  const current = indexedFor
  if (!current) return
  const links = zettelLinks(after.body)
  const tags = zettelTags(after.body)
  const oldLinks = linksOf.get(after.id) ?? (before ? zettelLinks(before.body) : [])
  const oldTags = tagsOf.get(after.id) ?? (before ? zettelTags(before.body) : [])
  const same = (a: string[], b: string[]) => a.length === b.length && a.every((one, index) => one === b[index])
  if (!same(links, oldLinks)) {
    for (const target of oldLinks) backlinks.get(target)?.delete(after.id)
    for (const target of links) {
      let from = backlinks.get(target)
      if (!from) backlinks.set(target, (from = new Set()))
      from.add(after.id)
    }
    linksOf.set(after.id, links)
  }
  if (!same(tags, oldTags)) {
    for (const tag of new Set(oldTags)) {
      const left = (tagCounts.get(tag) ?? 1) - 1
      if (left > 0) tagCounts.set(tag, left)
      else tagCounts.delete(tag)
    }
    for (const tag of new Set(tags)) tagCounts.set(tag, (tagCounts.get(tag) ?? 0) + 1)
    tagsOf.set(after.id, tags)
  }
}

/** Whether a change of one note moved its links or its tags — what the lists beside it draw from. */
export function linksOrTagsChanged(before: Pick<Note, 'body'>, after: Pick<Note, 'body'>): boolean {
  const a = zettelLinks(before.body), b = zettelLinks(after.body)
  const c = zettelTags(before.body), d = zettelTags(after.body)
  return a.join('\u0000') !== b.join('\u0000') || c.join('\u0000') !== d.join('\u0000')
}

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

/**
 * One note, changed: kept in hand now, written a moment after the typing stops.
 *
 * `store.notes` is replaced, never changed in place — like every list in the
 * store, whoever holds the old array holds what was true when they looked.
 */
export function updateNote(note: Note) {
  const edited = { ...note, modified: new Date() }
  const at = store.notes.findIndex((one) => one.id === note.id)
  const before = at >= 0 ? store.notes[at] : undefined
  const indexed = indexedFor === store.notes
  store.notes = at >= 0
    ? [...store.notes.slice(0, at), edited, ...store.notes.slice(at + 1)]
    : sorted([...store.notes, edited])
  // The same box with one note changed: the indexes move with it rather
  // than being read again off every note.
  if (indexed) {
    indexedFor = store.notes
    reindex(before, edited)
  }
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
  // of is a note nobody wrote: it leaves the box now, rather than standing
  // in the list as an untitled row until the library is read again.
  const note = noteByID(id)
  if (note && zettelIsEmpty(note)) {
    unwritten.delete(id)
    store.notes = store.notes.filter((one) => one.id !== id)
    changed('notes')
  }
}

async function write(id: string) {
  saveTimers.delete(id)
  const note = noteByID(id)
  if (!note) return
  let saved: RequestResult<'notes:save'>
  try {
    saved = await call('notes:save', { note: noteDTO(note) })
  } catch (reason) {
    // Kept in hand (`unwritten`), and written with the next change or the
    // next reading — said once per note, not once a keystroke.
    if (!failedOnce.has(id)) {
      failedOnce.add(id)
      writeFailed(id, reason)
    }
    return
  }
  failedOnce.delete(id)
  // Which box it went into, on a new copy of the note — see `updateNote`.
  const at = store.notes.findIndex((one) => one.id === id)
  if (at >= 0 && store.notes[at].box !== saved.box) {
    store.notes = [...store.notes.slice(0, at), { ...store.notes[at], box: saved.box }, ...store.notes.slice(at + 1)]
  }
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
  for (const [paperID, open] of store.noteOpenByPaper) if (open === id) store.noteOpenByPaper.delete(paperID)
  if (store.slipBox.openID === id) store.slipBox.openID = null
  void call('notes:delete', { id }).catch((reason: unknown) => writeFailed(id, reason))
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
  if (tag) {
    indexes()
    result = result.filter((note) => (tagsOf.get(note.id) ?? zettelTags(note.body)).includes(tag))
  }
  const terms = trimWhitespaceAndNewlines(store.slipBox.query).toLowerCase()
  if (!terms) return result
  return result.filter((note) =>
    zettelDisplayTitle(note).toLowerCase().includes(terms)
    || note.body.toLowerCase().includes(terms)
    || note.id.includes(terms))
}

/** How many notes wear each tag, most worn first. */
export function noteTagCounts(): { tag: string; count: number }[] {
  return [...indexes().tagCounts]
    .map(([tag, count]) => ({ tag, count }))
    .sort((a, b) => (a.count === b.count ? (a.tag < b.tag ? -1 : 1) : b.count - a.count))
}

/** The notes pointing at this one, newest first. */
export function linkedFrom(id: string): Note[] {
  return [...(indexes().backlinks.get(id) ?? [])]
    .filter((from) => from !== id)
    .map(noteByID)
    .filter((one): one is Note => Boolean(one))
    .sort((a, b) => b.modified.getTime() - a.modified.getTime())
}

/**
 * The notes a `[[` could link to — the title or the identifier holds what is
 * typed after it — eight at most, never the note being written
 * (`NotesModel.suggestions(matching:excluding:)`).
 */
export function noteSuggestions(text: string, excluding: string | null): Note[] {
  const terms = trimWhitespace(text).toLowerCase()
  const candidates = store.notes.filter((note) => note.id !== excluding)
  if (!terms) return candidates.slice(0, 8)
  return candidates
    .filter((note) => zettelDisplayTitle(note).toLowerCase().includes(terms) || note.id.includes(terms))
    .slice(0, 8)
}

/** The notes this one points at, in the order they are mentioned. */
export function linksOut(id: string): Note[] {
  const note = noteByID(id)
  if (!note) return []
  return zettelLinks(note.body).map(noteByID).filter((one): one is Note => Boolean(one))
}

export const maps = (): Note[] => store.notes.filter((note) => note.kind === 'map')
export const drafts = (): Note[] => store.notes.filter((note) => note.kind === 'draft')
