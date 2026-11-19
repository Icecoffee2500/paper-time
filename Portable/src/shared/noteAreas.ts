/**
 * The slip-box's places (1.1, 2026-11-18): 문헌 노트 — the notes written
 * against a paper, a book or a document — and 지식, the notes of no paper,
 * filed in areas that are folders under the notes folder. The names follow
 * the Zettelkasten's own: a literature note is about a source, and the
 * knowledge is what was written in one's own words.
 *
 * The port of the Mac's `KnowledgeArea`, `NoteOrder` and the reading half of
 * `NotesModel`'s areas (`knowledge`, `literature`, `knowledge(in:)`). Pure,
 * so both processes and the tests read the same rules: the main process
 * files the notes (`main/slipBox.ts`), the window lists them.
 *
 * An area is a path of folder names joined by `/` on every desktop —
 * «통계/추정» is a folder in a folder — whatever the desktop's own
 * separator is: the same text the Mac keeps.
 */
import { L, prefersKorean } from './lang.js'
import { standardOrder } from './authorKey.js'
import { trimWhitespaceAndNewlines, zettelDisplayTitle, type Zettel } from './zettel.js'

/**
 * How deep areas go: a folder in a folder in a folder is as far as anybody
 * files thoughts, and a walk with no floor is a walk that can be led round a
 * link for ever (`LooseNotes.deepest`).
 */
export const DEEPEST_AREA = 6

/** The last folder of an area's path. */
export function areaName(area: string): string {
  const parts = area.split('/').filter(Boolean)
  return parts[parts.length - 1] ?? area
}

/** How deep an area sits: one for an area at the top. */
export function areaDepth(area: string): number {
  return area.split('/').filter(Boolean).length
}

/** The area an area is in, or '' for the top. */
export function areaParent(area: string): string {
  return area.split('/').filter(Boolean).slice(0, -1).join('/')
}

/**
 * What a knowledge shelf is called: «지식» for all of it, «분류 안 함» for
 * the notes filed in no area, an area by its own (last) name.
 */
export function areaTitle(area: string | null): string {
  if (area === null) return L('지식', 'Knowledge')
  if (area === '') return L('분류 안 함', 'Unfiled')
  return areaName(area)
}

/**
 * Whether a name can be an area's — one folder's name, not a path
 * (`LooseNotes.isAreaName`): not blank, not hidden, no `/` or `:`. On
 * Windows the names Windows refuses for a folder are refused here too — a
 * `\` would make a folder in a folder, and `CON` is no folder at all.
 */
export function isAreaName(name: string, platform: string = 'darwin'): boolean {
  const trimmed = trimWhitespaceAndNewlines(name)
  if (trimmed.length === 0 || trimmed.startsWith('.') || /[/:]/.test(trimmed)) return false
  if (platform !== 'win32') return true
  // eslint-disable-next-line no-control-regex
  if (/[\\*?"<>|\u0000-\u001f]/.test(trimmed) || /[. ]$/.test(trimmed)) return false
  return !/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)/i.test(trimmed)
}

/**
 * What the name sheet says under a name it will not take — or null when it
 * takes it, or when the field is empty (an empty field greys the button and
 * says nothing). The Mac's sheet says it for a `/` and a leading dot.
 */
export function areaNameProblem(name: string, platform: string = 'darwin'): string | null {
  const trimmed = trimWhitespaceAndNewlines(name)
  if (trimmed.length === 0 || isAreaName(trimmed, platform)) return null
  if (platform === 'win32') {
    if (/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)/i.test(trimmed)) {
      return L('Windows가 쓰는 이름이라 영역 이름으로 쓸 수 없어요.', 'Windows keeps that name for itself.')
    }
    return L('이름에 \\ / : * ? " < > |를 넣거나 .으로 시작하거나 끝낼 수 없어요.', 'A name can’t contain \\ / : * ? " < > |, or start or end with a dot.')
  }
  if (trimmed.includes('/') || trimmed.startsWith('.')) {
    return L('이름에 /를 넣거나 .으로 시작할 수 없어요.', 'A name can’t contain / or start with a dot.')
  }
  return L('이름에 :를 넣을 수 없어요.', 'A name can’t contain a colon.')
}

/** An area renamed: the same parent, the new last name. */
export function renamedArea(area: string, name: string): string {
  const parent = areaParent(area)
  const trimmed = trimWhitespaceAndNewlines(name)
  return parent ? `${parent}/${trimmed}` : trimmed
}

