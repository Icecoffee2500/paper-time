/**
 * What the drawing panel, the rack and the keys ask of the page's editor —
 * `SketchEditing`, and the keys on top of it. One editor per reader.
 */
import { call, isCommand } from '../../bridge.js'
import { setSketchTool, store, type SketchTool } from '../../state.js'
import {
  SketchElement,
  SketchStyle,
  rectInset,
  rectMaxX,
  rectMaxY,
  rectMidX,
  rectMidY,
  rectUnionAll,
  type Rect,
} from '../../../shared/sketch.js'
import {
  SketchTree,
  commonParent,
  copied,
  guessedDirection,
  nextFrameName,
  ordered,
  pruned,
} from '../../../shared/sketchTree.js'
import { InkStroke } from '../../../shared/ink.js'
import { fittedRect } from '../../../shared/sketchRender.js'
import { resized } from '../../../shared/sketchGeometry.js'
import { makeUUID } from '../../../shared/coding.js'
import type { Reader } from '../reader.js'
import { defaultLayout, type SketchAlignment, type SketchEditing } from '../sketchEditing.js'
import { copyText } from '../clipboard.js'
import { beginTextEditing, endTextEditing } from './textEditor.js'
import {
  apply,
  applyBoth,
  editorOwners,
  pageRectOf,
  selectedElements,
  selectedOne,
  selectedPage,
  selection,
  session,
  setSelection,
  setTool,
  strokeBox,
  watchTool,
  type SketchInputHost,
} from './session.js'

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

const editors = new WeakMap<Reader, SketchInputEditing>()



/**
 * The drawing on the clipboard, read again whenever the window comes to the
 * front: copied in another window it can be pasted here, and anything copied
 * since in any app means there is no drawing to paste.
 */

/** The elements with a style change on the chosen ones — a group's change goes to what is in it. */
function restyled(before: SketchElement[], ids: string[], change: (style: SketchStyle) => void): SketchElement[] {
  const tree = new SketchTree(before)
  const targets = new Set(ids)
  for (const id of ids) if (tree.get(id)?.kind === 'group') for (const inner of tree.descendantIDs(id)) targets.add(inner)
  return before.map((element) => {
    if (!targets.has(element.id) || element.kind === 'group') return element
    const changed = element.copy()
    change(changed.style)
    return changed
  })
}

export function watchSketchClipboard() {
  const read = () => {
    void call('clipboard:readSketch').then((raw) => {
      if (!raw) {
        session.clipboard = null
        return
      }
      try {
        session.clipboard = JSON.parse(raw) as typeof session.clipboard
      } catch {
        session.clipboard = null
      }
    }).catch(() => undefined)
  }
  window.addEventListener('focus', read)
  read()
}

export function makeEditing(reader: Reader, host: SketchInputHost): SketchInputEditing {
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

    previewStyle(change) {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current || current.ids.length === 0) return
      if (!session.stylePreview || session.stylePreview.pageIndex !== page.index) session.stylePreview = { pageIndex: page.index, before: page.elements }
      page.elements = restyled(session.stylePreview.before, current.ids, change)
      page.redraw()
    },

    applyStyle(change) {
      const page = selectedPage(reader)
      const current = selection()
      if (!page || !current || current.ids.length === 0) return
      // A colour dragged and then let go is one step, from where it began.
      if (session.stylePreview?.pageIndex === page.index) page.elements = session.stylePreview.before
      session.stylePreview = null
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
      session.entered = null
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
      session.entered = null
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
      const page = reader.pages[reader.state.currentPage]
      if (!page) return
      session.entered = null
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
      if (session.editing) {
        endTextEditing()
        return
      }
      if (session.entered) {
        const group = session.entered
        const current = selection()
        session.entered = null
        setSelection(reader, host, current ? { pageIndex: current.pageIndex, ids: [group], strokeIDs: [] } : null)
        return
      }
      if (selection()) {
        setSelection(reader, host, null)
        return
      }
      if (store.sketch.tool !== 'select') {
        setSketchTool('select')
        session.lastTool = 'select'
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
      session.entered = group.id
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
      session.clipboard = {
        elements: copies.map((element) => element.encode()),
        strokes: strokes.map((stroke) => stroke.encode()),
        fromPage: page.index,
      }
      // So the same copy can land in a note, or anywhere else — and in the
      // other windows, through the main process.
      const words = copies.map((element) => element.text).filter((text) => text.length > 0).join('\n')
      void call('clipboard:writeSketch', { clipping: JSON.stringify(session.clipboard), text: words }).catch(() => {
        if (words.length > 0) void copyText(words)
      })
      return true
    },

    cutSelection() {
      if (editor.copySelection()) editor.deleteSelection()
    },

    /** Pastes onto whichever page is in view. Onto a different page the
     *  drawing keeps its coordinates; back onto the page it came from it is
     *  nudged, so the copy does not hide the original. */
    pasteSketch() {
      const page = reader.pages[reader.state.currentPage]
      if (!session.clipboard || !page) return
      const shift = session.clipboard.fromPage === page.index ? { x: 12, y: -12 } : { x: 0, y: 0 }
      const source = session.clipboard.elements.map(SketchElement.from)
      const { copies, roots } = copied(source.map((element) => element.id), source, shift, makeUUID)
      const before = page.elements
      const strokesBefore = page.strokes
      const pasted = session.clipboard.strokes.map(InkStroke.from).map((stroke) => stroke.translated(shift))
      const strokes = pasted.length > 0 ? [...strokesBefore, ...pasted] : strokesBefore
      const landed = pasted.map((_, index) => strokesBefore.length + index)
      if (!applyBoth(reader, host, page, [...before, ...copies], strokes, before, strokesBefore)) return
      session.entered = null
      setSelection(reader, host, { pageIndex: page.index, ids: [...roots], strokeIDs: landed })
    },

    isEditingText: () => session.editing !== null,

    handleKey(event: KeyboardEvent): boolean {
      const target = event.target as HTMLElement | null
      if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) return false
      if (!reader.state.drawing) return false
      // The desktop's own command key: Ctrl off the Mac, never the Windows key.
      const command = isCommand(event)
      const key = event.key
      const lower = key.toLowerCase()
      // Plain means no modifier at all: Ctrl+A on a Mac is not the arrow tool.
      const plain = !event.metaKey && !event.ctrlKey && !event.altKey
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
          case 'v': if (!session.clipboard) return false; editor.pasteSketch(); return true
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
  editorOwners.set(editor, { reader, host })
  watchTool()
  return editor
}

const TOOL_KEYS: Record<string, SketchTool> = {
  v: 'select', f: 'frame', p: 'pen', h: 'highlighter', e: 'eraser',
  r: 'rectangle', o: 'ellipse', a: 'arrow', l: 'line', t: 'text',
}

/** The editor for a reader — built once, handed to the panel whenever the
 *  pen is out or a page is clicked. */
export function sketchEditingFor(reader: Reader, host: SketchInputHost): SketchInputEditing {
  return makeEditing(reader, host)
}
