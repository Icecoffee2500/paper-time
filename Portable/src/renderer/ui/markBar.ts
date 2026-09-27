/**
 * The little bar over a selection, and over a mark that was clicked.
 *
 * Marking a passage should be one gesture away from having selected it —
 * reaching for a menu breaks the reading. Over a selection it is the Mac's
 * bar: five colours, underline and strikethrough, then a note about the
 * passage and a plain copy. Over a mark already on the page it is the Mac's
 * editor for one: its colour changed, a note written on it, or the mark
 * taken off.
 *
 * The bar stays over what it is about: a scroll moves it with the words, and
 * it goes when they leave the view — unless a note is being written in it,
 * which a scroll must not throw away.
 */
import { clear, el, on } from '../dom.js'
import { icon } from '../icons.js'
import { platform } from '../bridge.js'
import { L } from '../../shared/lang.js'
import { withKey } from '../../shared/shortcuts.js'
import { MARK_COLORS, MARK_COLOR_NAMES, cssColor, nearestColorName, type Mark, type MarkKind } from '../../shared/marks.js'
import type { MenuEntry } from './menu.js'
import { copyText } from './clipboard.js'
import type { PageView } from './pageView.js'

/** A part of a selection, as marks take it: the page, its lines, its words. */
export interface SelectionPart {
  page: PageView
  quads: number[][]
  text: string
}

export interface MarkBarHost {
  /** Where the bar is put: over the reader, outside its scroll view. */
  overlay: HTMLElement
  /** The reader's own node — a selection in a neighbouring pane is not ours. */
  node: HTMLElement
  /** The scroll view, whose box the words must be in for the bar to stay. */
  scroll: HTMLElement
  drawing: () => boolean
  page: (index: number) => PageView | undefined
  selectionParts: () => SelectionPart[]
  markSelection: (kind: MarkKind, colorName: string) => void
  addMarks: (parts: SelectionPart[], kind: MarkKind, colorName: string, comment?: string) => void
  setMarkComment: (pageIndex: number, id: string, comment: string) => void
  recolorMark: (pageIndex: number, id: string, colorName: string) => void
  removeMark: (pageIndex: number, id: string) => void
  markClientBox: (page: PageView, mark: Mark) => DOMRect | null
  toast: (message: string) => void
  /** Ultracopy: the selection with its formulas as LaTeX. */
  ultracopy?: () => void
  markShown?: (id: string) => void
}

/** One of the five mark colours, said in the window's language. */
export function colourWord(name: string): string {
  return ({
    yellow: L('노랑', 'yellow'),
    green: L('초록', 'green'),
    blue: L('파랑', 'blue'),
    pink: L('분홍', 'pink'),
    purple: L('보라', 'purple'),
  } as Record<string, string>)[name] ?? name
}

/** How long the selection has to rest before the bar comes — the Mac's
 *  220 ms (`scheduleMarkupPanel`): a bar chasing the pointer letter by letter
 *  flickered, and landed under the pointer at the release. */
const SETTLE_MS = 220

export class MarkBar {
  private node: HTMLElement | null = null
  /** While a note is being written, the way to finish it. */
  private composing: { finish: (keep: boolean) => void } | null = null
  /** The mark whose controls are showing, when the bar is a mark's. */
  private editing: { pageIndex: number; id: string } | null = null
  /** Where what the bar is about is on screen now. */
  private anchor: (() => DOMRect | null) | null = null
  /** The kind a colour applies: a highlight, unless Underline or
   *  Strikethrough was pressed first (`MarkupBarView.arm`). */
  private armed: MarkKind = 'highlight'
  private settle = 0
  /** A button is down over the pages: the selection is still being made. */
  private pressing = false

  private readonly listening = new AbortController()

  constructor(private readonly host: MarkBarHost) {
    const signal = this.listening.signal
    host.node.addEventListener('pointerdown', (event: PointerEvent) => {
      if (this.node?.contains(event.target as Node)) return
      this.pressing = true
    }, { signal })
    window.addEventListener('pointerup', () => {
      if (!this.pressing) return
      this.pressing = false
      this.selectionChanged()
    }, { signal })
    // The window went behind another: the bar goes with its focus, as the
    // Mac's panel does on `didResignKey` — unless a note is being written.
    window.addEventListener('blur', () => this.hide(), { signal })
  }

  /** The reader is gone for good. */
  dispose() {
    this.listening.abort()
    clearTimeout(this.settle)
    this.reset()
  }

