/**
 * The window's keys.
 *
 * In order: Escape for what stands over the page; the page's own drawing
 * editor, while the pen is out — it has the Mac's whole key map; then nothing
 * at all while somebody is typing; then the command keys and the page turns. Menu items reach `commands.ts` from the main
 * process; these catch the keys a desktop hands the page first.
 */
import { isCommand, platform } from './bridge.js'
import { eventIs } from '../shared/shortcuts.js'
import { on } from './dom.js'
import { changed, readerState, setSketchTool, store, type SketchTool } from './state.js'
import { findBar, focused, readers } from './pageArea.js'
import { closeWindowOrPane, showOpenPapersPopup } from './actions/openPapers.js'
import { closeOpenPapers, isOpenPapersShowing } from './ui/openPapers.js'
import { closePalette, isPaletteOpen } from './ui/search.js'
import { closeMenu, isMenuOpen } from './ui/menu.js'
import { isSheetKey, isSheetOpen } from './ui/sheet.js'
import { resetSketchInput, undoStack, type SketchInputEditing } from './ui/sketchInput.js'
import { sketchEditor } from './ui/sketchEditing.js'
import { backToNotes } from './ui/slipBox.js'
import { toast } from './ui/toolbar.js'
import { L } from '../shared/lang.js'

export function pickTool(tool: SketchTool) {
  setSketchTool(tool)
  changed('sketch')
}

/** Undo or redo one step, into the paper the step was taken in. A card being
 *  typed into is finished first: its words are the step on top. */
export function applyUndo(redo: boolean) {
  resetSketchInput()
  const snapshot = redo ? undoStack.redo() : undoStack.undo()
  if (!snapshot) return
  // Into the paper the step was taken in, or nowhere. Put into whichever
  // paper happened to be in front, an undo wrote one paper's page over
  // another's.
  const target = snapshot.paperID ? readers.get(snapshot.paperID) ?? null : focused()
  if (!target) return
  // A step may cover two pages — a selection carried from one to the other.
  target.restore(snapshot)
  // A step of the marks leaves the drawing's selection alone; it is not
  // about the drawing at all.
  if (snapshot.marks) {
    if (snapshot.name) toast(redo ? L(`다시 하기: ${snapshot.name}`, `Redo ${snapshot.name}`) : L(`되돌리기: ${snapshot.name}`, `Undo ${snapshot.name}`))
    return
  }
  store.sketch.selection = null
  changed('sketch')
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
    // An open menu has the keyboard; Escape puts it away first of all.
    if (isMenuOpen()) {
      if (event.key === 'Escape') {
        event.preventDefault()
        closeMenu()
      }
      return
    }
    // A sheet over the window is modal: nothing under it hears a key — even
    // the Escape that has just closed it.
    if (isSheetOpen() || isSheetKey(event)) return
    const typing = isTyping(event.target)
    const reader = focused()
    const drawing = readerState().drawing

    // Escape puts away what is over the page before anything on it: the
    // palette, the find bar, the open papers, the bar over a selection. With
    // the pen out it used to drop the drawing's selection first and leave
    // the popup standing.
    if (event.key === 'Escape' && !typing) {
      if (isPaletteOpen()) return closePalette()
      if (findBar.isOpen) return findBar.close()
      if (isOpenPapersShowing()) return closeOpenPapers()
      if (reader?.markBarShowing) return reader.hideMarkBar()
      // The formula lasso: Escape lets go of the catch, and Escape again puts
      // the lasso away (`LassoInputView.keyDown`).
      if (reader?.state.lasso) {
        event.preventDefault()
        if (reader.caught) return reader.dropCatch()
        reader.setLasso(false)
        reader.update()
        changed('sketch')
        return
      }
      // A passage followed out of a note: Escape is the «‹ Notes» above it.
      if (!drawing && store.shelf.kind === 'notes' && backToNotes()) return
    }

    // While the pen is out the page's own editor has the Mac's whole key map
    // — Escape's steps, the tools, the arrows, ⌘C/⌘X/⌘V, ⌘G, Enter into a
    // group (`sketch/commands.ts`, `handleKey`) — and it goes first. There
    // is no second copy of that map here: the one that was here moved
    // shapes past the undo stack.
    if (drawing && !isPaletteOpen()) {
      const current = sketchEditor.current as SketchInputEditing | null
      if (current && typeof current.handleKey === 'function' && !(typing && event.key !== 'Escape') && current.handleKey(event)) {
        event.preventDefault()
        return
      }
    }

    // A field answers its own keys.
    if (typing) return

    if (isCommand(event)) {
      const key = event.key.toLowerCase()
      // ⇧⌘O: the open papers, over the page. ⌘W: the pane in focus, or the
      // window. Both are menu items too; these catch the key where a desktop
      // hands it to the page first.
      if (eventIs('openPapers', event, platform)) {
        event.preventDefault()
        showOpenPapersPopup()
        return
      }
      if (eventIs('closeWindow', event, platform)) {
        event.preventDefault()
        closeWindowOrPane()
        return
      }
      // `Z` with Shift held: `event.key` is the capital, and ⇧⌘Z never matched.
      if (key === 'z') {
        event.preventDefault()
        applyUndo(event.shiftKey)
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
      // The space bar the way every reader has it: forward, and back with Shift.
      if (event.key === ' ') {
        event.preventDefault()
        return reader.turnPage(event.shiftKey ? -1 : 1)
      }
    }
  })
}
