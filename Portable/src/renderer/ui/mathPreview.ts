/**
 * The formula being typed, set as it will read, in a small card under it —
 * `MathPreviewCard.swift`, as a CodeMirror extension of the note editor.
 *
 * The line under the caret is shown as written, so a formula being typed is
 * a string of backslashes and braces. While the caret is inside `$…$` or a
 * `$$` block this shows it set by the same MathJax the rest of the note uses,
 * a keystroke behind the fingers, and takes itself away when the caret
 * leaves the formula or the note loses focus. It never takes a key: the card
 * is `pointer-events: none`, so Tab still goes to the next placeholder.
 *
 * A half-typed formula does not set. Rather than an error, the card keeps
 * the last formula that did, dimmed; before anything has set it shows the
 * words as they are, in the secondary colour.
 */
import type { Extension } from '@codemirror/state'
import { EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view'
import { mathSpanAt, type MathSpan } from '../../shared/noteMath.js'
import { typeset } from '../sketchMath.js'


/** The editor has the caret — not whether the window is in front, which a
 *  card under the caret does not care about (and a hidden probe never is). */
function holdsCaret(view: EditorView): boolean {
  return view.root.activeElement === view.contentDOM
}

const DEBOUNCE_MS = 80

export function mathPreview(): { extension: Extension; report: () => string } {
  let card: HTMLDivElement | null = null
  let timer: ReturnType<typeof setTimeout> | null = null
  let lastGood: string | null = null
  let shown: { span: MathSpan; face: 'set' | 'stale' | 'raw' } | null = null

  const hide = () => {
    if (timer) clearTimeout(timer)
    timer = null
    shown = null
    card?.remove()
    card = null
  }

  const show = (view: EditorView) => {
    timer = null
    const range = view.state.selection.main
    if (!holdsCaret(view) || !range.empty) return hide()
    const span = mathSpanAt(view.state.doc.toString(), range.head)
    if (!span) return hide()
    let face: 'set' | 'stale' | 'raw'
    let markup: string | null = typeset(span.latex, span.display)
    if (markup) {
      lastGood = markup
      face = 'set'
    } else if (lastGood) {
      markup = lastGood
      face = 'stale'
    } else {
      face = 'raw'
    }
    const start = view.coordsAtPos(span.range.from)
    const end = view.coordsAtPos(Math.max(span.range.from, span.range.to - 1))
    if (!start || !end) return hide()
    if (!card) {
      card = document.createElement('div')
      card.className = 'math-preview'
      card.setAttribute('aria-hidden', 'true')
      document.body.append(card)
    }
    card.classList.toggle('stale', face === 'stale')
    card.classList.toggle('raw', face === 'raw')
    if (face === 'raw') card.textContent = span.latex
    else card.innerHTML = markup ?? ''
    const box = view.dom.getBoundingClientRect()
    card.style.maxWidth = `${Math.max(120, Math.min(480, box.width - 16))}px`
    const width = card.offsetWidth
    const height = card.offsetHeight
    let top = end.bottom + 4
    if (top + height > Math.min(box.bottom, window.innerHeight)) top = end.top - height - 4
    const left = Math.min(Math.max(start.left, box.left), Math.max(box.left, box.right - width - 8))
    card.style.left = `${left}px`
    card.style.top = `${Math.max(box.top, top)}px`
    shown = { span, face }
  }

  const plugin = ViewPlugin.fromClass(class {
    update(update: ViewUpdate) {
      if (!update.docChanged && !update.selectionSet && !update.focusChanged && !update.geometryChanged) return
      if (timer) clearTimeout(timer)
      const view = update.view
      timer = setTimeout(() => show(view), DEBOUNCE_MS)
    }
    destroy() { hide() }
  })

  return {
    extension: [plugin, EditorView.domEventHandlers({ blur: () => { hide() } })],
    report: () => (shown && card
      ? JSON.stringify({ face: shown.face, from: shown.span.range.from, to: shown.span.range.to, display: shown.span.display, left: card.style.left, top: card.style.top })
      : 'none'),
  }
}
