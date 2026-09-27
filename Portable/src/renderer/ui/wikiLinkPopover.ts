/**
 * The notes a `[[` could link to, in a small card under the caret — the
 * Mac's `WikiLinkPopover`, as a CodeMirror extension of the note editor.
 *
 * Without it, linking one note to another meant knowing a twelve-digit
 * identifier. Typing `[[` and a word of the title is how the Mac does it:
 * eight at most, the note being written left out, ↑↓ to move, Return or Tab
 * to take one, Escape to put the card away, a click to take the one under
 * the pointer. What goes in is `[[id|title]]` — the file keeps the
 * identifier, which does not change when a title does — and a `]]` already
 * after the caret is taken over rather than doubled.
 */
import { Prec, type Extension } from '@codemirror/state'
import { EditorView, ViewPlugin, keymap, type ViewUpdate } from '@codemirror/view'
import { el, on } from '../dom.js'
import { acceptWikiLink, openWikiLink } from '../../shared/noteBlocks.js'
import { noteSuggestions } from '../notesModel.js'
import { zettelDisplayTitle } from '../../shared/zettel.js'

export interface WikiLinkReport { showing: boolean; rows: string[]; selected: number }


/** The editor has the caret — not whether the window is in front, which a
 *  card under the caret does not care about (and a hidden probe never is). */
function holdsCaret(view: EditorView): boolean {
  return view.root.activeElement === view.contentDOM
}

const ROW = 44
const WIDTH = 320

export function wikiLinkCompletion(noteID: string): { extension: Extension; report: () => WikiLinkReport } {
  let card: HTMLElement | null = null
  let matches: { id: string; title: string }[] = []
  let selection = 0
  let current: EditorView | null = null

  const hide = () => {
    card?.remove()
    card = null
    matches = []
    selection = 0
  }

  const choose = (view: EditorView, index: number) => {
    const match = matches[index]
    if (!match) return
    const caret = view.state.selection.main.head
    const edit = acceptWikiLink(view.state.doc.toString(), caret, match.id, match.title)
    hide()
    if (!edit) return
    view.dispatch({ changes: { from: edit.from, to: edit.to, insert: edit.insert }, selection: { anchor: edit.caret }, userEvent: 'input.complete' })
    view.focus()
  }

  const draw = (view: EditorView) => {
    if (!card) {
      card = el('div', { class: 'wiki-popover', role: 'listbox' })
      // A press on the card would take the focus from the note first.
      on(card, 'mousedown', (event: MouseEvent) => event.preventDefault())
      document.body.append(card)
    }
    card.replaceChildren(...matches.map((match, index) => {
      const row = el('div', { class: 'wiki-popover-row', role: 'option', 'aria-selected': String(index === selection) }, [
        el('span', { class: 'wiki-popover-title', text: match.title }),
        el('span', { class: 'wiki-popover-id', text: match.id }),
      ])
      on(row, 'click', () => choose(view, index))
      return row
    }))
    const height = Math.min(matches.length * ROW + 12, 232)
    const caret = view.coordsAtPos(view.state.selection.main.head)
    if (!caret) return hide()
    let top = caret.bottom + 6
    if (top + height > window.innerHeight - 20) top = caret.top - height - 6
    const left = Math.max(8, Math.min(caret.left, window.innerWidth - WIDTH - 8))
    Object.assign(card.style, { left: `${left}px`, top: `${Math.max(8, top)}px`, width: `${WIDTH}px`, maxHeight: `${height}px` })
    card.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' })
  }

  const refresh = (view: EditorView) => {
    const range = view.state.selection.main
    if (!holdsCaret(view) || !range.empty || view.state.selection.ranges.length > 1) return hide()
    const open = openWikiLink(view.state.doc.toString(), range.head)
    if (!open) return hide()
    matches = noteSuggestions(open.query, noteID).map((note) => ({ id: note.id, title: zettelDisplayTitle(note) }))
    if (matches.length === 0) return hide()
    if (selection >= matches.length) selection = 0
    draw(view)
  }

  const plugin = ViewPlugin.fromClass(class {
    constructor(view: EditorView) { current = view }
    update(update: ViewUpdate) {
      if (update.docChanged || update.selectionSet || update.focusChanged) {
        // Measured after the editor has drawn, so the caret has its place.
        const view = update.view
        requestAnimationFrame(() => refresh(view))
      }
    }
    destroy() {
      hide()
      current = null
    }
  })

  const whenShowing = (run: (view: EditorView) => void) => (view: EditorView) => {
    if (!card) return false
    run(view)
    return true
  }

  const keys = Prec.highest(keymap.of([
    { key: 'ArrowDown', run: whenShowing((view) => { selection = (selection + 1) % matches.length; draw(view) }) },
    { key: 'ArrowUp', run: whenShowing((view) => { selection = (selection - 1 + matches.length) % matches.length; draw(view) }) },
    { key: 'Enter', run: whenShowing((view) => choose(view, selection)) },
    { key: 'Tab', run: whenShowing((view) => choose(view, selection)) },
    { key: 'Escape', run: whenShowing(() => hide()) },
  ]))

  return {
    extension: [plugin, keys, EditorView.domEventHandlers({ blur: () => { hide() }, scroll: () => { hide() } })],
    report: () => ({ showing: card !== null && current !== null, rows: matches.map((match) => match.title), selected: selection }),
  }
}
