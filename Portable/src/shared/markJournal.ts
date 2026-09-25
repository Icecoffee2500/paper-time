/**
 * The marks journal, in the shape the Mac reads — the port of
 * `MarkJournal.swift`.
 *
 * Each device keeps one file per paper, `.papertime/papers/<id>/marks/
 * <device>.json`, naming every mark it made, changed or took away and when.
 * Every device reads all of them, lets the newest word on each mark win, and
 * writes the PDF to agree. It is the fast path between machines — a few
 * kilobytes that land in the synced folder at once, where the PDF follows a
 * second or so later — and it is where a mark lives when the PDF cannot hold
 * it: an encrypted file, which this build will not write into.
 *
 * Before 0.9.9 this build wrote only `{ "at": … }` for each mark it made. The
 * Mac's `Entry` is `descriptor` *and* `at`, with a missing descriptor meaning
 * the mark was removed — so the Mac read every highlight made here as one
 * somebody had deleted, hid it, and took it out of the file on its next save.
 * Entries now carry the mark, exactly as `MarkupDescriptor` encodes it, and a
 * removal is written as the Mac writes one.
 */
import { isoTimestamp } from './coding.js'
import { MARK_COLORS, quadToRect, rectToQuad, type Mark, type MarkKind } from './marks.js'

/** `MarkupDescriptor` as Swift's `JSONEncoder` writes it through `JSONCoding`. */
export interface Descriptor {
  /** `MarkupColor`'s raw value. */
  color: string
  comment: string
  /** `.iso8601`, whole seconds. */
  createdAt: string
  id: string
  kind: MarkKind | 'note'
  pageIndex: number
  quotedText: string
  /** `CGRect` is `[[x, y], [width, height]]` in Swift's encoding. */
  rects: [[number, number], [number, number]][]
}

/**
 * `MarkJournal.Entry`: the mark as it should be, or no mark at all.
 *
 * A removal written here says so out loud, `"descriptor" : null` — Swift
 * reads that exactly as it reads the key left out, which is how the Mac
 * writes one. The difference is for this build: an entry with no key at all
 * from a Windows or Linux machine is one written before 0.9.9, when every
 * entry here looked like that and every one of them was a mark being made.
 */
export interface JournalEntry {
  at: string
  descriptor?: Descriptor | null
}

export interface Journal {
  device: string
  name: string
  updated: string
  entries: Record<string, JournalEntry>
}

/** A journal, and the device whose file it is. */
export interface Held {
  device: string
  journal: Journal
}

/** The newest word on one mark, and which device said it. */
export interface Word {
  entry: JournalEntry
  device: string
}

/**
 * `MarkupColor.nearest`: the named colour closest to a colour — grey and
 * black, which are near none of them, take the default.
 */
export function nearestColorName(rgb: [number, number, number]): string {
  const [red, green, blue] = rgb
  if (Math.max(red, green, blue) - Math.min(red, green, blue) <= 0.18) return 'yellow'
  let best = 'yellow'
  let closest = Infinity
  for (const [name, value] of Object.entries(MARK_COLORS)) {
    const distance = (value[0] - red) ** 2 + (value[1] - green) ** 2 + (value[2] - blue) ** 2
    if (distance < closest) {
      closest = distance
      best = name
    }
  }
  return best
}

/** A mark as the Mac describes it. */
export function describe(mark: Mark, pageIndex: number, createdAt: string): Descriptor {
  return {
    color: nearestColorName(mark.color),
    comment: mark.comment ?? '',
    createdAt: mark.createdAt ?? createdAt,
    id: mark.id.toUpperCase(),
    kind: mark.kind,
    pageIndex,
    quotedText: mark.text,
    rects: mark.quads.map((quad) => {
      const rect = quadToRect(quad)
      return [[rect.x, rect.y], [rect.width, rect.height]]
    }),
  }
}

/**
 * The mark a descriptor describes, as the window draws it. Null for a note,
 * which this build neither draws nor writes — and so never takes out of a
 * file either.
 */
