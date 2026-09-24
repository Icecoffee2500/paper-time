/**
 * Drawing on a page with a mouse.
 *
 * Ported from `SketchInputView.swift`, which exists because PDFKit gives the
 * Mac no canvas and its page overlays never see the mouse. Here the reason is
 * different — a PDF rendered to a canvas has no notion of a pen at all — but
 * the answer is the same: a surface over each page that takes every gesture,
 * in page coordinates, with the same tools and the same keys.
 *
 * What the surface has to get right is that a reader is not a drawing program.
 * A shape is drawn by dragging; it is moved by dragging it; it is selected by
 * clicking it or by sweeping a marquee over nothing. Nothing is modal except
 * the tool, and Escape always steps back out. The tree — frames that hold
 * things and lay them out, groups that are picked up whole — is the Mac's,
 * and every change to a page goes through `SketchTree.normalized` so the
 * sidecar written here is the one the Mac would have written.
 */
import { el, on } from '../dom.js'
import { store, subscribe, type SketchTool } from '../state.js'
import {
  SketchColor,
  SketchElement,
  SketchStyle,
  rectContains,
  rectContainsRect,
  rectFrom,
  rectInset,
  rectIntersects,
  rectMaxX,
  rectMaxY,
  rectMidX,
  rectMidY,
  rectUnion,
  rectUnionAll,
  type Point,
  type Rect,
} from '../../shared/sketch.js'
import {
  SketchTree,
  adopted,
  commonParent,
  copied,
  guessedDirection,
  nextFrameName,
  ordered,
  pruned,
  sameElements,
} from '../../shared/sketchTree.js'
import { InkStroke, nibWidth, resample, type InkPoint } from '../../shared/ink.js'
import {
  drawElement,
  drawElements,
  drawInkStroke,
  fittedRect,
  fontSpec,
  pathOf,
  textLineHeight,
  TEXT_PADDING,
} from '../../shared/sketchRender.js'
import { L } from '../../shared/lang.js'
import { makeUUID } from '../../shared/coding.js'
import type { PageView, Reader } from './reader.js'
import { SketchUndo, snapshot, type Snapshot } from './sketchUndo.js'
import { attachLatexSuite, type LatexSuiteField } from './latexSuiteInput.js'
import {
  defaultLayout,
  sketchEditor,
  sketchSelectionChanged,
  type SketchAlignment,
  type SketchEditing,
} from './sketchEditing.js'

export const undoStack = new SketchUndo()

export interface SketchInputHost {
  changed: () => void
  save: (page: PageView) => void
}

/** Where a handle sits on a selected element. */
type Handle =
  | 'topLeft' | 'top' | 'topRight' | 'right'
  | 'bottomRight' | 'bottom' | 'bottomLeft' | 'left'
  | 'start' | 'end' | 'mid'

const BOX_HANDLES: Handle[] = [
  'topLeft', 'top', 'topRight', 'right', 'bottomRight', 'bottom', 'bottomLeft', 'left',
]

interface Selection {
  pageIndex: number
  ids: string[]
  strokeIDs: number[]
}

type Drag =
  | { kind: 'none' }
  | { kind: 'shape'; element: SketchElement }
  | { kind: 'textBox'; origin: Point; current: Point }
  | { kind: 'stroke'; points: InkPoint[]; tool: 'pen' | 'marker' }
  | { kind: 'erase'; last: Point; elementsBefore: SketchElement[]; strokesBefore: InkStroke[] }
  | { kind: 'move'; elementsBefore: SketchElement[]; strokesBefore: InkStroke[]; origin: Point; moved: boolean }
  | { kind: 'resize'; elementsBefore: SketchElement[]; original: SketchElement; handle: Handle }
  | { kind: 'bend'; elementsBefore: SketchElement[]; original: SketchElement }
  | { kind: 'marquee'; origin: Point; current: Point; additive: boolean; before: Selection | null }
  | { kind: 'pendingClick'; origin: Point; additive: boolean; before: Selection | null }

export interface SketchInput {
  detach: () => void
  drawOverlay: (context: CanvasRenderingContext2D) => void
  endTextEditing: () => void
  /** Takes a press that began elsewhere — on the text layer, in read mode. */
  press: (event: PointerEvent) => void
}

/** What the input view offers beyond the panel's contract: the keys. */
export interface SketchInputEditing extends SketchEditing {
  /** Escape, in Figma's order: out of the group, drop the selection, put the tool down, put the pen away. */
  escape(): void
  enterSelectedGroup(): void
  nudge(dx: number, dy: number, far: boolean): void
  copySelection(): boolean
  cutSelection(): void
  pasteSketch(): void
  isEditingText(): boolean
  /** Every key the drawing layer answers to; true when it took the key. */
  handleKey(event: KeyboardEvent): boolean
}

/** Handle size on screen, in CSS pixels — the same however far you zoom. */
const HANDLE_SIZE = 7
/** How near the pointer has to be, on screen, to hit something. */
const HIT_SLOP = 6
const ACCENT = '47, 110, 240'

// MARK: - State shared by every page's surface

/** The group a double-click went into, whose children are chosen one at a
 *  time until the selection leaves it. */
let entered: string | null = null

/** What ⌘C took: the elements as their JSON, the strokes likewise, and the
 *  page they came from so pasting back onto it can offset. */
let clipboard: { elements: unknown[]; strokes: unknown[]; fromPage: number } | null = null

/** The card being typed into, on whichever page. */
let editing: {
  page: PageView
  id: string
  area: HTMLTextAreaElement
  before: SketchElement[]
  isNew: boolean
  host: SketchInputHost
} | null = null
/** Latex Suite in that card: `$…$` on a card is typed the way it is in a note. */
let latexField: LatexSuiteField | null = null

const editors = new WeakMap<Reader, SketchInputEditing>()
let keysInstalled = false
let lastTool: SketchTool = store.sketch.tool

/** Called when the pen goes away: whatever was half done is let go of. */
export function resetSketchInput() {
  entered = null
  if (editing) endTextEditing()
}

export function isEditingSketchText(): boolean {
  return editing !== null
}

// MARK: - The selection, kept in the store

function selection(): Selection | null {
  return store.sketch.selection
}

function selectedPage(reader: Reader): PageView | null {
  const current = selection()
  return current ? reader.pages[current.pageIndex] ?? null : null
}

function setSelection(reader: Reader, host: SketchInputHost, next: Selection | null) {
  const cleaned = next && next.ids.length === 0 && next.strokeIDs.length === 0 ? null : next
  const before = store.sketch.selection
  const same = JSON.stringify(before) === JSON.stringify(cleaned)
  store.sketch.selection = cleaned
  // A group entered is left when the selection leaves it.
  if (entered) {
    const page = cleaned ? reader.pages[cleaned.pageIndex] : null
    const tree = page ? new SketchTree(page.elements) : null
    if (!cleaned || cleaned.ids.length === 0 || !tree || !cleaned.ids.every((id) => tree.isDescendant(id, entered!))) {
      entered = null
    }
  }
  if (!same) {
    sketchSelectionChanged()
    host.changed()
  }
}

/** Tells the panel again after the selection's elements changed under it. */
function refreshSelection(reader: Reader) {
  const current = selection()
  if (current) {
    const page = reader.pages[current.pageIndex]
    const present = new Set(page?.elements.map((element) => element.id) ?? [])
    const kept = current.ids.filter((id) => present.has(id))
    const strokes = current.strokeIDs.filter((index) => index < (page?.strokes.length ?? 0))
    if (kept.length !== current.ids.length || strokes.length !== current.strokeIDs.length) {
      store.sketch.selection = kept.length === 0 && strokes.length === 0
        ? null
        : { pageIndex: current.pageIndex, ids: kept, strokeIDs: strokes }
    }
  }
  sketchSelectionChanged()
}

function selectedElements(reader: Reader): SketchElement[] {
  const current = selection()
  const page = selectedPage(reader)
  if (!current || !page) return []
  return page.elements.filter((element) => current.ids.includes(element.id))
}

function selectedOne(reader: Reader): SketchElement | null {
  const chosen = selectedElements(reader)
  return chosen.length === 1 && (selection()?.strokeIDs.length ?? 0) === 0 ? chosen[0] : null
}

// MARK: - Writing a change

/** One change to a page's elements, put in tree order, written, made
 *  undoable, and shown. */
function apply(reader: Reader, host: SketchInputHost, page: PageView, elements: SketchElement[], before: SketchElement[]): boolean {
  const after = SketchTree.normalized(elements)
  if (sameElements(after, before)) return false
  const was = snapshot(page.index, before, page.strokes)
  page.elements = after
  undoStack.record(was, snapshot(page.index, after, page.strokes))
  host.save(page)
  page.redraw()
  refreshSelection(reader)
  host.changed()
  return true
}

