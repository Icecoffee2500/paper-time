/**
 * Which columns the window shows, and focus mode — the Mac's rules
 * (`AppModel.toggleSidebar/PaperList/Reader/Inspector`, `setFocusMode`), pure
 * so they are tested (`src/test/focus.ts`) rather than clicked.
 *
 * Focus is a state of its own, not four flags overwritten: it remembers the
 * list and the inspector it hid, and what is saved is the window focus
 * would give back — the window used to save the focused panes themselves,
 * and a restart stranded it with every column shut and no way back.
 */
export interface Panes {
  sidebar: boolean
  paperList: boolean
  reader: boolean
  inspector: boolean
}

export type Pane = keyof Panes

export interface PaneState {
  panes: Panes
  focus: { on: boolean; before: { paperList: boolean; inspector: boolean } }
}

export const unfocused = (panes: Panes): PaneState => ({
  panes: { ...panes },
  focus: { on: false, before: { paperList: panes.paperList, inspector: panes.inspector } },
})

/** The paper and nothing else: the list and the inspector remembered. */
export function enterFocus(state: PaneState): PaneState {
  if (state.focus.on) return state
  return {
    panes: { sidebar: false, paperList: false, reader: true, inspector: false },
    focus: { on: true, before: { paperList: state.panes.paperList, inspector: state.panes.inspector } },
  }
}

/** Back: the sidebar, and the list and inspector as they were. */
export function leaveFocus(state: PaneState): PaneState {
  if (!state.focus.on) return state
  return {
    panes: { ...state.panes, sidebar: true, paperList: state.focus.before.paperList, inspector: state.focus.before.inspector },
    focus: { ...state.focus, on: false },
  }
}

/**
 * One column on or off. Something is always left to look at: closing the
 * list with nothing else showing opens the paper, closing the paper with
 * nothing else showing opens the list — and asking for the paper in focus
 * mode, which is the paper and nothing else, leaves focus mode.
 */
export function togglePaneState(state: PaneState, pane: Pane): PaneState {
  if (pane === 'reader' && state.focus.on) return leaveFocus(state)
  const panes = { ...state.panes, [pane]: !state.panes[pane] }
  if (pane === 'paperList' && !panes.paperList && !panes.reader && !panes.sidebar) panes.reader = true
  if (pane === 'reader' && !panes.reader && !panes.paperList && !panes.sidebar) panes.paperList = true
  if (pane === 'sidebar' && !panes.sidebar && !panes.paperList && !panes.reader) panes.reader = true
  return { ...state, panes }
}

/** A column shown for someone — the pen bringing the Tools tab, a note
 *  opening — in or out of focus. */
export function showPane(state: PaneState, pane: Pane): PaneState {
  if (state.panes[pane]) return state
  return { ...state, panes: { ...state.panes, [pane]: true } }
}

/** What is written to the settings: the window as it is out of focus. */
export function restingPanes(state: PaneState): Panes {
  return state.focus.on ? leaveFocus(state).panes : state.panes
}

// MARK: - The row of panes (1.1)

/**
 * The window's content panes: one to four in a row between the sidebar and
 * the inspector (the Mac's `PaneRow`, 2026-11-18). Each holds one thing:
 *
 * - `list` — whatever the sidebar's row shows in the list's column (a shelf's
 *   table, a plan, the slip-box's notes, the projects). It follows the sidebar.
 * - `page` — what the page area shows: the paper (side by side too), the open
 *   note, a project's page.
 * - `shelf` — one sidebar item pinned, whatever the sidebar shows: its table,
 *   its notes, its project. The item is the build's own shelf, as canonical
 *   JSON (`paneShelfKey`).
 * - `note` — one note, picked and then written in.
 *
 * At most one `list` and one `page`. The window keeps one arrangement — the
 * panes, their order and widths — where it used to keep one per place, and a
 * companion pane at the far end: «which arrangement am I in» was a question
 * nobody could answer from the window, and the companion was a fifth pane
 * with rules of its own. Closing a pane keeps it on a stack it is reopened
 * from (the capsule, ⌘Z, ⇧⌘T, the «+» column's menu), so a closed pane is
 * never a pane lost.
 */
export type PaneContent =
  | { kind: 'list' }
  | { kind: 'page' }
  | { kind: 'shelf'; shelf: string }
  | { kind: 'note'; note: string | null }

