/**
 * The drawing layer's input, as the rest of the window sees it.
 *
 * The work is in `sketch/`: the gestures on one page's surface
 * (`gestures.ts`), what the panel and the keys ask of the editor
 * (`commands.ts`), the card being typed into (`textEditor.ts`), and what is
 * kept between gestures — the selection's helpers and the one way a change
 * is written (`session.ts`). The geometry is pure, in
 * `shared/sketchGeometry.ts`. Every change to a page goes through
 * `SketchTree.normalized`, so the sidecar written here is the one the Mac
 * would have written.
 */
export { attachSketchInput, hitsDrawing, type SketchInput } from './sketch/gestures.js'
export { sketchEditingFor, type SketchInputEditing } from './sketch/commands.js'
export { endTextEditing } from './sketch/textEditor.js'
export { isEditingSketchText, resetSketchInput, undoStack, type SketchInputHost } from './sketch/session.js'
