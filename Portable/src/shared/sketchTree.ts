/**
 * A page's elements read as a tree — `InkEngine/SketchTree.swift`.
 *
 * The array stays flat: the file is a flat list, and every renderer and every
 * PDF copy walks it as one. The tree is read off the `parent` fields when
 * something needs it — what a click selects, what a drag takes along, where a
 * frame's children go — and `normalized` puts the list back in the order a
 * tree wants after every change, with every frame's layout applied and every
 * group's box drawn round its children. The arithmetic here is the Mac's,
 * step for step, so a frame laid out on Windows lands where the Mac would
 * have put it and the sidecar comes out the same.
 */
import { L } from './lang.js'
import {
  SketchElement,
  rectUnionAll,
  rectInset,
  rectContains,
  rectMaxX,
  rectMaxY,
  rectMidX,
  rectMidY,
  type Point,
  type Rect,
  type SketchLayout,
} from './sketch.js'

export class SketchTree {
  readonly elements: SketchElement[]
  private readonly position = new Map<string, number>()
  private readonly childIDs = new Map<string, string[]>()
  /** The elements with no parent, in the order they lie. */
  readonly roots: string[] = []

  constructor(elements: SketchElement[]) {
    this.elements = elements
    elements.forEach((element, index) => this.position.set(element.id, index))
    for (const element of elements) {
      // A parent that is not on the page — hidden mid-drag, or lost — makes
      // its children roots for now.
      if (element.parent && this.position.has(element.parent) && element.parent !== element.id) {
        const list = this.childIDs.get(element.parent)
        if (list) list.push(element.id)
        else this.childIDs.set(element.parent, [element.id])
      } else {
        this.roots.push(element.id)
      }
    }
  }

  get(id: string): SketchElement | undefined {
    const index = this.position.get(id)
    return index === undefined ? undefined : this.elements[index]
  }

  children(id: string): SketchElement[] {
    return (this.childIDs.get(id) ?? []).map((child) => this.get(child)).filter((e): e is SketchElement => e !== undefined)
  }

  hasChildren(id: string): boolean {
    return (this.childIDs.get(id) ?? []).length > 0
  }

  /** Everything inside a container, at any depth, parents before children. */
  descendants(id: string): SketchElement[] {
    const out: SketchElement[] = []
    const walk = (parent: string) => {
      for (const child of this.children(parent)) {
        out.push(child)
        walk(child.id)
      }
    }
    walk(id)
    return out
  }

  descendantIDs(id: string): Set<string> {
    return new Set(this.descendants(id).map((element) => element.id))
  }

  /** The chain above an element, nearest first. */
  ancestors(id: string): SketchElement[] {
    const out: SketchElement[] = []
    let current = this.get(id)?.parent ?? null
    const seen = new Set([id])
    while (current && !seen.has(current)) {
      const element = this.get(current)
      if (!element) break
      out.push(element)
      seen.add(current)
      current = element.parent
    }
    return out
  }

  isDescendant(id: string, container: string): boolean {
    return this.ancestors(id).some((ancestor) => ancestor.id === container)
  }

  /** The element at the top of an element's chain. */
  root(id: string): SketchElement | undefined {
    const chain = this.ancestors(id)
    return chain.length > 0 ? chain[chain.length - 1] : this.get(id)
  }

  /**
   * What a click on an element selects.
   *
   * Figma's rule: a group is picked up whole — the outermost group round the
   * thing clicked — while a frame lets the click through to its children,
   * because a frame is a place and a group is a thing. A group that has been
   * entered (double-clicked) lets the click through to the child inside it,
   * one level down.
   */
  selectable(id: string, entered: string | null = null): string {
    let chosen = id
    for (const ancestor of this.ancestors(id)) {
      if (ancestor.id === entered) break
      if (ancestor.kind === 'group') chosen = ancestor.id
    }
    return chosen
  }

  /**
   * Everything an element covers, its descendants included.
   *
   * A frame is its own box whatever lies in it; a group is the box round its
   * children; anything else is what it is on its own.
   */
  bounds(id: string): Rect | null {
    const element = this.get(id)
    if (!element) return null
    switch (element.kind) {
      case 'group': {
        const inner = this.children(id).map((child) => this.bounds(child.id)).filter((r): r is Rect => r !== null)
        return inner.length === 0 ? element.rect : rectUnionAll(inner)
      }
      case 'frame':
        return element.rect
      case 'line':
      case 'arrow':
        return element.bounds
      default:
        return element.rect
    }
  }

  /** The box round several elements. */
  boundsOf(ids: Iterable<string>): Rect | null {
    return rectUnionAll([...ids].map((id) => this.bounds(id)).filter((r): r is Rect => r !== null))
  }

  /** The ids among these that are not inside another of them — what a
   *  selection is really of, once its descendants are taken out. */
  outermost(ids: Iterable<string>): Set<string> {
    const set = new Set(ids)
    const out = new Set<string>()
    for (const id of set) {
      if (!this.ancestors(id).some((ancestor) => set.has(ancestor.id))) out.add(id)
    }
    return out
  }

