/**
 * The drawing layer's geometry, without a page or a pointer: where a
 * handle is, what a handle does to an element, where Shift holds a drag,
 * whether a point touches a stroke. Pure, so the gestures that use it are
 * tested (`src/test/sketchGeometry.ts`) rather than dragged.
 */
import {
  rectContains,
  rectFrom,
  rectInset,
  rectMaxX,
  rectMaxY,
  rectMidX,
  rectMidY,
  rectUnionAll,
  type Point,
  type Rect,
  type SketchElement,
} from './sketch.js'
import type { SketchTree } from './sketchTree.js'
import type { InkStroke } from './ink.js'
import { fittedRect } from './sketchRender.js'

/** Where a handle sits on a selected element. */
export type Handle =
  | 'topLeft' | 'top' | 'topRight' | 'right'
  | 'bottomRight' | 'bottom' | 'bottomLeft' | 'left'
  | 'start' | 'end' | 'mid'

export const BOX_HANDLES: Handle[] = [
  'topLeft', 'top', 'topRight', 'right', 'bottomRight', 'bottom', 'bottomLeft', 'left',
]

/** A page's box in its own points, from `[x0, y0, x1, y1]`. */
export function pageRect(view: number[]): Rect {
  return { x: view[0], y: view[1], width: view[2] - view[0], height: view[3] - view[1] }
}

/** A handle's place on a box — in page coordinates, y up, so the top is the
 *  box's largest y. */
export function handlePoint(box: Rect, handle: Handle): Point {
  switch (handle) {
    case 'topLeft': return { x: box.x, y: rectMaxY(box) }
    case 'top': return { x: rectMidX(box), y: rectMaxY(box) }
    case 'topRight': return { x: rectMaxX(box), y: rectMaxY(box) }
    case 'right': return { x: rectMaxX(box), y: rectMidY(box) }
    case 'bottomRight': return { x: rectMaxX(box), y: box.y }
    case 'bottom': return { x: rectMidX(box), y: box.y }
    case 'bottomLeft': return { x: box.x, y: box.y }
    case 'left': return { x: box.x, y: rectMidY(box) }
    default: return { x: rectMidX(box), y: rectMidY(box) }
  }
}

/**
 * Where Shift holds a drag: a box stays square; a line keeps to the nearest
 * eighth of a turn, at the length the hand has pulled it.
 */
export function constrained(origin: Point, point: Point, isLine: boolean): Point {
  const dx = point.x - origin.x
  const dy = point.y - origin.y
  if (!isLine) {
    const side = Math.max(Math.abs(dx), Math.abs(dy))
    return { x: origin.x + side * (dx < 0 ? -1 : 1), y: origin.y + side * (dy < 0 ? -1 : 1) }
  }
  const step = Math.PI / 4
  const angle = Math.round(Math.atan2(dy, dx) / step) * step
  const length = Math.hypot(dx, dy)
  return { x: origin.x + Math.cos(angle) * length, y: origin.y + Math.sin(angle) * length }
}

/** Whether a point is within reach of a stroke — its line, not its box. */
export function strokeTouches(stroke: InkStroke, point: Point, reach: number): boolean {
  const box = stroke.bounds
  if (!rectContains(rectInset(box, -reach, -reach), point)) return false
  return stroke.points.some(
    (sample) => Math.hypot(sample.x - point.x, sample.y - point.y) <= reach + sample.w / 2,
  )
}

/** The box round the chosen strokes, or null. */
export function strokesBox(strokes: InkStroke[], indices: number[]): Rect | null {
  return rectUnionAll(indices.filter((index) => index < strokes.length).map((index) => strokes[index].bounds))
}

/** The element — and, for a container, everything in it — as the handle
 *  leaves it. */
export function resized(original: SketchElement, handle: Handle, p: Point, shift: boolean, tree: SketchTree): SketchElement[] {
  const element = original.copy()
  switch (handle) {
    case 'start':
      element.points = [p, original.end]
      return [element]
    case 'end':
      element.points = [original.start, p]
      return [element]
    case 'mid':
      return [element]
    default:
      break
  }
  const r = (original.kind === 'group' ? tree.bounds(original.id) : null) ?? original.rect
  let minX = r.x, maxX = rectMaxX(r), minY = r.y, maxY = rectMaxY(r)
  switch (handle) {
    case 'topLeft': minX = p.x; maxY = p.y; break
    case 'top': maxY = p.y; break
    case 'topRight': maxX = p.x; maxY = p.y; break
    case 'right': maxX = p.x; break
    case 'bottomRight': maxX = p.x; minY = p.y; break
    case 'bottom': minY = p.y; break
    case 'bottomLeft': minX = p.x; minY = p.y; break
    case 'left': minX = p.x; break
    default: break
  }
  const box = rectFrom({ x: minX, y: minY }, { x: maxX, y: maxY })
  if (shift && original.kind !== 'text') {
    const side = Math.max(box.width, box.height)
    box.width = side
    box.height = side
  }
  box.width = Math.max(box.width, 4)
  box.height = Math.max(box.height, 4)
  switch (original.kind) {
    case 'text':
      // Pulling a text card's handle sets how wide its words may run —
      // which makes it a card of fixed width, as it does in Figma.
      element.textSizing = 'autoHeight'
      element.setRect({ x: box.x, y: rectMaxY(box), width: box.width, height: 0 })
      element.setRect(fittedRect(element))
      return [element]
    case 'frame':
      element.setRect(box)
      // Resized by hand, a frame stops hugging its children. Its children
      // stay where they are; the frame moves round them.
      if (element.layout) element.layout = { ...element.layout, hugs: false }
      return [element, ...tree.descendants(original.id)]
    case 'group': {
      // The group scales with everything in it.
      const out = [element, ...tree.descendants(original.id).map((child) => child.fitted(box, r))]
      out[0].setRect(box)
      return out
    }
    default:
      return [original.fitted(box, r)]
  }
}
