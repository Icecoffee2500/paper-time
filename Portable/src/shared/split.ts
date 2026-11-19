/**
 * Papers side by side: up to four in the page area, in a left column and,
 * when there is one, a right column, each of one or two panes.
 *
 * The same rules as the Mac's `SplitArrangement` — what was in a zone slides
 * to the other half of its column, what there is no room for leaves the
 * arrangement and stays open in the list — so a person who tiles papers on
 * one machine finds the same tiling on the other.
 */

export type DockZone = 'left' | 'right' | 'topLeft' | 'topRight' | 'bottomLeft' | 'bottomRight'

export const DOCK_ZONES: DockZone[] = ['left', 'right', 'topLeft', 'topRight', 'bottomLeft', 'bottomRight']

/**
 * A pane is named by a key, not by its paper: the same paper may stand in
 * two panes at once (one at the figure, one at the text that cites it). The
 * first pane of a paper is keyed by the paper's id alone, so everything that
 * knew a pane by its paper still does; a second pane of the same paper is
 * `<paper>@2`, a third `<paper>@3` (`freshPaneKey`), and `paperOfPane` gives
 * the paper back. The Mac's `SplitArrangement.Pane` carries the same two.
 */
export interface SplitColumn {
  top: string
  bottom?: string
}

/** The paper a pane shows. */
export function paperOfPane(key: string): string {
  const at = key.indexOf('@')
  return at < 0 ? key : key.slice(0, at)
}

/** A key for one more pane of `paper`: the paper's own id while it has no pane, `<paper>@n` after that. */
export function freshPaneKey(arrangement: SplitArrangement | null, paper: string): string {
  const taken = new Set(arrangement ? splitPapers(arrangement) : [])
  if (!taken.has(paper)) return paper
  let n = 2
  while (taken.has(`${paper}@${n}`)) n += 1
  return `${paper}@${n}`
}

/** The panes showing `paper`, in the arrangement's order. */
export function splitPanesOf(arrangement: SplitArrangement, paper: string): string[] {
  return splitPapers(arrangement).filter((key) => paperOfPane(key) === paper)
}

export function splitContainsPaper(arrangement: SplitArrangement, paper: string): boolean {
  return splitPanesOf(arrangement, paper).length > 0
}

/** Every pane of `paper` taken out, closing up the space they leave. */
export function splitRemovePaper(arrangement: SplitArrangement, paper: string): SplitArrangement {
  let next = arrangement
  for (const key of splitPanesOf(arrangement, paper)) next = splitRemove(next, key)
  return next
}

export interface SplitArrangement {
  left: SplitColumn
  right?: SplitColumn
}

function columnPapers(column: SplitColumn | undefined): string[] {
  if (!column) return []
  return column.bottom ? [column.top, column.bottom] : [column.top]
}

function column(ids: string[]): SplitColumn | undefined {
  if (ids.length === 0) return undefined
  return ids.length > 1 ? { top: ids[0], bottom: ids[1] } : { top: ids[0] }
}

/** Every pane's key in the arrangement, left column first, top before bottom (`paperOfPane` for the papers). */
export function splitPapers(arrangement: SplitArrangement): string[] {
  return [...columnPapers(arrangement.left), ...columnPapers(arrangement.right)]
}

export function splitContains(arrangement: SplitArrangement, id: string): boolean {
  return splitPapers(arrangement).includes(id)
}

/** Takes a paper out, closing up the space it leaves. */
export function splitRemove(arrangement: SplitArrangement, id: string): SplitArrangement {
  const columns = [arrangement.left, arrangement.right]
    .filter((c): c is SplitColumn => Boolean(c))
    .map((c) => column(columnPapers(c).filter((paper) => paper !== id)))
    .filter((c): c is SplitColumn => Boolean(c))
  if (columns.length === 0) return arrangement
  return { left: columns[0], right: columns[1] }
}

/**
 * Puts a pane into a zone — a new one, or one already in the arrangement,
 * which moves. What was there slides to the other half of its column; what
 * there is no room for leaves the arrangement.
 */
export function splitDock(arrangement: SplitArrangement, id: string, zone: DockZone): SplitArrangement {
  const leftIDs = columnPapers(arrangement.left).filter((paper) => paper !== id)
  const rightIDs = columnPapers(arrangement.right).filter((paper) => paper !== id)
  const others = [...leftIDs, ...rightIDs]
  switch (zone) {
    case 'left':
      return { left: { top: id }, right: column(others.slice(0, 2)) }
    case 'right': {
      const rest = column(others.slice(0, 2))
      return rest ? { left: rest, right: { top: id } } : { left: { top: id } }
    }
    case 'topLeft':
    case 'bottomLeft': {
      const kept = leftIDs.slice(0, 1)
      const spill = leftIDs.slice(1)
      const placed = column(zone === 'topLeft' ? [id, ...kept] : [...kept, id])!
      return { left: placed, right: column([...rightIDs, ...spill].slice(0, 2)) }
    }
    case 'topRight':
    case 'bottomRight': {
      const kept = rightIDs.slice(0, 1)
      const spill = rightIDs.slice(1)
      const placed = column(zone === 'topRight' ? [id, ...kept] : [...kept, id])!
      const rest = column([...leftIDs, ...spill].slice(0, 2))
      return rest ? { left: rest, right: placed } : { left: placed }
    }
  }
}

