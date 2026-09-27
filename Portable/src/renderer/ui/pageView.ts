/**
 * One page of a paper, and everything laid over it.
 *
 * Bottom to top: the print — the rendered page with the marks, what a search
 * found and the drawing on it (ink and shapes, drawn from the sidecars rather
 * than from the PDF's copies — the copies are hidden, exactly as the Mac
 * hides them under its overlay), in one box that a tint blends onto the
 * ground as one thing; under night, the pictures again as printed; the text
 * layer you select words in; and, with the pen out, a surface that takes the
 * mouse.
 *
 * A page is drawn when it comes near the view and let go of when it goes
 * far from it: its canvases emptied, its text layer taken down, and pdf.js
 * told to drop what it decoded. A 686-page scanned textbook read from cover
 * to cover used to keep every page it had passed — at the width of the
 * column and twice the pixels of the screen, a few hundred megabytes of
 * canvases nobody would see again.
 */
import type { Box, TextRun } from '../../shared/strokeSnap.js'
import { clear, el } from '../dom.js'
import { TextLayer, type PDFPageProxy } from '../pdf.js'
import { SketchElement } from '../../shared/sketch.js'
import { InkStroke } from '../../shared/ink.js'
import { drawElements, drawInk, drawMarks } from '../../shared/sketchRender.js'
import { linesFromRuns } from '../../shared/textLines.js'
import type { Mark } from '../../shared/marks.js'
import type { PageRendering } from '../../shared/pageTint.js'
import {
  applyInverseTransform, applyTransform, devicePixels, pageViewport, type PageShape, type Viewport,
} from '../../shared/readerMath.js'
import { PageImagesLayer, noteDrawnListMissing } from './pageImagesLayer.js'
import type { SketchInput } from './sketchInput.js'

/** A stretch of a page's text: where it starts and ends in the page's text. */
export interface TextRange {
  start: number
  end: number
}

/** A place found on a page, and whether it is the one being shown. */
export interface FindMark extends TextRange {
  current: boolean
}

/** A link on a page: where it is, and where it goes. */
export interface PageLink {
  /** `[x1, y1, x2, y2]` in the page's own coordinates. */
  rect: number[]
  /** Out of the paper, to the browser. */
  url?: string
  /** Inside the paper: a named or an explicit destination. */
  dest?: unknown
  /** A named action — NextPage, PrevPage, GoBack… */
  action?: string
}

/** What a page asks of the reader it belongs to. */
export interface PageOwner {
  /** Its page, fetched from the document the first time it is needed. */
  fetchPage(index: number): Promise<PDFPageProxy | null>
  /** Its own shape turned out other than the first page's: laid out again. */
  pageResized(page: PageView): void
}

type TextContent = { items: { str?: string; hasEOL?: boolean }[] }