export interface ContentPane {
  id: string
  content: PaneContent
  /** The width it was dragged to; null for its kind's own. The `list` and
   *  `page` panes keep theirs in the settings' columns, as they did. */
  width: number | null
}

/** A pane closed, and where it stood: the panes either side of it, and its place. */
export interface ClosedPane {
  pane: ContentPane
  left: string | null
  right: string | null
  index: number
}

export interface PaneRow {
  panes: ContentPane[]
  /** The panes closed, the last one last. */
  closed: ClosedPane[]
}

export const MAX_PANES = 4
/** How many closed panes can be opened again. */
export const CLOSED_KEPT = 8

/** Why a change did not happen: the row is full, the pane is the last one,
 *  the `list` or the `page` is open already, or the pane is not there. */
export type Refusal = 'full' | 'last' | 'taken' | 'missing'

export interface RowChange {
  row: PaneRow
  refused?: Refusal
  /** The pane the change is about: the one inserted, reopened or given the content. */
  pane?: string
}

/** A shelf as the pane keeps it: JSON with its keys in order, so the same shelf is the same string. */
export function paneShelfKey(shelf: unknown): string {
  const ordered = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(ordered)
    if (value && typeof value === 'object') {
      return Object.fromEntries(Object.keys(value as Record<string, unknown>).sort().map((key) => [key, ordered((value as Record<string, unknown>)[key])]))
    }
    return value
  }
  return JSON.stringify(ordered(shelf))
}

export function sameContent(a: PaneContent, b: PaneContent): boolean {
  if (a.kind !== b.kind) return false
  if (a.kind === 'shelf') return a.shelf === (b as typeof a).shelf
  if (a.kind === 'note') return a.note === (b as typeof a).note
  return true
}

/** `list` and `page` stand once in a row. */
const isSingle = (content: PaneContent): content is { kind: 'list' } | { kind: 'page' } => content.kind === 'list' || content.kind === 'page'

export function paneOf(row: PaneRow, kind: 'list' | 'page'): ContentPane | null {
  return row.panes.find((pane) => pane.content.kind === kind) ?? null
}

/** The window as it always was: the list, and the page beside it. */
export function defaultRow(): PaneRow {
  return { panes: [{ id: 'list', content: { kind: 'list' }, width: null }, { id: 'page', content: { kind: 'page' }, width: null }], closed: [] }
}

/** A row of these panes, nothing closed. */
export function rowOf(panes: ContentPane[]): PaneRow {
  return { panes: panes.map((pane) => ({ ...pane, content: { ...pane.content } })), closed: [] }
}

/** A pane put in at `at`. Five is one too many, and a second `list` or `page` is none. */
export function insertPane(row: PaneRow, pane: { id: string; content: PaneContent; width?: number | null }, at: number): RowChange {
  if (row.panes.length >= MAX_PANES) return { row, refused: 'full' }
  if (isSingle(pane.content) && paneOf(row, pane.content.kind)) return { row, refused: 'taken' }
  if (row.panes.some((one) => one.id === pane.id)) return { row, refused: 'taken' }
  const index = Math.max(0, Math.min(at, row.panes.length))
  const panes = [...row.panes]
  panes.splice(index, 0, { id: pane.id, content: { ...pane.content }, width: pane.width ?? null })
  return { row: { ...row, panes }, pane: pane.id }
}

/**
 * A pane shows something else. Asked to be the `list` or the `page` while
 * another pane is, the two trade what they show — the row keeps one of each.
 */
export function setContent(row: PaneRow, id: string, content: PaneContent): RowChange {
  const target = row.panes.find((pane) => pane.id === id)
  if (!target) return { row, refused: 'missing' }
  if (sameContent(target.content, content)) return { row, pane: id }
  const holder = isSingle(content) ? paneOf(row, content.kind) : null
  const panes = row.panes.map((pane) => {
    if (pane.id === id) return { ...pane, content: { ...content }, width: isSingle(content) ? null : pane.width }
    if (holder && pane.id === holder.id) return { ...pane, content: { ...target.content }, width: isSingle(target.content) ? null : pane.width }
    return pane
  })
  return { row: { ...row, panes }, pane: id }
}

