/**
 * Latex Suite in a textarea: the adapter between the browser's own editing
 * and the engine in `shared/latexSuite.ts`.
 *
 * The engine is asked at the moment Latex Suite's keydown handler is asked —
 * before the key goes in. A typed character arrives as `beforeinput`
 * (`insertText`), which is cancelable and carries exactly the character the
 * keyboard made, Option or AltGr included; Tab, Shift-Tab, Enter, Shift-Enter
 * and Backspace are read at `keydown`, because the textarea's own answer to
 * them (move the focus, break the line, delete) happens there. When the engine
 * answers, the key is cancelled and the edit goes in through
 * `execCommand('insertText')`, which is the one way to change a textarea's
 * text that stays on its native undo stack — one Undo brings back `@a` from
 * `\alpha`, the way it does in the plugin.
 *
 * **Input methods are left alone.** Nothing runs while a composition is open,
 * nor for the key that closes one (`keyCode` 229): Korean is typed through a
 * composition, and a snippet that fired on the jamo the IME had not finished
 * would take the syllable apart. Latex Suite suppresses the same keys.
 *
 * **Mirrors.** A textarea has one selection; Latex Suite's placeholders often
 * have two (`\begin{…}` and `\end{…}` from `beg`). The extra ranges are kept
 * here, typed into together with the main one — one character or one
 * Backspace at a time, which is what filling in a placeholder is — and let go
 * the moment anything else happens (a click, a paste, a word deleted).
 *
 * **Showing the placeholders.** A textarea cannot mark part of its text, so a
 * copy of its text lies over it, invisible but for the placeholders — the
 * same layout, the same scroll — as a faint box where a placeholder has text
 * and a dotted mark where Tab will go, as the plugin draws them. The group the
 * caret starts in is not drawn, as in the plugin; the mirrors of the
 * selection are.
 */
import { LatexEngine, Tabstops, type LatexChange, type LatexEdit, type LatexInput, type TextRange } from '../../shared/latexSuite.js'
import { ChangeSet } from '../../shared/latexSuite/changes.js'
import { store } from '../state.js'

let sharedEngine: LatexEngine | null = null

/** One engine for every field: it holds no document state, and building it reads the snippet file. */
function engine(): LatexEngine {
  if (!sharedEngine) sharedEngine = new LatexEngine()
  return sharedEngine
}

/** Whether the reader has Latex Suite on — the settings sheet's «LaTeX 단축 입력». */
export function latexShortcutsEnabled(): boolean {
  return store.settings.latexShortcuts !== false
}

export interface LatexSuiteField {
  /** The placeholders the next key will be read against. */
  readonly tabstops: Tabstops
  /** Every range the field treats as selected, the textarea's own first. */
  readonly ranges: TextRange[]
  /** Stops listening and takes the overlay away. */
  detach(): void
}

/**
 * The change that turned `a` into `b`, placed where typing would have put it:
 * an insertion or deletion inside a run of equal characters could sit
 * anywhere in the run, and the caret says which end it was.
 */
function diff(a: string, b: string, caret: number): LatexChange {
  const min = Math.min(a.length, b.length)
  let from = 0
  while (from < min && a.charCodeAt(from) === b.charCodeAt(from)) from += 1
  let toA = a.length
  let toB = b.length
  while (toA > from && toB > from && a.charCodeAt(toA - 1) === b.charCodeAt(toB - 1)) {
    toA -= 1
    toB -= 1
  }
  if (toA === from) {
    while (from > 0 && toB > caret && a.charCodeAt(from - 1) === b.charCodeAt(toB - 1)) {
      from -= 1
      toA -= 1
      toB -= 1
    }
  } else if (toB === from) {
    while (from > 0 && from > caret && a.charCodeAt(from - 1) === a.charCodeAt(toA - 1)) {
      from -= 1
      toA -= 1
      toB -= 1
    }
  }
  return { from, to: toA, text: b.slice(from, toB) }
}

/** Applies changes against `text` (sorted, apart), right to left. */
function applied(changes: LatexChange[], text: string): string {
  let out = text
  for (const change of [...changes].sort((x, y) => y.from - x.from)) {
    out = out.slice(0, change.from) + change.text + out.slice(change.to)
  }
  return out
}

/** The carets after every range was replaced by what `changes` put there, in document order. */
function caretsAfter(changes: LatexChange[]): TextRange[] {
  let shift = 0
  return [...changes].sort((x, y) => x.from - y.from).map((change) => {
    const p = change.from + shift + change.text.length
    shift += change.text.length - (change.to - change.from)
    return { from: p, to: p }
  })
}

