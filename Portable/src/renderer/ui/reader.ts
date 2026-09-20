/**
 * The paper itself.
 *
 * Pages are laid out continuously and rendered only when they come near the
 * window, because a forty-page paper rendered eagerly costs a second of
 * stutter and two hundred megabytes for pages nobody has scrolled to.
 *
 * Every page carries four layers, bottom to top: the rendered page, a tint,
 * the drawing (ink and shapes, drawn from the sidecars rather than from the
 * PDF's copies — the copies are hidden, exactly as the Mac hides them under
 * its overlay), and the text layer you select words in. When the pen is out, a
 * fifth surface takes the mouse and the text layer steps aside.
 */
import { clear, el, on } from '../dom.js'
import { store } from '../state.js'
import { loadDocument, TextLayer, type PDFDocumentProxy, type PDFPageProxy } from '../pdf.js'
import { SketchElement } from '../../shared/sketch.js'
import { InkStroke } from '../../shared/ink.js'
import { drawElements, drawInk, drawMarks } from '../../shared/sketchRender.js'
import {
  MARK_COLORS,
  MARK_COLOR_NAMES,
  cssColor,
  rectToQuad,
  type Mark,
  type MarkKind,
} from '../../shared/marks.js'
import { makeUUID } from '../../shared/coding.js'
import { call } from '../bridge.js'
import { attachSketchInput, type SketchInput } from './sketchInput.js'
import { icon } from '../icons.js'
import { L } from '../../shared/lang.js'

const TINTS: Record<string, string | null> = {
  none: null,
  sepia: 'rgba(247, 231, 198, 1)',
  grey: 'rgba(232, 232, 234, 1)',
  night: 'rgba(150, 156, 168, 1)',
}

export interface ReaderActions {
  /** Ask the window to redraw the parts that show what is selected. */
  changed: () => void
  toast: (message: string) => void
}

export class PageView {
  root: HTMLElement
  canvas: HTMLCanvasElement
  drawCanvas: HTMLCanvasElement
  textLayer: HTMLElement
  inputSurface: HTMLElement
  tint: HTMLElement
  elements: SketchElement[] = []
  strokes: InkStroke[] = []
  marks: Mark[] = []
  /** Mid-gesture elements the input surface is drawing itself. */
  hidden = new Set<string>()
  viewport: { width: number; height: number; transform: number[]; scale: number; rotation: number } | null = null
  rendered = false
  private renderTask: { cancel: () => void } | null = null
  private textTask: { cancel: () => void } | null = null
  input: SketchInput | null = null

  constructor(
    readonly index: number,
    readonly proxy: PDFPageProxy,
    private readonly owner: Reader,
  ) {
    this.canvas = el('canvas', { class: 'page-canvas' })
    this.drawCanvas = el('canvas', { class: 'draw-canvas' })
    this.textLayer = el('div', { class: 'text-layer' })
    this.inputSurface = el('div', { class: 'sketch-input' })
    this.tint = el('div', { class: 'page-tint' })
    this.root = el('div', { class: 'page', 'data-page': String(index) }, [
      this.canvas,
      this.tint,
      this.drawCanvas,
      this.textLayer,
      this.inputSurface,
    ])
  }

  layout(scale: number) {
    const viewport = this.proxy.getViewport({ scale })
    this.viewport = {
      width: viewport.width,
      height: viewport.height,
      transform: viewport.transform as number[],
      scale,
      rotation: viewport.rotation,
    }
    this.root.style.width = `${Math.floor(viewport.width)}px`
    this.root.style.height = `${Math.floor(viewport.height)}px`
    this.rendered = false
  }

  /** Page coordinates from a point in the page element's own box. */
  toPage(x: number, y: number): { x: number; y: number } {
    const viewport = this.proxy.getViewport({ scale: this.viewport?.scale ?? 1 })
    const [px, py] = viewport.convertToPdfPoint(x, y)
    return { x: px, y: py }
  }

  /** And back, for placing a handle or a text box over the page. */
  toView(x: number, y: number): { x: number; y: number } {
    const viewport = this.proxy.getViewport({ scale: this.viewport?.scale ?? 1 })
    const [vx, vy] = viewport.convertToViewportPoint(x, y)
    return { x: vx, y: vy }
  }

