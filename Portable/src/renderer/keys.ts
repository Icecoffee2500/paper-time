/**
 * The window's keys.
 *
 * In order: the page's own drawing editor, while the pen is out — it has the
 * Mac's whole key map and goes first; then Escape's steps back; then nothing
 * at all while somebody is typing; then the command keys, the page turns,
 * and the drawing tools. Menu items reach `commands.ts` from the main
 * process; these catch the keys a desktop hands the page first.
 */
import { isCommand } from './bridge.js'
import { on } from './dom.js'
import { changed, readerState, setSketchTool, store, type SketchTool } from './state.js'
import { findBar, focused, readers } from './pageArea.js'
import { closeWindowOrPane, showOpenPapersPopup } from './actions/openPapers.js'
import { closeOpenPapers, isOpenPapersShowing } from './ui/openPapers.js'
import { closePalette, isPaletteOpen } from './ui/search.js'
import { TOOLS } from './ui/sketchToolbar.js'
import { undoStack, type SketchInputEditing } from './ui/sketchInput.js'
import { sketchEditor } from './ui/sketchEditing.js'
import { expandedIDs } from '../shared/sketch.js'

export function pickTool(tool: SketchTool) {
  setSketchTool(tool)
  changed('sketch')
}

/** Undo or redo one step, into the paper the step was taken in. */
export function applyUndo(redo: boolean) {
  const snapshot = redo ? undoStack.redo() : undoStack.undo()
  if (!snapshot) return
  // Into the paper the step was taken in, or nowhere. Put into whichever
  // paper happened to be in front, an undo wrote one paper's page over
  // another's.
  const target = snapshot.paperID ? readers.get(snapshot.paperID) ?? null : focused()
  if (!target) return
  // A step may cover two pages — a selection carried from one to the other.
  target.restore(snapshot)
  store.sketch.selection = null
  changed('sketch')
}

function selectedPage() {
  const selection = store.sketch.selection
  if (!selection) return null
  return focused()?.pages[selection.pageIndex] ?? null
}

function nudge(key: string, distance: number) {
  const page = selectedPage()
  const selection = store.sketch.selection
  const reader = focused()
  if (!page || !selection || !reader) return
  const offset = {
    ArrowLeft: { x: -distance, y: 0 },
    ArrowRight: { x: distance, y: 0 },
    // The page's y goes up, so up on the keyboard is up on the page.
    ArrowUp: { x: 0, y: distance },
    ArrowDown: { x: 0, y: -distance },
  }[key]
  if (!offset) return
  const moving = expandedIDs(page.elements, selection.ids)
  page.elements = page.elements.map((element) =>
    moving.has(element.id) ? element.translated(offset) : element)
  page.redraw()
  void reader.save(page)
}

/** Whether a key is going into a field — a note, a title, a search. */
function isTyping(target: EventTarget | null): boolean {
  const node = target as HTMLElement | null
  return Boolean(node && (node.tagName === 'INPUT' || node.tagName === 'TEXTAREA' || node.isContentEditable))
}