/** The same, for a change that touched the strokes as well. */
function applyBoth(
  reader: Reader, host: SketchInputHost, page: PageView,
  elements: SketchElement[], strokes: InkStroke[],
  elementsBefore: SketchElement[], strokesBefore: InkStroke[],
): boolean {
  const after = SketchTree.normalized(elements)
  const elementsChanged = !sameElements(after, elementsBefore)
  const strokesChanged = strokes !== strokesBefore && (strokes.length !== strokesBefore.length || strokes.some((stroke, index) => stroke !== strokesBefore[index]))
  if (!elementsChanged && !strokesChanged) return false
  const was = snapshot(page.index, elementsBefore, strokesBefore)
  page.elements = after
  page.strokes = strokes
  undoStack.record(was, snapshot(page.index, after, strokes))
  host.save(page)
  page.redraw()
  refreshSelection(reader)
  host.changed()
  return true
}

function pageRectOf(page: PageView): Rect {
  const view = page.proxy.getViewport({ scale: 1 })
  const box = view.viewBox as number[]
  return { x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1] }
}

/** The bounds of a stroke and the pen strokes chosen, as the panel sees them. */
function strokeBox(page: PageView, indices: number[]): Rect | null {
  return rectUnionAll(indices.filter((index) => index < page.strokes.length).map((index) => page.strokes[index].bounds))
}

function strokeTouches(stroke: InkStroke, point: Point, reach: number): boolean {
  const box = stroke.bounds
  if (!rectContains(rectInset(box, -reach, -reach), point)) return false
  return stroke.points.some(
    (sample) => Math.hypot(sample.x - point.x, sample.y - point.y) <= reach + sample.w / 2,
  )
}

// MARK: - The editor the panel talks to

