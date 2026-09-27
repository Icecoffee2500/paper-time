/**
 * Drawing on a page with a mouse: one page's surface, and every gesture it
 * takes — drawing, selecting, moving, resizing, erasing — with the overlay
 * it draws while a gesture lasts.
 *
 * Ported from `SketchInputView.swift`, which exists because PDFKit gives the
 * Mac no canvas and its page overlays never see the mouse. Here the reason is
 * different — a PDF rendered to a canvas has no notion of a pen at all — but
 * the answer is the same: a surface over each page that takes every gesture,
 * in page coordinates, with the same tools and the same keys.
 *
 * A reader is not a drawing program. A shape is drawn by dragging; it is
 * moved by dragging it; it is selected by clicking it or by sweeping a
 * marquee over nothing. Nothing is modal except the tool, and Escape always
 * steps back out.
 */
import { on } from '../../dom.js'
import { setSketchTool, store } from '../../state.js'
import {
  SketchColor,
  SketchElement,
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
} from '../../../shared/sketch.js'
import { SketchTree, adopted, copied, nextFrameName, pruned, sameElements } from '../../../shared/sketchTree.js'
import { InkStroke, nibWidth, resample, type InkPoint } from '../../../shared/ink.js'
import { drawElement, drawElements, drawInkStroke, fittedRect, fontSpec, pathOf } from '../../../shared/sketchRender.js'
import { BOX_HANDLES, constrained, handlePoint, resized, strokeTouches, type Handle } from '../../../shared/sketchGeometry.js'
import { L } from '../../../shared/lang.js'
import { makeUUID } from '../../../shared/coding.js'
import { SketchSnap, type SnapAxis, type SnapGuide } from '../../../shared/sketchSnap.js'
import type { PageView, Reader } from '../reader.js'
import { snapshot } from '../sketchUndo.js'
import { sketchEditor, sketchSelectionChanged } from '../sketchEditing.js'
import { makeEditing } from './commands.js'
import { beginTextEditing, endTextEditing } from './textEditor.js'
import {
  apply,
  applyBoth,
  pageRectOf,
  refreshSelection,
  selection,
  session,
  setSelection,
  strokeBox,
  undoStack,
  type Selection,
  type SketchInputHost,
} from './session.js'

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

/** Handle size on screen, in CSS pixels — the same however far you zoom. */
const HANDLE_SIZE = 7
/** How near the pointer has to be, on screen, to hit something. */
const HIT_SLOP = 6
const ACCENT = '47, 110, 240'
/** The lines a drag lines up with: the Mac's `systemRed`, which is Figma's
 *  colour for the same lines. */
