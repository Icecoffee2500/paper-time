/**
 * What a box being dragged should line up with — `InkEngine/SketchSnap.swift`.
 *
 * Figma's behaviour, and the reason it is worth having: a page of cards laid
 * out by eye is a page of cards that are all nearly aligned, and nearly is
 * what makes a page look unmade. The drag gives up the last few points to the
 * nearest edge or centre, and says which line it found so the reader can see
 * why it moved.
 *
 * Pure geometry, on purpose — no page, no canvas, no pdf.js — so it is tested
 * without a window, the way `sketchTree.ts` is. The arithmetic and the order
 * things are compared in are the Mac's, step for step: a tie goes to the first
 * line found, and a card dragged on Windows lands where the Mac would put it.
 */
import { rectMaxX, rectMaxY, rectMidX, rectMidY, type Point, type Rect } from './sketch.js'

export type SnapAxis = 'vertical' | 'horizontal'

/** A line the drag lined up with, in page coordinates. */
export class SnapGuide {
  /** Where the line is: an x for a vertical guide, a y for a horizontal. */
  readonly position: number
  /** How far the line reaches — enough to touch both the box that moved and
   *  the one it lined up with, which is what makes it readable. */
  readonly from: number
  readonly to: number

  constructor(readonly axis: SnapAxis, position: number, from: number, to: number) {
    this.position = position
    this.from = Math.min(from, to)
    this.to = Math.max(from, to)
  }
}

export interface SnapResult {
  offset: Point
  guides: SnapGuide[]
}

interface Best {
  distance: number
  shift: number
  guide: SnapGuide
}

/** The three places a box can line up by, on each axis: its two edges and
 *  its middle. Six numbers, compared against the same six of everything else
 *  on the page. */
function marks(box: Rect): { x: number[]; y: number[] } {
  return {
    x: [box.x, rectMidX(box), rectMaxX(box)],
    y: [box.y, rectMidY(box), rectMaxY(box)],
  }
}

export const SketchSnap = {
  /**
   * Corrects a drag so it lines up, when something is close enough.
   *
   * `tolerance` is in page points and should be the same few points on screen
   * at any zoom — the caller divides by the zoom, as the rest of the input
   * surface does for hitting things.
   */
  adjust(box: Rect, offset: Point, others: Rect[], page: Rect | null = null, tolerance = 6): SnapResult {
    if (!(tolerance > 0)) return { offset: { x: offset.x, y: offset.y }, guides: [] }
    const moved: Rect = { x: box.x + offset.x, y: box.y + offset.y, width: box.width, height: box.height }
    const candidates = [...others]
    // The page's own edges and middle, because a card centred on the page is
    // a thing people line up by and nothing else on the page says where that is.
    if (page) candidates.push(page)

    const mine = marks(moved)
    let bestX: Best | null = null
    let bestY: Best | null = null

    for (const other of candidates) {
      const theirs = marks(other)
      for (const mineX of mine.x) {
        for (const theirX of theirs.x) {
          const distance = Math.abs(theirX - mineX)
          if (!(distance <= tolerance) || !(distance < (bestX?.distance ?? Infinity))) continue
          bestX = {
            distance,
            shift: theirX - mineX,
            guide: new SnapGuide(
              'vertical', theirX,
              Math.min(moved.y, other.y), Math.max(rectMaxY(moved), rectMaxY(other)),
            ),
          }
        }
      }
      for (const mineY of mine.y) {
        for (const theirY of theirs.y) {
          const distance = Math.abs(theirY - mineY)
          if (!(distance <= tolerance) || !(distance < (bestY?.distance ?? Infinity))) continue
          bestY = {
            distance,
            shift: theirY - mineY,
            guide: new SnapGuide(
              'horizontal', theirY,
              Math.min(moved.x, other.x), Math.max(rectMaxX(moved), rectMaxX(other)),
            ),
          }
        }
      }
    }

    const guides: SnapGuide[] = []
    if (bestX) guides.push(bestX.guide)
    if (bestY) guides.push(bestY.guide)
    return {
      offset: { x: offset.x + (bestX?.shift ?? 0), y: offset.y + (bestY?.shift ?? 0) },
      guides,
    }
  },
}