  /** Whether the bar is up over a selection or a mark — Escape's first step. */
  get showing(): boolean {
    return this.node?.style.display === 'flex'
  }

  get isComposing(): boolean {
    return this.composing !== null
  }

  private bar(): HTMLElement {
    if (!this.node) {
      this.node = el('div', { class: 'mark-bar' })
      this.host.overlay.append(this.node)
    }
    return this.node
  }

  /** One of the bar's buttons. The selection has to survive the press, so
   *  the default mousedown — which would collapse it — never happens. */
  private button(className: string, title: string, html: string, press: () => void): HTMLElement {
    const button = el('button', { class: className, title, 'aria-label': title, html })
    on(button, 'mousedown', (event: MouseEvent) => event.preventDefault())
    on(button, 'click', press)
    return button
  }

  private swatch(name: string, title: string, press: () => void, current = false): HTMLElement {
    const button = this.button('mark-swatch', title, '', press)
    button.style.background = cssColor(MARK_COLORS[name] as [number, number, number])
    if (current) button.setAttribute('aria-pressed', 'true')
    return button
  }

  /** The bar over a box in the window: above it, or under it with no room. */
  private place(rect: DOMRect) {
    const bar = this.bar()
    bar.style.display = 'flex'
    const host = this.host.overlay.getBoundingClientRect()
    const size = bar.getBoundingClientRect()
    const width = size.width || 190
    let left = rect.left + rect.width / 2 - host.left - width / 2
    left = Math.max(6, Math.min(left, host.width - width - 6))
    let top = rect.top - host.top - (size.height || 31) - 7
    if (top < 4) top = rect.bottom - host.top + 8
    top = Math.max(4, Math.min(top, host.height - (size.height || 31) - 4))
    bar.style.left = `${left}px`
    bar.style.top = `${top}px`
  }

  /** The view scrolled: the bar goes with its words, or goes. */
  followScroll() {
    if (!this.showing || !this.anchor) return
    const rect = this.anchor()
    const view = this.host.scroll.getBoundingClientRect()
    const inView = rect && rect.bottom > view.top && rect.top < view.bottom
    if (rect && (inView || this.composing)) this.place(rect)
    else this.hide()
  }

  /** The selection changed: the bar follows it once it rests, or goes. */
  selectionChanged() {
    // The note being written keeps the bar where it is.
    if (this.composing) return
    clearTimeout(this.settle)
    const selection = window.getSelection()
    if (!selection || selection.isCollapsed) {
      if (!this.editing) this.hide()
      return
    }
    // While the drag is still going, nothing: the bar arrives at the words
    // the hand let go of.
    if (this.pressing) {
      if (this.node?.dataset.mode === 'selection') this.hide()
      return
    }
    this.settle = window.setTimeout(() => this.showForSelection(), SETTLE_MS)
  }

  private showForSelection() {
    if (this.composing) return
    const selection = window.getSelection()
    if (!selection || selection.isCollapsed || selection.rangeCount === 0 || this.host.drawing()) {
      if (!this.editing) this.hide()
      return
    }
    const range = selection.getRangeAt(0)
    const inside = (range.commonAncestorContainer instanceof Element
      ? range.commonAncestorContainer
      : range.commonAncestorContainer.parentElement)?.closest('.text-layer, .reader-pages')
    // This reader's own text, not a neighbouring pane's.
    if (!inside || !this.host.node.contains(inside)) return this.hide()
    const rect = range.getBoundingClientRect()
    if (rect.width === 0 && rect.height === 0) return this.hide()
    this.editing = null
    this.anchor = () => {
      const now = window.getSelection()
      return now && now.rangeCount > 0 && !now.isCollapsed ? now.getRangeAt(0).getBoundingClientRect() : null
    }
    this.fillSelection()
    this.place(rect)
  }