export class PageView {
  root: HTMLElement
  canvas: HTMLCanvasElement
  /** Highlights and underlines, on a surface of their own. See `redraw`. */
  markCanvas: HTMLCanvasElement
  /** What a search found on this page — boxes over the words, multiplied
   *  onto the page like a highlight, but never written anywhere. */
  findLayer: HTMLElement
  findMarks: FindMark[] = []
  /** The runs the text layer was built from, and a span for each, in order.
   *  A range of the page's text is found on screen through these. */
  private textItems: { str: string; hasEOL: boolean }[] = []
  private textDivs: HTMLElement[] = []
  private textStarts: number[] = []
  drawCanvas: HTMLCanvasElement
  /** What a gesture draws while it lasts — handles, a marquee, a shape being
   *  dragged, a stroke being written — over the drawing, so a pointer move
   *  redraws this and not every stroke and shape on the page. */
  overlayCanvas: HTMLCanvasElement
  /**
   * The paper as printed and everything drawn onto it — the page, the marks,
   * what a search found, the drawing — in one box, so a tint can blend it
   * onto the ground as one thing: multiplied, so the paper's white falls away
   * and the ink stays; or turned to night and screened, so the paper's black
   * falls away and the ink is light. Either way no edge is left where the
   * page ends.
   */
  print: HTMLElement
  /** Under night, the page's pictures again as printed. */
  readonly images = new PageImagesLayer()
  textLayer: HTMLElement
  inputSurface: HTMLElement
  /** How the reader draws its pages now, and the ground under night. */
  private rendering: PageRendering = 'plain'
  private ground = '#000000'
  /** Whether the page canvas holds this layout's page yet. */
  private painted = false
  elements: SketchElement[] = []
  strokes: InkStroke[] = []
  marks: Mark[] = []
  /** The mark under the pointer, drawn lighter with an edge. */
  hoveredMarkID: string | null = null
  /** Mid-gesture elements the input surface is drawing itself. */
  hidden = new Set<string>()
  /** Pen strokes being moved, likewise left to the surface. */
  hiddenStrokes = new Set<number>()
  /** Another page's surface drawing over this one — a selection being
   *  carried here from the page it started on. */
  guest: ((context: CanvasRenderingContext2D) => void) | null = null
  /** The page's box, turn and unit — the first page's until its own arrives. */
  shape: PageShape
  /** This layout, from `shape` — made once, read on every pointer move. */
  viewport: Viewport | null = null
  /** The page's own proxy, once fetched; null again once let go of. */
  proxy: PDFPageProxy | null = null
  private proxyAsked: Promise<PDFPageProxy | null> | null = null
  private textAsked: Promise<TextContent | null> | null = null
  /** The render in progress or done for this layout, so a caller can wait
   *  for the words. Null when the page is not drawn at this layout. */
  private drawing: Promise<void> | null = null
  /** Every layout and every release starts a new one; a render that finds
   *  it changed after an await stops, and its canvas is not trusted. */
  private generation = 0
  private renderTask: { cancel: () => void } | null = null
  private textTask: { cancel: () => void } | null = null
  /** Near the view: a render cut short by a new layout starts again. */
  wanted = false
  private composeFrame = 0
  input: SketchInput | null = null

  constructor(
    readonly index: number,
    shape: PageShape,
    private readonly owner: PageOwner,
  ) {
    this.shape = shape
    this.canvas = el('canvas', { class: 'page-canvas' })
    this.markCanvas = el('canvas', { class: 'mark-canvas' })
    this.findLayer = el('div', { class: 'find-layer' })
    this.drawCanvas = el('canvas', { class: 'draw-canvas' })
    this.overlayCanvas = el('canvas', { class: 'draw-canvas draw-overlay' })
    this.print = el('div', { class: 'page-print' }, [
      this.canvas,
      this.markCanvas,
      this.findLayer,
      this.drawCanvas,
      this.overlayCanvas,
    ])
    this.textLayer = el('div', { class: 'text-layer' })
    this.inputSurface = el('div', { class: 'sketch-input' })
    this.root = el('div', { class: 'page', 'data-page': String(index) }, [
      this.print,
      this.images.canvas,
      this.textLayer,
      this.inputSurface,
    ])
  }

  /** Drawn, or being drawn, at this layout. */
  get rendered(): boolean {
    return this.drawing !== null
  }

  /** The page's proxy, fetched once. Its shape replaces the guess it was
   *  laid out with, and a page that turns out another size is laid out again. */
  fetchProxy(): Promise<PDFPageProxy | null> {
    if (this.proxy) return Promise.resolve(this.proxy)
    if (!this.proxyAsked) {
      this.proxyAsked = this.owner.fetchPage(this.index).then((proxy) => {
        this.proxyAsked = null
        if (!proxy) return null
        this.proxy = proxy
        const shape: PageShape = { view: [...(proxy.view as number[])], rotate: proxy.rotate, userUnit: (proxy as { userUnit?: number }).userUnit ?? 1 }
        const changed = shape.rotate !== this.shape.rotate || shape.userUnit !== this.shape.userUnit
          || shape.view.some((value, at) => Math.abs(value - this.shape.view[at]) > 0.01)
        this.shape = shape
        if (changed) {
          if (this.viewport) this.layout(this.viewport.scale)
          this.owner.pageResized(this)
        }
        return proxy
      })
    }
    return this.proxyAsked
  }