function makeEditing(reader: Reader, host: SketchInputHost): SketchInputEditing {
  const cached = editors.get(reader)
  if (cached) return cached

  const frameStyle = (): SketchStyle => {
    const style = store.sketch.style.copy()
    style.fill = null
    style.startHead = 'none'
    style.endHead = 'none'
    style.corners = 'round'
    return style
  }

  const selectedFrame = (): SketchElement | null => {
    const one = selectedOne(reader)
    return one?.kind === 'frame' ? one : null
  }

  const editor: SketchInputEditing = {
    selectedElements: () => selectedElements(reader).map((element) => element.copy()),
    selectedStrokeCount: () => selection()?.strokeIDs.length ?? 0,
    selectionBox: () => {
      const current = selection()
      const page = selectedPage(reader)
      if (!current || !page) return null
      const tree = new SketchTree(page.elements)
      const boxes = [tree.boundsOf(current.ids), strokeBox(page, current.strokeIDs)].filter((r): r is Rect => r !== null)
      return rectUnionAll(boxes)
    },
    pageBox: () => {
      const page = selectedPage(reader)
      return page ? pageRectOf(page) : null
    },

    applyStyle(change) {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current || current.ids.length === 0) return
      const before = page.elements
      // A group has no look of its own; restyling it restyles what is in
      // it. A frame has one, and keeps its children as they are.
      const tree = new SketchTree(before)
      const targets = new Set(current.ids)
      for (const id of current.ids) if (tree.get(id)?.kind === 'group') for (const inner of tree.descendantIDs(id)) targets.add(inner)
      const after = before.map((element) => {
        if (!targets.has(element.id) || element.kind === 'group') return element
        const changed = element.copy()
        change(changed.style)
        if (changed.kind === 'text' && (changed.style.points !== element.style.points || changed.style.textAlign !== element.style.textAlign)) {
          changed.setRect(fittedRect(changed))
        }
        return changed
      })
      apply(reader, host, page, after, before)
    },

    editSelection(change) {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current || current.ids.length === 0) return
      const before = page.elements
      const after = before.map((element) => {
        if (!current.ids.includes(element.id)) return element
        const changed = element.copy()
        change(changed)
        if (changed.kind === 'text' && changed.textSizing !== element.textSizing) changed.setRect(fittedRect(changed))
        return changed
      })
      apply(reader, host, page, after, before)
    },

    deleteSelection() {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current) return
      const before = page.elements
      const gone = new SketchTree(before).expanded(current.ids)
      const after = pruned(before.filter((element) => !gone.has(element.id)))
      const strokesBefore = page.strokes
      const strokes = current.strokeIDs.length > 0
        ? strokesBefore.filter((_, index) => !current.strokeIDs.includes(index))
        : strokesBefore
      setSelection(reader, host, null)
      applyBoth(reader, host, page, after, strokes, before, strokesBefore)
    },

    duplicateSelection() {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current || current.ids.length === 0) return
      const before = page.elements
      const { copies, roots } = copied(current.ids, before, { x: 12, y: -12 }, makeUUID)
      apply(reader, host, page, [...before, ...copies], before)
      setSelection(reader, host, { pageIndex: page.index, ids: [...roots], strokeIDs: [] })
    },

    /** A frame round the selection — XMind's frame round a topic, Figma's
     *  frame round a selection: it takes the elements in as its children,
     *  and encloses any handwriting that was chosen with them. */
    frameSelection() {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current) return
      const before = page.elements
      const tree = new SketchTree(before)
      let box = rectUnionAll([tree.boundsOf(current.ids), strokeBox(page, current.strokeIDs)].filter((r): r is Rect => r !== null))
      if (!box) return
      box = rectInset(box, -8, -8)
      const frame = new SketchElement({
        kind: 'frame',
        points: [{ x: box.x, y: box.y }, { x: rectMaxX(box), y: rectMaxY(box) }],
        style: frameStyle(),
      })
      frame.name = nextFrameName(before)
      frame.parent = commonParent(current.ids, tree)
      const after = [...before]
      const chosen = new Set(current.ids)
      let lowest = after.findIndex((element) => chosen.has(element.id))
      if (lowest === -1) lowest = after.length
      after.splice(lowest, 0, frame)
      for (let i = 0; i < after.length; i += 1) {
        if (chosen.has(after[i].id)) {
          const child = after[i].copy()
          child.parent = frame.id
          after[i] = child
        }
      }
      apply(reader, host, page, after, before)
      setSelection(reader, host, { pageIndex: page.index, ids: [frame.id], strokeIDs: [] })
    },

    groupSelection() {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current || current.ids.length === 0) return
      const before = page.elements
      const tree = new SketchTree(before)
      const members = tree.outermost(current.ids)
      const box = tree.boundsOf(members)
      if (!box) return
      const group = new SketchElement({
        kind: 'group',
        points: [{ x: box.x, y: box.y }, { x: rectMaxX(box), y: rectMaxY(box) }],
      })
      group.parent = commonParent(members, tree)
      const after = [...before]
      let lowest = after.findIndex((element) => members.has(element.id))
      if (lowest === -1) lowest = after.length
      after.splice(lowest, 0, group)
      for (let i = 0; i < after.length; i += 1) {
        if (members.has(after[i].id)) {
          const child = after[i].copy()
          child.parent = group.id
          after[i] = child
        }
      }
      apply(reader, host, page, after, before)
      entered = null
      setSelection(reader, host, { pageIndex: page.index, ids: [group.id], strokeIDs: [] })
    },

    /** Takes the selected groups and frames apart: their children take
     *  their place, and the container goes. */
    ungroupSelection() {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current || current.ids.length === 0) return
      const before = page.elements
      const tree = new SketchTree(before)
      const containers = current.ids.filter((id) => tree.get(id)?.isContainer)
      if (containers.length === 0) return
      let after = [...before]
      const freed: string[] = []
      for (const id of containers) {
        const container = tree.get(id)
        if (!container) continue
        after = after.map((element) => {
          if (element.parent !== id) return element
          const child = element.copy()
          child.parent = container.parent
          freed.push(child.id)
          return child
        })
      }
      after = after.filter((element) => !containers.includes(element.id))
      apply(reader, host, page, after, before)
      entered = null
      setSelection(reader, host, {
        pageIndex: page.index,
        ids: [...new Set([...freed, ...current.ids.filter((id) => !containers.includes(id))])],
        strokeIDs: [],
      })
    },

    /** Auto layout, the way ⇧A gives it in Figma: on a frame, a column (or
     *  a row, when its children already lie in one) that it then keeps; on
     *  loose elements, a new frame round them that has one; on a frame that
     *  has one, nothing but the frame again. */
    toggleAutoLayout() {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current || current.ids.length === 0) return
      const layOut = (frameID: string) => {
        const now = page.elements
        const tree = new SketchTree(now)
        const i = now.findIndex((element) => element.id === frameID)
        if (i === -1) return
        const children = tree.children(frameID)
        const direction = guessedDirection(children.map((child) => tree.bounds(child.id) ?? child.rect))
        let after = [...now]
        const framed = after[i].copy()
        framed.layout = { ...defaultLayout(), direction }
        after[i] = framed
        after = ordered(children.map((child) => child.id), direction, after, tree)
        apply(reader, host, page, after, now)
      }
      const frame = selectedFrame()
      if (frame) {
        if (frame.layout) {
          editor.editSelection((element) => { element.layout = null })
          return
        }
        layOut(frame.id)
        return
      }
      // Loose elements: a frame is put round them first, then laid out.
      editor.frameSelection()
      const made = selectedFrame()
      if (made) layOut(made.id)
    },

    bringSelectionToFront() {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current || current.ids.length === 0) return
      const before = page.elements
      // Among siblings: `normalized` gathers each parent's children in
      // array order, so putting the chosen ones last puts them on top of
      // their siblings and nowhere else.
      const chosen = new Set(current.ids)
      const after = [...before.filter((e) => !chosen.has(e.id)), ...before.filter((e) => chosen.has(e.id))]
      apply(reader, host, page, after, before)
    },

    sendSelectionToBack() {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current || current.ids.length === 0) return
      const before = page.elements
      const chosen = new Set(current.ids)
      const after = [...before.filter((e) => chosen.has(e.id)), ...before.filter((e) => !chosen.has(e.id))]
      apply(reader, host, page, after, before)
    },

    selectAllOnPage() {
      const page = reader.pages[store.reader.currentPage]
      if (!page) return
      entered = null
      const roots = new SketchTree(page.elements).roots
      setSelection(reader, host, {
        pageIndex: page.index,
        ids: roots,
        strokeIDs: page.strokes.map((_, index) => index),
      })
    },

    editSelectedText() {
      const page = selectedPage(reader)
      const one = selectedOne(reader)
      if (!page || !one || one.isContainer || one.isConnector) return
      beginTextEditing(reader, host, page, one, false)
    },

    align(alignment: SketchAlignment) {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current || current.ids.length === 0) return
      const before = page.elements
      const tree = new SketchTree(before)
      const members = tree.outermost(current.ids)
      // What to line up with: each other when there are several; the frame
      // round it when there is one and it is in a frame; the page.
      let reference: Rect
      const only = [...members][0]
      const parent = only ? tree.get(only)?.parent ?? null : null
      const frame = parent ? tree.get(parent) : undefined
      if (members.size > 1) {
        reference = tree.boundsOf(members) ?? pageRectOf(page)
      } else if (frame && frame.kind === 'frame') {
        const pad = frame.layout?.padding ?? 0
        reference = rectInset(frame.rect, pad, pad)
      } else {
        reference = pageRectOf(page)
      }
      let after = [...before]
      for (const id of members) {
        const box = tree.bounds(id)
        if (!box) continue
        const delta = { x: 0, y: 0 }
        switch (alignment) {
          case 'left': delta.x = reference.x - box.x; break
          case 'centerX': delta.x = rectMidX(reference) - rectMidX(box); break
          case 'right': delta.x = rectMaxX(reference) - rectMaxX(box); break
          case 'top': delta.y = rectMaxY(reference) - rectMaxY(box); break
          case 'centerY': delta.y = rectMidY(reference) - rectMidY(box); break
          case 'bottom': delta.y = reference.y - box.y; break
        }
        if (!(Math.abs(delta.x) > 0.01 || Math.abs(delta.y) > 0.01)) continue
        const moving = tree.expanded([id])
        after = after.map((element) => (moving.has(element.id) ? element.translated(delta) : element))
      }
      apply(reader, host, page, after, before)
    },

    setSelectionOrigin(x, top) {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current || current.ids.length === 0) return
      const before = page.elements
      const tree = new SketchTree(before)
      const members = tree.outermost(current.ids)
      const box = tree.boundsOf(members)
      if (!box) return
      const pageTop = rectMaxY(pageRectOf(page))
      const delta = { x: 0, y: 0 }
      if (x !== null) delta.x = x - box.x
      if (top !== null) delta.y = (pageTop - top) - rectMaxY(box)
      if (!(Math.abs(delta.x) > 0.01 || Math.abs(delta.y) > 0.01)) return
      const moving = tree.expanded(members)
      apply(reader, host, page, before.map((element) => (moving.has(element.id) ? element.translated(delta) : element)), before)
    },

    setSelectionSize(width, height) {
      const page = selectedPage(reader)
      const one = selectedOne(reader)
      if (!page || !one || one.isConnector) return
      const before = page.elements
      const tree = new SketchTree(before)
      const old = (one.kind === 'group' ? tree.bounds(one.id) : null) ?? one.rect
      const box = { ...old }
      if (width !== null) box.width = Math.max(width, 1)
      if (height !== null) {
        box.height = Math.max(height, 1)
        box.y = rectMaxY(old) - box.height
      }
      if (box.width === old.width && box.height === old.height && box.y === old.y) return
      const changed = resized(one, 'bottomRight', { x: rectMaxX(box), y: box.y }, false, tree)
      const after = before.map((element) => changed.find((entry) => entry.id === element.id) ?? element)
      apply(reader, host, page, after, before)
    },

    // ------------------------------------------------------------ the keys

    escape() {
      if (editing) {
        endTextEditing()
        return
      }
      if (entered) {
        const group = entered
        const current = selection()
        entered = null
        setSelection(reader, host, current ? { pageIndex: current.pageIndex, ids: [group], strokeIDs: [] } : null)
        return
      }
      if (selection()) {
        setSelection(reader, host, null)
        return
      }
      if (store.sketch.tool !== 'select') {
        store.sketch.tool = 'select'
        lastTool = 'select'
        host.changed()
        return
      }
      reader.setDrawing(false)
      reader.update()
      host.changed()
    },

    /** Into the selected group: its first child is chosen, and the next
     *  clicks choose among its children. */
    enterSelectedGroup() {
      const page = selectedPage(reader)
      const group = selectedOne(reader)
      if (!page || !group || group.kind !== 'group') return
      const first = new SketchTree(page.elements).children(group.id)[0]
      if (!first) return
      entered = group.id
      setSelection(reader, host, { pageIndex: page.index, ids: [first.id], strokeIDs: [] })
    },

    nudge(dx, dy, far) {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current) return
      const step = far ? 10 : 1
      const offset = { x: dx * step, y: dy * step }
      const before = page.elements
      const moving = new SketchTree(before).expanded(current.ids)
      const after = before.map((element) => (moving.has(element.id) ? element.translated(offset) : element))
      const strokesBefore = page.strokes
      const strokes = current.strokeIDs.length > 0
        ? strokesBefore.map((stroke, index) => (current.strokeIDs.includes(index) ? stroke.translated(offset) : stroke))
        : strokesBefore
      applyBoth(reader, host, page, after, strokes, before, strokesBefore)
    },

    copySelection() {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current) return false
      const { copies } = copied(current.ids, page.elements, { x: 0, y: 0 }, makeUUID)
      const strokes = current.strokeIDs.filter((index) => index < page.strokes.length).map((index) => page.strokes[index])
      if (copies.length === 0 && strokes.length === 0) return false
      clipboard = {
        elements: copies.map((element) => element.encode()),
        strokes: strokes.map((stroke) => stroke.encode()),
        fromPage: page.index,
      }
      // So the same copy can land in a note, or anywhere else.
      const words = copies.map((element) => element.text).filter((text) => text.length > 0).join('\n')
      if (words.length > 0) void navigator.clipboard?.writeText(words).catch(() => undefined)
      return true
    },

    cutSelection() {
      if (editor.copySelection()) editor.deleteSelection()
    },

    /** Pastes onto whichever page is in view. Onto a different page the
     *  drawing keeps its coordinates; back onto the page it came from it is
     *  nudged, so the copy does not hide the original. */
    pasteSketch() {
      const page = reader.pages[store.reader.currentPage]
      if (!clipboard || !page) return
      const shift = clipboard.fromPage === page.index ? { x: 12, y: -12 } : { x: 0, y: 0 }
      const source = clipboard.elements.map(SketchElement.from)
      const { copies, roots } = copied(source.map((element) => element.id), source, shift, makeUUID)
      const before = page.elements
      const strokesBefore = page.strokes
      const pasted = clipboard.strokes.map(InkStroke.from).map((stroke) => stroke.translated(shift))
      const strokes = pasted.length > 0 ? [...strokesBefore, ...pasted] : strokesBefore
      const landed = pasted.map((_, index) => strokesBefore.length + index)
      if (!applyBoth(reader, host, page, [...before, ...copies], strokes, before, strokesBefore)) return
      entered = null
      setSelection(reader, host, { pageIndex: page.index, ids: [...roots], strokeIDs: landed })
    },

    isEditingText: () => editing !== null,

    handleKey(event: KeyboardEvent): boolean {
      const target = event.target as HTMLElement | null
      if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) return false
      if (!store.reader.drawing) return false
      const command = event.metaKey || event.ctrlKey
      const key = event.key
      const lower = key.toLowerCase()
      const plain = !command && !event.altKey
      if (plain) {
        switch (key) {
          case 'Escape': editor.escape(); return true
          case 'Delete': case 'Backspace':
            if (!selection()) return false
            editor.deleteSelection(); return true
          case 'Enter': {
            const one = selectedOne(reader)
            if (!one) return false
            if (one.kind === 'group') { editor.enterSelectedGroup(); return true }
            if (!one.isConnector && one.kind !== 'frame') { editor.editSelectedText(); return true }
            return false
          }
          case 'ArrowLeft': if (!selection()) return false; editor.nudge(-1, 0, event.shiftKey); return true
          case 'ArrowRight': if (!selection()) return false; editor.nudge(1, 0, event.shiftKey); return true
          // The page's y goes up, so up on the keyboard is up on the page.
          case 'ArrowUp': if (!selection()) return false; editor.nudge(0, 1, event.shiftKey); return true
          case 'ArrowDown': if (!selection()) return false; editor.nudge(0, -1, event.shiftKey); return true
          default: break
        }
        if (!event.shiftKey && key.length === 1) {
          const tool = TOOL_KEYS[lower]
          if (tool) { setTool(reader, host, tool); return true }
          if (lower === 'b') { editor.frameSelection(); return true }
        }
        if (event.shiftKey && lower === 'a' && key.length === 1) { editor.toggleAutoLayout(); return true }
        return false
      }
      if (command && !event.altKey && !event.shiftKey) {
        switch (lower) {
          case 'd': editor.duplicateSelection(); return true
          case 'a': editor.selectAllOnPage(); return true
          case 'g': editor.groupSelection(); return true
          case 'c': return editor.copySelection()
          case 'x': if (!selection()) return false; editor.cutSelection(); return true
          case 'v': if (!clipboard) return false; editor.pasteSketch(); return true
          default: return false
        }
      }
      if (command && event.shiftKey && !event.altKey) {
        switch (key) {
          case ']': case '}': editor.bringSelectionToFront(); return true
          case '[': case '{': editor.sendSelectionToBack(); return true
          default: break
        }
        if (lower === 'g') { editor.ungroupSelection(); return true }
        return false
      }
      if (command && event.altKey && !event.shiftKey && (lower === 'g' || event.code === 'KeyG')) {
        editor.frameSelection()
        return true
      }
      return false
    },
  }
  editors.set(reader, editor)
  return editor
}