  async render() {
    if (this.rendered || !this.viewport) return
    this.rendered = true
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const viewport = this.proxy.getViewport({ scale: this.viewport.scale })
    this.canvas.width = Math.floor(viewport.width * dpr)
    this.canvas.height = Math.floor(viewport.height * dpr)
    const context = this.canvas.getContext('2d', { alpha: false })!
    this.renderTask?.cancel()
    const task = this.proxy.render({
      canvasContext: context,
      viewport,
      transform: dpr === 1 ? undefined : [dpr, 0, 0, dpr, 0, 0],
      // Our own marks are drawn from the sidecars; the PDF's copies of them
      // are hidden so nothing is drawn twice and slightly out of register.
      annotationMode: 1,
      background: '#ffffff',
    })
    this.renderTask = task as unknown as { cancel: () => void }
    try {
      await task.promise
    } catch {
      this.rendered = false
      return
    }
    await this.renderText(viewport)
    this.redraw()
  }

  private async renderText(viewport: unknown) {
    this.textTask?.cancel?.()
    clear(this.textLayer)
    try {
      const source = await this.proxy.getTextContent()
      const layer = new (TextLayer as unknown as new (options: unknown) => {
        render: () => Promise<void>
        cancel: () => void
      })({
        textContentSource: source,
        container: this.textLayer,
        viewport,
      })
      this.textTask = layer
      await layer.render()
    } catch {
      // A page with no text — a scan, a figure — simply has nothing to select.
    }
  }

  /** The drawing, redrawn from the sidecars into page coordinates. */
  redraw() {
    if (!this.viewport) return
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const canvas = this.drawCanvas
    const width = Math.floor(this.viewport.width * dpr)
    const height = Math.floor(this.viewport.height * dpr)
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width
      canvas.height = height
    }
    const context = canvas.getContext('2d')!
    context.setTransform(1, 0, 0, 1, 0, 0)
    context.clearRect(0, 0, canvas.width, canvas.height)
    const [a, b, c, d, e, f] = this.viewport.transform
    context.setTransform(dpr * a, dpr * b, dpr * c, dpr * d, dpr * e, dpr * f)
    // Marks first: they belong to the words, and the pen goes over them.
    drawMarks(this.marks, context)
    drawInk(this.strokes, context)
    drawElements(this.elements.filter((element) => !this.hidden.has(element.id)), context)
    this.input?.drawOverlay(context)
  }

  applyTint() {
    const colour = TINTS[store.settings.pageTint]
    this.tint.style.background = colour ?? 'transparent'
    this.tint.style.display = colour ? '' : 'none'
  }

  setDrawing(on: boolean) {
    this.root.setAttribute('data-drawing', String(on))
  }

  destroy() {
    this.renderTask?.cancel()
    this.textTask?.cancel?.()
    this.input?.detach()
    this.proxy.cleanup()
  }
}

export class Reader {
  node: HTMLElement
  private header = el('div', { class: 'reader-header' })
  private scroll = el('div', { class: 'reader-scroll' })
  private pagesBox = el('div', { class: 'reader-pages' })
  private footer = el('div', { class: 'reader-footer' })
  private overlayHost = el('div')
  document: PDFDocumentProxy | null = null
  pages: PageView[] = []
  paperID: string | null = null
  private observer: IntersectionObserver | null = null
  private generation = 0

  constructor(private readonly actions: ReaderActions) {
    this.scroll.append(this.pagesBox)
    // Outside the scroll view: the tool rack and the style panel belong to the
    // reader, not to the page under it, and a rack that scrolled away with the
    // paper would be gone the moment you needed it.
    this.overlayHost.className = 'reader-overlay'
    this.node = el('div', { class: 'panel reader-panel' }, [
      this.header, this.scroll, this.overlayHost, this.footer,
    ])
    on(this.scroll, 'scroll', () => this.noteCurrentPage(), { passive: true } as never)
    on(this.scroll, 'wheel', (event: WheelEvent) => {
      // Ctrl or ⌘ with the wheel is zoom everywhere else; it should be here.
      if (!(event.ctrlKey || event.metaKey)) return
      event.preventDefault()
      this.zoomBy(event.deltaY < 0 ? 1.1 : 1 / 1.1)
    })
  }

  get overlayContainer(): HTMLElement {
    return this.overlayHost
  }