/** One pane moved beside another — or the two traded places. */
export function movePane(row: PaneRow, id: string, beside: string, side: 'left' | 'right' | 'swap'): RowChange {
  const from = row.panes.findIndex((pane) => pane.id === id)
  const to = row.panes.findIndex((pane) => pane.id === beside)
  if (from < 0 || to < 0) return { row, refused: 'missing' }
  if (from === to) return { row, pane: id }
  const panes = [...row.panes]
  if (side === 'swap') {
    ;[panes[from], panes[to]] = [panes[to], panes[from]]
    return { row: { ...row, panes }, pane: id }
  }
  const [moving] = panes.splice(from, 1)
  const target = panes.findIndex((pane) => pane.id === beside)
  panes.splice(side === 'left' ? target : target + 1, 0, moving)
  return { row: { ...row, panes }, pane: id }
}

/** A pane closed and kept to be opened again. The last one stays: there must be something to look at. */
export function closePane(row: PaneRow, id: string): RowChange {
  const index = row.panes.findIndex((pane) => pane.id === id)
  if (index < 0) return { row, refused: 'missing' }
  if (row.panes.length <= 1) return { row, refused: 'last' }
  const entry: ClosedPane = {
    pane: { ...row.panes[index], content: { ...row.panes[index].content } },
    left: row.panes[index - 1]?.id ?? null,
    right: row.panes[index + 1]?.id ?? null,
    index,
  }
  const closed = [...row.closed.filter((one) => one.pane.id !== id), entry].slice(-CLOSED_KEPT)
  return { row: { panes: row.panes.filter((pane) => pane.id !== id), closed }, pane: id }
}

/**
 * A closed pane back where it stood: after the pane that was on its left,
 * else before the one on its right, else at its old place. `at` is its place
 * on the closed stack, the last one by default. A `list` or `page` already
 * open again is no pane to reopen, and leaves the stack.
 */
export function reopenPane(row: PaneRow, at = row.closed.length - 1): RowChange {
  const entry = row.closed[at]
  if (!entry) return { row, refused: 'missing' }
  const drop = (): PaneRow => ({ ...row, closed: row.closed.filter((_, index) => index !== at) })
  if ((isSingle(entry.pane.content) && paneOf(row, entry.pane.content.kind)) || row.panes.some((pane) => pane.id === entry.pane.id)) {
    return { row: drop(), refused: 'taken' }
  }
  if (row.panes.length >= MAX_PANES) return { row, refused: 'full' }
  const left = entry.left ? row.panes.findIndex((pane) => pane.id === entry.left) : -1
  const right = entry.right ? row.panes.findIndex((pane) => pane.id === entry.right) : -1
  const index = left >= 0 ? left + 1 : right >= 0 ? right : Math.min(entry.index, row.panes.length)
  const panes = [...row.panes]
  panes.splice(index, 0, { ...entry.pane, content: { ...entry.pane.content } })
  return { row: { panes, closed: drop().closed }, pane: entry.pane.id }
}

/** Puts `pane` in `victim`'s place, the victim kept on the closed stack. */
function replacing(row: PaneRow, victim: ContentPane, pane: ContentPane): RowChange {
  const index = row.panes.indexOf(victim)
  const closedRow = closePane({ ...row, panes: [...row.panes, pane] }, victim.id).row
  const panes = closedRow.panes.filter((one) => one.id !== pane.id)
  panes.splice(index, 0, pane)
  // Where it stood is said by the row it stood in, not by the one with the newcomer at the end.
  const closed = closedRow.closed.map((one) => (one.pane.id === victim.id
    ? { ...one, left: row.panes[index - 1]?.id ?? null, right: row.panes[index + 1]?.id ?? null, index }
    : one))
  return { row: { panes, closed }, pane: pane.id }
}

/**
 * A paper chosen with no `page` pane open: one comes, to the right of the
 * pane the choice was made in — else at the right end. A full row gives up
 * the pane to the right of that one (to its left, at the end), which can be
 * reopened.
 */
export function ensurePage(row: PaneRow, from: string | null, id: string): RowChange {
  const page = paneOf(row, 'page')
  if (page) return { row, pane: page.id }
  const at = from ? row.panes.findIndex((pane) => pane.id === from) : -1
  const pane: ContentPane = { id, content: { kind: 'page' }, width: null }
  if (row.panes.length < MAX_PANES) return insertPane(row, pane, at >= 0 ? at + 1 : row.panes.length)
  const victim = at >= 0 ? (row.panes[at + 1] ?? row.panes[at - 1]) : row.panes[row.panes.length - 1]
  return replacing(row, victim, pane)
}