const TOOL_KEYS: Record<string, SketchTool> = {
  v: 'select', f: 'frame', p: 'pen', h: 'highlighter', e: 'eraser',
  r: 'rectangle', o: 'ellipse', a: 'arrow', l: 'line', t: 'text',
}

/** Picking a drawing tool lets go of what was chosen and closes the words
 *  being typed. Coming back to Select does neither. */
function setTool(reader: Reader, host: SketchInputHost, tool: SketchTool) {
  store.sketch.tool = tool
  toolChanged(reader, host)
  host.changed()
}

function toolChanged(reader: Reader, host: SketchInputHost) {
  const tool = store.sketch.tool
  if (tool === lastTool) return
  lastTool = tool
  if (tool === 'select') return
  if (editing) endTextEditing()
  if (selection()) {
    store.sketch.selection = null
    entered = null
    sketchSelectionChanged()
    reader.redrawAll()
  }
  void host
}

/** The editor for a reader — built once, handed to the panel whenever the
 *  pen is out or a page is clicked. */
export function sketchEditingFor(reader: Reader, host: SketchInputHost): SketchInputEditing {
  return makeEditing(reader, host)
}

// MARK: - Resizing

/** The element — and, for a container, everything in it — as the handle
 *  leaves it. */
function resized(original: SketchElement, handle: Handle, p: Point, shift: boolean, tree: SketchTree): SketchElement[] {
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

// MARK: - Text

function beginTextEditing(reader: Reader, host: SketchInputHost, page: PageView, element: SketchElement, isNew: boolean, before?: SketchElement[]) {
  if (editing) endTextEditing()
  const size = page.viewport?.scale ?? 1
  const area = el('textarea', { class: 'sketch-text-editor', spellcheck: 'false' }) as HTMLTextAreaElement
  area.value = element.text
  // Figma's way: no field. The words appear in their own face, size and
  // colour on the page itself, with a caret; the card behind them is drawn
  // by the canvas underneath, so what is seen while typing is what will be
  // there when the typing stops.
  area.style.background = 'transparent'
  area.style.outline = 'none'
  area.style.border = '0'
  area.style.borderRadius = '0'
  area.style.boxShadow = 'none'
  area.style.overflow = 'hidden'
  area.style.whiteSpace = element.kind === 'text' && element.sizing === 'autoWidth' ? 'pre' : 'pre-wrap'
  area.style.font = fontSpec(element.style.points * size, element.style.fontName)
  area.style.lineHeight = `${textLineHeight(element.style.points, element.style.fontName) * size}px`
  area.style.color = element.style.stroke.css
  area.style.caretColor = element.style.stroke.css
  area.style.textAlign = element.kind === 'text' ? element.style.textAlign : 'center'
  area.style.padding = element.kind === 'text' ? `${TEXT_PADDING * size}px` : '0'
  area.style.boxSizing = 'border-box'
  page.root.append(area)
  editing = { page, id: element.id, area, before: before ?? page.elements, isNew, host }
  placeEditor()
  page.hidden.add(element.id)
  page.redraw()
  area.focus()
  area.select()

  on(area, 'input', () => editorTextChanged(reader, host))
  on(area, 'keydown', (event: KeyboardEvent) => {
    event.stopPropagation()
    if (event.key === 'Escape' || (event.key === 'Enter' && (event.metaKey || event.ctrlKey))) {
      event.preventDefault()
      endTextEditing()
    }
    // Enter makes a new line; the card is finished by clicking away, by
    // Escape or by ⌘Return, so a note can be more than one line.
  })
  on(area, 'blur', () => {
    // A blur while the words are still being placed is not the end.
    if (editing?.area === area) endTextEditing()
  })
  // After the card's own listeners, so the card has moved to fit the words
  // before the placeholders are drawn over them.
  latexField = attachLatexSuite(area)
  sketchSelectionChanged()
}

/** The editor over the card, where the card is. */
function placeEditor() {
  if (!editing) return
  const { page, id, area } = editing
  const element = page.elements.find((entry) => entry.id === id)
  if (!element) return
  const size = page.viewport?.scale ?? 1
  const box = element.kind !== 'text' ? rectInset(element.rect, TEXT_PADDING, TEXT_PADDING) : element.rect
  const topLeft = page.toView(box.x, rectMaxY(box))
  area.style.left = `${topLeft.x}px`
  area.style.top = `${topLeft.y}px`
  area.style.width = `${Math.max(box.width * size, 24)}px`
  area.style.height = `${Math.max(box.height * size, 12)}px`
  if (element.kind !== 'text') {
    // Words in a box sit in its middle, as the canvas draws them.
    const lines = Math.max(1, area.value.split('\n').length)
    const lineHeight = textLineHeight(element.style.points, element.style.fontName) * size
    area.style.paddingTop = `${Math.max(0, (box.height * size - lines * lineHeight) / 2)}px`
  }
}

/** The words change and the card follows them, live — and the frame round
 *  it, when it has a layout, moves its neighbours to make room. */
function editorTextChanged(reader: Reader, host: SketchInputHost) {
  if (!editing) return
  const { page, id, area } = editing
  const i = page.elements.findIndex((entry) => entry.id === id)
  if (i === -1) return
  const changed = page.elements[i].copy()
  changed.text = area.value
  if (changed.kind === 'text') changed.setRect(fittedRect(changed))
  const next = [...page.elements]
  next[i] = changed
  page.elements = SketchTree.normalized(next)
  placeEditor()
  page.redraw()
  void reader
  void host
}

/** Ends the typing: the words go into the element, an empty card is thrown
 *  away, and the whole thing is one step to undo. */
export function endTextEditing() {
  if (!editing) return
  const { page, id, area, before, host } = editing
  editing = null
  const text = area.value.trim()
  let elements = [...page.elements]
  const i = elements.findIndex((entry) => entry.id === id)
  if (i !== -1) {
    const changed = elements[i].copy()
    changed.text = text
    if (changed.kind === 'text') {
      if (text.length === 0) elements.splice(i, 1)
      else {
        changed.setRect(fittedRect(changed))
        elements[i] = changed
      }
    } else {
      elements[i] = changed
    }
  }
  latexField?.detach()
  latexField = null
  area.remove()
  page.hidden.delete(id)
  const after = SketchTree.normalized(pruned(elements))
  page.elements = after
  if (!sameElements(after, before)) {
    undoStack.record(snapshot(page.index, before, page.strokes), snapshot(page.index, after, page.strokes))
    host.save(page)
  }
  if (!after.some((entry) => entry.id === id)) {
    store.sketch.selection = null
    entered = null
  }
  page.redraw()
  sketchSelectionChanged()
  host.changed()
}

// MARK: - One page's surface

export function attachSketchInput(
  page: PageView,
  reader: Reader,
  host: SketchInputHost,
): SketchInput {
  const surface = page.inputSurface
  const editor = makeEditing(reader, host)
  let drag: Drag = { kind: 'none' }
  /** The page the pointer is over during a move — where the selection will land. */
  let moveTarget: PageView | null = null
  /** The elements as they are mid-drag, drawn here instead of by the page.
   *  During a move they are in the target page's coordinates. */
  let working: SketchElement[] = []
  let workingStrokes: InkStroke[] | null = null
  let lastPress: { at: number; point: Point } | null = null

  const scale = () => page.viewport?.scale ?? 1
  const tolerance = () => HIT_SLOP / scale()

  function pointOf(event: PointerEvent | MouseEvent, clamp = true): Point {
    const box = surface.getBoundingClientRect()
    const p = page.toPage(event.clientX - box.left, event.clientY - box.top)
    if (!clamp) return p
    const bounds = pageRectOf(page)
    return {
      x: Math.min(Math.max(p.x, bounds.x), rectMaxX(bounds)),
      y: Math.min(Math.max(p.y, bounds.y), rectMaxY(bounds)),
    }
  }

  const tree = () => new SketchTree(page.elements)

  function ownSelection(): Selection | null {
    const current = selection()
    return current && current.pageIndex === page.index ? current : null
  }

  function chosenElements(): SketchElement[] {
    const current = ownSelection()
    if (!current) return []
    return page.elements.filter((element) => current.ids.includes(element.id))
  }

  function select(ids: string[], strokeIDs: number[] = []) {
    setSelection(reader, host, { pageIndex: page.index, ids, strokeIDs })
  }

  // ------------------------------------------------------------ hit testing

  /** The topmost element under a point — the thing itself, before the rule
   *  about groups is applied. */
  function elementAt(point: Point): SketchElement | null {
    const reach = tolerance()
    for (let index = page.elements.length - 1; index >= 0; index -= 1) {
      if (page.elements[index].hits(point, reach)) return page.elements[index]
    }
    return null
  }

  /** What a click at this point selects: the outermost group round the
   *  element hit, or the element itself. */
  function selectableAt(point: Point): string | null {
    const hit = elementAt(point)
    return hit ? tree().selectable(hit.id, entered) : null
  }

  function strokeAt(point: Point): number | null {
    const reach = tolerance() + 2
    for (let index = page.strokes.length - 1; index >= 0; index -= 1) {
      if (strokeTouches(page.strokes[index], point, reach)) return index
    }
    return null
  }

  function handlesOf(element: SketchElement, current: SketchTree): [Handle, Point][] {
    if (element.isConnector) {
      return [['start', element.start], ['end', element.end], ['mid', element.midpoint]]
    }
    const r = (element.kind === 'group' ? current.bounds(element.id) : null) ?? element.rect
    return BOX_HANDLES.map((handle) => [handle, handlePoint(r, handle)])
  }

  function handleAt(point: Point, element: SketchElement, current: SketchTree): Handle | null {
    const reach = 7 / scale()
    for (const [handle, at] of handlesOf(element, current)) {
      if (Math.hypot(at.x - point.x, at.y - point.y) <= reach) return handle
    }
    return null
  }

  function handlePoint(box: Rect, handle: Handle): Point {
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

  // ------------------------------------------------------------- the mouse

  function onPointerDown(event: PointerEvent) {
    if (event.button !== 0) return
    press(event)
  }

  function press(event: PointerEvent) {
    // No compatibility mousedown: it would move the focus off the words just
    // opened for typing, and the page has nothing else to do with it.
    event.preventDefault()
    try {
      surface.setPointerCapture(event.pointerId)
    } catch {
      // A synthesised pointer has nothing to capture.
    }
    if (editing) endTextEditing()
    const point = pointOf(event)
    // With several papers open side by side, the inspector follows the pane
    // last clicked in.
    sketchEditor.current = editor
    const additive = event.shiftKey
    const now = performance.now()
    const clicks = lastPress && now - lastPress.at < 400
      && Math.hypot(lastPress.point.x - point.x, lastPress.point.y - point.y) * scale() < 5 ? 2 : 1
    lastPress = clicks === 2 ? null : { at: now, point }
    moveTarget = null
    const tool = store.sketch.tool

    switch (tool) {
      case 'select':
        beginSelecting(point, additive, clicks)
        break
      case 'pen':
      case 'highlighter': {
        const kind = tool === 'highlighter' ? 'marker' : 'pen'
        const base = kind === 'marker' ? Math.max(store.sketch.style.width * 5, 10) : store.sketch.style.width
        drag = { kind: 'stroke', tool: kind, points: [{ ...point, w: nibWidth(base, event.pressure, kind) }] }
        break
      }
      case 'eraser':
        drag = { kind: 'erase', last: point, elementsBefore: page.elements, strokesBefore: page.strokes }
        eraseAt(point, point)
        break
      case 'text':
        drag = { kind: 'textBox', origin: point, current: point }
        break
      default: {
        const style = store.sketch.style.copy()
        const kind = tool === 'arrow' ? 'arrow' : tool === 'line' ? 'line' : tool
        if (kind === 'line') {
          style.startHead = 'none'
          style.endHead = 'none'
        }
        const element = new SketchElement({ kind, points: [point, point], style })
        if (kind === 'frame') {
          // A frame is a place, not a shape: an outline and a name,
          // whatever the next shape's style was going to be.
          element.style.fill = null
          element.style.startHead = 'none'
          element.style.endHead = 'none'
          element.style.corners = 'round'
          element.name = nextFrameName(page.elements)
        }
        drag = { kind: 'shape', element }
        break
      }
    }
    page.redraw()
  }

  function beginSelecting(point: Point, additive: boolean, clicks: number) {
    const current = tree()
    const before = ownSelection()
    if (selection() && selection()!.pageIndex !== page.index) entered = null

    // A double-click: go into a group, type into what is there, or start a
    // card where there is nothing.
    if (clicks === 2) {
      const hit = elementAt(point)
      if (hit) {
        const chosen = current.selectable(hit.id, entered)
        const group = current.get(chosen)
        if (chosen !== hit.id && group?.kind === 'group') {
          // Into the group, one level: the child under the pointer.
          entered = chosen
          select([current.selectable(hit.id, chosen)])
          return
        }
        select([hit.id])
        if (!hit.isContainer && !hit.isConnector) beginTextEditing(reader, host, page, hit, false)
        return
      }
      // Anywhere inside an empty box — a double-click in a box means
      // "write in here", as it does in Excalidraw.
      const inside = [...page.elements].reverse().find((element) => (element.kind === 'rectangle' || element.kind === 'ellipse') && rectContains(element.rect, point))
      if (inside) {
        select([inside.id])
        beginTextEditing(reader, host, page, inside, false)
      } else {
        createText(point, null)
      }
      return
    }

    // A handle of the one selected element.
    if (before && before.ids.length === 1 && before.strokeIDs.length === 0) {
      const chosen = current.get(before.ids[0])
      const handle = chosen ? handleAt(point, chosen, current) : null
      if (chosen && handle) {
        if (handle === 'mid') {
          drag = { kind: 'bend', elementsBefore: page.elements, original: chosen }
          working = [chosen]
        } else {
          drag = { kind: 'resize', elementsBefore: page.elements, original: chosen, handle }
          const moving = current.expanded([chosen.id])
          working = page.elements.filter((element) => moving.has(element.id))
        }
        hideWorking()
        return
      }
    }

    const hit = selectableAt(point)
    if (hit) {
      if (additive) {
        const ids = before ? [...before.ids] : []
        const index = ids.indexOf(hit)
        if (index === -1) ids.push(hit)
        else ids.splice(index, 1)
        select(ids, before?.strokeIDs ?? [])
      } else if (!before || !before.ids.includes(hit)) {
        select([hit])
      }
      beginMove(point)
      return
    }

    const stroke = strokeAt(point)
    if (stroke !== null) {
      if (additive) {
        const strokes = before ? [...before.strokeIDs] : []
        const index = strokes.indexOf(stroke)
        if (index === -1) strokes.push(stroke)
        else strokes.splice(index, 1)
        select(before?.ids ?? [], strokes)
      } else if (!before || !before.strokeIDs.includes(stroke)) {
        select([], [stroke])
      }
      beginMove(point)
      return
    }

    if (!additive) {
      entered = null
      setSelection(reader, host, null)
    }
    drag = { kind: 'pendingClick', origin: point, additive, before: additive ? before : null }
  }

  function beginMove(point: Point) {
    const current = ownSelection()
    if (!current) return
    drag = { kind: 'move', elementsBefore: page.elements, strokesBefore: page.strokes, origin: point, moved: false }
    const moving = tree().expanded(current.ids)
    working = page.elements.filter((element) => moving.has(element.id))
    workingStrokes = null
    moveTarget = page
    hideWorking()
  }

  /** The page's own pass leaves out what this surface is drawing itself. */
  function hideWorking() {
    page.hidden = new Set(working.map((element) => element.id))
    const current = ownSelection()
    page.hiddenStrokes = drag.kind === 'move' && current ? new Set(current.strokeIDs) : new Set()
  }

  function unhideWorking() {
    page.hidden = new Set()
    page.hiddenStrokes = new Set()
  }

  function onPointerMove(event: PointerEvent) {
    if (drag.kind === 'none') {
      surface.style.cursor = cursorFor(pointOf(event))
      return
    }
    const point = pointOf(event)
    const shift = event.shiftKey
    switch (drag.kind) {
      case 'shape': {
        const element = drag.element
        let end = point
        if (shift) end = constrained(element.start, point, element.isConnector)
        element.points = [element.start, end]
        break
      }
      case 'textBox':
        drag.current = point
        break
      case 'stroke': {
        const last = drag.points[drag.points.length - 1]
        if (Math.hypot(point.x - last.x, point.y - last.y) < 0.6 / scale()) return
        const base = drag.tool === 'marker' ? Math.max(store.sketch.style.width * 5, 10) : store.sketch.style.width
        drag.points.push({ ...point, w: nibWidth(base, event.pressure, drag.tool) })
        break
      }
      case 'erase':
        eraseAt(point, drag.last)
        drag.last = point
        break
      case 'move': {
        // The page under the pointer is where the selection is going; the
        // offset from where the drag began keeps the grip.
        const move = drag
        const target = reader.pageAtClient(event.clientX, event.clientY) ?? page
        const landing = target === page ? point : target.toPageFromClient(event.clientX, event.clientY)
        const offset = { x: landing.x - move.origin.x, y: landing.y - move.origin.y }
        const current = ownSelection()
        const before = new SketchTree(move.elementsBefore)
        const moving = before.expanded(current?.ids ?? [])
        working = move.elementsBefore.filter((element) => moving.has(element.id)).map((element) => element.translated(offset))
        if (current && current.strokeIDs.length > 0) {
          workingStrokes = current.strokeIDs
            .filter((index) => index < move.strokesBefore.length)
            .map((index) => move.strokesBefore[index].translated(offset))
        }
        if (moveTarget !== target) {
          if (moveTarget && moveTarget !== page) {
            moveTarget.guest = null
            moveTarget.redraw()
          }
          moveTarget = target
          if (target !== page) target.guest = drawWorking
        }
        move.moved = true
        if (target !== page) target.redraw()
        break
      }
      case 'resize':
        working = resized(drag.original, drag.handle, point, shift, new SketchTree(drag.elementsBefore))
        break
      case 'bend': {
        const bent = drag.original.copy()
        bent.setMidpoint(point)
        working = [bent]
        break
      }
      case 'pendingClick': {
        const moved = Math.hypot(point.x - drag.origin.x, point.y - drag.origin.y) * scale()
        if (moved > 3) {
          drag = { kind: 'marquee', origin: drag.origin, current: point, additive: drag.additive, before: drag.before }
          updateMarquee(drag.origin, point, drag.additive, drag.before)
        }
        break
      }
      case 'marquee':
        drag.current = point
        updateMarquee(drag.origin, point, drag.additive, drag.before)
        break
      default:
        break
    }
    page.redraw()
  }

  function onPointerUp(event: PointerEvent) {
    const point = pointOf(event)
    const finished = drag
    const target = moveTarget
    drag = { kind: 'none' }
    try {
      surface.releasePointerCapture(event.pointerId)
    } catch {
      // The capture is already gone; nothing to release.
    }
    switch (finished.kind) {
      case 'shape': {
        const element = finished.element
        const big = element.isConnector
          ? Math.hypot(element.end.x - element.start.x, element.end.y - element.start.y) > 3
          : element.rect.width > 3 && element.rect.height > 3
        if (!big) break
        const before = page.elements
        let after = [...before, element]
        if (element.kind === 'frame') {
          // Drawn round things, a frame takes them in — as Figma's does.
          const current = new SketchTree(before)
          after = after.map((entry) => {
            if (entry.id === element.id || entry.parent !== null) return entry
            const inside = current.bounds(entry.id)
            if (!inside || !rectContainsRect(element.rect, inside)) return entry
            const child = entry.copy()
            child.parent = element.id
            return child
          })
        } else {
          after = adopted([element.id], after)
        }
        apply(reader, host, page, after, before)
        // The shape drawn, the pointer goes back to choosing — as it does in
        // Figma — with the new shape chosen, so the panel is about it.
        store.sketch.tool = 'select'
        lastTool = 'select'
        select([element.id])
        break
      }
      case 'textBox': {
        const width = Math.abs(finished.current.x - finished.origin.x)
        if (width * scale() < 8) {
          createText(finished.origin, null)
        } else {
          const corner = { x: Math.min(finished.origin.x, finished.current.x), y: Math.max(finished.origin.y, finished.current.y) }
          createText(corner, width)
        }
        break
      }
      case 'stroke': {
        const points = resample(finished.points)
        if (points.length === 1) points.push({ ...points[0], x: points[0].x + 0.2 })
        const colour = finished.tool === 'marker'
          ? (store.sketch.style.fill ?? SketchColor.paleYellow).withAlpha(1)
          : store.sketch.style.stroke
        applyBoth(reader, host, page, page.elements, [...page.strokes, new InkStroke(points, colour, finished.tool)], page.elements, page.strokes)
        break
      }
      case 'erase': {
        const strokesChanged = page.strokes !== finished.strokesBefore
        const elementsChanged = !sameElements(page.elements, finished.elementsBefore)
        if (strokesChanged || elementsChanged) {
          undoStack.record(
            snapshot(page.index, finished.elementsBefore, finished.strokesBefore),
            snapshot(page.index, page.elements, page.strokes),
          )
          host.save(page)
          refreshSelection(reader)
          host.changed()
        }
        break
      }
      case 'move':
        unhideWorking()
        if (target && target !== page) {
          target.guest = null
          target.redraw()
        }
        if (finished.moved) finishMove(finished.elementsBefore, finished.strokesBefore, target ?? page)
        break
      case 'resize': {
        unhideWorking()
        const changed = working.find((element) => element.id === finished.original.id)
        if (!changed || sameElements([changed], [finished.original])) break
        const after = finished.elementsBefore.map((element) => working.find((entry) => entry.id === element.id) ?? element)
        apply(reader, host, page, after, finished.elementsBefore)
        break
      }
      case 'bend': {
        unhideWorking()
        const changed = working[0]
        if (!changed || sameElements([changed], [finished.original])) break
        const after = finished.elementsBefore.map((element) => (element.id === changed.id ? changed : element))
        apply(reader, host, page, after, finished.elementsBefore)
        break
      }
      default:
        break
    }
    moveTarget = null
    working = []
    workingStrokes = null
    page.redraw()
    void point
  }

  /** Puts a moved selection down — on the page it came from, or on the page
   *  the pointer ended over, in which case it leaves one page's sidecar and
   *  joins the other's as one undoable step. */
  function finishMove(elementsBefore: SketchElement[], strokesBefore: InkStroke[], target: PageView) {
    const current = ownSelection()
    if (!current) return
    const before = new SketchTree(elementsBefore)
    const moving = before.expanded(current.ids)
    const strokesAfter = workingStrokes
      ? strokesBefore.map((stroke, index) => {
        const at = current.strokeIDs.indexOf(index)
        return at === -1 ? stroke : workingStrokes![at]
      })
      : strokesBefore

    if (target === page) {
      let after = elementsBefore.map((element) => working.find((entry) => entry.id === element.id) ?? element)
      after = adopted(before.outermost(current.ids), after)
      applyBoth(reader, host, page, after, workingStrokes ? strokesAfter : strokesBefore, elementsBefore, strokesBefore)
      return
    }

    // Across pages. The elements keep their ids — it is the same box, on the
    // next page — and lose any parent left behind.
    const sourceAfter = SketchTree.normalized(pruned(elementsBefore.filter((element) => !moving.has(element.id))))
    const targetBefore = target.elements
    const landing = working.map((element) => {
      if (element.parent && !moving.has(element.parent)) {
        const loose = element.copy()
        loose.parent = null
        return loose
      }
      return element
    })
    let targetAfter = [...targetBefore, ...landing]
    targetAfter = adopted(landing.filter((element) => element.parent === null).map((element) => element.id), targetAfter)
    targetAfter = SketchTree.normalized(targetAfter)

    const taken = current.strokeIDs.filter((index) => index < strokesBefore.length)
    const sourceStrokesAfter = taken.length > 0 ? strokesBefore.filter((_, index) => !taken.includes(index)) : strokesBefore
    const targetStrokesBefore = target.strokes
    const carried = workingStrokes ?? []
    const targetStrokesAfter = carried.length > 0 ? [...targetStrokesBefore, ...carried] : targetStrokesBefore
    const landedStrokes = carried.map((_, index) => targetStrokesBefore.length + index)

    undoStack.record(
      [snapshot(page.index, elementsBefore, strokesBefore), snapshot(target.index, targetBefore, targetStrokesBefore)],
      [snapshot(page.index, sourceAfter, sourceStrokesAfter), snapshot(target.index, targetAfter, targetStrokesAfter)],
    )
    page.elements = sourceAfter
    page.strokes = sourceStrokesAfter
    target.elements = targetAfter
    target.strokes = targetStrokesAfter
    host.save(page)
    host.save(target)
    page.redraw()
    target.redraw()
    entered = null
    setSelection(reader, host, { pageIndex: target.index, ids: current.ids, strokeIDs: landedStrokes })
    sketchSelectionChanged()
  }

  function updateMarquee(origin: Point, current: Point, additive: boolean, before: Selection | null) {
    const box = rectFrom(origin, current)
    const ids = new Set(additive && before ? before.ids : [])
    const strokes = new Set(additive && before ? before.strokeIDs : [])
    const now = tree()
    const touched = new Set<string>()
    for (const element of page.elements) {
      if (!element.isContainer && rectIntersects(element.bounds, box)) touched.add(now.selectable(element.id, entered))
    }
    for (const id of now.outermost(touched)) ids.add(id)
    page.strokes.forEach((stroke, index) => {
      if (rectIntersects(stroke.bounds, box)) strokes.add(index)
    })
    select([...ids], [...strokes])
  }

  function constrained(origin: Point, point: Point, isLine: boolean): Point {
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

  /**
   * The eraser, walking the gap between samples.
   *
   * A pointer reports every few milliseconds and a hand moves faster than
   * that, so erasing only at the reported points leaves untouched islands in
   * a fast sweep. The segment between two samples is walked instead. The
   * eraser takes an element and what lies inside it.
   */
  function eraseAt(point: Point, previous: Point) {
    const radius = Math.max(8 / scale(), 3)
    const distance = Math.hypot(point.x - previous.x, point.y - previous.y)
    const steps = Math.max(1, Math.floor(distance / (radius / 2)))
    let strokes = page.strokes
    let elements = page.elements
    let touched = false
    for (let step = 0; step <= steps; step += 1) {
      const t = step / steps
      const sample = { x: previous.x + (point.x - previous.x) * t, y: previous.y + (point.y - previous.y) * t }
      const kept = strokes.filter((stroke) => !strokeTouches(stroke, sample, radius))
      if (kept.length !== strokes.length) {
        strokes = kept
        touched = true
      }
      const now = new SketchTree(elements)
      const gone = now.expanded(elements.filter((element) => element.hits(sample, radius)).map((element) => element.id))
      if (gone.size > 0) {
        elements = elements.filter((element) => !gone.has(element.id))
        touched = true
      }
    }
    if (!touched) return
    page.strokes = strokes
    page.elements = SketchTree.normalized(pruned(elements))
  }

  // ---------------------------------------------------------------- words

  /** Starts a text card at a point — as wide as its words will be — or,
   *  given a width, a card of that width whose height follows its lines. */
  function createText(point: Point, width: number | null) {
    const style = store.sketch.style.copy()
    style.startHead = 'none'
    style.endHead = 'none'
    const element = new SketchElement({
      kind: 'text',
      points: [point, { x: point.x + (width ?? 24), y: point.y - 1 }],
      style,
    })
    element.textSizing = width === null ? 'autoWidth' : 'autoHeight'
    element.setRect(fittedRect(element))
    const before = page.elements
    page.elements = SketchTree.normalized(adopted([element.id], [...before, element]))
    store.sketch.tool = 'select'
    lastTool = 'select'
    select([element.id])
    page.redraw()
    beginTextEditing(reader, host, page, element, true, before)
  }

  // ------------------------------------------------------------- overlay

  /** Whether a drag is moving, resizing or bending — the states in which
   *  the selection is drawn from `working`. */
  const isMoving = () => drag.kind === 'move' || drag.kind === 'resize' || drag.kind === 'bend'

  /** The frame the moving selection would land in, if it were let go now —
   *  lit up while it is over it, so going into a frame is seen to happen
   *  rather than found out afterwards. */
  function landingFrame(): string | null {
    if (drag.kind !== 'move' || !moveTarget || working.length === 0) return null
    const all = moveTarget.elements
    const moving = new Set(working.map((element) => element.id))
    const now = new SketchTree(all)
    const box = new SketchTree(working).boundsOf(moving)
    if (!box) return null
    const centre = { x: rectMidX(box), y: rectMidY(box) }
    for (let index = all.length - 1; index >= 0; index -= 1) {
      const candidate = all[index]
      if (candidate.kind === 'frame' && !moving.has(candidate.id) && rectContains(candidate.rect, centre)
        && ![...moving].some((id) => now.isDescendant(candidate.id, id))) return candidate.id
    }
    return null
  }

  /** The working elements and strokes, drawn on whichever page they are over. */
  function drawWorking(context: CanvasRenderingContext2D) {
    const landing = moveTarget ?? page
    const size = landing.viewport?.scale ?? 1
    drawElements(working, context, { fillAlphaScale: 0.7 })
    if (workingStrokes) for (const stroke of workingStrokes) drawInkStroke(stroke, context)
    context.save()
    context.lineWidth = 1 / size
    if (drag.kind === 'move') {
      const box = new SketchTree(working).boundsOf(working.map((element) => element.id))
      const strokeBounds = workingStrokes ? rectUnionAll(workingStrokes.map((stroke) => stroke.bounds)) : null
      const whole = [box, strokeBounds].filter((r): r is Rect => r !== null).reduce<Rect | null>((a, b) => (a ? rectUnion(a, b) : b), null)
      if (whole) {
        context.strokeStyle = `rgba(${ACCENT}, 0.8)`
        context.setLineDash(landing !== page ? [4 / size, 3 / size] : [])
        context.strokeRect(whole.x, whole.y, whole.width, whole.height)
        context.setLineDash([])
      }
    } else {
      const now = new SketchTree(working)
      const current = ownSelection()
      for (const element of working) {
        if (current?.ids.includes(element.id)) drawHandles(element, now, context, size)
      }
    }
    context.restore()
  }

  /** Every frame's name, in small type above its top-left corner — the label
   *  Figma gives a frame on the canvas, so a frame is a place with a name and
   *  not an anonymous box. */
  function drawFrameNames(context: CanvasRenderingContext2D, size: number) {
    const landing = landingFrame()
    const current = selection()
    const onThisPage = current?.pageIndex === page.index
    // The frame the selection lives in, so it is seen to be inside
    // something — the way Figma lights the parent's name.
    const parents = new Set<string>()
    if (onThisPage && current && (drag.kind === 'none' || isMoving())) {
      const now = tree()
      for (const id of current.ids) {
        const parent = now.get(id)?.parent
        if (parent && now.get(parent)?.kind === 'frame') parents.add(parent)
      }
    }
    context.save()
    for (const frame of page.elements) {
      if (frame.kind !== 'frame' || page.hidden.has(frame.id)) continue
      const title = frame.name ?? L('프레임', 'Frame')
      const chosen = onThisPage && (current?.ids.includes(frame.id) ?? false)
      const isLanding = landing === frame.id && moveTarget === page
      const isParent = parents.has(frame.id)
      const box = frame.rect
      if (isLanding || isParent) {
        // The frame's edge, in the accent: strong while something is being
        // dropped into it, faint while something inside it is merely selected.
        context.strokeStyle = `rgba(${ACCENT}, ${isLanding ? 0.95 : 0.4})`
        context.lineWidth = (isLanding ? 2 : 1) / size
        context.setLineDash([])
        context.strokeRect(box.x, box.y, box.width, box.height)
        if (isLanding) {
          context.fillStyle = `rgba(${ACCENT}, 0.05)`
          context.fillRect(box.x, box.y, box.width, box.height)
        }
      }
      context.fillStyle = chosen || isLanding || isParent ? `rgb(${ACCENT})` : 'rgba(110, 110, 115, 0.9)'
      context.font = `500 ${10 / size}px ${fontSpec(10, null).replace(/^[\d.]+px /, '')}`
      context.textBaseline = 'alphabetic'
      context.textAlign = 'left'
      context.save()
      context.translate(box.x, rectMaxY(box) + 3 / size)
      context.scale(1, -1)
      context.fillText(title, 0, 0)
      context.restore()
    }
    context.restore()
  }

  /** The selection's handles and the marquee, drawn in page coordinates. */
  function drawOverlay(context: CanvasRenderingContext2D) {
    const size = scale()
    drawFrameNames(context, size)

    // The card being typed into: its box, drawn here under the editor,
    // which draws only the words.
    if (editing && editing.page === page) {
      const element = page.elements.find((entry) => entry.id === editing!.id)
      if (element) {
        const box = element.copy()
        box.text = ''
        drawElement(box, context)
        context.save()
        context.strokeStyle = `rgba(${ACCENT}, 0.9)`
        context.lineWidth = 1 / size
        context.setLineDash([])
        pathOf(box, context)
        context.stroke()
        context.restore()
      }
    }

    const current = ownSelection()
    if (current && (drag.kind === 'none' || isMoving())) drawSelection(current, context, size)

    context.save()
    context.lineWidth = 1 / size
    context.setLineDash([])
    switch (drag.kind) {
      case 'shape':
        drawElement(drag.element, context, { fillAlphaScale: 0.7 })
        break
      case 'textBox': {
        const box = rectFrom(drag.origin, drag.current)
        if (box.width * size <= 2) break
        context.strokeStyle = `rgba(${ACCENT}, 0.8)`
        context.strokeRect(box.x, box.y, box.width, box.height)
        break
      }
      case 'stroke': {
        const colour = drag.tool === 'marker'
          ? (store.sketch.style.fill ?? SketchColor.paleYellow).withAlpha(1)
          : store.sketch.style.stroke
        drawInkStroke(new InkStroke(drag.points, colour, drag.tool), context)
        break
      }
      case 'move':
      case 'resize':
      case 'bend':
        if ((moveTarget ?? page) === page) drawWorking(context)
        break
      case 'marquee': {
        const box = rectFrom(drag.origin, drag.current)
        context.fillStyle = `rgba(${ACCENT}, 0.08)`
        context.fillRect(box.x, box.y, box.width, box.height)
        context.strokeStyle = `rgba(${ACCENT}, 0.7)`
        context.setLineDash([4 / size, 3 / size])
        context.strokeRect(box.x, box.y, box.width, box.height)
        context.setLineDash([])
        break
      }
      default:
        break
    }
    context.restore()
  }

  function drawSelection(current: Selection, context: CanvasRenderingContext2D, size: number) {
    const now = tree()
    const elements = page.elements.filter((element) => current.ids.includes(element.id))
    context.save()
    context.lineWidth = 1 / size
    // The strokes: a dashed box round the lot.
    const inkBox = strokeBox(page, current.strokeIDs)
    if (inkBox) {
      const box = rectInset(inkBox, -3, -3)
      context.strokeStyle = `rgba(${ACCENT}, 0.8)`
      context.setLineDash([4 / size, 3 / size])
      context.strokeRect(box.x, box.y, box.width, box.height)
      context.setLineDash([])
    }
    if (isMoving()) {
      context.restore()
      return
    }
    // The group that has been entered, faintly, so it is seen that the thing
    // chosen is inside something.
    const group = entered ? now.get(entered) : undefined
    if (group) {
      const box = rectInset(now.bounds(group.id) ?? group.rect, -4 / size, -4 / size)
      context.strokeStyle = `rgba(${ACCENT}, 0.35)`
      context.setLineDash([3 / size, 3 / size])
      context.strokeRect(box.x, box.y, box.width, box.height)
      context.setLineDash([])
    }
    if (elements.length > 1 || inkBox) {
      for (const element of elements) {
        const box = element.isConnector ? element.bounds : now.bounds(element.id) ?? element.rect
        context.strokeStyle = `rgba(${ACCENT}, 0.6)`
        context.strokeRect(box.x, box.y, box.width, box.height)
      }
    }
    if (elements.length === 1 && !inkBox) drawHandles(elements[0], now, context, size)
    context.restore()
  }

  /** The outline and the handles of one element. */
  function drawHandles(element: SketchElement, now: SketchTree, context: CanvasRenderingContext2D, size: number) {
    context.save()
    context.strokeStyle = `rgba(${ACCENT}, 0.85)`
    context.lineWidth = 1 / size
    context.setLineDash([])
    if (element.isConnector) {
      // The curve itself, faintly, so the bend handle is seen to belong to it.
      context.strokeStyle = `rgba(${ACCENT}, 0.35)`
      pathOf(element, context)
      context.stroke()
    } else {
      const rect = (element.kind === 'group' ? now.bounds(element.id) : null) ?? element.rect
      const box = rectInset(rect, -2 / size, -2 / size)
      context.strokeStyle = `rgba(${ACCENT}, 0.85)`
      context.strokeRect(box.x, box.y, box.width, box.height)
    }
    for (const [handle, at] of handlesOf(element, now)) {
      const side = (handle === 'mid' ? 9 : HANDLE_SIZE) / size
      context.fillStyle = '#ffffff'
      context.strokeStyle = `rgb(${ACCENT})`
      context.lineWidth = 1.2 / size
      context.beginPath()
      if (handle === 'mid' || element.isConnector) context.arc(at.x, at.y, side / 2, 0, Math.PI * 2)
      else context.rect(at.x - side / 2, at.y - side / 2, side, side)
      context.fill()
      context.stroke()
    }
    context.restore()
  }

  function cursorFor(point: Point): string {
    switch (store.sketch.tool) {
      case 'select': break
      case 'text': return 'text'
      default: return 'crosshair'
    }
    const current = ownSelection()
    if (current && current.ids.length === 1 && current.strokeIDs.length === 0) {
      const now = tree()
      const chosen = now.get(current.ids[0])
      const handle = chosen ? handleAt(point, chosen, now) : null
      if (handle) {
        switch (handle) {
          case 'topLeft': case 'bottomRight': return 'nwse-resize'
          case 'topRight': case 'bottomLeft': return 'nesw-resize'
          case 'top': case 'bottom': return 'ns-resize'
          case 'left': case 'right': return 'ew-resize'
          default: return 'grab'
        }
      }
    }
    return selectableAt(point) !== null || strokeAt(point) !== null ? 'move' : 'default'
  }

  // ---------------------------------------------------------------- wiring

  // One controller for every listener, so putting the pen away really does
  // take the surface out of the picture rather than leaving it listening.
  const listeners = new AbortController()
  const signal = listeners.signal
  on(surface, 'pointerdown', onPointerDown, { signal } as never)
  on(surface, 'pointermove', onPointerMove, { signal } as never)
  on(surface, 'pointerup', onPointerUp, { signal } as never)
  on(surface, 'pointercancel', onPointerUp, { signal } as never)
  on(surface, 'contextmenu', (event: MouseEvent) => event.preventDefault(), { signal } as never)

  if (!keysInstalled) {
    keysInstalled = true
    // The keys themselves are answered in `index.ts`, through the editor
    // object — one place, so a key is never taken twice. What is watched
    // here is the tool: picking a drawing tool lets go of the selection.
    subscribe((keys) => {
      if (keys.has('sketch')) toolChanged(reader, host)
    })
  }

  return {
    detach() {
      if (editing?.page === page) endTextEditing()
      listeners.abort()
      surface.style.cursor = ''
      unhideWorking()
      if (moveTarget && moveTarget !== page) moveTarget.guest = null
    },
    drawOverlay,
    endTextEditing,
    press,
  }
}

/** Whether a point on a page is on something the pencil drew: a sketch
 *  element or a pen stroke — `hitsDrawing` on the Mac. */
export function hitsDrawing(page: PageView, point: Point): boolean {
  const tolerance = HIT_SLOP / (page.viewport?.scale ?? 1)
  if (page.elements.some((element) => element.hits(point, tolerance))) return true
  return page.strokes.some((stroke) => strokeTouches(stroke, point, tolerance + 2))
}
