/**
 * Drawing on a page with a mouse.
 *
 * Ported from `SketchInputView.swift`, which exists because PDFKit gives the
 * Mac no canvas and its page overlays never see the mouse. Here the reason is
 * different — a PDF rendered to a canvas has no notion of a pen at all — but
 * the answer is the same: a surface over the page that takes every gesture,
 * in page coordinates, with the same tools and the same keys.
 *
 * What the surface has to get right is that a reader is not a drawing program.
 * A shape is drawn by dragging; it is moved by dragging it; it is selected by
 * clicking it or by sweeping a marquee over nothing. Nothing is modal except
 * the tool, and Escape always steps back out.
 */
import { el, on } from '../dom.js'
import { store } from '../state.js'
import {
  SketchColor,
  SketchElement,
  SketchStyle,
  rectContains,
  rectFrom,
  rectInset,
  rectIntersects,
  rectMaxX,
  rectMaxY,
  rectMidX,
  rectMidY,
  expandedIDs,
  selectableFor,
  treeBounds,
  type Point,
  type Rect,
} from '../../shared/sketch.js'
import { InkStroke, nibWidth, resample, type InkPoint } from '../../shared/ink.js'
import {
  cardSize,
  drawElement,
  drawInkStroke,
  fittedRect,
  SKETCH_FONT_STACK,
  TEXT_PADDING,
} from '../../shared/sketchRender.js'
import { TEXT_POINTS } from '../../shared/sketch.js'
import type { PageView, Reader } from './reader.js'
import { SketchUndo, snapshot, type Snapshot } from './sketchUndo.js'

export const undoStack = new SketchUndo()

export interface SketchInputHost {
  changed: () => void
  save: (page: PageView) => void
}

/** Where a handle sits on a selected element. */
type Handle =
  | 'topLeft' | 'top' | 'topRight' | 'right'
  | 'bottomRight' | 'bottom' | 'bottomLeft' | 'left'
  | 'start' | 'end' | 'bend'

const BOX_HANDLES: Handle[] = [
  'topLeft', 'top', 'topRight', 'right', 'bottomRight', 'bottom', 'bottomLeft', 'left',
]

type Drag =
  | { kind: 'none' }
  | { kind: 'shape'; element: SketchElement; origin: Point }
  | { kind: 'stroke'; points: InkPoint[]; tool: 'pen' | 'marker' }
  | { kind: 'erase' }
  | { kind: 'move'; origin: Point; before: SketchElement[] }
  | { kind: 'resize'; handle: Handle; origin: Rect; before: SketchElement[] }
  | { kind: 'bend'; before: SketchElement }
  | { kind: 'marquee'; origin: Point; current: Point }
  | { kind: 'pendingClick'; origin: Point; hit: SketchElement | null }

export interface SketchInput {
  detach: () => void
  drawOverlay: (context: CanvasRenderingContext2D) => void
  endTextEditing: () => void
}

/** Handle size on screen, in CSS pixels — the same however far you zoom. */
const HANDLE_SIZE = 7
/** How near the pointer has to be, on screen, to hit something. */
const HIT_SLOP = 6