export interface Size { width: number; height: number }
export interface Rect { x: number; y: number; width: number; height: number }

/**
 * The zone a point in the page area asks for: the outer 30% of the width on
 * either side, split into a top, a middle and a bottom third. The middle 40%
 * is no zone — a drop there does nothing, so a drag that wanders over the
 * page does not rearrange it.
 */
export function zoneAt(x: number, y: number, size: Size): DockZone | null {
  if (!(size.width > 0) || !(size.height > 0)) return null
  const fx = x / size.width
  const fy = y / size.height
  const onLeft = fx < 0.3
  const onRight = fx > 0.7
  if (!onLeft && !onRight) return null
  if (fy < 0.33) return onLeft ? 'topLeft' : 'topRight'
  if (fy > 0.67) return onLeft ? 'bottomLeft' : 'bottomRight'
  return onLeft ? 'left' : 'right'
}

/** Where the zone is drawn while a paper is dragged over it. */
export function zoneRect(zone: DockZone, size: Size): Rect {
  const inset = 8
  const w = size.width
  const h = size.height
  const half = w / 2 - inset * 1.5
  const quarter = h / 2 - inset * 1.5
  switch (zone) {
    case 'left': return { x: inset, y: inset, width: half, height: h - inset * 2 }
    case 'right': return { x: w / 2 + inset / 2, y: inset, width: half, height: h - inset * 2 }
    case 'topLeft': return { x: inset, y: inset, width: half, height: quarter }
    case 'topRight': return { x: w / 2 + inset / 2, y: inset, width: half, height: quarter }
    case 'bottomLeft': return { x: inset, y: h / 2 + inset / 2, width: half, height: quarter }
    case 'bottomRight': return { x: w / 2 + inset / 2, y: h / 2 + inset / 2, width: half, height: quarter }
  }
}

/** The MIME type a dragged paper travels under, inside the window. */
export const PAPER_DRAG_TYPE = 'application/x-papertime-paper'
/** And the reader a drag started from, when it started on a side-by-side reader's title: that reader moves rather than a second one opening. */
export const READER_PANE_DRAG_TYPE = 'application/x-papertime-reader-pane'

/**
 * A sidebar row dragged into the row of panes (1.1): `{"shelf": <shelf>}`,
 * the build's own shelf — it never leaves the window.
 */
export const SHELF_DRAG_TYPE = 'application/x-papertime-shelf'
/** A pane's head dragged: the pane's id, and the pane moves. */
export const CONTENT_PANE_DRAG_TYPE = 'application/x-papertime-pane'

export function writeDraggedShelf(data: DataTransfer, shelf: unknown) {
  data.setData(SHELF_DRAG_TYPE, JSON.stringify({ shelf }))
}

export function draggedShelf(data: DataTransfer | null | undefined): unknown | null {
  const raw = data?.getData(SHELF_DRAG_TYPE) ?? ''
  if (!raw) return null
  try {
    const value = JSON.parse(raw) as { shelf?: unknown }
    return value && typeof value === 'object' && value.shelf && typeof value.shelf === 'object' ? value.shelf : null
  } catch {
    return null
  }
}

/**
 * Whether a drag is a shelf's or a pane's — the drags the row of panes takes,
 * with their three zones. Papers and notes keep their own places to go.
 */
export function carriesPaneDrop(data: DataTransfer | null | undefined): boolean {
  if (!data) return false
  const types = [...data.types]
  if (types.includes(PAPER_DRAG_TYPE) || types.includes('application/x-papertime-note')) return false
  return types.includes(SHELF_DRAG_TYPE) || types.includes(CONTENT_PANE_DRAG_TYPE)
}

/**
 * The papers a drag carries. A drag that starts on one of several chosen
 * rows carries all of them — the Mac's `draggedPapers(startingAt:)` — so
 * filing a term's slides into a collection is one gesture. One identifier
 * per line: a drag from the open-papers popup or a pane's title carries one,
 * and reads the same.
 */
export function writeDraggedPapers(data: DataTransfer, ids: string[]) {
  data.setData(PAPER_DRAG_TYPE, ids.join('\n'))
}

export function draggedPapers(data: DataTransfer | null | undefined): string[] {
  const raw = data?.getData(PAPER_DRAG_TYPE) ?? ''
  return raw.split('\n').map((one) => one.trim()).filter(Boolean)
}

/** Whether a drag is carrying papers — all a drop target can know before the drop. */
export function carriesPapers(data: DataTransfer | null | undefined): boolean {
  return Boolean(data && [...data.types].includes(PAPER_DRAG_TYPE))
}

/** A note, dragged from the slip-box's list: onto an area in the sidebar to file it there (the Mac's `NoteTransfer`). */
export const NOTE_DRAG_TYPE = 'application/x-papertime-note'

export function writeDraggedNote(data: DataTransfer, id: string) {
  data.setData(NOTE_DRAG_TYPE, id)
}

export function draggedNote(data: DataTransfer | null | undefined): string | null {
  const id = (data?.getData(NOTE_DRAG_TYPE) ?? '').trim()
  return id || null
}

/** Whether a drag is carrying a note. */
export function carriesNote(data: DataTransfer | null | undefined): boolean {
  return Boolean(data && [...data.types].includes(NOTE_DRAG_TYPE))
}
