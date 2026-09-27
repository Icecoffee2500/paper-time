/**
 * The notes a `[[` could link to, in a small card under the caret — the
 * Mac's `WikiLinkPopover`.
 *
 * Without it, linking one note to another meant knowing a twelve-digit
 * identifier, and the only way to learn one was the ⋯ menu's «Copy
 * Identifier». Typing `[[` and a word of the title is how the Mac does it:
 * eight at most, the note being written left out, ↑↓ to move, Return or Tab
 * to take one, Escape to put the card away, a click to take the one under
 * the pointer. What goes in is `[[id|title]]` — the file keeps the
 * identifier, which does not change when a title does — and a `]]` already
 * after the caret is taken over rather than doubled.
 */
import { el, on } from '../dom.js'
import { acceptWikiLink, openWikiLink, type LineEdit } from '../../shared/noteBlocks.js'
import { noteSuggestions } from '../notesModel.js'
import { zettelDisplayTitle } from '../../shared/zettel.js'

/** The textarea's styles a measuring mirror has to share to wrap like it. */
const MIRRORED = [
  'fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'lineHeight', 'letterSpacing', 'wordSpacing',
  'whiteSpace', 'wordBreak', 'overflowWrap', 'tabSize', 'boxSizing',
  'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
  'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth',
] as const

/** Where a character offset of a textarea is in the window. */
export function caretPoint(area: HTMLTextAreaElement, offset: number): { left: number; top: number; bottom: number } {
  const box = area.getBoundingClientRect()
  const style = getComputedStyle(area)
  const mirror = document.createElement('div')
  for (const key of MIRRORED) mirror.style[key] = style[key]
  Object.assign(mirror.style, {
    position: 'fixed', visibility: 'hidden', left: `${box.left}px`, top: `${box.top}px`,
    width: `${box.width}px`, whiteSpace: 'pre-wrap', overflowWrap: 'break-word',
  })
  const marker = document.createElement('span')
  marker.textContent = '​'
  mirror.append(area.value.slice(0, offset), marker, area.value.slice(offset) + '​')
  document.body.append(mirror)
  const lineHeight = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.4
  const left = box.left + marker.offsetLeft
  const top = box.top + marker.offsetTop - area.scrollTop
  mirror.remove()
  return { left, top, bottom: top + lineHeight }
}

export interface WikiLinkPopover {
  /** Asks again after the caret or the text moved. */
  update(): void
  hide(): void
  readonly isShowing: boolean
  /** What the card shows, for a probe. */
  report(): { showing: boolean; rows: string[]; selected: number }
  detach(): void
}

const ROW = 44
const WIDTH = 320

export function attachWikiLinkPopover(
  area: HTMLTextAreaElement,
  noteID: string,
  apply: (edit: LineEdit) => void,
): WikiLinkPopover {
  let card: HTMLElement | null = null
  let matches: { id: string; title: string }[] = []
  let selection = 0

  const hide = () => {
    card?.remove()
    card = null
    matches = []
    selection = 0
  }

  const choose = (index: number) => {
    const match = matches[index]
    if (!match) return
    const edit = acceptWikiLink(area.value, area.selectionStart, match.id, match.title)
    hide()
    if (edit) apply(edit)
  }

  const draw = () => {
    if (!card) {
      card = el('div', { class: 'wiki-popover', role: 'listbox' })
      // A press on the card would take the focus from the note first, and
      // the note would forget where the link was being typed.
      on(card, 'mousedown', (event: MouseEvent) => event.preventDefault())
      document.body.append(card)
    }
    card.replaceChildren(...matches.map((match, index) => {
      const row = el('div', { class: 'wiki-popover-row', role: 'option', 'aria-selected': String(index === selection) }, [
        el('span', { class: 'wiki-popover-title', text: match.title }),
        el('span', { class: 'wiki-popover-id', text: match.id }),
      ])
      on(row, 'click', () => choose(index))
      return row
    }))
    const height = Math.min(matches.length * ROW + 12, 232)
    const caret = caretPoint(area, area.selectionStart)
    let top = caret.bottom + 6
    if (top + height > window.innerHeight - 20) top = caret.top - height - 6
    const left = Math.max(8, Math.min(caret.left, window.innerWidth - WIDTH - 8))
    Object.assign(card.style, { left: `${left}px`, top: `${Math.max(8, top)}px`, width: `${WIDTH}px`, maxHeight: `${height}px` })
    card.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' })
  }

  const update = () => {
    if (document.activeElement !== area || area.selectionStart !== area.selectionEnd) return hide()
    const open = openWikiLink(area.value, area.selectionStart)
    if (!open) return hide()
    matches = noteSuggestions(open.query, noteID).map((note) => ({ id: note.id, title: zettelDisplayTitle(note) }))
    if (matches.length === 0) return hide()
    if (selection >= matches.length) selection = 0
    draw()
  }

  /** Runs before the field's own keys (Latex Suite's Tab among them). */
  const onKeyDown = (event: KeyboardEvent) => {
    if (!card || event.target !== area || event.isComposing) return
    let handled = true
    if (event.key === 'ArrowDown') selection = (selection + 1) % matches.length
    else if (event.key === 'ArrowUp') selection = (selection - 1 + matches.length) % matches.length
    else if ((event.key === 'Enter' || event.key === 'Tab') && !event.shiftKey) choose(selection)
    else if (event.key === 'Escape') hide()
    else handled = false
    if (!handled) return
    event.preventDefault()
    event.stopPropagation()
    if (card) draw()
  }

  const onSelection = () => {
    if (document.activeElement === area) update()
  }

  const parent = area.parentElement ?? area
  parent.addEventListener('keydown', onKeyDown, true)
  area.addEventListener('input', update)
  area.addEventListener('blur', hide)
  area.addEventListener('scroll', hide)
  document.addEventListener('selectionchange', onSelection)

  return {
    update,
    hide,
    get isShowing() { return card !== null },
    report: () => ({ showing: card !== null, rows: matches.map((match) => match.title), selected: selection }),
    detach() {
      hide()
      parent.removeEventListener('keydown', onKeyDown, true)
      area.removeEventListener('input', update)
      area.removeEventListener('blur', hide)
      area.removeEventListener('scroll', hide)
      document.removeEventListener('selectionchange', onSelection)
    },
  }
}
