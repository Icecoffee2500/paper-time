/**
 * Which note the format panel is about — the Mac's `NoteFormatCenter`.
 *
 * The panel is in the inspector and the note is somewhere else in the
 * window, so something has to say which note has the caret and what its
 * selection is set in. A note that takes the caret takes the panel; the pen
 * picked up takes it back for the drawing's tools. The note keeps the panel
 * while a press is on the panel itself: its selection is in the editor's
 * state, not in the focus.
 */
import type { FormatCommand, PanelState } from './noteEditor.js'

/** What the centre needs of a note's editor. */
export interface Formattable {
  format(command: FormatCommand): void
  formatState(): PanelState
  focus?: () => void
}

let front: Formattable | null = null
let isFront = false
let scheduled = false
const listeners = new Set<() => void>()
/** How the panel is brought into view: set by the window (`index.ts`). */
let door: ((anchor: HTMLElement) => void) | null = null

function changed() {
  if (scheduled) return
  scheduled = true
  // Once a frame: a drag across a line changes the selection at every character.
  requestAnimationFrame(() => {
    scheduled = false
    for (const listener of listeners) listener()
  })
}

export const formatCenter = {
  /** A note has the caret: the panel is about it. */
  took(editor: Formattable) {
    if (front === editor && isFront) return
    front = editor
    isFront = true
    changed()
  },
  /** The pen is in hand: the Tools tab is the drawing's again. */
  yielded() {
    if (!isFront) return
    isFront = false
    changed()
  },
  /** The note is gone. */
  left(editor: Formattable) {
    if (front !== editor) return
    front = null
    isFront = false
    changed()
  },
  /** The note's selection or its words changed. */
  read(editor: Formattable) {
    if (front === editor) changed()
  },
  isFront: () => isFront && front !== null,
  state: (): PanelState | null => front?.formatState() ?? null,
  apply(command: FormatCommand) {
    front?.format(command)
    changed()
  },
  askForPanel(anchor: HTMLElement) {
    door?.(anchor)
  },
  setDoor(next: (anchor: HTMLElement) => void) {
    door = next
  },
  subscribe(listener: () => void): () => void {
    listeners.add(listener)
    return () => listeners.delete(listener)
  },
}
