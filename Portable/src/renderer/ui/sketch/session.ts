/**
 * What the drawing layer keeps between gestures: the selection's helpers,
 * the one text card being typed into, the group a double-click went into,
 * the drawing clipboard — and the one way a change to a page is written.
 *
 * The selection lives in the store and there is one per window, so what
 * hangs off it is one per window too. What is per reader is the editor
 * (`commands.ts`), and the tool watch below asks the editor in use which
 * reader it is — it used to keep the first reader it met, forever, and
 * redraw it after it was gone.
 */
import { setSketchTool, store, subscribe, type SketchTool } from '../../state.js'
import { SketchElement } from '../../../shared/sketch.js'
import { SketchTree, sameElements } from '../../../shared/sketchTree.js'
import { InkStroke } from '../../../shared/ink.js'
import { pageRect, strokesBox } from '../../../shared/sketchGeometry.js'
import type { Rect } from '../../../shared/sketch.js'
import type { PageView, Reader } from '../reader.js'
import { SketchUndo, snapshot } from '../sketchUndo.js'
import type { LatexSuiteField } from '../latexSuiteInput.js'
import { sketchEditor, sketchSelectionChanged, type SketchEditing } from '../sketchEditing.js'

export const undoStack = new SketchUndo()

export interface SketchInputHost {
  changed: () => void
  save: (page: PageView) => void
}

export interface Selection {
  pageIndex: number
  ids: string[]
  strokeIDs: number[]
}

/** The card being typed into, on whichever page. */
export interface TextEditing {
  page: PageView
  id: string
  area: HTMLTextAreaElement
  before: SketchElement[]
  isNew: boolean
  host: SketchInputHost
  reader: Reader
}

export const session: {
  /** The group a double-click went into, whose children are chosen one at
   *  a time until the selection leaves it. */
  entered: string | null
  /** What ⌘C took: the elements and strokes as their JSON, and the page they
   *  came from so pasting back onto it can offset. */
  clipboard: { elements: unknown[]; strokes: unknown[]; fromPage: number } | null
  editing: TextEditing | null
  /** Latex Suite in that card: `$…$` on a card is typed the way it is in a note. */
  latexField: LatexSuiteField | null
  /** The tool as it was last seen, so a change of it is seen once. */
  lastTool: SketchTool
  /** Set by the text editor: ends the typing, if there is any, and puts
   *  the field back over its card after the card changed. */
  endTextEditing?: () => void
  placeEditor?: () => void
  /** A colour still moving under the hand: the page shows it, and what the
   *  page held before it is what the one undo step goes back to. */
  stylePreview: { pageIndex: number; before: SketchElement[] } | null
} = {
  entered: null,
  clipboard: null,
  editing: null,
  latexField: null,
  lastTool: store.sketch.tool,
  stylePreview: null,
}

/** Which reader each editor is for — asked by the tool watch. */
export const editorOwners = new WeakMap<SketchEditing, { reader: Reader; host: SketchInputHost }>()

/** Called when the pen goes away: whatever was half done is let go of. */
export function resetSketchInput() {
  session.entered = null
  session.endTextEditing?.()
}

export function isEditingSketchText(): boolean {
  return session.editing !== null
}

export function pageRectOf(page: PageView): Rect {
  return pageRect(page.shape.view)
}

/** The bounds of the pen strokes chosen, as the panel sees them. */
export function strokeBox(page: PageView, indices: number[]): Rect | null {
  return strokesBox(page.strokes, indices)
}


export function selection(): Selection | null {
  return store.sketch.selection
}

export function selectedPage(reader: Reader): PageView | null {
  const current = selection()
  return current ? reader.pages[current.pageIndex] ?? null : null
}

export function setSelection(reader: Reader, host: SketchInputHost, next: Selection | null) {
  const cleaned = next && next.ids.length === 0 && next.strokeIDs.length === 0 ? null : next
  const before = store.sketch.selection
  const same = JSON.stringify(before) === JSON.stringify(cleaned)
  store.sketch.selection = cleaned
  // A group entered is left when the selection leaves it.
  if (session.entered) {
    const page = cleaned ? reader.pages[cleaned.pageIndex] : null
    const tree = page ? new SketchTree(page.elements) : null
    if (!cleaned || cleaned.ids.length === 0 || !tree || !cleaned.ids.every((id) => tree.isDescendant(id, session.entered!))) {
      session.entered = null
    }
  }
  if (!same) {
    sketchSelectionChanged()
    host.changed()
  }
}

/** Tells the panel again after the selection's elements changed under it. */
export function refreshSelection(reader: Reader) {
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

export function selectedElements(reader: Reader): SketchElement[] {
  const current = selection()
  const page = selectedPage(reader)
  if (!current || !page) return []
  return page.elements.filter((element) => current.ids.includes(element.id))
}

export function selectedOne(reader: Reader): SketchElement | null {
  const chosen = selectedElements(reader)
  return chosen.length === 1 && (selection()?.strokeIDs.length ?? 0) === 0 ? chosen[0] : null
}

// MARK: - Writing a change

/** One change to a page's elements, put in tree order, written, made
 *  undoable, and shown. */
export function apply(reader: Reader, host: SketchInputHost, page: PageView, elements: SketchElement[], before: SketchElement[]): boolean {
  const after = SketchTree.normalized(elements)
  if (sameElements(after, before)) return false
  const was = snapshot(page.index, before, page.strokes)
  page.elements = after
  undoStack.record(was, snapshot(page.index, after, page.strokes))
  host.save(page)
  page.redraw()
  session.placeEditor?.()
  refreshSelection(reader)
  host.changed()
  return true
}

/** The same, for a change that touched the strokes as well. */
export function applyBoth(
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
  session.placeEditor?.()
  refreshSelection(reader)
  host.changed()
  return true
}


// MARK: - The tool

/** Picking a drawing tool lets go of what was chosen and closes the words
 *  being typed. Coming back to Select does neither. Every change of tool
 *  goes through `setSketchTool`, so the rack's group buttons show the tool
 *  last reached for — the keys and the surface used to set it past that. */
export function setTool(reader: Reader, host: SketchInputHost, tool: SketchTool) {
  setSketchTool(tool)
  toolChanged(reader)
  host.changed()
}

export function toolChanged(reader: Reader) {
  const tool = store.sketch.tool
  if (tool === session.lastTool) return
  session.lastTool = tool
  if (tool === 'select') return
  session.endTextEditing?.()
  if (selection()) {
    store.sketch.selection = null
    session.entered = null
    sketchSelectionChanged()
    reader.redrawOverlays()
  }
}

let watching = false

/** The tool, watched once for the window: whichever reader's editor is in
 *  use hears that it changed. */
export function watchTool() {
  if (watching) return
  watching = true
  subscribe((keys) => {
    if (!keys.has('sketch')) return
    const owner = sketchEditor.current ? editorOwners.get(sketchEditor.current) : undefined
    if (owner) toolChanged(owner.reader)
  })
}