export function attachSketchInput(
  page: PageView,
  reader: Reader,
  host: SketchInputHost,
): SketchInput {
  const surface = page.inputSurface
  let drag: Drag = { kind: 'none' }
  let editor: HTMLTextAreaElement | null = null
  let editing: SketchElement | null = null
  let editingIsNew = false
  let before: Snapshot | null = null

  const scale = () => page.viewport?.scale ?? 1
  const tolerance = () => HIT_SLOP / scale()

  function pointOf(event: PointerEvent | MouseEvent): Point {
    const box = surface.getBoundingClientRect()
    return page.toPage(event.clientX - box.left, event.clientY - box.top)
  }

  function selection(): SketchElement[] {
    const current = store.sketch.selection
    if (!current || current.pageIndex !== page.index) return []
    return page.elements.filter((element) => current.ids.includes(element.id))
  }

  function select(elements: SketchElement[]) {
    store.sketch.selection = elements.length === 0
      ? null
      : { pageIndex: page.index, ids: elements.map((element) => element.id), strokeIDs: [] }
    host.changed()
  }

  function begin() {
    before = snapshot(page.index, page.elements, page.strokes)
  }

  function commit() {
    if (!before) return
    undoStack.record(before, snapshot(page.index, page.elements, page.strokes))
    before = null
    host.save(page)
  }

  // ------------------------------------------------------------ hit testing

  function elementAt(point: Point): SketchElement | null {
    // Topmost first: the last drawn is the one on top — and a hit inside a
    // group picks up the group, as it does on the Mac.
    for (let index = page.elements.length - 1; index >= 0; index -= 1) {
      if (page.elements[index].hits(point, tolerance())) {
        const chosen = selectableFor(page.elements, page.elements[index].id)
        return page.elements.find((element) => element.id === chosen) ?? page.elements[index]
      }
    }
    return null
  }

  /** The selection and everything inside it — what a move or a resize takes along. */
  function selectionWithin(): SketchElement[] {
    const ids = expandedIDs(page.elements, selection().map((element) => element.id))
    return page.elements.filter((element) => ids.has(element.id))
  }

  function handleAt(point: Point): Handle | null {
    const chosen = selection()
    if (chosen.length === 0) return null
    const reach = (HANDLE_SIZE / scale()) * 0.9
    if (chosen.length === 1 && chosen[0].isConnector) {
      const element = chosen[0]
      if (near(point, element.start, reach)) return 'start'
      if (near(point, element.end, reach)) return 'end'
      if (near(point, element.midpoint, reach)) return 'bend'
      return null
    }
    const box = selectionRect(chosen)
    if (!box) return null
    for (const handle of BOX_HANDLES) {
      if (near(point, handlePoint(box, handle), reach)) return handle
    }
    return null
  }

  function near(a: Point, b: Point, reach: number): boolean {
    return Math.abs(a.x - b.x) <= reach && Math.abs(a.y - b.y) <= reach
  }

  function selectionRect(elements: SketchElement[]): Rect | null {
    if (elements.length === 0) return null
    return elements
      .map((element) => treeBounds(page.elements, element.id) ?? element.rect)
      .reduce((a, b) => {
        const minX = Math.min(a.x, b.x)
        const minY = Math.min(a.y, b.y)
        const maxX = Math.max(rectMaxX(a), rectMaxX(b))
        const maxY = Math.max(rectMaxY(a), rectMaxY(b))
        return { x: minX, y: minY, width: maxX - minX, height: maxY - minY }
      })
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

  function resized(box: Rect, handle: Handle, point: Point): Rect {
    let { x, y } = box
    let maxX = rectMaxX(box)
    let maxY = rectMaxY(box)
    if (handle.includes('Left') || handle === 'left') x = point.x
    if (handle.includes('Right') || handle === 'right') maxX = point.x
    if (handle.startsWith('top') || handle === 'top') maxY = point.y
    if (handle.startsWith('bottom') || handle === 'bottom') y = point.y
    return rectFrom({ x, y }, { x: maxX, y: maxY })
  }

  // ------------------------------------------------------------- the mouse

  function onPointerDown(event: PointerEvent) {
    if (event.button !== 0) return
    surface.setPointerCapture(event.pointerId)
    const point = pointOf(event)
    endTextEditing()
    const tool = store.sketch.tool

    if (tool === 'eraser') {
      begin()
      drag = { kind: 'erase' }
      eraseAt(point)
      return
    }

    if (tool === 'pen' || tool === 'highlighter') {
      begin()
      const kind = tool === 'highlighter' ? 'marker' : 'pen'
      const base = kind === 'marker' ? Math.max(store.sketch.style.width * 5, 10) : store.sketch.style.width
      drag = {
        kind: 'stroke',
        tool: kind,
        points: [{ ...point, w: nibWidth(base, event.pressure, kind) }],
      }
      return
    }

    if (tool === 'text') {
      begin()
      const element = new SketchElement({
        kind: 'text',
        points: [point, { x: point.x + 24, y: point.y - 1 }],
        style: store.sketch.style.copy(),
      })
      element.textSizing = 'autoWidth'
      element.setRect(fittedRect(element))
      page.elements.push(element)
      select([element])
      startTextEditing(element, true)
      return
    }

    if (tool !== 'select') {
      begin()
      const element = new SketchElement({
        kind: tool === 'arrow' ? 'arrow' : tool === 'line' ? 'line' : tool,
        points: [point, point],
        style: store.sketch.style.copy(),
      })
      if (element.kind === 'line') element.style.endHead = 'none'
      page.elements.push(element)
      drag = { kind: 'shape', element, origin: point }
      page.hidden.add(element.id)
      page.redraw()
      return
    }

    // Select.
    const handle = handleAt(point)
    if (handle) {
      begin()
      const chosen = selection()
      if (handle === 'bend' && chosen.length === 1) {
        drag = { kind: 'bend', before: chosen[0].copy() }
      } else if ((handle === 'start' || handle === 'end') && chosen.length === 1) {
        drag = { kind: 'resize', handle, origin: chosen[0].rect, before: chosen.map((e) => e.copy()) }
      } else {
        const box = selectionRect(chosen)!
        drag = { kind: 'resize', handle, origin: box, before: selectionWithin().map((e) => e.copy()) }
      }
      return
    }

    const hit = elementAt(point)
    if (hit) {
      const chosen = selection()
      const already = chosen.some((element) => element.id === hit.id)
      if (event.shiftKey) {
        select(already ? chosen.filter((e) => e.id !== hit.id) : [...chosen, hit])
      } else if (!already) {
        select([hit])
      }
      begin()
      drag = { kind: 'move', origin: point, before: selectionWithin().map((e) => e.copy()) }
      return
    }

    if (!event.shiftKey) select([])
    drag = { kind: 'marquee', origin: point, current: point }
    page.redraw()
  }

  function onPointerMove(event: PointerEvent) {
    if (drag.kind === 'none') {
      surface.style.cursor = cursorFor(pointOf(event))
      return
    }
    const point = pointOf(event)
    switch (drag.kind) {
      case 'shape': {
        // Shift makes a square, a circle, or a line at 45°.
        let end = point
        if (event.shiftKey) end = constrained(drag.origin, point, drag.element.isConnector)
        drag.element.points = [drag.origin, end]
        break
      }
      case 'stroke': {
        const base = drag.tool === 'marker'
          ? Math.max(store.sketch.style.width * 5, 10)
          : store.sketch.style.width
        drag.points.push({ ...point, w: nibWidth(base, event.pressure, drag.tool) })
        break
      }
      case 'erase':
        eraseAt(point)
        break
      case 'move': {
        const move = drag
        const offset = { x: point.x - move.origin.x, y: point.y - move.origin.y }
        const ids = move.before.map((element) => element.id)
        page.elements = page.elements.map((element) => {
          const index = ids.indexOf(element.id)
          return index === -1 ? element : move.before[index].translated(offset)
        })
        break
      }
      case 'resize': {
        const resize = drag
        if (resize.handle === 'start' || resize.handle === 'end') {
          const element = page.elements.find((e) => e.id === resize.before[0].id)
          if (element) {
            const points = [...element.points]
            points[resize.handle === 'start' ? 0 : 1] = point
            element.points = points
          }
          break
        }
        const box = resized(resize.origin, resize.handle, point)
        if (box.width < 1 || box.height < 1) break
        const ids = resize.before.map((element) => element.id)
        page.elements = page.elements.map((element) => {
          const index = ids.indexOf(element.id)
          return index === -1 ? element : resize.before[index].fitted(box, resize.origin)
        })
        break
      }
      case 'bend': {
        const bend = drag
        const element = page.elements.find((e) => e.id === bend.before.id)
        element?.setMidpoint(point)
        break
      }
      case 'marquee':
        drag.current = point
        break
      default:
        break
    }
    page.redraw()
  }

  function onPointerUp(event: PointerEvent) {
    const point = pointOf(event)
    switch (drag.kind) {
      case 'shape': {
        const shape = drag
        page.hidden.delete(shape.element.id)
        const box = shape.element.rect
        const tiny = shape.element.isConnector
          ? Math.hypot(
              shape.element.end.x - shape.element.start.x,
              shape.element.end.y - shape.element.start.y,
            ) < 4
          : box.width < 4 && box.height < 4
        if (tiny) {
          // A click with a shape tool is a click, not a shape the size of a
          // full stop. Nothing is left behind.
          page.elements = page.elements.filter((element) => element.id !== shape.element.id)
          before = null
        } else {
          select([shape.element])
          commit()
        }
        // The tool steps back to select, the way it does on the Mac: you drew
        // the box, and the next thing you want is to move or label it.
        store.sketch.tool = 'select'
        host.changed()
        break
      }
      case 'stroke': {
        const points = resample(drag.points)
        if (points.length > 1) {
          const colour = drag.tool === 'marker'
            ? (store.sketch.style.fill ?? SketchColor.paleYellow).withAlpha(1)
            : store.sketch.style.stroke
          page.strokes.push(new InkStroke(points, colour, drag.tool))
          commit()
        } else {
          before = null
        }
        break
      }
      case 'erase':
        commit()
        break
      case 'move':
      case 'resize':
      case 'bend':
        commit()
        break
      case 'marquee': {
        const box = rectFrom(drag.origin, point)
        if (box.width > 2 || box.height > 2) {
          select(page.elements.filter((element) => rectIntersects(element.bounds, box)))
        }
        break
      }
      default:
        break
    }
    drag = { kind: 'none' }
    page.redraw()
    try {
      surface.releasePointerCapture(event.pointerId)
    } catch {
      // The capture is already gone; nothing to release.
    }
  }

  function onDoubleClick(event: MouseEvent) {
    const point = pointOf(event)
    const hit = elementAt(point)
    if (!hit) return
    if (hit.kind === 'text' || hit.isBox) {
      select([hit])
      startTextEditing(hit, false)
    }
  }

  function constrained(origin: Point, point: Point, isLine: boolean): Point {
    const dx = point.x - origin.x
    const dy = point.y - origin.y
    if (!isLine) {
      const size = Math.max(Math.abs(dx), Math.abs(dy))
      return { x: origin.x + Math.sign(dx) * size, y: origin.y + Math.sign(dy) * size }
    }
    const angle = Math.atan2(dy, dx)
    const step = Math.PI / 4
    const snapped = Math.round(angle / step) * step
    const length = Math.hypot(dx, dy)
    return { x: origin.x + Math.cos(snapped) * length, y: origin.y + Math.sin(snapped) * length }
  }

  /**
   * The eraser, walking the gap between samples.
   *
   * A pointer reports every few milliseconds and a hand moves faster than
   * that, so erasing only at the reported points leaves untouched islands in a
   * fast sweep. The segment between two samples is walked instead.
   */
  let lastErase: Point | null = null
  function eraseAt(point: Point) {
    const reach = Math.max(8 / scale(), 4)
    const path = lastErase ? walk(lastErase, point, reach / 2) : [point]
    lastErase = point
    for (const step of path) {
      page.strokes = page.strokes.filter((stroke) => !strokeTouches(stroke, step, reach))
      const gone = expandedIDs(page.elements, page.elements.filter((element) => element.hits(step, reach)).map((e) => e.id))
      page.elements = page.elements.filter((element) => !gone.has(element.id))
    }
  }

  function walk(from: Point, to: Point, step: number): Point[] {
    const distance = Math.hypot(to.x - from.x, to.y - from.y)
    const count = Math.max(1, Math.ceil(distance / Math.max(step, 0.5)))
    return Array.from({ length: count + 1 }, (_, index) => ({
      x: from.x + ((to.x - from.x) * index) / count,
      y: from.y + ((to.y - from.y) * index) / count,
    }))
  }

  function strokeTouches(stroke: InkStroke, point: Point, reach: number): boolean {
    return stroke.points.some(
      (sample) => Math.hypot(sample.x - point.x, sample.y - point.y) <= reach + sample.w / 2,
    )
  }

  // ---------------------------------------------------------------- words

  function startTextEditing(element: SketchElement, isNew: boolean) {
    endTextEditing()
    editing = element
    editingIsNew = isNew
    if (!before) begin()
    const box = element.isBox && element.kind !== 'text'
      ? rectInset(element.rect, TEXT_PADDING, TEXT_PADDING)
      : element.rect
    const topLeft = page.toView(box.x, rectMaxY(box))
    const size = scale()
    const area = el('textarea', { class: 'sketch-text-editor', spellcheck: 'false' }) as HTMLTextAreaElement
    area.value = element.text
    area.style.left = `${topLeft.x}px`
    area.style.top = `${topLeft.y}px`
    area.style.width = `${Math.max(box.width * size, 40)}px`
    area.style.height = `${Math.max(box.height * size, element.style.points * size * 1.2)}px`
    area.style.fontFamily = SKETCH_FONT_STACK
    area.style.fontSize = `${element.style.points * size}px`
    area.style.color = element.style.stroke.css
    area.style.textAlign = element.kind === 'text' ? element.style.textAlign : 'center'
    page.root.append(area)
    editor = area
    area.focus()
    area.select()
    page.hidden.add(element.id)
    page.redraw()

    const grow = () => {
      if (!editing) return
      editing.text = area.value
      if (editing.kind === 'text') {
        // A text card follows its words: wider when it sizes to its width,
        // taller when it sizes to its height.
        const fitted = fittedRect(editing)
        editing.setRect(fitted)
        const corner = page.toView(fitted.x, rectMaxY(fitted))
        area.style.left = `${corner.x}px`
        area.style.top = `${corner.y}px`
        area.style.width = `${fitted.width * size}px`
        area.style.height = `${fitted.height * size}px`
      }
    }
    on(area, 'input', grow)
    on(area, 'keydown', (event: KeyboardEvent) => {
      event.stopPropagation()
      if (event.key === 'Escape') {
        event.preventDefault()
        endTextEditing()
      }
      // Enter makes a new line; the card is finished by clicking away or by
      // Escape, so a note can be more than one line without a modifier.
    })
    on(area, 'blur', () => endTextEditing())
  }

  function endTextEditing() {
    if (!editor || !editing) return
    const area = editor
    const element = editing
    editor = null
    editing = null
    element.text = area.value
    area.remove()
    page.hidden.delete(element.id)
    if (element.kind === 'text' && element.text.trim() === '') {
      // An empty card is nothing at all.
      page.elements = page.elements.filter((entry) => entry.id !== element.id)
      if (editingIsNew) {
        before = null
        store.sketch.selection = null
      }
    } else {
      commit()
    }
    editingIsNew = false
    store.sketch.tool = 'select'
    page.redraw()
    host.changed()
  }

  // ------------------------------------------------------------- overlay

  /** The selection's handles and the marquee, drawn in page coordinates. */
  function drawOverlay(context: CanvasRenderingContext2D) {
    const size = scale()
    const chosen = selection()

    if (drag.kind === 'shape') {
      // The shape being drawn is hidden from the page's own pass so it can be
      // drawn here, above everything, while the drag is live.
      drawElement(drag.element, context)
    }
    if (drag.kind === 'stroke') {
      const colour = drag.tool === 'marker'
        ? (store.sketch.style.fill ?? SketchColor.paleYellow).withAlpha(1)
        : store.sketch.style.stroke
      drawInkStroke(new InkStroke(drag.points, colour, drag.tool), context)
    }

    context.save()
    context.lineWidth = 1 / size
    context.setLineDash([])

    if (drag.kind === 'marquee') {
      const box = rectFrom(drag.origin, drag.current)
      context.fillStyle = 'rgba(47, 110, 240, 0.12)'
      context.strokeStyle = 'rgba(47, 110, 240, 0.9)'
      context.setLineDash([4 / size, 3 / size])
      context.fillRect(box.x, box.y, box.width, box.height)
      context.strokeRect(box.x, box.y, box.width, box.height)
      context.setLineDash([])
    }

    if (chosen.length > 0) {
      const box = selectionRect(chosen)!
      context.strokeStyle = 'rgba(47, 110, 240, 0.85)'
      if (chosen.length > 1 || !chosen[0].isConnector) {
        const outline = rectInset(box, -3 / size, -3 / size)
        context.setLineDash([3 / size, 2.5 / size])
        context.strokeRect(outline.x, outline.y, outline.width, outline.height)
        context.setLineDash([])
        for (const handle of BOX_HANDLES) {
          knob(context, handlePoint(outline, handle), size)
        }
      } else {
        const element = chosen[0]
        knob(context, element.start, size)
        knob(context, element.end, size)
        knob(context, element.midpoint, size, true)
      }
    }
    context.restore()
  }

  function knob(context: CanvasRenderingContext2D, point: Point, size: number, round = false) {
    const half = HANDLE_SIZE / size / 2
    context.fillStyle = '#ffffff'
    context.strokeStyle = 'rgba(47, 110, 240, 0.95)'
    context.lineWidth = 1.2 / size
    context.beginPath()
    if (round) context.arc(point.x, point.y, half, 0, Math.PI * 2)
    else context.rect(point.x - half, point.y - half, half * 2, half * 2)
    context.fill()
    context.stroke()
  }

  function cursorFor(point: Point): string {
    if (store.sketch.tool !== 'select') return 'crosshair'
    const handle = handleAt(point)
    if (handle) {
      switch (handle) {
        case 'topLeft': case 'bottomRight': return 'nwse-resize'
        case 'topRight': case 'bottomLeft': return 'nesw-resize'
        case 'top': case 'bottom': return 'ns-resize'
        case 'left': case 'right': return 'ew-resize'
        default: return 'grab'
      }
    }
    return elementAt(point) ? 'move' : 'default'
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
  on(surface, 'dblclick', onDoubleClick, { signal } as never)
  on(surface, 'contextmenu', (event: MouseEvent) => event.preventDefault(), { signal } as never)

  return {
    detach() {
      endTextEditing()
      listeners.abort()
      surface.style.cursor = ''
    },
    drawOverlay,
    endTextEditing,
  }
}