  /** These ids and everything inside them. */
  expanded(ids: Iterable<string>): Set<string> {
    const out = new Set(ids)
    for (const id of [...out]) for (const inner of this.descendantIDs(id)) out.add(inner)
    return out
  }

  // MARK: - Keeping the list honest

  /**
   * The same elements, put in the order a tree wants — every element after
   * its parent, each container's children in their own order — with every
   * frame's layout applied and every group's own box drawn round its
   * children. Every change to a page passes through this.
   */
  static normalized(elements: SketchElement[]): SketchElement[] {
    let tree = new SketchTree(elements)
    const ordered: SketchElement[] = []
    const emit = (id: string) => {
      const element = tree.get(id)
      if (!element) return
      if (element.parent && !tree.get(element.parent)) {
        const loose = element.copy()
        loose.id = element.id
        loose.parent = null
        ordered.push(loose)
      } else {
        ordered.push(element)
      }
      for (const child of tree.children(id)) emit(child.id)
    }
    for (const root of tree.roots) emit(root)
    tree = new SketchTree(ordered)
    let result = ordered
    // Innermost first: an outer frame's layout measures its inner frame
    // after that one has taken its own size.
    const settle = (id: string) => {
      for (const child of tree.children(id)) settle(child.id)
      const element = tree.get(id)
      if (!element || !element.isContainer) return
      if (element.kind === 'frame' && element.layout) {
        result = SketchTree.arrange(id, element.layout, result)
        tree = new SketchTree(result)
      } else if (element.kind === 'group' && tree.hasChildren(id)) {
        const box = tree.bounds(id)
        const i = result.findIndex((entry) => entry.id === id)
        if (i !== -1 && box && !sameRect(result[i].rect, box)) {
          const grown = result[i].copy()
          grown.id = id
          grown.setRect(box)
          result = result.map((entry, index) => (index === i ? grown : entry))
          tree = new SketchTree(result)
        }
      }
    }
    for (const root of tree.roots) settle(root)
    return result
  }

  /**
   * Moves a frame's children into their row or column, and — when the frame
   * hugs — fits the frame round them, keeping its top-left corner where it is.
   */
  static arrange(frameID: string, layout: SketchLayout, elements: SketchElement[]): SketchElement[] {
    const tree = new SketchTree(elements)
    const frame = tree.get(frameID)
    if (!frame) return elements
    const children = tree.children(frameID)
    if (children.length === 0) return elements
    let result = [...elements]
    const boxes = children.map((child) => tree.bounds(child.id) ?? child.rect)
    const pad = layout.padding
    const gapTotal = layout.gap * (children.length - 1)
    const content = layout.direction === 'vertical'
      ? { width: Math.max(0, ...boxes.map((b) => b.width)), height: boxes.reduce((sum, b) => sum + b.height, 0) + gapTotal }
      : { width: boxes.reduce((sum, b) => sum + b.width, 0) + gapTotal, height: Math.max(0, ...boxes.map((b) => b.height)) }
    let outer = frame.rect
    if (layout.hugs) {
      outer = {
        x: outer.x,
        y: rectMaxY(outer) - content.height - pad * 2,
        width: content.width + pad * 2,
        height: content.height + pad * 2,
      }
      const i = result.findIndex((entry) => entry.id === frameID)
      if (i !== -1) {
        const fitted = result[i].copy()
        fitted.id = frameID
        fitted.setRect(outer)
        result[i] = fitted
      }
    }
    const inner = rectInset(outer, pad, pad)
    let cursor = layout.direction === 'vertical' ? rectMaxY(inner) : inner.x
    children.forEach((child, index) => {
      const box = boxes[index]
      let target: Point
      if (layout.direction === 'vertical') {
        let x: number
        switch (layout.align) {
          case 'start': x = inner.x; break
          case 'center': x = rectMidX(inner) - box.width / 2; break
          case 'end': x = rectMaxX(inner) - box.width; break
        }
        target = { x, y: cursor - box.height }
        cursor -= box.height + layout.gap
      } else {
        let y: number
        switch (layout.align) {
          case 'start': y = rectMaxY(inner) - box.height; break
          case 'center': y = rectMidY(inner) - box.height / 2; break
          case 'end': y = inner.y; break
        }
        target = { x: cursor, y }
        cursor += box.width + layout.gap
      }
      const delta = { x: target.x - box.x, y: target.y - box.y }
      if (!(Math.abs(delta.x) > 0.001 || Math.abs(delta.y) > 0.001)) return
      const moving = tree.descendantIDs(child.id)
      moving.add(child.id)
      result = result.map((entry) => (moving.has(entry.id) ? entry.translated(delta) : entry))
    })
    return result
  }
}

// MARK: - The moves the input view makes on the tree

/**
 * Elements just moved or made, given the frame they landed in — the topmost
 * frame whose box holds their middle — or set loose if they left one. Groups
 * are not taken apart by this: a thing dragged out of its group stays in
 * the group.
 */
