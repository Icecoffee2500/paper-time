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

export interface SplitColumn {
  top: string
  bottom?: string
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

/** Every paper in the arrangement, left column first, top before bottom. */
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
 * Puts a paper into a zone. What was there slides to the other half of its
 * column; what there is no room for leaves the arrangement.
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