  /**
   * The Mac's bar over a selection: five colours that apply the armed kind,
   * Underline and Strikethrough that arm it — a green underline is two
   * presses, and the armed button and the swatches say which is coming —
   * then a note and a copy. Built each time it shows, so its words are in
   * the language of now.
   */
  private fillSelection() {
    const bar = this.bar()
    bar.dataset.mode = 'selection'
    clear(bar)
    const swatches: HTMLElement[] = []
    for (const name of MARK_COLOR_NAMES) {
      const colour = colourWord(name)
      const swatch = this.swatch(name, colour, () => {
        this.host.markSelection(this.armed, name)
        this.hide()
      })
      swatch.dataset.kind = this.armed
      swatches.push(swatch)
      bar.append(swatch)
    }
    bar.append(el('span', { class: 'mark-divider' }))
    const arming: HTMLElement[] = []
    const arm = (kind: MarkKind) => {
      this.armed = this.armed === kind ? 'highlight' : kind
      for (const button of arming) button.setAttribute('aria-pressed', String(button.dataset.kind === this.armed))
      for (const swatch of swatches) swatch.dataset.kind = this.armed
    }
    for (const [kind, label, glyph, key] of [
      ['underline', L('밑줄', 'Underline'), 'underline', 'underline'],
      ['strikethrough', L('취소선', 'Strikethrough'), 'strikethrough', null],
    ] as const) {
      const button = this.button('mark-action mark-arm', key ? withKey(label, key, platform) : label, icon(glyph), () => arm(kind))
      button.dataset.kind = kind
      button.setAttribute('aria-pressed', String(this.armed === kind))
      arming.push(button)
      bar.append(button)
    }
    bar.append(el('span', { class: 'mark-divider' }))
    bar.append(this.button('mark-action', L('노트 더하기', 'Add Note'), icon('square.and.pencil'), () => this.compose()))
    bar.append(this.button('mark-action', L('복사', 'Copy'), icon('doc.on.doc'), () => void this.copySelection()))
    if (this.host.ultracopy) {
      const ultracopy = this.host.ultracopy
      bar.append(this.button('mark-action', withKey(L('Ultracopy — 수식은 LaTeX로 복사', 'Ultracopy — copy with formulas as LaTeX'), 'ultracopy', platform), icon('function'), () => ultracopy()))
    }
  }

  /** What a right-click on a selection offers (`MarkupCapablePDFView.menu(for:)`). */
  selectionMenu(): MenuEntry[] {
    return [
      {
        label: L('형광펜', 'Highlight'),
        icon: 'highlighter',
        children: MARK_COLOR_NAMES.map((name) => ({
          label: colourWord(name),
          action: () => void this.host.markSelection('highlight', name),
        })),
      },
      { label: L('밑줄', 'Underline'), icon: 'underline', action: () => void this.host.markSelection('underline', 'yellow') },
      { label: L('취소선', 'Strikethrough'), icon: 'strikethrough', action: () => void this.host.markSelection('strikethrough', 'yellow') },
      { label: L('노트 더하기…', 'Add Note…'), icon: 'square.and.pencil', action: () => this.compose() },
      { separator: true },
      { label: L('복사', 'Copy'), icon: 'doc.on.doc', action: () => void this.copySelection() },
      ...(this.host.ultracopy ? [{ label: 'Ultracopy', icon: 'function', key: 'ultracopy', action: () => this.host.ultracopy?.() }] : []),
    ]
  }

  /** What a right-click on a mark offers: its colour, and taking it off. */
  markMenu(page: PageView, mark: Mark): MenuEntry[] {
    const current = nearestColorName(mark.color)
    return [
      {
        label: L('표시 색', 'Mark Colour'),
        icon: 'circle.lefthalf.filled',
        children: MARK_COLOR_NAMES.map((name) => ({
          label: colourWord(name),
          checked: name === current,
          action: () => this.host.recolorMark(page.index, mark.id, name),
        })),
      },
      { label: L('노트…', 'Note…'), icon: 'square.and.pencil', action: () => this.compose({ pageIndex: page.index, id: mark.id }) },
      { separator: true },
      { label: L('표시 지우기', 'Remove Mark'), icon: 'trash', danger: true, action: () => this.host.removeMark(page.index, mark.id) },
    ]
  }

  /** Copies the selected words as they are, and says so — once it is true. */
  private async copySelection() {
    const text = window.getSelection()?.toString() ?? ''
    if (!text) return
    const copied = await copyText(text)
    this.host.toast(copied ? L('복사했어요', 'Copied') : L('복사하지 못했어요', "Paper Time couldn't copy that."))
    window.getSelection()?.removeAllRanges()
    this.hide()
  }