export function markFrom(descriptor: Descriptor): Mark | null {
  if (descriptor.kind === 'note') return null
  if (!(descriptor.kind in KINDS)) return null
  const quads = (descriptor.rects ?? [])
    .map(([[x, y], [width, height]]) => ({ x, y, width, height }))
    .filter((rect) => rect.width > 0.5 && rect.height > 0.5)
    .map(rectToQuad)
  if (quads.length === 0) return null
  const color = (MARK_COLORS[descriptor.color] ?? MARK_COLORS.yellow) as [number, number, number]
  const mark: Mark = {
    id: descriptor.id.toUpperCase(),
    kind: descriptor.kind,
    quads,
    color: [...color] as [number, number, number],
    text: descriptor.quotedText ?? '',
    createdAt: descriptor.createdAt,
  }
  if (descriptor.comment) mark.comment = descriptor.comment
  return mark
}

const KINDS: Record<MarkKind, true> = { highlight: true, underline: true, strikethrough: true }

/** An empty journal for this device. */
export function freshJournal(device: string, name: string): Journal {
  return { device, name, updated: isoTimestamp(new Date(0)), entries: {} }
}

/**
 * An entry a Windows or Linux machine wrote before 0.9.9: only a time, and no
 * `descriptor` key at all. Those were all marks being made — that build never
 * wrote a removal — so it is not read as one. The Mac, which cannot tell,
 * reads it as a removal; this device's own are brought up to date instead
 * (`upgradeLegacy`), and the others' are left for their machines to bring.
 */
export function isLegacyAddition(entry: JournalEntry, device: string): boolean {
  if ('descriptor' in entry) return false
  return device.startsWith('Win-') || device.startsWith('Linux-')
}

/**
 * `MarkJournal.merged`: the newest entry on every mark any device has spoken
 * about. Devices are taken in order of name and an entry only replaces one
 * that is strictly older, so a tie goes to the device that sorts first — on
 * both builds, which is what keeps two machines from each keeping their own.
 */
export function merged(journals: Held[]): Map<string, Word> {
  const out = new Map<string, Word>()
  const ordered = [...journals].sort((a, b) => (a.device < b.device ? -1 : a.device > b.device ? 1 : 0))
  for (const { device, journal } of ordered) {
    for (const [key, entry] of Object.entries(journal.entries ?? {})) {
      const at = Date.parse(entry?.at ?? '')
      if (Number.isNaN(at)) continue
      const id = key.toUpperCase()
      const existing = out.get(id)
      if (existing && Date.parse(existing.entry.at) >= at) continue
      out.set(id, { entry, device })
    }
  }
  return out
}

/**
 * Brings an entry this build wrote before 0.9.9 up to the Mac's shape.
 *
 * Those entries say only when a mark was made, which the Mac reads as a
 * removal. One whose mark is still in the file is given its mark, from the
 * file, keeping the time it was made; one whose mark is gone is left saying
 * so, which is now the truth. Only this device's own journal is touched — the
 * others belong to the machines that wrote them.
 *
 * True when anything changed and the journal should be written back.
 */
export function upgradeLegacy(journal: Journal, file: Map<number, Mark[]>): boolean {
  const inFile = new Map<string, { mark: Mark; pageIndex: number }>()
  for (const [pageIndex, marks] of file) {
    for (const mark of marks) if (!mark.id.startsWith('foreign-')) inFile.set(mark.id.toUpperCase(), { mark, pageIndex })
  }
  let changed = false
  for (const [key, entry] of Object.entries(journal.entries ?? {})) {
    // A removal this build wrote says `null`; only the entries with no key
    // at all are the old kind.
    if ('descriptor' in entry) continue
    const found = inFile.get(key.toUpperCase())
    if (!found) continue
    entry.descriptor = describe(found.mark, found.pageIndex, entry.at)
    changed = true
  }
  return changed
}

/** The same mark, to within what a PDF keeps of it — `isAlreadyWritten`. */
export function sameMark(left: Mark, right: Mark): boolean {
  if (left.kind !== right.kind) return false
  if (nearestColorName(left.color) !== nearestColorName(right.color)) return false
  if ((left.comment ?? '') !== (right.comment ?? '')) return false
  const lines = (mark: Mark) => mark.quads.map(quadToRect).filter((rect) => rect.width > 0.5 && rect.height > 0.5)
  const a = lines(left)
  const b = lines(right)
  if (a.length !== b.length) return false
  const near = (x: number, y: number) => Math.abs(x - y) < 0.01
  return a.every((rect) => b.some((other) =>
    near(rect.x, other.x) && near(rect.y, other.y) && near(rect.width, other.width) && near(rect.height, other.height)))
}