/**
 * A sidebar row pressed with no `list` pane open: one comes, at the left. A
 * full row gives up its leftmost pane that is not the page.
 */
export function ensureList(row: PaneRow, id: string): RowChange {
  const list = paneOf(row, 'list')
  if (list) return { row, pane: list.id }
  const pane: ContentPane = { id, content: { kind: 'list' }, width: null }
  if (row.panes.length < MAX_PANES) return insertPane(row, pane, 0)
  const victim = row.panes.find((one) => one.content.kind !== 'page') ?? row.panes[0]
  return replacing(row, victim, pane)
}

/**
 * The toolbar's list and paper buttons (⌘P, ⌘\): the pane closed, or back —
 * where it was when it was closed, or where it always went. The last pane is
 * not closed but turned into the other, as the Mac's columns never left
 * nothing to look at.
 */
export function togglePaneKind(row: PaneRow, kind: 'list' | 'page', id: string): RowChange {
  const holder = paneOf(row, kind)
  if (holder) {
    if (row.panes.length > 1) return closePane(row, holder.id)
    return setContent(row, holder.id, { kind: kind === 'list' ? 'page' : 'list' })
  }
  for (let at = row.closed.length - 1; at >= 0; at -= 1) {
    if (row.closed[at].pane.content.kind !== kind) continue
    const back = reopenPane(row, at)
    if (!back.refused) return back
    break
  }
  if (kind === 'list') return ensureList(row, id)
  return ensurePage(row, null, id)
}

/** What stands while focus mode is on: the page, alone — or, with no page, the first pane. */
export function focusedPanes(row: PaneRow): ContentPane[] {
  const page = paneOf(row, 'page')
  return [page ?? row.panes[0]].filter(Boolean)
}

/**
 * The pane that takes what room is left: the page, else the list, else the
 * last one — the others stand at their widths.
 */
export function flexiblePane(panes: ContentPane[]): string | null {
  return (panes.find((pane) => pane.content.kind === 'page') ?? panes.find((pane) => pane.content.kind === 'list') ?? panes[panes.length - 1])?.id ?? null
}

/**
 * The widths the fixed panes stand at when the row has less room than they
 * want: each gives way toward its floor in proportion to what it can give,
 * and when even the floors do not fit, the floors share what there is — a
 * pane pushed out past the window's edge is a pane nobody can reach (1.1:
 * four panes in a narrow window). With room enough, each has what it wants.
 */
export function fitWidths(panes: { wanted: number; least: number }[], room: number): number[] {
  const wanted = panes.reduce((sum, one) => sum + one.wanted, 0)
  if (wanted <= room) return panes.map((one) => one.wanted)
  const give = panes.reduce((sum, one) => sum + Math.max(one.wanted - one.least, 0), 0)
  const excess = wanted - room
  if (give >= excess) {
    return panes.map((one) => Math.round(one.wanted - (give > 0 ? Math.max(one.wanted - one.least, 0) / give * excess : 0)))
  }
  const floors = panes.reduce((sum, one) => sum + Math.min(one.least, one.wanted), 0)
  const share = floors > 0 ? Math.max(room, 0) / floors : 0
  return panes.map((one) => Math.max(Math.round(Math.min(one.least, one.wanted) * Math.min(share, 1)), 120))
}

// MARK: - Dropping into the row

/** Where a drag over a pane would go: a new pane on its left or right, or into it. */
export type PaneZone = 'left' | 'middle' | 'right'

/** The share of a pane's width each side zone takes. */
export const SIDE_ZONE = 0.26

/** Which zone a point across a pane falls in, from 0 at its left edge to 1 at its right. */
export function zoneAcross(fraction: number): PaneZone {
  if (fraction < SIDE_ZONE) return 'left'
  if (fraction > 1 - SIDE_ZONE) return 'right'
  return 'middle'
}