  layout(scale: number) {
    this.stop()
    const viewport = pageViewport(this.shape, scale)
    this.viewport = viewport
    this.root.style.width = `${Math.floor(viewport.width)}px`
    this.root.style.height = `${Math.floor(viewport.height)}px`
    // What pdf.js sizes the text layer with. Every span it makes carries
    // `font-size: calc(var(--scale-factor) * Npx)`, and with the variable
    // unset that declaration is invalid and dropped — so every run in the
    // paper inherited one size, whatever the text really was. Measured before
    // this: spans asking for 6.97px, 9.96px and 14.35px all came out 13px,
    // which is why a run's box bore no relation to its words and a highlight
    // drawn on that box was half again as tall as the line.
    this.root.style.setProperty('--scale-factor', String(scale))
  }

  /** Stops whatever is drawing: a render for the last layout paints nothing. */
  private stop() {
    this.generation += 1
    this.renderTask?.cancel()
    this.renderTask = null
    this.textTask?.cancel()
    this.textTask = null
    this.drawing = null
    this.painted = false
  }

  /**
   * Lets go of what the page holds for drawing: its canvases emptied, its
   * text layer taken down, pdf.js told to drop the page's decoded data.
   * What was drawn on it — marks, strokes, shapes — is kept; it is the page's
   * and costs nothing. Drawn again when it comes back.
   */
  release() {
    this.wanted = false
    this.stop()
    if (this.composeFrame) cancelAnimationFrame(this.composeFrame)
    this.composeFrame = 0
    for (const canvas of [this.canvas, this.markCanvas, this.drawCanvas, this.overlayCanvas]) {
      canvas.width = 0
      canvas.height = 0
    }
    this.images.clear()
    clear(this.textLayer)
    clear(this.findLayer)
    this.textItems = []
    this.textDivs = []
    this.textStarts = []
    this.textAsked = null
    this.proxy?.cleanup()
  }

  /**
   * The page's links — a citation to its reference, a figure's number to the
   * figure, a URL — read once from the PDF's own link annotations. Nothing is
   * laid over the page for them: a press is looked up here instead
   * (`Reader.followLink`), the way PDFKit follows a link on the Mac.
   */
  private linksRead: Promise<PageLink[]> | null = null
  links: PageLink[] = []

  pageLinks(): Promise<PageLink[]> {
    if (!this.linksRead) {
      this.linksRead = this.fetchProxy()
        .then((proxy) => proxy ? proxy.getAnnotations({ intent: 'display' }) : [])
        .then((annotations: unknown[]) => (annotations as {
          subtype?: string; rect?: number[]; url?: string; dest?: unknown; action?: string
        }[])
          .filter((one) => one.subtype === 'Link' && Array.isArray(one.rect) && (one.url || one.dest != null || one.action))
          .map((one) => ({ rect: one.rect as number[], url: one.url, dest: one.dest, action: one.action })))
        .catch(() => [])
        .then((links: PageLink[]) => {
          this.links = links
          return links
        })
    }
    return this.linksRead
  }

  /** The link under a point of the page, in the page's own coordinates. */
  linkAt(point: { x: number; y: number }): PageLink | null {
    for (const link of this.links) {
      const [x1, y1, x2, y2] = link.rect
      if (point.x >= Math.min(x1, x2) && point.x <= Math.max(x1, x2)
        && point.y >= Math.min(y1, y2) && point.y <= Math.max(y1, y2)) return link
    }
    return null
  }

  private get transform(): number[] {
    return (this.viewport ?? pageViewport(this.shape, 1)).transform
  }

  /** Page coordinates from a point in the page element's own box. */
  toPage(x: number, y: number): { x: number; y: number } {
    return applyInverseTransform(this.transform, x, y)
  }

  /** And back, for placing a handle or a text box over the page. */
  toView(x: number, y: number): { x: number; y: number } {
    return applyTransform(this.transform, x, y)
  }

  /** Page coordinates from a point in the window, kept on the page — for a
   *  drag, which may run off the paper and still means its edge. */
  toPageFromClient(clientX: number, clientY: number): { x: number; y: number } {
    const box = this.root.getBoundingClientRect()
    const p = this.toPage(clientX - box.left, clientY - box.top)
    const view = this.shape.view
    return {
      x: Math.min(Math.max(p.x, view[0]), view[2]),
      y: Math.min(Math.max(p.y, view[1]), view[3]),
    }
  }

  /** The same, or null off the paper — for a click, which in the gap
   *  between two pages means neither of them (a mark at the page's edge
   *  used to answer a click beside it). */
  pointOnPage(clientX: number, clientY: number): { x: number; y: number } | null {
    const box = this.root.getBoundingClientRect()
    const x = clientX - box.left
    const y = clientY - box.top
    if (x < 0 || y < 0 || x > box.width || y > box.height) return null
    return this.toPage(x, y)
  }