  /**
   * A note in the bar: about the selected passage — a yellow highlight with
   * the words written on it, which is what a note on the Mac is — or the note
   * of a mark already on the page. Return keeps it, Escape does not; clicking
   * away keeps what was typed rather than throwing it out.
   */
  compose(target?: { pageIndex: number; id: string }) {
    const parts = target ? [] : this.host.selectionParts()
    const page = target ? this.host.page(target.pageIndex) : undefined
    const mark = target ? page?.marks.find((one) => one.id === target.id) : undefined
    if (!target && parts.length === 0) return
    if (target && (!page || !mark)) return
    const anchor = target && page && mark
      ? () => this.host.markClientBox(page, mark)
      : (() => {
          const first = window.getSelection()?.getRangeAt(0).cloneRange() ?? null
          return () => first?.getBoundingClientRect() ?? null
        })()
    const rect = anchor()
    if (!rect) return
    this.anchor = anchor
    const bar = this.bar()
    bar.dataset.mode = 'compose'
    clear(bar)
    // The Mac's composer: the passage, quietly, over the field — so the note
    // is written looking at what it is about — then Cancel and Save.
    const quoted = (target ? mark?.text : parts.map((part) => part.text).join(' ')) ?? ''
    const input = el('input', {
      type: 'text',
      class: 'mark-note-field',
      placeholder: L('노트', 'Note'),
      'aria-label': L('노트', 'Note'),
      spellcheck: 'true',
    }) as HTMLInputElement
    input.value = mark?.comment ?? ''
    const cancel = el('button', { class: 'plain-button mark-note-cancel', text: L('취소', 'Cancel') })
    const save = el('button', { class: 'filled-button mark-note-save', text: L('저장', 'Save') })
    const finish = (keep: boolean) => {
      if (!this.composing) return
      this.composing = null
      const text = input.value.trim()
      if (keep) {
        if (target) this.host.setMarkComment(target.pageIndex, target.id, text)
        else if (text) this.host.addMarks(parts, 'highlight', 'yellow', text)
      }
      window.getSelection()?.removeAllRanges()
      this.editing = null
      this.hide()
    }
    on(input, 'keydown', (event: KeyboardEvent) => {
      // The window's keys — a letter picks a drawing tool — must not see this.
      event.stopPropagation()
      if (event.key === 'Enter') {
        event.preventDefault()
        finish(true)
      } else if (event.key === 'Escape') {
        event.preventDefault()
        finish(false)
      }
    })
    // Clicking away keeps what was typed, and throws away nothing typed.
    on(input, 'blur', () => finish(input.value.trim().length > 0 && input.value.trim() !== (mark?.comment ?? '')))
    for (const button of [cancel, save]) on(button, 'mousedown', (event: MouseEvent) => event.preventDefault())
    on(save, 'click', () => finish(true))
    on(cancel, 'click', () => finish(false))
    if (quoted.trim()) bar.append(el('div', { class: 'mark-note-quote', text: quoted.trim() }))
    bar.append(input, el('div', { class: 'mark-note-buttons' }, [el('span', { class: 'fb-spacer' }), cancel, save]))
    this.composing = { finish }
    this.place(rect)
    input.focus()
  }

  /** The controls for a mark already on the page, over it. */
  showMark(page: PageView, mark: Mark) {
    // Another reader's mark too: the first change takes it into this app's
    // care, under the identifier both builds derive for it.
    const anchor = () => this.host.markClientBox(page, mark)
    const rect = anchor()
    if (!rect) return
    this.composing = null
    this.anchor = anchor
    const bar = this.bar()
    bar.dataset.mode = 'mark'
    clear(bar)
    const current = nearestColorName(mark.color)
    for (const name of MARK_COLOR_NAMES) {
      const colour = colourWord(name)
      bar.append(this.swatch(name, L(`색 바꾸기: ${colour}`, `Change to ${colour}`), () => {
        this.host.recolorMark(page.index, mark.id, name)
        this.hideMark()
      }, name === current))
    }
    // Five colours and a red trash, the Mac's editor: a note on a mark is
    // written from its row in the Marks tab, or its right-click menu.
    bar.append(el('span', { class: 'mark-divider' }))
    bar.append(this.button('mark-action danger', L('표시 지우기', 'Remove Mark'), icon('trash'), () => this.host.removeMark(page.index, mark.id)))
    this.editing = { pageIndex: page.index, id: mark.id }
    this.place(rect)
    this.host.markShown?.(mark.id)
  }

  hideMark() {
    if (!this.editing) return
    this.editing = null
    this.hide()
  }

  hide() {
    if (this.composing) return
    clearTimeout(this.settle)
    this.armed = 'highlight'
    if (this.node) {
      this.node.style.display = 'none'
      delete this.node.dataset.mode
    }
    this.editing = null
    this.anchor = null
  }

  /** The paper closed: a note half written about it has nowhere to go. */
  reset() {
    this.composing = null
    this.hide()
  }
}