  async open(id: string, bytes: Uint8Array) {
    const generation = ++this.generation
    this.close()
    this.paperID = id
    try {
      const document = await loadDocument(bytes)
      if (generation !== this.generation) {
        document.destroy()
        return
      }
      this.document = document
      store.reader.pageCount = document.numPages
      const proxies = await Promise.all(
        Array.from({ length: document.numPages }, (_, index) => document.getPage(index + 1)),
      )
      if (generation !== this.generation) return
      this.pages = proxies.map((proxy, index) => new PageView(index, proxy, this))
      clear(this.pagesBox)
      for (const page of this.pages) this.pagesBox.append(page.root)
      this.relayout()
      await this.loadDrawings(id)
      this.watchVisibility()
      this.update()
    } catch (error) {
      this.actions.toast(L(`이 PDF를 열 수 없다: ${String(error)}`, `This PDF could not be opened: ${String(error)}`))
    }
  }

  close() {
    this.observer?.disconnect()
    this.observer = null
    for (const page of this.pages) page.destroy()
    this.pages = []
    clear(this.pagesBox)
    this.document?.destroy()
    this.document = null
    this.paperID = null
    store.reader.pageCount = 0
    store.reader.currentPage = 0
  }

  /**
   * Fits the page to the column, then applies the reader's own zoom.
   *
   * "Actual size" on a screen is a fiction — a PDF point is 1/72 inch and a
   * display is whatever it is — so the honest default is the width of the
   * column, which is what someone reading wants anyway.
   */
  private baseScale(): number {
    const first = this.pages[0]
    if (!first) return 1
    const unit = first.proxy.getViewport({ scale: 1 })
    const available = Math.max(this.scroll.clientWidth - 40, 200)
    return available / unit.width
  }

  relayout() {
    const scale = this.baseScale() * store.reader.zoom
    for (const page of this.pages) {
      page.layout(scale)
      page.applyTint()
      page.setDrawing(store.reader.drawing)
    }
    this.applyLayout()
    this.renderVisible()
  }

  /**
   * One page at a time, or all of them.
   *
   * Single-page reading is not a smaller continuous scroll — it is a
   * different way of reading, where the page is the unit and turning it is
   * deliberate. So the others are taken out of the flow entirely rather than
   * scrolled past, and the arrow keys turn pages instead of nudging the
   * scroll by a line.
   */
  applyLayout() {
    const single = store.settings.pageLayout === 'single'
    for (const page of this.pages) {
      page.root.style.display = !single || page.index === store.reader.currentPage ? '' : 'none'
    }
    if (single) this.scroll.scrollTop = 0
  }

  /** Moves by whole pages. Only meaningful when one page is showing. */
  turnPage(by: number) {
    const next = Math.max(0, Math.min(store.reader.currentPage + by, this.pages.length - 1))
    if (next === store.reader.currentPage) return
    store.reader.currentPage = next
    if (store.settings.pageLayout === 'single') {
      this.applyLayout()
      void this.pages[next]?.render()
      this.updateFooter()
    } else {
      this.scrollToPage(next)
    }
  }

  setLayout(layout: 'single' | 'continuous') {
    store.settings.pageLayout = layout
    this.applyLayout()
    this.renderVisible()
    this.updateFooter()
  }

  zoomBy(factor: number) {
    store.reader.zoom = Math.max(0.35, Math.min(store.reader.zoom * factor, 6))
    this.relayout()
    this.update()
  }

  setZoom(zoom: number) {
    store.reader.zoom = zoom
    this.relayout()
    this.update()
  }