/**
 * Where a paper dragged over a pane that is not the page would land (the
 * Mac's `AppModel.dropPaper`, 2026-11-18). Papers stand side by side on the
 * page — up to four, the same paper twice included — so with a page open
 * the whole pane is one zone, and the paper opens beside the page's paper
 * on the side that faces this pane. With no page open, the three zones say
 * where a page comes: on the pane's left, or to its right (the middle too).
 */
export type PaperDrop =
  | { kind: 'beside'; side: 'left' | 'right' }
  | { kind: 'page'; at: number }

/** Whether a paper held over this pane shows the one zone (a page to stand beside) or the three. */
export function paperZoneMode(row: PaneRow): 'one' | 'three' {
  return paneOf(row, 'page') ? 'one' : 'three'
}

/** What a paper let go of over a pane (`target`; null is the «+» column) does. Null: the pane is not there. */
export function paperDropOn(row: PaneRow, target: string | null, zone: PaneZone): PaperDrop | null {
  const page = paneOf(row, 'page')
  if (target === null) return page ? { kind: 'beside', side: 'right' } : { kind: 'page', at: row.panes.length }
  const index = row.panes.findIndex((pane) => pane.id === target)
  if (index < 0) return null
  if (!page) return { kind: 'page', at: zone === 'left' ? index : index + 1 }
  const at = row.panes.indexOf(page)
  if (index === at) return { kind: 'beside', side: zone === 'left' ? 'left' : 'right' }
  return { kind: 'beside', side: index < at ? 'left' : 'right' }
}

/**
 * Whether the «+» column stands: not in focus, and not when the row is full
 * — it could only say «칸은 네 개까지예요» (the Mac's `showsPlusColumn`,
 * 2026-11-19: «이미 4개 다 차면 저 "+"를 없애면 되잖아»). The panes take its room.
 */
export function showsPlusColumn(row: PaneRow, focus: boolean): boolean {
  return !focus && row.panes.length < MAX_PANES
}

// MARK: - The inspector, docked or floating

/** Where the inspector is: docked at the right, or a panel over the window. */
export interface InspectorPlace {
  floating: boolean
  /** The panel's frame inside the panes, when it floats; -1 until it has one. */
  x: number
  y: number
  width: number
  height: number
}

/** Whether the inspector shows, and how. */
export interface InspectorShowing {
  shown: boolean
  floating: boolean
}

/**
 * ⌘] and the toolbar's button: the inspector in turn — floating, docked at
 * the right, gone, and floating again (the Mac's `toggleInspector`,
 * 2026-11-19: «⌘]을 했을 때 floating으로 뜨는 것은 좋은데, 한번 더 누르면
 * 오른쪽 사이드바로 나오게 해주고, 한번 더 누르면 없어지도록»).
 */
export function cycleInspector(now: InspectorShowing): InspectorShowing {
  if (!now.shown) return { shown: true, floating: true }
  if (now.floating) return { shown: true, floating: false }
  return { shown: false, floating: false }
}

/**
 * The menus' two choices — «옆에 붙여 보기», «띄워 보기»: the inspector shown
 * that way, and the one showing already put away (the Mac's
 * `showInspector(floating:)`).
 */
export function chooseInspector(now: InspectorShowing, floating: boolean): InspectorShowing {
  if (now.shown && now.floating === floating) return { shown: false, floating }
  return { shown: true, floating }
}

export const INSPECTOR_PLACE: InspectorPlace = { floating: false, x: -1, y: -1, width: 340, height: 560 }
export const FLOAT_LEAST = { width: 280, height: 240 }
/** How far the panel keeps from the window's edges. */
const FLOAT_INSET = 8

/**
 * The floating panel's frame, kept inside the window: no smaller than it can
 * be read at, no larger than the window, and never out of reach — a panel
 * left beyond the edge of a window made smaller is a panel nobody can drag
 * back. Not placed yet, it stands at the right, under the panes' heads.
 */
