/**
 * What the drawing controls act on — the contract between the view over the
 * page that holds the selection (`sketchInput.ts`) and the panel and rack
 * that change it (`sketchInspector.ts`, `sketchToolbar.ts`). The Mac's
 * `SketchEditing` protocol, in TypeScript.
 *
 * Everything is in PDF page coordinates, y up. `top` in `setSelectionOrigin`
 * is measured down from the top of the page, as a design tool counts it.
 */
import type { SketchElement, SketchLayout, SketchStyle, Rect } from '../../shared/sketch.js'

export type SketchAlignment = 'left' | 'centerX' | 'right' | 'top' | 'centerY' | 'bottom'

export interface SketchEditing {
  /** The outermost selected elements — a group, not what is in it — as copies. */
  selectedElements(): SketchElement[]
  /** How many pen strokes are selected alongside them. */
  selectedStrokeCount(): number
  /** The box round everything selected, or null. */
  selectionBox(): Rect | null
  /** The page the selection is on, in its own coordinates. */
  pageBox(): Rect | null
  /** Changes the style of everything selected, as one undo step. Also the default for the next shape. */
  applyStyle(change: (style: SketchStyle) => void): void
  /** Changes the selected elements themselves — name, layout, clips, textSizing — as one undo step. */
  editSelection(change: (element: SketchElement) => void): void
  deleteSelection(): void
  duplicateSelection(): void
  frameSelection(): void
  groupSelection(): void
  ungroupSelection(): void
  toggleAutoLayout(): void
  bringSelectionToFront(): void
  sendSelectionToBack(): void
  selectAllOnPage(): void
  editSelectedText(): void
  align(alignment: SketchAlignment): void
  setSelectionOrigin(x: number | null, top: number | null): void
  setSelectionSize(width: number | null, height: number | null): void
}

/** The default a new frame's layout starts from — `SketchLayout()` on the Mac. */
export const defaultLayout = (): SketchLayout => ({ direction: 'vertical', gap: 8, padding: 8, align: 'start', hugs: true })

/**
 * The one editor at a time, set by the page's input view when the pen is out
 * (and, with several panes, by the pane last clicked in), read by the panel.
 */
export const sketchEditor: { current: SketchEditing | null; listeners: Set<() => void> } = {
  current: null,
  listeners: new Set(),
}

/** Tells the panel the selection or its elements changed. */
export function sketchSelectionChanged() {
  for (const listener of sketchEditor.listeners) listener()
}