const COPIED_STYLE = [
  'fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'fontVariant', 'fontStretch', 'fontFeatureSettings',
  'fontVariationSettings', 'lineHeight', 'letterSpacing', 'wordSpacing', 'textTransform', 'textIndent', 'textAlign',
  'whiteSpace', 'wordBreak', 'overflowWrap', 'tabSize', 'direction', 'boxSizing',
  'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
  'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth',
] as const

export function attachLatexSuite(area: HTMLTextAreaElement, enabled: () => boolean = latexShortcutsEnabled): LatexSuiteField {
  let tabstops = Tabstops.none
  let ranges: TextRange[] = [{ from: area.selectionStart, to: area.selectionEnd }]
  let lastValue = area.value
  let applying = false
  let composing = false
  /** What the last keydown said about the character that follows it. */
  let keyFromIME = false
  let keyWithCommand = false
  let overlay: HTMLDivElement | null = null
  /**
   * The text before each step this field put on the undo stack, and where the
   * caret was in it. The textarea's own Undo selects what it puts back — after
   * `@a` became `\alpha` it selects the `@`, and the next key would type over
   * it — where Latex Suite puts the caret back where it was. So an Undo that
   * lands on one of these texts puts the caret there.
   */
  const undoMarks: { value: string; caret: TextRange }[] = []
  const remember = (caret: TextRange) => {
    undoMarks.push({ value: lastValue, caret: { from: caret.from, to: caret.to } })
    if (undoMarks.length > 64) undoMarks.shift()
  }

  const textareaRange = (): TextRange => ({ from: area.selectionStart, to: area.selectionEnd })

  /**
   * Brings the placeholders up to date with whatever the textarea did on its
   * own — typing the engine let through, a click, an arrow, a paste — the
   * way Latex Suite maps its tabstops through every transaction.
   */
  const sync = () => {
    const value = area.value
    const selection = textareaRange()
    if (value !== lastValue) {
      const change = diff(lastValue, value, selection.to)
      ranges = [selection]
      tabstops = tabstops.afterEdit([change], ranges)
      lastValue = value
    } else if (selection.from !== ranges[0].from || selection.to !== ranges[0].to) {
      ranges = [selection]
      tabstops = tabstops.selecting(ranges)
    }
    draw()
  }

  /**
   * Replaces `from..<to` with `text` as one step on the textarea's undo stack.
   * `execCommand` is deprecated in name only — it is still the one path that
   * keeps the native undo stack — and where it refuses, the text goes in
   * anyway, and the field hears about it the way it hears about typing.
   */
  const replace = (from: number, to: number, text: string) => {
    const expected = applied([{ from, to, text }], lastValue)
    area.setSelectionRange(from, to)
    // The command types into whatever has the focus, which is this field
    // whenever one of its own keys got here — but never type into another.
    const focused = document.activeElement === area
    const done = !focused ? false
      : text.length === 0 ? document.execCommand('delete', false) : document.execCommand('insertText', false, text)
    if (!done || area.value !== expected) {
      area.value = expected
      area.setSelectionRange(from + text.length, from + text.length)
      area.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: text }))
    }
    lastValue = area.value
  }

  /** One undo step: every change of it inside one replacement, the text between them written back as it was. */
  const step = (changes: LatexChange[]) => {
    if (changes.length === 0) return
    const from = Math.min(...changes.map((c) => c.from))
    const to = Math.max(...changes.map((c) => c.to))
    const local = changes.map((c) => ({ from: c.from - from, to: c.to - from, text: c.text }))
    replace(from, to, applied(local, lastValue.slice(from, to)))
  }

  const apply = (edit: LatexEdit) => {
    applying = true
    try {
      let caret = ranges[0]
      for (const changes of edit.undoSteps) {
        remember(caret)
        step(changes)
        // After the echoed key, the caret stands after it (assoc 1), as the
        // plugin's history has it.
        const set = new ChangeSet(changes.map((c) => ({ from: c.from, to: c.to, insert: c.text })))
        const p = set.mapped(caret.from, 1)
        caret = { from: p, to: p }
      }
      ranges = edit.selection.length > 0 ? edit.selection : [textareaRange()]
      area.setSelectionRange(ranges[0].from, ranges[0].to)
      tabstops = edit.tabstops
    } finally {
      applying = false
    }
    lastValue = area.value
    draw()
  }

  /** Types `changes` at every range at once — the mirrors of a placeholder filled in together. */
  const typeEverywhere = (changes: LatexChange[]) => {
    applying = true
    try {
      remember(ranges[0])
      step(changes)
      ranges = caretsAfter(changes)
      area.setSelectionRange(ranges[0].from, ranges[0].to)
      tabstops = tabstops.afterEdit(changes, ranges)
    } finally {
      applying = false
    }
    lastValue = area.value
    draw()
  }

  const ask = (input: LatexInput): LatexEdit | null => {
    if (!enabled()) return null
    sync()
    return engine().handle(input, area.value, ranges, tabstops)
  }

  const onKeyDown = (event: KeyboardEvent) => {
    keyFromIME = event.isComposing || event.keyCode === 229
    // Option (and AltGr, which arrives as Control and Alt together) makes
    // characters; Command and Control make shortcuts.
    keyWithCommand = event.metaKey || (event.ctrlKey && !event.altKey)
    if (!enabled() || keyFromIME || composing || event.metaKey || event.ctrlKey || event.altKey) return
    let input: LatexInput | null = null
    if (event.key === 'Tab') input = event.shiftKey ? 'shiftTab' : 'tab'
    else if (event.key === 'Enter') input = event.shiftKey ? 'shiftEnter' : 'enter'
    else if (event.key === 'Backspace' && !event.shiftKey) input = 'backspace'
    if (!input) return
    const edit = ask(input)
    if (!edit) return
    event.preventDefault()
    apply(edit)
  }

  const onBeforeInput = (event: InputEvent) => {
    if (applying || !enabled()) return
    if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') {
      // Undo drops every placeholder (and Redo does not bring them back here:
      // the textarea's history holds text, not tabstops).
      tabstops = Tabstops.none
      ranges = [textareaRange()]
      return
    }
    if (composing || event.isComposing || keyFromIME) return
    if (event.inputType === 'insertText' && !keyWithCommand && event.data && event.data.length === 1) {
      const edit = ask({ text: event.data })
      if (edit) {
        event.preventDefault()
        apply(edit)
        return
      }
      if (ranges.length > 1) {
        event.preventDefault()
        typeEverywhere(ranges.map((r) => ({ from: r.from, to: r.to, text: event.data as string })))
      }
      return
    }
    if (ranges.length > 1 && (event.inputType === 'deleteContentBackward' || event.inputType === 'deleteContentForward')) {
      sync()
      if (ranges.length < 2) return
      const backward = event.inputType === 'deleteContentBackward'
      const text = area.value
      const changes: LatexChange[] = []
      let floor = 0
      for (const r of ranges) {
        let from = r.from
        let to = r.to
        if (from === to) {
          if (backward) {
            from -= from >= 2 && (text.charCodeAt(from - 1) & 0xfc00) === 0xdc00 && (text.charCodeAt(from - 2) & 0xfc00) === 0xd800 ? 2 : 1
          } else {
            to += (text.charCodeAt(to) & 0xfc00) === 0xd800 && (text.charCodeAt(to + 1) & 0xfc00) === 0xdc00 ? 2 : 1
          }
        }
        from = Math.max(from, floor, 0)
        to = Math.min(Math.max(to, from), text.length)
        if (to > from) changes.push({ from, to, text: '' })
        floor = to
      }
      event.preventDefault()
      if (changes.length > 0) typeEverywhere(changes)
      return
    }
    // Anything else — a paste, a word deleted — is one range's business.
    if (ranges.length > 1) ranges = [textareaRange()]
  }

  const onInput = (event: Event) => {
    if (applying) return
    // The Edit menu's Undo reaches the textarea without a `beforeinput` on
    // some desktops; the `input` after it says what it was either way.
    const kind = (event as InputEvent).inputType
    if (kind === 'historyUndo' || kind === 'historyRedo') {
      tabstops = Tabstops.none
      let k = undoMarks.length - 1
      while (k >= 0 && undoMarks[k].value !== area.value) k -= 1
      if (kind === 'historyUndo' && k >= 0) {
        area.setSelectionRange(undoMarks[k].caret.from, undoMarks[k].caret.to)
        undoMarks.length = k
      }
      ranges = [textareaRange()]
      lastValue = area.value
      draw()
      return
    }
    sync()
  }

  const onCompositionStart = () => {
    composing = true
  }

  const onCompositionEnd = () => {
    composing = false
    sync()
  }

  const onSelectionChange = () => {
    if (!area.isConnected) {
      detach()
      return
    }
    if (!applying && document.activeElement === area) sync()
  }

  // MARK: The overlay

  const draw = () => {
    const marks: { from: number; to: number; kind: 'slot' | 'mirror' }[] = []
    tabstops.groups.forEach((group, k) => {
      if (k === 0) return
      for (const r of group.ranges) marks.push({ from: r.from, to: r.to, kind: 'slot' })
    })
    for (const r of ranges.slice(1)) marks.push({ from: r.from, to: r.to, kind: 'mirror' })
    if (marks.length === 0 || !enabled()) {
      overlay?.remove()
      overlay = null
      return
    }
    if (!overlay) {
      const host = area.parentElement
      if (!host) return
      if (getComputedStyle(host).position === 'static') host.style.position = 'relative'
      overlay = document.createElement('div')
      overlay.className = 'ls-overlay'
      overlay.setAttribute('aria-hidden', 'true')
      area.after(overlay)
    }
    const style = getComputedStyle(area)
    for (const key of COPIED_STYLE) overlay.style[key] = style[key]
    overlay.style.borderStyle = 'solid'
    overlay.style.borderColor = 'transparent'
    const z = Number.parseInt(style.zIndex, 10)
    overlay.style.zIndex = Number.isFinite(z) ? String(z + 1) : ''
    const borders = (a: string, b: string) => Number.parseFloat(a) + Number.parseFloat(b)
    overlay.style.left = `${area.offsetLeft}px`
    overlay.style.top = `${area.offsetTop}px`
    overlay.style.width = `${area.clientWidth + borders(style.borderLeftWidth, style.borderRightWidth)}px`
    overlay.style.height = `${area.clientHeight + borders(style.borderTopWidth, style.borderBottomWidth)}px`

    const text = area.value
    const cuts = new Set<number>([0, text.length])
    for (const m of marks) {
      cuts.add(Math.min(m.from, text.length))
      cuts.add(Math.min(m.to, text.length))
    }
    const points = [...cuts].sort((a, b) => a - b)
    const fragment = document.createDocumentFragment()
    const spot = (at: number, kind: 'slot' | 'mirror') => {
      const node = document.createElement('span')
      node.className = kind === 'mirror' ? 'ls-caret' : 'ls-spot'
      node.dataset.at = String(at)
      fragment.append(node)
    }
    for (let k = 0; k < points.length; k += 1) {
      const at = points[k]
      for (const m of marks) if (m.from === m.to && m.from === at) spot(at, m.kind)
      const next = points[k + 1]
      if (next === undefined || next <= at) continue
      const covering = marks.filter((m) => m.from < m.to && m.from <= at && m.to >= next)
      const piece = text.slice(at, next)
      if (covering.length === 0) {
        fragment.append(piece)
        continue
      }
      const node = document.createElement('span')
      node.className = covering.some((m) => m.kind === 'mirror') ? 'ls-mirror' : 'ls-slot'
      node.dataset.from = String(at)
      node.dataset.to = String(next)
      node.textContent = piece
      fragment.append(node)
    }
    // A trailing newline has a line of its own in the textarea; give it one here.
    fragment.append('​')
    overlay.replaceChildren(fragment)
    overlay.scrollTop = area.scrollTop
    overlay.scrollLeft = area.scrollLeft
  }

  const onScroll = () => {
    if (!overlay) return
    overlay.scrollTop = area.scrollTop
    overlay.scrollLeft = area.scrollLeft
  }

  const resize = new ResizeObserver(() => {
    if (overlay) draw()
  })
  resize.observe(area)

  // Capture, so the field's own key handlers see a key only after Latex Suite has had it.
  area.addEventListener('keydown', onKeyDown, true)
  area.addEventListener('beforeinput', onBeforeInput)
  area.addEventListener('input', onInput)
  area.addEventListener('compositionstart', onCompositionStart)
  area.addEventListener('compositionend', onCompositionEnd)
  area.addEventListener('select', onInput)
  area.addEventListener('keyup', onInput)
  area.addEventListener('pointerup', onInput)
  area.addEventListener('scroll', onScroll)
  area.addEventListener('selectionchange', onSelectionChange)
  document.addEventListener('selectionchange', onSelectionChange)

  let attached = true
  function detach() {
    if (!attached) return
    attached = false
    area.removeEventListener('keydown', onKeyDown, true)
    area.removeEventListener('beforeinput', onBeforeInput)
    area.removeEventListener('input', onInput)
    area.removeEventListener('compositionstart', onCompositionStart)
    area.removeEventListener('compositionend', onCompositionEnd)
    area.removeEventListener('select', onInput)
    area.removeEventListener('keyup', onInput)
    area.removeEventListener('pointerup', onInput)
    area.removeEventListener('scroll', onScroll)
    area.removeEventListener('selectionchange', onSelectionChange)
    document.removeEventListener('selectionchange', onSelectionChange)
    resize.disconnect()
    overlay?.remove()
    overlay = null
  }

  return {
    get tabstops() {
      return tabstops
    },
    get ranges() {
      return ranges.map((r) => ({ ...r }))
    },
    detach,
  }
}