export function placeFloat(place: InspectorPlace, area: { width: number; height: number }): InspectorPlace {
  const room = { width: Math.max(area.width - 2 * FLOAT_INSET, 1), height: Math.max(area.height - 2 * FLOAT_INSET, 1) }
  const width = Math.min(Math.max(place.width, FLOAT_LEAST.width), room.width)
  const height = Math.min(Math.max(place.height, FLOAT_LEAST.height), room.height)
  // Never placed (-1, -1): the top right. Anything else was put somewhere by hand.
  const placed = !(place.x === INSPECTOR_PLACE.x && place.y === INSPECTOR_PLACE.y)
  const x = placed ? place.x : area.width - width - FLOAT_INSET * 2
  // Under the panes' heads, so the rightmost pane's ⌄ and × are not under it.
  const y = placed ? place.y : FLOAT_INSET * 9
  return {
    ...place,
    width,
    height,
    x: Math.min(Math.max(x, FLOAT_INSET), Math.max(area.width - width - FLOAT_INSET, FLOAT_INSET)),
    y: Math.min(Math.max(y, FLOAT_INSET), Math.max(area.height - height - FLOAT_INSET, FLOAT_INSET)),
  }
}

// MARK: - As the settings keep it

/** The arrangement the settings keep: which panes, in which order, their widths, and where the inspector is. */
export interface StoredPanes {
  panes: ContentPane[]
  inspector: InspectorPlace
}

function readContent(value: unknown): PaneContent | null {
  if (!value || typeof value !== 'object') return null
  const raw = value as Record<string, unknown>
  if (raw.kind === 'list' || raw.kind === 'page') return { kind: raw.kind }
  if (raw.kind === 'shelf' && typeof raw.shelf === 'string' && raw.shelf) return { kind: 'shelf', shelf: raw.shelf }
  if (raw.kind === 'note') return { kind: 'note', note: typeof raw.note === 'string' && raw.note ? raw.note : null }
  return null
}

const finite = (value: unknown, fallback: number) => (typeof value === 'number' && Number.isFinite(value) ? value : fallback)

/** The arrangement as JSON read back; what does not read is left out, and a row that is no row is none. */
export function readPanes(text: string | null | undefined): StoredPanes | null {
  if (!text) return null
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return null
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  const panes: ContentPane[] = []
  for (const one of Array.isArray((raw as Record<string, unknown>).panes) ? (raw as { panes: unknown[] }).panes : []) {
    if (!one || typeof one !== 'object') continue
    const value = one as Record<string, unknown>
    const content = readContent(value.content)
    if (!content || typeof value.id !== 'string' || !value.id) continue
    if (panes.some((pane) => pane.id === value.id)) continue
    if (isSingle(content) && panes.some((pane) => pane.content.kind === content.kind)) continue
    const width = typeof value.width === 'number' && Number.isFinite(value.width) && value.width > 0 ? value.width : null
    panes.push({ id: value.id, content, width })
    if (panes.length === MAX_PANES) break
  }
  if (panes.length === 0) return null
  const place = ((raw as Record<string, unknown>).inspector ?? {}) as Record<string, unknown>
  return {
    panes,
    inspector: {
      floating: place.floating === true,
      x: finite(place.x, INSPECTOR_PLACE.x),
      y: finite(place.y, INSPECTOR_PLACE.y),
      width: finite(place.width, INSPECTOR_PLACE.width),
      height: finite(place.height, INSPECTOR_PLACE.height),
    },
  }
}

export function writePanes(row: PaneRow, inspector: InspectorPlace): string {
  return JSON.stringify({
    panes: row.panes.map((pane) => ({ id: pane.id, content: pane.content, width: pane.width })),
    inspector: { floating: inspector.floating, x: Math.round(inspector.x), y: Math.round(inspector.y), width: Math.round(inspector.width), height: Math.round(inspector.height) },
  })
}

/**
 * The arrangement from settings written before there was a row (1.1's first
 * days): each place's panes (`workspaceArrangements`) and the companion at
 * the far end, with its width. The library's arrangement is the window's —
 * it is where the window opens — and a companion, the library's or any
 * place's, becomes the pane that does its job: a paper list a `shelf` of
 * papers, a note a `note`, a plan that plan's `shelf`. Null when there is
 * nothing to carry over: the panes' two switches say the rest.
 */