  private watchVisibility() {
    this.observer?.disconnect()
    this.observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const index = Number((entry.target as HTMLElement).dataset.page)
          const page = this.pages[index]
          if (!page) continue
          if (entry.isIntersecting) void page.render()
        }
      },
      // A screen either side, so scrolling meets a page already drawn.
      { root: this.scroll, rootMargin: '150% 0px' },
    )
    for (const page of this.pages) this.observer.observe(page.root)
  }

  private renderVisible() {
    const box = this.scroll.getBoundingClientRect()
    for (const page of this.pages) {
      const rect = page.root.getBoundingClientRect()
      if (rect.bottom > box.top - rect.height && rect.top < box.bottom + rect.height) {
        void page.render()
      }
    }
  }

  /**
   * Loads the page's drawings, and takes what is in the file when this
   * machine has no sidecar for it yet — a paper annotated on a Mac, opened
   * here for the first time.
   */
  private async loadDrawings(id: string) {
    const adopted = await call<{
      pages: Record<number, { elements: unknown[]; strokes: unknown[] }>
      unreadable: number[]
    }>('drawing:adoptFromFile', { id })
    const known = await call<{ sketch: number[]; ink: number[] }>('drawing:pages', { id })
    const indices = new Set<number>([
      ...known.sketch, ...known.ink, ...Object.keys(adopted.pages).map(Number),
    ])
    for (const index of indices) {
      const page = this.pages[index]
      if (!page) continue
      const elements = await call<unknown[] | null>('sketch:load', { id, pageIndex: index })
      const strokes = await call<unknown[] | null>('ink:load', { id, pageIndex: index })
      // This machine's sidecar first; what the file itself carries otherwise.
      page.elements = (elements ?? adopted.pages[index]?.elements ?? []).map(SketchElement.from)
      page.strokes = (strokes ?? adopted.pages[index]?.strokes ?? []).map(InkStroke.from)
      page.redraw()
    }
    const marks = await call<Record<number, Mark[]>>('marks:load', { id })
    for (const [index, list] of Object.entries(marks)) {
      const page = this.pages[Number(index)]
      if (!page) continue
      page.marks = list
      page.redraw()
    }
    if (adopted.unreadable.length > 0) {
      const pages = adopted.unreadable.map((index) => index + 1).join(', ')
      this.actions.toast(L(
        `${pages}쪽의 손글씨는 맥에서 쓴 것인데 아직 PDF에 기록되지 않았다. 맥에서 이 논문을 한 번 열면 건너온다.`,
        `Handwriting on page ${pages} was made on a Mac and has not been written into the PDF yet. `
        + 'Open the paper on the Mac once and it will come across.',
      ))
    }
  }

  /** Saves one page's drawing, sidecar first; the PDF follows behind. */
  async save(page: PageView) {
    if (!this.paperID) return
    await call('sketch:save', {
      id: this.paperID,
      pageIndex: page.index,
      elements: page.elements.map((element) => element.encode()),
    })
    await call('ink:save', {
      id: this.paperID,
      pageIndex: page.index,
      strokes: page.strokes.map((stroke) => stroke.encode()),
    })
  }

  /**
   * Marks whatever is selected, and clears the selection.
   *
   * The rectangles come from the text layer rather than from the PDF's own
   * text positions, because the text layer is what the reader actually
   * dragged over — so the mark lands where the pointer went, including across
   * a column break, where a run of PDF text indices would flood half the page.
   */
  markSelection(kind: MarkKind, colorName = 'yellow'): boolean {
    const selection = window.getSelection()
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) return false
    const text = selection.toString()
    const byPage = new Map<PageView, DOMRect[]>()
    for (let index = 0; index < selection.rangeCount; index += 1) {
      const range = selection.getRangeAt(index)
      const page = this.pageContaining(range.commonAncestorContainer)
      if (!page) continue
      const rects = [...range.getClientRects()].filter((rect) => rect.width > 0.5 && rect.height > 0.5)
      byPage.set(page, [...(byPage.get(page) ?? []), ...rects])
    }
    if (byPage.size === 0) return false

    const color = (MARK_COLORS[colorName] ?? MARK_COLORS.yellow) as [number, number, number]
    for (const [page, rects] of byPage) {
      const box = page.root.getBoundingClientRect()
      const lines = mergeIntoLines(rects)
      const quads = lines.map((line) => {
        // Two opposite corners through the page's own transform, which keeps
        // a rotated page honest.
        const topLeft = page.toPage(line.left - box.left, line.top - box.top)
        const bottomRight = page.toPage(line.right - box.left, line.bottom - box.top)
        return rectToQuad({
          x: Math.min(topLeft.x, bottomRight.x),
          y: Math.min(topLeft.y, bottomRight.y),
          width: Math.abs(bottomRight.x - topLeft.x),
          height: Math.abs(bottomRight.y - topLeft.y),
        })
      })
      if (quads.length === 0) continue
      page.marks = [...page.marks, { id: makeUUID(), kind, quads, color, text }]
      page.redraw()
      void this.saveMarks(page)
    }
    selection.removeAllRanges()
    return true
  }

  /** Takes back the marks under a point — the undo a reader reaches for. */
  removeMarkAt(page: PageView, point: { x: number; y: number }): boolean {
    const before = page.marks.length
    page.marks = page.marks.filter((mark) =>
      !mark.quads.some((quad) => {
        const xs = [quad[0], quad[2], quad[4], quad[6]]
        const ys = [quad[1], quad[3], quad[5], quad[7]]
        return point.x >= Math.min(...xs) && point.x <= Math.max(...xs)
          && point.y >= Math.min(...ys) && point.y <= Math.max(...ys)
      }))
    if (page.marks.length === before) return false
    page.redraw()
    void this.saveMarks(page)
    return true
  }

  async saveMarks(page: PageView) {
    if (!this.paperID) return
    await call('marks:save', { id: this.paperID, pageIndex: page.index, marks: page.marks })
  }

  private pageContaining(node: Node): PageView | null {
    const element = node instanceof Element ? node : node.parentElement
    const root = element?.closest('.page') as HTMLElement | null
    if (!root) return null
    return this.pages[Number(root.dataset.page)] ?? null
  }

  setDrawing(drawing: boolean) {
    store.reader.drawing = drawing
    for (const page of this.pages) {
      page.setDrawing(drawing)
      if (drawing && !page.input) {
        page.input = attachSketchInput(page, this, {
          changed: () => this.actions.changed(),
          save: (target) => void this.save(target),
        })
      }
    }
    if (!drawing) {
      for (const page of this.pages) {
        page.input?.detach()
        page.input = null
        page.redraw()
      }
      store.sketch.selection = null
    }
  }

  /**
   * The little bar that appears over a selection.
   *
   * Marking a passage should be one gesture away from having selected it —
   * reaching for a menu breaks the reading. Five colours and an underline,
   * which is all the Mac offers too, and it goes away the moment the
   * selection does.
   */
  private markBar: HTMLElement | null = null

  watchSelection() {
    on(document, 'selectionchange', () => this.updateMarkBar())
    on(this.scroll, 'scroll', () => this.hideMarkBar(), { passive: true } as never)
  }

  private updateMarkBar() {
    const selection = window.getSelection()
    if (!selection || selection.isCollapsed || selection.rangeCount === 0 || store.reader.drawing) {
      return this.hideMarkBar()
    }
    const range = selection.getRangeAt(0)
    const inside = (range.commonAncestorContainer instanceof Element
      ? range.commonAncestorContainer
      : range.commonAncestorContainer.parentElement)?.closest('.text-layer')
    if (!inside) return this.hideMarkBar()

    const rect = range.getBoundingClientRect()
    if (rect.width === 0 && rect.height === 0) return this.hideMarkBar()

    if (!this.markBar) {
      this.markBar = el('div', { class: 'mark-bar' })
      for (const name of MARK_COLOR_NAMES) {
        const colour = ({
          yellow: L('노랑', 'yellow'),
          green: L('초록', 'green'),
          blue: L('파랑', 'blue'),
          pink: L('분홍', 'pink'),
          purple: L('보라', 'purple'),
        } as Record<string, string>)[name] ?? name
        const swatch = el('button', {
          class: 'mark-swatch',
          title: L(`${colour} 형광펜`, `Highlight in ${colour}`),
          style: `background: ${cssColor(MARK_COLORS[name] as [number, number, number])}`,
        })
        // The selection has to survive the press, so the default mousedown
        // (which would collapse it) never happens.
        on(swatch, 'mousedown', (event: MouseEvent) => event.preventDefault())
        on(swatch, 'click', () => {
          this.markSelection('highlight', name)
          this.hideMarkBar()
        })
        this.markBar.append(swatch)
      }
      const underline = el('button', { class: 'mark-action', title: L('밑줄', 'Underline'), html: icon('line.solid') })
      on(underline, 'mousedown', (event: MouseEvent) => event.preventDefault())
      on(underline, 'click', () => {
        this.markSelection('underline', 'yellow')
        this.hideMarkBar()
      })
      this.markBar.append(underline)
      this.overlayHost.append(this.markBar)
    }

    const host = this.overlayHost.getBoundingClientRect()
    const size = this.markBar.getBoundingClientRect()
    const width = size.width || 190
    let left = rect.left + rect.width / 2 - host.left - width / 2
    left = Math.max(6, Math.min(left, host.width - width - 6))
    let top = rect.top - host.top - 38
    if (top < 4) top = rect.bottom - host.top + 8
    this.markBar.style.left = `${left}px`
    this.markBar.style.top = `${top}px`
    this.markBar.style.display = 'flex'
  }

  hideMarkBar() {
    if (this.markBar) this.markBar.style.display = 'none'
  }

  private noteCurrentPage() {
    // In single-page mode the scroll position says nothing about which page
    // is showing; the page is whatever was turned to.
    if (store.settings.pageLayout === 'single') return
    const middle = this.scroll.scrollTop + this.scroll.clientHeight / 2
    let current = 0
    for (const page of this.pages) {
      if (page.root.offsetTop <= middle) current = page.index
    }
    if (current !== store.reader.currentPage) {
      store.reader.currentPage = current
      this.updateFooter()
    }
  }

  scrollToPage(index: number) {
    const page = this.pages[index]
    if (!page) return
    this.scroll.scrollTo({ top: page.root.offsetTop - 14, behavior: 'smooth' })
  }

  update() {
    clear(this.header)
    const paper = store.papers.find((entry) => entry.id === store.selectedID)
    this.header.append(el('span', { class: 'reader-title', text: paper?.meta.displayTitle ?? '' }))
    if (paper) {
      const draw = el('button', {
        class: 'icon-button',
        title: L('쪽에 그리기', 'Draw on the Page'),
        'aria-pressed': String(store.reader.drawing),
        html: icon('pen'),
      })
      on(draw, 'click', () => {
        this.setDrawing(!store.reader.drawing)
        this.update()
        this.actions.changed()
      })
      this.header.append(draw)
    }
    this.updateFooter()
  }

  private updateFooter() {
    clear(this.footer)
    if (!this.document) return
    const position = el('span', {
      text: L(
        `${store.reader.currentPage + 1} / ${store.reader.pageCount}쪽`,
        `Page ${store.reader.currentPage + 1} of ${store.reader.pageCount}`,
      ),
    })
    this.footer.append(position)
    if (store.settings.pageLayout === 'single') {
      const turn = (label: string, by: number, disabled: boolean) => {
        const button = el('button', {
          class: 'icon-button',
          title: by < 0 ? L('이전 쪽', 'Previous page') : L('다음 쪽', 'Next page'),
          html: icon(label),
        })
        button.toggleAttribute('disabled', disabled)
        on(button, 'click', () => this.turnPage(by))
        return button
      }
      this.footer.append(el('div', { class: 'toolbar-group' }, [
        turn('chevron.left', -1, store.reader.currentPage === 0),
        turn('chevron.right', 1, store.reader.currentPage >= store.reader.pageCount - 1),
      ]))
    }
    this.footer.append(el('span', { text: `${Math.round(store.reader.zoom * 100)}%` }))
  }

  /** Redraws every page that has a drawing on it. */
  redrawAll() {
    for (const page of this.pages) page.redraw()
  }

  applyTint() {
    for (const page of this.pages) page.applyTint()
  }
}

/**
 * Groups a selection's client rectangles into one per line.
 *
 * `getClientRects` hands back a rectangle per text run, and a line of a
 * two-column paper is a dozen of them. A highlight drawn from those has a gap
 * at every word the typesetter kerned separately, so runs that sit on the same
 * baseline are merged into the line they belong to.
 */
interface Line {
  left: number
  right: number
  top: number
  bottom: number
}

const lineHeight = (line: Line) => line.bottom - line.top

function mergeIntoLines(rects: DOMRect[]): Line[] {
  const sorted = [...rects].sort((a, b) => a.top - b.top || a.left - b.left)
  const lines: Line[] = []
  for (const rect of sorted) {
    const middle = rect.top + rect.height / 2
    const line = lines.find(
      (candidate) =>
        middle > candidate.top - lineHeight(candidate) * 0.4 &&
        middle < candidate.bottom + lineHeight(candidate) * 0.4,
    )
    if (line) {
      line.left = Math.min(line.left, rect.left)
      line.right = Math.max(line.right, rect.right)
      line.top = Math.min(line.top, rect.top)
      line.bottom = Math.max(line.bottom, rect.bottom)
    } else {
      lines.push({ left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom })
    }
  }
  return lines
}
