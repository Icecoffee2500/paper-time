/**
 * Find in Document — the bar over the reader, the port of the Mac's
 * `FindBar` and the `DocumentFinder` behind it.
 *
 * The same shape and the same keys: a field, how many were found, the two
 * arrows and a close button; Return for the next, Shift-Return for the one
 * before, Escape to put it away. The search waits a quarter of a second after
 * the typing stops (the Mac's 250 ms), and asking again for what was already
 * found keeps the place rather than starting over — a text field re-commits
 * its value when Return is pressed, and on the Mac that once sent the
 * counter back to "1 of 47" while the reader sat still.
 *
 * One thing is deliberately different: the first match is shown as soon as
 * the search lands, and every match on the pages in view is marked, the
 * current one strongest. The Mac waits for Return and then goes to the second.
 * And the words are folded the way the index folds them, so a word broken at
 * the end of a line is found here as it is in the palette, and the two counts
 * agree.
 */
import { el, on } from '../dom.js'
import { iconNode } from '../icons.js'
import { L } from '../../shared/lang.js'
import type { Reader } from './reader.js'

type Found = { pageIndex: number; start: number; end: number }

export class FindBar {
  readonly node: HTMLElement
  private readonly input: HTMLInputElement
  private readonly summary: HTMLElement
  private readonly glass: HTMLElement
  private readonly previous: HTMLButtonElement
  private readonly next: HTMLButtonElement
  private reader: Reader | null = null
  private matches: Found[] = []
  private current = 0
  /** The query the matches were found for. */
  private searched: string | null = null
  private searching = false
  private timer: ReturnType<typeof setTimeout> | null = null
  private generation = 0

  constructor() {
    this.input = el('input', {
      type: 'text',
      spellcheck: 'false',
      placeholder: L('이 논문에서 찾기', 'Find in Document'),
      'aria-label': L('이 논문에서 찾기', 'Find in Document'),
    }) as HTMLInputElement
    this.summary = el('span', { class: 'find-summary' })
    this.glass = el('span', { class: 'find-glass' })
    const button = (icon: string, label: string, press: () => void) => {
      const made = el('button', { class: 'icon-button', title: label, 'aria-label': label }) as HTMLButtonElement
      const glyph = iconNode(icon)
      if (glyph) made.append(glyph)
      on(made, 'mousedown', (event: MouseEvent) => event.preventDefault())
      on(made, 'click', press)
      return made
    }
    this.previous = button('chevron.up', L('이전 결과', 'Previous Match'), () => void this.step(-1))
    this.next = button('chevron.down', L('다음 결과', 'Next Match'), () => void this.step(1))
    const close = button('xmark.circle.fill', L('찾기 막대 닫기', 'Close Find Bar'), () => this.close())
    close.classList.add('find-close')
    this.node = el('div', { class: 'find-bar', role: 'search' }, [
      this.glass, this.input, this.summary, el('span', { class: 'find-divider' }), this.previous, this.next, close,
    ])
    on(this.input, 'input', () => this.schedule())
    on(this.input, 'keydown', (event: KeyboardEvent) => {
      // The reader's own keys — the arrows turn pages, a letter picks a tool —
      // must not see what is being typed here.
      event.stopPropagation()
      if (event.key === 'Enter') {
        event.preventDefault()
        void this.submit(event.shiftKey ? -1 : 1)
      } else if (event.key === 'Escape') {
        event.preventDefault()
        this.close()
      }
    })
    this.update()
  }

  get isOpen(): boolean {
    return this.node.isConnected
  }

  /** Opens over a reader, or brings the caret back to the field. */
  open(reader: Reader) {
    if (this.reader !== reader) {
      this.reset()
      this.reader = reader
    }
    if (!this.node.isConnected) reader.overlayContainer.append(this.node)
    this.input.focus()
    this.input.select()
    if (this.input.value.trim() && this.searched === null) this.schedule()
  }

  close() {
    this.reset()
    this.node.remove()
    this.reader = null
  }

  /** Whether this bar belongs to that reader. */
  isFor(reader: Reader | null): boolean {
    return reader !== null && this.reader === reader
  }

  private reset() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
    this.generation += 1
    this.reader?.clearFound()
    this.matches = []
    this.current = 0
    this.searched = null
    this.searching = false
    this.update()
  }

  private schedule() {
    if (this.timer) clearTimeout(this.timer)
    const query = this.input.value.trim()
    if (!query) {
      this.reset()
      return
    }
    // Asked again for what was already found: nothing to do, and the place
    // in the matches is kept.
    if (query === this.searched && this.matches.length > 0) return
    this.timer = setTimeout(() => {
      this.timer = null
      void this.run(query)
    }, 250)
  }

  private async run(query: string): Promise<void> {
    const reader = this.reader
    if (!reader) return
    const mine = (this.generation += 1)
    this.searching = true
    this.update()
    const found = await reader.findAll(query)
    // A newer keystroke, or a closed bar, owns the result now.
    if (mine !== this.generation || reader !== this.reader) return
    this.matches = found
    this.current = 0
    this.searched = query
    this.searching = false
    this.update()
    reader.showFound(found, 0)
    if (found.length > 0) await reader.scrollToFound(found[0].pageIndex)
  }

  /** Return: the next match, once the search for what is typed is in. */
  private async submit(by: number) {
    const query = this.input.value.trim()
    if (!query) return
    if (query !== this.searched) {
      if (this.timer) clearTimeout(this.timer)
      this.timer = null
      await this.run(query)
      return
    }
    await this.step(by)
  }

  private async step(by: number) {
    const reader = this.reader
    if (!reader || this.matches.length === 0) return
    this.current = (this.current + by + this.matches.length) % this.matches.length
    this.update()
    reader.showFound(this.matches, this.current)
    await reader.scrollToFound(this.matches[this.current].pageIndex)
  }

  /** "3 of 47", or "No results", or nothing at all while the field is empty. */
  private update() {
    const query = this.input.value.trim()
    let text = ''
    if (query && !this.searching && this.searched === query) {
      text = this.matches.length > 0
        ? L(`${this.current + 1} / ${this.matches.length}`, `${this.current + 1} of ${this.matches.length}`)
        : L('못 찾았어요', 'No results')
    }
    this.summary.textContent = text
    this.previous.disabled = this.matches.length === 0
    this.next.disabled = this.matches.length === 0
    // A small spinner stands in for the magnifying glass while a longer
    // document is being read; the count beside it stays put either way.
    this.glass.replaceChildren(this.searching ? el('span', { class: 'spinner' }) : (iconNode('magnifyingglass') ?? el('span')))
  }

  /** For a probe: what the bar is showing. */
  state() {
    return {
      open: this.isOpen,
      query: this.input.value,
      summary: this.summary.textContent,
      matches: this.matches.length,
      current: this.current,
      searching: this.searching,
    }
  }

  /** For a probe: typing, without a key sent anywhere. */
  type(text: string) {
    this.input.value = text
    this.schedule()
  }

  press(key: 'Enter' | 'Shift+Enter' | 'Escape') {
    if (key === 'Escape') this.close()
    else void this.submit(key === 'Enter' ? 1 : -1)
  }
}
