/**
 * Typing into a card on the page.
 *
 * Figma's way: no field. The words appear in their own face, size and
 * colour on the page itself, with a caret; the card behind them is drawn by
 * the canvas underneath, so what is seen while typing is what will be there
 * when the typing stops. One card at a time, in the whole window.
 */
import { el, on } from '../../dom.js'
import { store } from '../../state.js'
import { SketchElement, rectInset, rectMaxY } from '../../../shared/sketch.js'
import { SketchTree, pruned, sameElements } from '../../../shared/sketchTree.js'
import { fittedRect, fontSpec, textLineHeight, TEXT_PADDING } from '../../../shared/sketchRender.js'
import type { PageView, Reader } from '../reader.js'
import { snapshot } from '../sketchUndo.js'
import { attachLatexSuite } from '../latexSuiteInput.js'
import { sketchSelectionChanged } from '../sketchEditing.js'
import { session, undoStack, type SketchInputHost } from './session.js'


export function beginTextEditing(reader: Reader, host: SketchInputHost, page: PageView, element: SketchElement, isNew: boolean, before?: SketchElement[]) {
  if (session.editing) endTextEditing()
  const size = page.viewport?.scale ?? 1
  const area = el('textarea', { class: 'sketch-text-editor', spellcheck: 'false' }) as HTMLTextAreaElement
  area.value = element.text
  // Figma's way: no field. The words appear in their own face, size and
  // colour on the page itself, with a caret; the card behind them is drawn
  // by the canvas underneath, so what is seen while typing is what will be
  // there when the typing stops.
  area.style.background = 'transparent'
  area.style.outline = 'none'
  area.style.border = '0'
  area.style.borderRadius = '0'
  area.style.boxShadow = 'none'
  area.style.overflow = 'hidden'
  area.style.whiteSpace = element.kind === 'text' && element.sizing === 'autoWidth' ? 'pre' : 'pre-wrap'
  area.style.font = fontSpec(element.style.points * size, element.style.fontName)
  area.style.lineHeight = `${textLineHeight(element.style.points, element.style.fontName) * size}px`
  area.style.color = element.style.stroke.css
  area.style.caretColor = element.style.stroke.css
  area.style.textAlign = element.kind === 'text' ? element.style.textAlign : 'center'
  area.style.padding = element.kind === 'text' ? `${TEXT_PADDING * size}px` : '0'
  area.style.boxSizing = 'border-box'
  page.root.append(area)
  session.editing = { page, id: element.id, area, before: before ?? page.elements, isNew, host, reader }
  placeEditor()
  page.hidden.add(element.id)
  page.redraw()
  area.focus()
  area.select()

  on(area, 'input', () => editorTextChanged(reader, host))
  on(area, 'keydown', (event: KeyboardEvent) => {
    event.stopPropagation()
    if (event.key === 'Escape' || (event.key === 'Enter' && (event.metaKey || event.ctrlKey))) {
      event.preventDefault()
      endTextEditing()
    }
    // Enter makes a new line; the card is finished by clicking away, by
    // Escape or by ⌘Return, so a note can be more than one line.
  })
  on(area, 'blur', (event: FocusEvent) => {
    // A press on the Tools tab or the rack while typing is a change to the
    // card being typed, not the end of typing: the words stay open and the
    // change lands on them. It used to end the card first, so the size or
    // the colour chosen went to a card nobody was typing in any more.
    const to = event.relatedTarget as Element | null
    if (to?.closest('.sketch-inspector, .sketch-rack')) return
    // A blur while the words are still being placed is not the end.
    if (session.editing?.area === area) endTextEditing()
  })
  // After the card's own listeners, so the card has moved to fit the words
  // before the placeholders are drawn over them.
  session.latexField = attachLatexSuite(area)
  sketchSelectionChanged()
}

/** The editor over the card, where the card is and looking as it looks —
 *  asked again whenever the card changes, a style from the panel included. */
export function placeEditor() {
  if (!session.editing) return
  const { page, id, area } = session.editing
  const element = page.elements.find((entry) => entry.id === id)
  if (!element) return
  const size = page.viewport?.scale ?? 1
  area.style.font = fontSpec(element.style.points * size, element.style.fontName)
  area.style.lineHeight = `${textLineHeight(element.style.points, element.style.fontName) * size}px`
  area.style.color = element.style.stroke.css
  area.style.caretColor = element.style.stroke.css
  area.style.textAlign = element.kind === 'text' ? element.style.textAlign : 'center'
  const box = element.kind !== 'text' ? rectInset(element.rect, TEXT_PADDING, TEXT_PADDING) : element.rect
  const topLeft = page.toView(box.x, rectMaxY(box))
  area.style.left = `${topLeft.x}px`
  area.style.top = `${topLeft.y}px`
  area.style.width = `${Math.max(box.width * size, 24)}px`
  area.style.height = `${Math.max(box.height * size, 12)}px`
  if (element.kind !== 'text') {
    // Words in a box sit in its middle, as the canvas draws them.
    const lines = Math.max(1, area.value.split('\n').length)
    const lineHeight = textLineHeight(element.style.points, element.style.fontName) * size
    area.style.paddingTop = `${Math.max(0, (box.height * size - lines * lineHeight) / 2)}px`
  }
}

/** The words change and the card follows them, live — and the frame round
 *  it, when it has a layout, moves its neighbours to make room. */
function editorTextChanged(reader: Reader, host: SketchInputHost) {
  if (!session.editing) return
  const { page, id, area } = session.editing
  const i = page.elements.findIndex((entry) => entry.id === id)
  if (i === -1) return
  const changed = page.elements[i].copy()
  changed.text = area.value
  if (changed.kind === 'text') changed.setRect(fittedRect(changed))
  const next = [...page.elements]
  next[i] = changed
  page.elements = SketchTree.normalized(next)
  placeEditor()
  page.redraw()
  void reader
  void host
}

/** Whether the words being typed are on this page — for an undo, which
 *  ends them first. */
export function editingOn(page: PageView): boolean {
  return session.editing?.page === page
}

/** Ends the typing: the words go into the element, an empty card is thrown
 *  away, and the whole thing is one step to undo. */
export function endTextEditing() {
  if (!session.editing) return
  const { page, id, area, before, host } = session.editing
  session.editing = null
  const text = area.value.trim()
  let elements = [...page.elements]
  const i = elements.findIndex((entry) => entry.id === id)
  if (i !== -1) {
    const changed = elements[i].copy()
    changed.text = text
    if (changed.kind === 'text') {
      if (text.length === 0) elements.splice(i, 1)
      else {
        changed.setRect(fittedRect(changed))
        elements[i] = changed
      }
    } else {
      elements[i] = changed
    }
  }
  session.latexField?.detach()
  session.latexField = null
  area.remove()
  page.hidden.delete(id)
  const after = SketchTree.normalized(pruned(elements))
  page.elements = after
  if (!sameElements(after, before)) {
    undoStack.record(snapshot(page.index, before, page.strokes), snapshot(page.index, after, page.strokes))
    host.save(page)
  }
  if (!after.some((entry) => entry.id === id)) {
    store.sketch.selection = null
    session.entered = null
  }
  page.redraw()
  sketchSelectionChanged()
  host.changed()
}

session.endTextEditing = endTextEditing
session.placeEditor = placeEditor
