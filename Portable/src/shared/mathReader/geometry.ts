/**
 * CoreGraphics' rectangles, with the edge cases MathReader leans on — read
 * off the Mac (`CGRect`), not assumed:
 *
 * - `intersects` is half-open on each axis, and a side of zero length is a
 *   point on it: two boxes that only touch do not intersect, a line inside
 *   one does, and a line on its far edge does not.
 * - `intersection` of boxes that only touch is a box of zero width, not null;
 *   of boxes apart, null.
 * - `insetBy` past nothing is null. `union` with null is the other.
 * - `contains` a point is half-open like `intersects`.
 */

export interface Rect { x: number; y: number; width: number; height: number }
export interface Point { x: number; y: number }

export const NULL_RECT: Rect = { x: Infinity, y: Infinity, width: 0, height: 0 }
export const ZERO_RECT: Rect = { x: 0, y: 0, width: 0, height: 0 }

export const isNull = (r: Rect) => r.x === Infinity || r.y === Infinity
export const minX = (r: Rect) => r.x
export const minY = (r: Rect) => r.y
export const maxX = (r: Rect) => r.x + r.width
export const maxY = (r: Rect) => r.y + r.height
export const midX = (r: Rect) => r.x + r.width / 2
export const midY = (r: Rect) => r.y + r.height / 2

export function isEmpty(r: Rect): boolean {
  return isNull(r) || r.width === 0 || r.height === 0
}

export function union(a: Rect, b: Rect): Rect {
  if (isNull(a)) return b
  if (isNull(b)) return a
  const x = Math.min(a.x, b.x)
  const y = Math.min(a.y, b.y)
  return { x, y, width: Math.max(maxX(a), maxX(b)) - x, height: Math.max(maxY(a), maxY(b)) - y }
}

export function intersection(a: Rect, b: Rect): Rect {
  if (isNull(a) || isNull(b)) return NULL_RECT
  const x = Math.max(a.x, b.x)
  const y = Math.max(a.y, b.y)
  const right = Math.min(maxX(a), maxX(b))
  const top = Math.min(maxY(a), maxY(b))
  if (x > right || y > top) return NULL_RECT
  return { x, y, width: right - x, height: top - y }
}

function overlaps(a0: number, a1: number, b0: number, b1: number): boolean {
  const la = a1 - a0
  const lb = b1 - b0
  if (la > 0 && lb > 0) return Math.max(a0, b0) < Math.min(a1, b1)
  if (la === 0 && lb > 0) return a0 >= b0 && a0 < b1
  if (lb === 0 && la > 0) return b0 >= a0 && b0 < a1
  return a0 === b0
}

export function intersects(a: Rect, b: Rect): boolean {
  if (isNull(a) || isNull(b)) return false
  return overlaps(a.x, maxX(a), b.x, maxX(b)) && overlaps(a.y, maxY(a), b.y, maxY(b))
}

/** `CGRect.contains(CGPoint)`: half-open too — a point on the far edge is
 *  outside, and a box of no width holds nothing. */
export function containsPoint(r: Rect, p: Point): boolean {
  if (isNull(r)) return false
  return p.x >= minX(r) && p.x < maxX(r) && p.y >= minY(r) && p.y < maxY(r)
}

export function insetBy(r: Rect, dx: number, dy: number): Rect {
  if (isNull(r)) return r
  const width = r.width - dx * 2
  const height = r.height - dy * 2
  if (width < 0 || height < 0) return NULL_RECT
  return { x: r.x + dx, y: r.y + dy, width, height }
}

export function offsetBy(r: Rect, dx: number, dy: number): Rect {
  return isNull(r) ? r : { x: r.x + dx, y: r.y + dy, width: r.width, height: r.height }
}

export function sameRect(a: Rect, b: Rect): boolean {
  return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height
}

/** `CGAffineTransform` as [a, b, c, d, tx, ty]. */
export type Matrix = [number, number, number, number, number, number]
export const IDENTITY: Matrix = [1, 0, 0, 1, 0, 0]

/** `t1.concatenating(t2)`: t1, then t2 — CoreGraphics' order of operations. */
export function concat(t1: Matrix, t2: Matrix): Matrix {
  return [
    t1[0] * t2[0] + t1[1] * t2[2],
    t1[0] * t2[1] + t1[1] * t2[3],
    t1[2] * t2[0] + t1[3] * t2[2],
    t1[2] * t2[1] + t1[3] * t2[3],
    t1[4] * t2[0] + t1[5] * t2[2] + t2[4],
    t1[4] * t2[1] + t1[5] * t2[3] + t2[5],
  ]
}

export function applyPoint(p: Point, t: Matrix): Point {
  return { x: t[0] * p.x + t[2] * p.y + t[4], y: t[1] * p.x + t[3] * p.y + t[5] }
}

/** `CGRect.applying`: the box round the four corners. */
export function applyRect(r: Rect, t: Matrix): Rect {
  const corners = [
    applyPoint({ x: r.x, y: r.y }, t), applyPoint({ x: maxX(r), y: r.y }, t),
    applyPoint({ x: r.x, y: maxY(r) }, t), applyPoint({ x: maxX(r), y: maxY(r) }, t),
  ]
  const xs = corners.map((c) => c.x)
  const ys = corners.map((c) => c.y)
  const x = Math.min(...xs)
  const y = Math.min(...ys)
  return { x, y, width: Math.max(...xs) - x, height: Math.max(...ys) - y }
}