export function installKeys() {
  // Every undo step remembers the paper it was taken in (`applyUndo`).
  undoStack.paperOf = () => store.selectedID

  on(window, 'keydown', (event: KeyboardEvent) => {
    const typing = isTyping(event.target)
    const reader = focused()
    const drawing = readerState().drawing

    // While the pen is out the page's own editor has the Mac's whole key map
    // — Escape's three steps, the arrows, ⌘C/⌘X/⌘V, Enter into a group — and
    // it goes first. What it does not take falls through to the keys below.
    if (drawing && !isPaletteOpen()) {
      const current = sketchEditor.current as SketchInputEditing | null
      if (current && typeof current.handleKey === 'function' && !(typing && event.key !== 'Escape') && current.handleKey(event)) {
        event.preventDefault()
        return
      }
    }

    // A field answers its own keys. Escape in a note used to fall through
    // to the steps below and put the pen away; the palette and the find bar
    // close themselves on their own Escape.
    if (typing) return

    if (event.key === 'Escape') {
      // Three steps back, in the order a hand expects: finish the words, then
      // drop the selection, then put the tool away.
      if (isPaletteOpen()) return closePalette()
      if (findBar.isOpen) return findBar.close()
      if (isOpenPapersShowing()) return closeOpenPapers()
      if (reader?.markBarShowing) return reader.hideMarkBar()
      if (store.sketch.selection) {
        store.sketch.selection = null
        reader?.redrawAll()
        return changed('sketch')
      }
      if (store.sketch.tool !== 'select') return pickTool('select')
      if (drawing && reader) {
        reader.setDrawing(false)
        reader.update()
        return changed('sketch')
      }
      return
    }

    const editor = sketchEditor.current

    if (isCommand(event)) {
      const key = event.key.toLowerCase()
      // ⇧⌘O: the open papers, over the page. ⌘W: the pane in focus, or the
      // window. Both are menu items too; these catch the key where a desktop
      // hands it to the page first.
      if (event.shiftKey && key === 'o') {
        event.preventDefault()
        showOpenPapersPopup()
        return
      }
      if (key === 'w' && !event.shiftKey && !event.altKey) {
        event.preventDefault()
        closeWindowOrPane()
        return
      }
      // `Z` with Shift held: `event.key` is the capital, and ⇧⌘Z never matched.
      if (key === 'z') {
        event.preventDefault()
        applyUndo(event.shiftKey)
        return
      }
      if (!drawing) return
      // Figma's keys for the tree, on the selection the page holds.
      if (key === 'g') {
        event.preventDefault()
        if (event.altKey) editor?.frameSelection()
        else if (event.shiftKey) editor?.ungroupSelection()
        else editor?.groupSelection()
        return
      }
      if (key === 'd') {
        event.preventDefault()
        editor?.duplicateSelection()
        return
      }
      if (key === 'a') {
        event.preventDefault()
        editor?.selectAllOnPage()
        return
      }
      if (event.shiftKey && (event.code === 'BracketRight' || event.key === ']' || event.key === '}')) {
        event.preventDefault()
        editor?.bringSelectionToFront()
        return
      }
      if (event.shiftKey && (event.code === 'BracketLeft' || event.key === '[' || event.key === '{')) {
        event.preventDefault()
        editor?.sendSelectionToBack()
        return
      }
      return
    }

    if (event.key === 'Delete' || event.key === 'Backspace') {
      if (store.sketch.selection) {
        event.preventDefault()
        editor?.deleteSelection()
      }
      return
    }

    // Turned rather than scrolled — one page, or a book's spread — the arrows
    // and Page Up/Down turn.
    if (store.settings.pageLayout !== 'continuous' && !drawing && reader) {
      if (event.key === 'PageDown' || event.key === 'ArrowRight') {
        event.preventDefault()
        return reader.turnPage(1)
      }
      if (event.key === 'PageUp' || event.key === 'ArrowLeft') {
        event.preventDefault()
        return reader.turnPage(-1)
      }
    }

    if (drawing) {
      if (event.altKey) return
      // ⇧A is auto layout before A is the arrow tool.
      if (event.shiftKey && event.key === 'A') {
        event.preventDefault()
        editor?.toggleAutoLayout()
        return
      }
      if (event.shiftKey) return
      const tool = TOOLS.find((entry) => entry.key.toLowerCase() === event.key.toLowerCase())
      if (tool) {
        event.preventDefault()
        return pickTool(tool.tool)
      }
      if (event.key.toLowerCase() === 'b') {
        event.preventDefault()
        editor?.frameSelection()
        return
      }
      if (event.key === 'Enter' && store.sketch.selection) {
        event.preventDefault()
        editor?.editSelectedText()
        return
      }
      if (event.key.startsWith('Arrow') && store.sketch.selection) {
        event.preventDefault()
        nudge(event.key, event.shiftKey ? 10 : 1)
      }
    }
  })
}