/**
 * The marks the pages should show: what the file holds, overruled mark by
 * mark by the newest journal entry — a device's addition, change or removal.
 * `DocumentSession.reconcile`, for a process that reads the file afresh each
 * time instead of holding it open.
 *
 * A mark the file already carries as the journal describes it is kept as the
 * file has it, so a page is only `dirty` — written again on the next save —
 * when it actually differs from what the journals say.
 */
export function reconcile(
  file: Map<number, Mark[]>,
  words: Map<string, Word>,
): { pages: Map<number, Mark[]>; dirty: Set<number> } {
  const pages = new Map<number, Mark[]>()
  const where = new Map<string, number>()
  for (const [pageIndex, marks] of file) {
    pages.set(pageIndex, [...marks])
    for (const mark of marks) where.set(mark.id.toUpperCase(), pageIndex)
  }
  const dirty = new Set<number>()
  const take = (id: string) => {
    const pageIndex = where.get(id)
    if (pageIndex === undefined) return null
    const list = pages.get(pageIndex) ?? []
    const at = list.findIndex((mark) => mark.id.toUpperCase() === id)
    if (at < 0) return null
    const [mark] = list.splice(at, 1)
    where.delete(id)
    return { mark, pageIndex }
  }
  for (const [id, { entry, device }] of words) {
    const descriptor = entry.descriptor
    if (descriptor?.kind === 'note') continue
    if (!descriptor) {
      if (isLegacyAddition(entry, device)) continue
      const gone = take(id)
      if (gone) dirty.add(gone.pageIndex)
      continue
    }
    const wanted = markFrom(descriptor)
    if (!wanted) continue
    const pageIndex = descriptor.pageIndex
    const existing = where.get(id)
    if (existing === pageIndex) {
      const list = pages.get(pageIndex) ?? []
      const at = list.findIndex((mark) => mark.id.toUpperCase() === id)
      if (at >= 0 && sameMark(list[at], wanted)) {
        list[at] = { ...list[at], createdAt: descriptor.createdAt }
        continue
      }
    }
    const moved = take(id)
    if (moved) dirty.add(moved.pageIndex)
    const list = pages.get(pageIndex) ?? []
    list.push(wanted)
    pages.set(pageIndex, list)
    where.set(id, pageIndex)
    dirty.add(pageIndex)
  }
  for (const [pageIndex, list] of [...pages]) if (list.length === 0) pages.delete(pageIndex)
  return { pages, dirty }
}

/** Two records of a mark that would be written the same way. */
function unchanged(left: Mark, right: Mark): boolean {
  return left.kind === right.kind
    && (left.comment ?? '') === (right.comment ?? '')
    && left.text === right.text
    && JSON.stringify(left.color) === JSON.stringify(right.color)
    && JSON.stringify(left.quads) === JSON.stringify(right.quads)
}

/**
 * Writes what changed on one page into this device's journal.
 *
 * A mark of ours that is new or different gets its whole descriptor; one that
 * is gone gets a removal, unless it is still on another page (`elsewhere`).
 * A mark that was already there when the file arrived — made in another
 * reader, with no identifier of ours — is not a journal's to describe. True
 * when anything was written into the journal.
 */
export function recordChanges(
  journal: Journal,
  pageIndex: number,
  before: Mark[],
  after: Mark[],
  now: Date,
  elsewhere: Set<string> = new Set(),
): boolean {
  const at = isoTimestamp(now)
  const ours = (marks: Mark[]) =>
    new Map(marks.filter((mark) => !mark.id.startsWith('foreign-')).map((mark) => [mark.id.toUpperCase(), mark]))
  const was = ours(before)
  const is = ours(after)
  let changed = false
  for (const [id, mark] of is) {
    const previous = was.get(id)
    // Only what changed here. A mark that came in from the file and was left
    // alone is not this device's to describe: the Mac's own description of
    // it knows the quoted text, which a file with a comment does not carry.
    if (previous && unchanged(previous, mark)) continue
    journal.entries[id] = { at, descriptor: describe(mark, pageIndex, at) }
    changed = true
  }
  for (const id of was.keys()) {
    if (is.has(id) || elsewhere.has(id)) continue
    journal.entries[id] = { at, descriptor: null }
    changed = true
  }
  if (changed) journal.updated = at
  return changed
}