  /** The page's text runs, asked of pdf.js once while the page is held. */
  textContent(): Promise<TextContent | null> {
    if (!this.textAsked) {
      this.textAsked = this.fetchProxy()
        .then((proxy) => proxy ? proxy.getTextContent() as Promise<TextContent> : null)
        .catch(() => null)
    }
    return this.textAsked
  }

  /**
   * Draws the page and builds its text layer, once per layout. Asked again
   * while it is under way, it hands back the same promise — which is how a
   * search waits for the words of a page it has just scrolled to. A render a
   * new layout cut short hands over to the render at the new size, so the
   * caller that waited is not left with an empty page to scroll to.
   */
  render(): Promise<void> {
    if (!this.viewport) return Promise.resolve()
    if (this.drawing) return this.drawing
    const generation = (this.generation += 1)
    const drawing = this.draw(generation).then(() => {
      if (generation === this.generation || !this.wanted) return undefined
      return this.render()
    })
    this.drawing = drawing
    return drawing
  }

  private async draw(generation: number) {
    const proxy = await this.fetchProxy()
    const layout = this.viewport
    if (!proxy || !layout || generation !== this.generation) return
    const dpr = devicePixels(window.devicePixelRatio)
    const viewport = proxy.getViewport({ scale: layout.scale })
    this.canvas.width = Math.floor(viewport.width * dpr)
    this.canvas.height = Math.floor(viewport.height * dpr)
    const context = this.canvas.getContext('2d', { alpha: false })!
    // Paper before pdf.js paints it: a canvas sized afresh is black until the
    // page's background arrives, and under night black is what turns white.
    context.fillStyle = '#ffffff'
    context.fillRect(0, 0, this.canvas.width, this.canvas.height)
    const task = proxy.render({
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
      // Cancelled by a new layout or by the page being let go of.
      return
    }
    if (generation !== this.generation) return
    this.renderTask = null
    this.painted = true
    noteDrawnListMissing(proxy)
    await this.renderText(viewport, generation)
    if (generation !== this.generation) return
    this.redraw()
    this.drawFind()
    // The pictures, the first time night meets this page.
    if (this.rendering === 'night' && !this.images.found) void this.findImages()
  }

  private async renderText(viewport: unknown, generation: number) {
    // Cleared before the text is asked for, and built only if this is still
    // the render the page wants: two layers used to land in one container
    // when a layout came while the text was on its way.
    clear(this.textLayer)
    this.textItems = []
    this.textDivs = []
    this.textStarts = []
    const source = await this.textContent()
    if (!source || generation !== this.generation) return
    try {
      const layer = new (TextLayer as unknown as new (options: unknown) => {
        render: () => Promise<void>
        cancel: () => void
        textDivs: HTMLElement[]
      })({
        textContentSource: source,
        container: this.textLayer,
        viewport,
      })
      this.textTask = layer
      await layer.render()
      if (generation !== this.generation) return
      this.textTask = null
      // The layer makes one span for every run that has a string, in order
      // — the same runs the page's text is made of.
      const items = source.items
        .filter((item) => item.str !== undefined)
        .map((item) => ({ str: item.str!, hasEOL: Boolean(item.hasEOL) }))
      this.textItems = items
      this.textDivs = layer.textDivs
      let at = 0
      for (const item of items) {
        this.textStarts.push(at)
        at += item.str.length + (item.hasEOL ? 1 : 0)
      }
    } catch {
      // A page with no text — a scan, a figure — simply has nothing to select.
      this.textItems = []
      this.textDivs = []
      this.textStarts = []
    }
  }

  /** How many runs the text layer holds — for a probe. */
  get textRunCount(): number {
    return this.textDivs.length
  }

  /** The page's text as the text layer holds it: every run, and a line break
   *  after each that ends a line. The index reads the page the same way. */
  layerText(): string | null {
    if (this.textDivs.length === 0) return null
    return this.textItems.map((item) => item.str + (item.hasEOL ? '\n' : '')).join('')
  }

  /**
   * Where a stretch of the page's text is on screen, as the lines it runs
   * along — in the page's own box, as fractions of it, so a box stays over
   * its words when the page is laid out at another size.
   */
  rangeBoxes(range: TextRange): { x: number; y: number; width: number; height: number }[] {
    if (this.textDivs.length === 0) return []
    const rects: DOMRect[] = []
    const dom = document.createRange()
    for (let index = 0; index < this.textItems.length; index += 1) {
      const start = this.textStarts[index]
      const item = this.textItems[index]
      const end = start + item.str.length
      if (end <= range.start) continue
      if (start >= range.end) break
      const node = this.textDivs[index]?.firstChild
      if (!node || !this.textDivs[index].isConnected) continue
      const from = Math.max(range.start - start, 0)
      const to = Math.min(range.end - start, item.str.length)
      if (from >= to) continue
      dom.setStart(node, from)
      dom.setEnd(node, to)
      for (const rect of dom.getClientRects()) if (rect.width > 0.5 && rect.height > 0.5) rects.push(rect)
    }
    const box = this.root.getBoundingClientRect()
    if (box.width === 0 || box.height === 0) return []
    return linesFromRuns(rects).map((line) => ({
      x: (line.left - box.left) / box.width,
      y: (line.top - box.top) / box.height,
      width: (line.right - line.left) / box.width,
      height: (line.bottom - line.top) / box.height,
    }))
  }

  /**
   * The page's words as the text layer sets them — its lines and its runs,
   * in the page's own coordinates — for a highlighter stroke to be fitted to
   * (`strokeSnap.ts`). Empty while the text layer is not drawn.
   */
  textGeometry(): { lines: Box[]; runs: TextRun[] } {
    const rects: DOMRect[] = []
    const runs: TextRun[] = []
    const toPage = (rect: DOMRect): Box => {
      const a = this.toPageFromClient(rect.left, rect.top)
      const b = this.toPageFromClient(rect.right, rect.bottom)
      return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(b.x - a.x), height: Math.abs(b.y - a.y) }
    }
    for (let index = 0; index < this.textDivs.length; index += 1) {
      const div = this.textDivs[index]
      const text = this.textItems[index]?.str ?? ''
      if (!div.isConnected || !text.trim()) continue
      const rect = div.getBoundingClientRect()
      if (rect.width <= 0.5 || rect.height <= 0.5) continue
      rects.push(rect)
      runs.push({ box: toPage(rect), text })
    }
    const lines = linesFromRuns(rects).map((line) => toPage(new DOMRect(line.left, line.top, line.right - line.left, line.bottom - line.top)))
    return { lines, runs }
  }