export function migrateLegacyPanes(raw: { workspaceArrangements?: unknown; columns?: unknown; panes?: unknown }): string | null {
  type Old = { list: boolean; page: boolean; companion: { kind: 'papers' } | { kind: 'note' } | { kind: 'plan'; id: string } | null }
  const places = ['library', 'literature', 'knowledge', 'projects']
  const kept: Record<string, Old> = {}
  if (typeof raw.workspaceArrangements === 'string') {
    try {
      const parsed = JSON.parse(raw.workspaceArrangements) as Record<string, unknown>
      for (const place of places) {
        const one = parsed?.[place] as Record<string, unknown> | undefined
        if (!one || typeof one !== 'object' || typeof one.list !== 'boolean' || typeof one.page !== 'boolean') continue
        const companion = one.companion as Record<string, unknown> | null | undefined
        const read: Old['companion'] = !companion || typeof companion !== 'object' ? null
          : companion.kind === 'papers' ? { kind: 'papers' }
            : companion.kind === 'note' ? { kind: 'note' }
              : companion.kind === 'plan' && typeof companion.id === 'string' ? { kind: 'plan', id: companion.id } : null
        kept[place] = { list: one.list, page: one.page, companion: read }
      }
    } catch {
      // Settings that do not read carry nothing over.
    }
  }
  const companion = kept.library?.companion ?? places.map((place) => kept[place]?.companion).find(Boolean) ?? null
  if (!kept.library && !companion) return null
  const switches = (raw.panes ?? {}) as Record<string, unknown>
  const list = kept.library ? kept.library.list : switches.paperList !== false
  const page = kept.library ? kept.library.page : switches.reader !== false
  const panes: ContentPane[] = []
  if (list) panes.push({ id: 'list', content: { kind: 'list' }, width: null })
  if (page) panes.push({ id: 'page', content: { kind: 'page' }, width: null })
  if (companion) {
    const width = finite((raw.columns as Record<string, unknown> | undefined)?.companion, 340)
    const content: PaneContent = companion.kind === 'note' ? { kind: 'note', note: null }
      : companion.kind === 'plan' ? { kind: 'shelf', shelf: paneShelfKey({ kind: 'plan', id: companion.id }) }
        : { kind: 'shelf', shelf: paneShelfKey({ kind: 'kind', of: 'paper' }) }
    panes.push({ id: 'companion', content, width })
  }
  if (panes.length === 0) panes.push({ id: 'page', content: { kind: 'page' }, width: null })
  return writePanes(rowOf(panes), INSPECTOR_PLACE)
}

// MARK: - How the table and the page share the window

/** The least a page is ever left (the Mac's `Pane.pageFloor`). */
export const PAGE_FLOOR = 300
/**
 * The width a page keeps while something beside it can give way: a column
 * of a two-column paper at a size you can read (the Mac's
 * `Pane.readingFloor`). The table yields before the page goes under it
 * (2026-11-16: with the inspector open, the table took the room and left the
 * paper 270 points).
 */
export const READING_FLOOR = 520
/**
 * How far the table yields for it — a title with room to be read (the Mac's
 * `Pane.tableLeast`). Its authors, year and venue fold under the title long
 * before this.
 */
export const TABLE_LEAST = 300

/** What stands beside the table and the page: `null` for a column that is shut. */
export interface TableNeighbours {
  /** The panes' own width, inside their margins. */
  window: number
  sidebar: number | null
  inspector: number | null
  /** The other panes in the row, each at its width (1.1). */
  others?: number[]
  /** The gap between two panels, which is also the divider. */
  gap: number
}

/** The room the table and the page share: the window less the sidebar, the inspector, the other panes and the gaps. */
export function tableAndPageRoom({ window, sidebar, inspector, others = [], gap }: TableNeighbours): number {
  let room = window - gap
  if (sidebar !== null) room -= sidebar + gap
  if (inspector !== null) room -= inspector + gap
  for (const width of others) room -= width + gap
  return room
}

/**
 * The widest the table may be: up to where the page would go under a
 * reading width, unless that leaves the table less than a title's room.
 * Also how far its divider may be dragged.
 */
export function tableWidest(room: number): number {
  return Math.max(room - READING_FLOOR, TABLE_LEAST)
}

/**
 * The table's width as laid out (the Mac's `tableShown`). What it was given,
 * until the page would lose its reading width — then the table gives way,
 * folding its authors, year and venue under the titles, and it has its width
 * back when the room comes back. Opening the inspector takes its room from
 * the table, not from the paper. Never so wide that the page goes under its
 * floor.
 */
export function tableShownWidth(stored: number, room: number): number {
  const width = Math.min(stored, tableWidest(room))
  return Math.max(Math.min(width, room - PAGE_FLOOR), 200)
}