/** Where a note filed in `area` is after `from` became `to` — or null when it is not under `from`. */
export function areaAfterRename(area: string, from: string, to: string): string | null {
  if (area === from) return to
  if (area.startsWith(`${from}/`)) return to + area.slice(from.length)
  return null
}

/**
 * The areas in Finder's order (`localizedStandardCompare`), a folder before
 * the folders inside it and those right after it — compared a name at a
 * time, so «A-C» does not land between «A» and «A/B».
 */
export function sortAreas(areas: readonly string[]): string[] {
  return [...areas].sort((a, b) => {
    const left = a.split('/')
    const right = b.split('/')
    for (let at = 0; at < Math.min(left.length, right.length); at += 1) {
      const order = standardOrder.compare(left[at], right[at])
      if (order !== 0) return order
      if (left[at] !== right[at]) return left[at] < right[at] ? -1 : 1
    }
    return left.length - right.length
  })
}

// MARK: - Which notes a place holds

/** The notes about no paper — the slip-box's 지식. */
export function knowledgeNotes<T extends Pick<Zettel, 'paperID'>>(notes: readonly T[]): T[] {
  return notes.filter((note) => !note.paperID)
}

/** The notes written against a paper, a book or a document — 문헌 노트. */
export function literatureNotes<T extends Pick<Zettel, 'paperID'>>(notes: readonly T[]): T[] {
  return notes.filter((note) => Boolean(note.paperID))
}

/** The knowledge in an area and the areas inside it; null is every area, '' the notes filed in none. */
export function knowledgeIn<T extends Pick<Zettel, 'paperID' | 'area'>>(notes: readonly T[], area: string | null): T[] {
  const knowledge = knowledgeNotes(notes)
  if (area === null) return knowledge
  if (area === '') return knowledge.filter((note) => !note.area)
  return knowledge.filter((note) => note.area === area || note.area.startsWith(`${area}/`))
}

// MARK: - The order a list of notes is in

export type NoteOrder = 'edited' | 'created' | 'title'
export const NOTE_ORDERS: readonly NoteOrder[] = ['edited', 'created', 'title']

export function noteOrderFrom(raw: unknown): NoteOrder {
  return raw === 'created' || raw === 'title' ? raw : 'edited'
}

export function noteOrderLabel(order: NoteOrder): string {
  switch (order) {
    case 'edited': return L('최근에 고친 순', 'Recently Edited')
    case 'created': return L('최근에 쓴 순', 'Recently Written')
    case 'title': return L('이름 순', 'Name')
  }
}

/** The notes in an order: the last edited first, the last written first, or by name. */
export function sortNotes<T extends Pick<Zettel, 'id' | 'title' | 'body' | 'created' | 'modified'>>(notes: readonly T[], order: NoteOrder): T[] {
  const newestFirst = (a: Date, b: Date, x: string, y: string) =>
    a.getTime() === b.getTime() ? (x > y ? -1 : x < y ? 1 : 0) : b.getTime() - a.getTime()
  switch (order) {
    case 'edited': return [...notes].sort((a, b) => newestFirst(a.modified, b.modified, a.id, b.id))
    case 'created': return [...notes].sort((a, b) => newestFirst(a.created, b.created, a.id, b.id))
    case 'title': return [...notes].sort((a, b) => standardOrder.compare(zettelDisplayTitle(a), zettelDisplayTitle(b)))
  }
}

/** «14:20» today, «11월 18일» this year, the full date before that (`SlipNoteRow.when`). */
export function noteDateText(date: Date, now: Date = new Date()): string {
  const locale = prefersKorean() ? 'ko' : 'en'
  const sameDay = date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth() && date.getDate() === now.getDate()
  if (sameDay) return date.toLocaleTimeString(locale, { hour: 'numeric', minute: '2-digit' })
  if (date.getFullYear() === now.getFullYear()) return date.toLocaleDateString(locale, { month: 'short', day: 'numeric' })
  return date.toLocaleDateString(locale, { year: 'numeric', month: 'numeric', day: 'numeric' })
}

/**
 * A literature note turned into knowledge: a new note of one's own that
 * starts with the way back to its source (`SlipNoteMenu.rewriteAsKnowledge`).
 * The label keeps the link's own two marks out of it.
 */
export function rewrittenAsKnowledge(source: Pick<Zettel, 'id' | 'title' | 'body'>): string {
  const label = zettelDisplayTitle(source).replaceAll(']', '').replaceAll('|', ' ')
  return L(`출처: [[${source.id}|${label}]]\n\n`, `From: [[${source.id}|${label}]]\n\n`)
}