  /** Puts the found places' boxes on the page, or takes them away. A page
   *  not drawn has no words to put them over; it draws them when it is. */
  drawFind() {
    clear(this.findLayer)
    if (this.findMarks.length === 0 || this.textDivs.length === 0) return
    for (const mark of this.findMarks) {
      for (const box of this.rangeBoxes(mark)) {
        const node = el('div', { class: mark.current ? 'find-box current' : 'find-box' })
        node.style.left = `${box.x * 100}%`
        node.style.top = `${box.y * 100}%`
        node.style.width = `${box.width * 100}%`
        node.style.height = `${box.height * 100}%`
        this.findLayer.append(node)
      }
    }
  }

  /** The first box of the current find mark, in the page's own pixels. */
  currentBox(): { x: number; y: number; width: number; height: number } | null {
    const current = this.findMarks.find((mark) => mark.current)
    if (!current) return null
    const boxes = this.rangeBoxes(current)
    if (boxes.length === 0) return null
    const width = this.root.clientWidth
    const height = this.root.clientHeight
    const top = Math.min(...boxes.map((one) => one.y))
    const bottom = Math.max(...boxes.map((one) => one.y + one.height))
    const left = Math.min(...boxes.map((one) => one.x))
    const right = Math.max(...boxes.map((one) => one.x + one.width))
    return { x: left * width, y: top * height, width: (right - left) * width, height: (bottom - top) * height }
  }

  /** A canvas the size of the page, cleared, in page coordinates. */
  private surface(canvas: HTMLCanvasElement): CanvasRenderingContext2D | null {
    if (!this.viewport) return null
    const dpr = devicePixels(window.devicePixelRatio)
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
    return context
  }