const GUIDE = 'rgb(255, 59, 48)'


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
  /** The same, by the index each stroke has on its page. */
  let movedStrokes: Map<number, InkStroke> | null = null
  /** The copies a held Alt or Command (Control off the Mac) left behind,
   *  standing where the selection was when the key came down. They are not in
   *  the page while the drag lasts — this surface draws them, and
   *  `finishMove` puts them down together with the move, so one undo takes
   *  both back. */
  let duplicates: SketchElement[] = []
  /** The lines the drag is lining up with, on this page. Drawn while a move
   *  is in hand and gone the moment it ends. */
  let snapGuides: SnapGuide[] = []
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
    return hit ? tree().selectable(hit.id, session.entered) : null
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
    if (session.editing) endTextEditing()
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
    if (selection() && selection()!.pageIndex !== page.index) session.entered = null

    // A double-click: go into a group, type into what is there, or start a
    // card where there is nothing.
    if (clicks === 2) {
      const hit = elementAt(point)
      if (hit) {
        const chosen = current.selectable(hit.id, session.entered)
        const group = current.get(chosen)
        if (chosen !== hit.id && group?.kind === 'group') {
          // Into the group, one level: the child under the pointer.
          session.entered = chosen
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
      session.entered = null
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
    duplicates = []
    snapGuides = []
    moveTarget = page
    hideWorking()
  }

  /** The page's own pass leaves out what this surface is drawing itself. */
  function hideWorking() {
    page.hidden = new Set(working.map((element) => element.id))
    const current = ownSelection()
    page.hiddenStrokes = drag.kind === 'move' && current ? new Set(current.strokeIDs) : new Set()
    page.redraw()
  }

  function unhideWorking() {
    page.hidden = new Set()
    page.hiddenStrokes = new Set()
  }

  /** Where the idle pointer was last, for the cursor worked out once a
   *  frame — hit-testing every stroke's every point on every move was the
   *  most expensive thing an idle pointer did. */
  let idleAt: Point | null = null
  let idleFrame = 0

  function onPointerMove(event: PointerEvent) {
    if (drag.kind === 'none') {
      idleAt = pointOf(event)
      if (!idleFrame) {
        idleFrame = requestAnimationFrame(() => {
          idleFrame = 0
          if (idleAt && drag.kind === 'none') surface.style.cursor = cursorFor(idleAt)
        })
      }
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
        // The eraser changes what is on the page: the page is drawn again.
        eraseAt(point, drag.last)
        drag.last = point
        page.redraw()
        return
      case 'move': {
        // The page under the pointer is where the selection is going; the
        // offset from where the drag began keeps the grip.
        const move = drag
        const target = reader.pageAtClient(event.clientX, event.clientY) ?? page
        const landing = target === page ? point : target.toPageFromClient(event.clientX, event.clientY)
        let offset = { x: landing.x - move.origin.x, y: landing.y - move.origin.y }
        const current = ownSelection()
        const before = new SketchTree(move.elementsBefore)
        const moving = before.expanded(current?.ids ?? [])

        // Held down, the drag leaves a copy behind — Figma's Alt, and the
        // Command the reader asked for because that is the one their hand
        // knows (Control off the Mac, as the keys are read everywhere else
        // here). Done once, the first time the key is seen: the copies stand
        // in the places the selection is leaving, and the selection carries
        // on being dragged.
        if ((event.altKey || event.metaKey || event.ctrlKey) && duplicates.length === 0 && current) {
          duplicates = copied(current.ids, move.elementsBefore, { x: 0, y: 0 }, makeUUID).copies
        }

        // Shift holds the drag to one axis — Figma's constraint, and the
        // reason Shift with Command is the gesture for "another one of these,
        // straight below this one". Shift when the button went down still
        // means "add this to the selection"; it is only read here, mid-drag.
        let held: SnapAxis | null = null
        if (shift) {
          if (Math.abs(offset.x) >= Math.abs(offset.y)) {
            offset.y = 0
            held = 'horizontal'
          } else {
            offset.x = 0
            held = 'vertical'
          }
        }

        // Lined up with whatever else is on the page, and with the page
        // itself. The copies left behind are not lined up with: they stand
        // where the drag started, and a magnet back to the start is not help.
        const box = before.boundsOf(moving)
        if (target === page && box) {
          const others = move.elementsBefore.filter((element) => !moving.has(element.id)).map((element) => element.rect)
          const result = SketchSnap.adjust(box, offset, others, pageRectOf(page), tolerance())
          // A held axis wins over a line found on it: the reader said this
          // row, and a guide that cannot move anything is a lie.
          const snapped = { ...result.offset }
          if (held === 'horizontal') snapped.y = offset.y
          if (held === 'vertical') snapped.x = offset.x
          offset = snapped
          snapGuides = result.guides.filter((guide) => guide.axis !== held)
        } else {
          snapGuides = []
        }
        // The strokes go by the same corrected offset as the shapes: a
        // selection is one thing in the hand, and a stroke left behind by the
        // few points a shape gave up would come apart from it.
        working = move.elementsBefore.filter((element) => moving.has(element.id)).map((element) => element.translated(offset))
        if (current && current.strokeIDs.length > 0) {
          movedStrokes = new Map(current.strokeIDs
            .filter((index) => index < move.strokesBefore.length)
            .map((index) => [index, move.strokesBefore[index].translated(offset)]))
          workingStrokes = [...movedStrokes.values()]
        }
        if (moveTarget !== target) {
          if (moveTarget && moveTarget !== page) {
            moveTarget.guest = null
            moveTarget.redrawOverlay()
          }
          moveTarget = target
          if (target !== page) target.guest = drawWorking
        }
        move.moved = true
        if (target !== page) target.redrawOverlay()
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
    // What is being drawn, moved or swept is the overlay's; the page under it
    // is drawn again only when what is on it changed. Every pointer move used
    // to draw the page's whole drawing again, ink and shapes and all.
    page.redrawOverlay()
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
        setSketchTool('select')
        session.lastTool = 'select'
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
        duplicates = []
        snapGuides = []
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
    movedStrokes = null
    page.redraw()
    void point
  }

  /**
   * The gesture was taken away — the system claimed the pointer, a touch
   * became a scroll. Nothing it was doing is kept: it was handled as a
   * gesture that finished, so a cancelled drag put a shape down.
   */
  function onPointerCancel(event: PointerEvent) {
    const cancelled = drag
    drag = { kind: 'none' }
    try {
      surface.releasePointerCapture(event.pointerId)
    } catch {
      // Already gone.
    }
    if (cancelled.kind === 'erase') {
      page.elements = cancelled.elementsBefore
      page.strokes = cancelled.strokesBefore
    }
    if (cancelled.kind === 'marquee' || cancelled.kind === 'pendingClick') {
      if (cancelled.before) setSelection(reader, host, cancelled.before)
    }
    if (moveTarget && moveTarget !== page) {
      moveTarget.guest = null
      moveTarget.redrawOverlay()
    }
    unhideWorking()
    moveTarget = null
    working = []
    workingStrokes = null
    movedStrokes = null
    duplicates = []
    snapGuides = []
    page.redraw()
  }

  /** Puts a moved selection down — on the page it came from, or on the page
   *  the pointer ended over, in which case it leaves one page's sidecar and
   *  joins the other's as one undoable step. */
  function finishMove(elementsBefore: SketchElement[], strokesBefore: InkStroke[], target: PageView) {
    const current = ownSelection()
    if (!current) return
    const before = new SketchTree(elementsBefore)
    const moving = before.expanded(current.ids)
    // By the stroke's own index: `workingStrokes` leaves out any index past
    // the end, and reading it by position in the selection put a moved stroke
    // in another stroke's place.
    const strokesAfter = movedStrokes
      ? strokesBefore.map((stroke, index) => movedStrokes!.get(index) ?? stroke)
      : strokesBefore

    if (target === page) {
      // The copies a held key left behind go down with the move, so the page
      // gains them and loses nothing in one undoable step.
      let after = [...elementsBefore, ...duplicates].map((element) => working.find((entry) => entry.id === element.id) ?? element)
      after = adopted(before.outermost(current.ids), after)
      applyBoth(reader, host, page, after, workingStrokes ? strokesAfter : strokesBefore, elementsBefore, strokesBefore)
      return
    }

    // Across pages. The elements keep their ids — it is the same box, on the
    // next page — and lose any parent left behind. The copies stay on the
    // page they were left on, and keep a group they were left in from being
    // taken for empty.
    const sourceAfter = SketchTree.normalized(pruned([...elementsBefore.filter((element) => !moving.has(element.id)), ...duplicates]))
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
    session.entered = null
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
      if (!element.isContainer && rectIntersects(element.bounds, box)) touched.add(now.selectable(element.id, session.entered))
    }
    for (const id of now.outermost(touched)) ids.add(id)
    page.strokes.forEach((stroke, index) => {
      if (rectIntersects(stroke.bounds, box)) strokes.add(index)
    })
    select([...ids], [...strokes])
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
      // A highlight or an underline under the eraser comes off too, as on
      // the Mac — a step of its own, «Erase Mark», back with ⌘Z.
      if (page.marks.length > 0) reader.eraseMarkAt(page, sample)
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
    setSketchTool('select')
    session.lastTool = 'select'
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
    if (session.editing && session.editing.page === page) {
      const element = page.elements.find((entry) => entry.id === session.editing!.id)
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
        if (drag.kind === 'move') {
          // The copies standing where the drag began, drawn on the page they
          // will be put down on rather than the one being dragged to.
          if (duplicates.length > 0) drawElements(duplicates, context)
          drawSnapGuides(context)
        }
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

  /** The lines a snapped drag lined up with: thin, red, and only while the
   *  hand is down. Figma's colour, and the reason for it is that they must
   *  not be read as part of the drawing — nothing else on a page is that red
   *  and one pixel wide. */
  function drawSnapGuides(context: CanvasRenderingContext2D) {
    if (snapGuides.length === 0) return
    // In the canvas's own pixels rather than the page's, rounded onto them,
    // so a guide is one sharp pixel at any zoom — the Mac rounds to its
    // grid for the same reason. One pixel on screen is as many canvas pixels
    // as the page's surface was given: the display's ratio, at most two.
    const toCanvas = context.getTransform()
    const width = Math.max(1, Math.round(Math.min(window.devicePixelRatio || 1, 2)))
    const onGrid = (value: number) => Math.round(value) + (width % 2 === 1 ? 0.5 : 0)
    context.save()
    context.setTransform(1, 0, 0, 1, 0, 0)
    context.strokeStyle = GUIDE
    context.lineWidth = width
    context.setLineDash([])
    context.beginPath()
    for (const guide of snapGuides) {
      const [a, b] = guide.axis === 'vertical'
        ? [{ x: guide.position, y: guide.from }, { x: guide.position, y: guide.to }]
        : [{ x: guide.from, y: guide.position }, { x: guide.to, y: guide.position }]
      const from = toCanvas.transformPoint(a)
      const to = toCanvas.transformPoint(b)
      context.moveTo(onGrid(from.x), onGrid(from.y))
      context.lineTo(onGrid(to.x), onGrid(to.y))
    }
    context.stroke()
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
    const group = session.entered ? now.get(session.entered) : undefined
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
  on(surface, 'pointercancel', onPointerCancel, { signal } as never)
  on(surface, 'contextmenu', (event: MouseEvent) => event.preventDefault(), { signal } as never)

  return {
    detach() {
      if (session.editing?.page === page) endTextEditing()
      if (idleFrame) cancelAnimationFrame(idleFrame)
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