export function adopted(ids: Iterable<string>, elements: SketchElement[]): SketchElement[] {
  const tree = new SketchTree(elements)
  const out = [...elements]
  const wanted = [...ids]
  const moving = tree.expanded(wanted)
  for (const id of wanted) {
    const i = out.findIndex((entry) => entry.id === id)
    if (i === -1) continue
    const parent = out[i].parent
    if (parent && tree.get(parent)?.kind === 'group') continue
    const box = tree.bounds(id)
    if (!box) continue
    const centre = { x: rectMidX(box), y: rectMidY(box) }
    let home: SketchElement | null = null
    for (let index = elements.length - 1; index >= 0; index -= 1) {
      const candidate = elements[index]
      if (candidate.kind === 'frame' && !moving.has(candidate.id) && rectContains(candidate.rect, centre)
        && !tree.isDescendant(candidate.id, id)) {
        home = candidate
        break
      }
    }
    const placed = out[i].copy()
    placed.id = id
    placed.parent = home?.id ?? null
    out[i] = placed
  }
  return out
}

/** Without the groups nothing is left in. A frame stays; it is a place. */
export function pruned(elements: SketchElement[]): SketchElement[] {
  let out = elements
  for (;;) {
    const tree = new SketchTree(out)
    const empty = new Set(out.filter((entry) => entry.kind === 'group' && !tree.hasChildren(entry.id)).map((entry) => entry.id))
    if (empty.size === 0) return out
    out = out.filter((entry) => !empty.has(entry.id))
  }
}

export function commonParent(ids: Iterable<string>, tree: SketchTree): string | null {
  const parents = new Set([...ids].map((id) => tree.get(id)?.parent ?? null))
  return parents.size === 1 ? [...parents][0] : null
}

/** "Frame N": one more than the frames the page already has. */
export function nextFrameName(elements: SketchElement[]): string {
  const count = elements.filter((entry) => entry.kind === 'frame').length
  return L(`프레임 ${count + 1}`, `Frame ${count + 1}`)
}

/** A row when the children spread more sideways than up and down. */
export function guessedDirection(boxes: Rect[]): 'vertical' | 'horizontal' {
  if (boxes.length <= 1) return 'vertical'
  const union = rectUnionAll(boxes)!
  const widest = Math.max(...boxes.map((b) => b.width))
  const tallest = Math.max(...boxes.map((b) => b.height))
  return union.width - widest > union.height - tallest ? 'horizontal' : 'vertical'
}

/**
 * The children put in the order they lie — top to bottom, or left to right —
 * so a layout that starts keeps them where the eye had them.
 */
export function ordered(ids: string[], direction: 'vertical' | 'horizontal', elements: SketchElement[], tree: SketchTree): SketchElement[] {
  const sorted = [...ids].sort((a, b) => {
    const ra = tree.bounds(a) ?? { x: 0, y: 0, width: 0, height: 0 }
    const rb = tree.bounds(b) ?? { x: 0, y: 0, width: 0, height: 0 }
    if (direction === 'vertical') return rectMaxY(rb) - rectMaxY(ra)
    return ra.x - rb.x
  })
  if (sorted.every((id, index) => id === ids[index])) return elements
  // Reorder the array so these children (and only these) appear in the
  // sorted order at the slots they occupied.
  const out = [...elements]
  const wanted = new Set(ids)
  const slots = out.map((entry, index) => (wanted.has(entry.id) ? index : -1)).filter((index) => index !== -1)
  const byID = new Map(out.map((entry) => [entry.id, entry]))
  slots.forEach((slot, index) => {
    out[slot] = byID.get(sorted[index])!
  })
  return out
}

/**
 * Copies of these elements and everything in them, with new ids and the
 * parent links carried across — the outermost copies loose.
 */
export function copied(
  ids: Iterable<string>,
  elements: SketchElement[],
  shift: Point,
  newID: () => string,
): { copies: SketchElement[]; roots: Set<string> } {
  const tree = new SketchTree(elements)
  const members = tree.outermost(ids)
  const taking = tree.expanded(members)
  const renamed = new Map<string, string>()
  for (const id of taking) renamed.set(id, newID())
  const copies: SketchElement[] = []
  for (const element of elements) {
    if (!taking.has(element.id)) continue
    const copy = shift.x === 0 && shift.y === 0 ? element.copy() : element.translated(shift)
    copy.id = renamed.get(element.id)!
    copy.createdAt = new Date()
    copy.resetCreatedAt()
    copy.parent = element.parent && renamed.has(element.parent)
      ? renamed.get(element.parent)!
      : members.has(element.id) ? element.parent : null
    copies.push(copy)
  }
  return { copies, roots: new Set([...members].map((id) => renamed.get(id)!)) }
}

/** Whether two lists of elements would write the same file. */
export function sameElements(a: SketchElement[], b: SketchElement[]): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i += 1) {
    if (JSON.stringify(a[i].encode()) !== JSON.stringify(b[i].encode())) return false
  }
  return true
}

function sameRect(a: Rect, b: Rect): boolean {
  return Math.abs(a.x - b.x) < 1e-9 && Math.abs(a.y - b.y) < 1e-9
    && Math.abs(a.width - b.width) < 1e-9 && Math.abs(a.height - b.height) < 1e-9
}