  /**
   * The marks and the drawing, redrawn from the sidecars into page
   * coordinates — on a page that is drawn; a page far from the view draws
   * them when it comes back.
   *
   * Marks go on a surface of their own, under the pen's, and that surface is
   * multiplied onto the page by the browser. The Mac learned this the hard
   * way and says so in `MarkOverlayView`: a blend mode set while drawing only
   * blends against the surface's own contents, which are empty, so a
   * highlight came out as solid paint over the words. It has to be the
   * finished layer that blends with the page under it. The pen's surface
   * blends with nothing — ink is paint, and a white shape has to stay white.
   */
  redraw() {
    if (!this.drawing) return
    // A page with no marks on it costs no surface: sizing a canvas to the page
    // reserves the pixels whether or not anything is drawn, and most pages of
    // most papers are never marked.
    if (this.marks.length > 0) {
      const marks = this.surface(this.markCanvas)
      if (marks) drawMarks(this.marks, marks, this.hoveredMarkID)
    } else if (this.markCanvas.width !== 0) {
      this.markCanvas.width = 0
      this.markCanvas.height = 0
    }
    if (this.strokes.length > 0 || this.elements.length > 0) {
      const context = this.surface(this.drawCanvas)
      if (context) {
        drawInk(this.hiddenStrokes.size === 0 ? this.strokes : this.strokes.filter((_, index) => !this.hiddenStrokes.has(index)), context)
        drawElements(this.hidden.size === 0 ? this.elements : this.elements.filter((element) => !this.hidden.has(element.id)), context)
      }
    } else if (this.drawCanvas.width !== 0) {
      this.drawCanvas.width = 0
      this.drawCanvas.height = 0
    }
    this.redrawOverlay()
    // The pictures carry a copy of what is drawn over them — once a frame,
    // however many strokes a frame brings.
    if (this.rendering === 'night') this.composeSoon()
  }

  /** Only the gesture's layer: handles, a marquee, what is in the hand. */
  redrawOverlay() {
    if (!this.drawing) return
    if (this.input || this.guest) {
      const context = this.surface(this.overlayCanvas)
      if (context) {
        this.input?.drawOverlay(context)
        this.guest?.(context)
      }
    } else if (this.overlayCanvas.width !== 0) {
      this.overlayCanvas.width = 0
      this.overlayCanvas.height = 0
    }
  }

  /**
   * How the page is drawn for the reader's tint. The blending itself is CSS
   * on the reader (`data-rendering`); what is left for the page is its
   * pictures, which night must not turn into negatives.
   *
   * @param ground what the page is screened onto under night — the tint's
   *   ground, or the panel itself under Glass — for the drawing laid over a
   *   picture, which has to come out the colour it is beside the picture.
   */
  applyTint(rendering: PageRendering, ground: string) {
    this.rendering = rendering
    this.ground = ground
    if (rendering !== 'night') {
      this.images.clear()
      return
    }
    if (this.images.found) this.composeSoon()
    else if (this.painted) void this.findImages()
  }

  private async findImages() {
    const proxy = await this.fetchProxy()
    if (!proxy) return
    await this.images.find(proxy, this.shape.view)
    this.composeSoon()
  }

  private composeSoon() {
    if (this.composeFrame) return
    this.composeFrame = requestAnimationFrame(() => {
      this.composeFrame = 0
      this.composeImages()
    })
  }

  private composeImages() {
    if (this.rendering !== 'night') return this.images.clear()
    // Not drawn yet at this size: what is there is the last size's, and it
    // scales with the page until the new one arrives.
    if (!this.painted || !this.viewport) return
    this.images.compose({
      canvas: this.canvas,
      markCanvas: this.markCanvas,
      drawCanvas: this.drawCanvas,
      transform: this.viewport.transform,
      dpr: devicePixels(window.devicePixelRatio),
      hasMarks: this.marks.length > 0,
      hasDrawing: this.strokes.length > 0 || this.elements.length > 0,
    }, this.ground)
  }

  /** For a probe: the pictures this page found. */
  imageReport() {
    return this.images.report()
  }

  setDrawing(on: boolean) {
    this.root.setAttribute('data-drawing', String(on))
  }

  destroy() {
    this.release()
    this.input?.detach()
    this.input = null
    this.proxy = null
  }
}
