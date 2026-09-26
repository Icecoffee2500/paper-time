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
import { freshReaderState, store, type ReaderState } from '../state.js'
import { PAPER_DRAG_TYPE } from '../../shared/split.js'
import { loadDocument, TextLayer, type PDFDocumentProxy, type PDFPageProxy } from '../pdf.js'
import { headBytes, headLine, rightsHandler, type ByteTrouble, type PDFLock } from '../../shared/pdfLock.js'
import type { KeptReason } from '../../shared/api.js'
import {
  guessKind, hasAbstract, hasIdentifier, hasReferences, namesACourse, type DocumentKind,
} from '../../shared/documentKind.js'

/** What the main process already worked out about these bytes, if anything. */
export type Reason = { trouble?: ByteTrouble; size?: number; again?: () => void }

/** The handler as it is written in the file, said the way a person would. */
const SERVICE_NAMES: Record<string, string> = {
  MicrosoftIRMServices: L('Microsoft Purview(회사 IRM)', 'Microsoft Purview'),
  FoxitIRM: 'Foxit IRM',
  'Adobe.PubSec': L('인증서 보안', 'Certificate security'),
  EBX_HANDLER: 'Adobe DRM',
}
import { SketchElement } from '../../shared/sketch.js'
import { InkStroke } from '../../shared/ink.js'
import { drawElements, drawInk, drawMarks } from '../../shared/sketchRender.js'
import { linesFromRuns } from '../../shared/textLines.js'
import { foldText, foldWithMap, type Folded } from '../../shared/textFold.js'
import {
  MARK_COLORS,
  MARK_COLOR_NAMES,
  cssColor,
  rectToQuad,
  type Mark,
  type MarkKind,
} from '../../shared/marks.js'
import { makeUUID } from '../../shared/coding.js'
import { call, platform } from '../bridge.js'
import { withKey } from '../../shared/shortcuts.js'
import {
  attachSketchInput,
  hitsDrawing,
  resetSketchInput,
  sketchEditingFor,
  undoStack,
  type SketchInput,
  type SketchInputHost,
} from './sketchInput.js'
import { sketchEditor } from './sketchEditing.js'
import { marksSnapshot, pagesOf, type Snapshot } from './sketchUndo.js'
import { installMathProvider, removeMathListener } from '../sketchMath.js'
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
  /** A press landed in this reader: it is the one in use. */
  activated?: () => void
  /** The × in a pane's title strip: take the pane out and close the paper. */
  close?: () => void
  /** What this document looks like, once its text can be read. Only asked
   *  when nobody has guessed yet; the answer to "paper or document?" is the
   *  reader's and is never set from here. */
  guessed?: (kind: DocumentKind) => void
  /** The paper's own file name, which is half of what says it belongs to a
   *  course: a deck's first page often says only the week's title, while the
   *  file on disk says lecture06.pdf. */
  fileName?: () => string
  /** Show the file in the desktop's own file manager. Offered when the app
   *  cannot open it: the next thing to try is the app the company registered,
   *  and that is reached from the folder. */
  reveal?: () => void
  /** The highlights and underlines changed — the Marks tab lists them. */
  marksChanged?: () => void
  /** A mark on the page was clicked: the Marks tab brings its row forward. */
  markShown?: (id: string) => void
  /** A link was followed, or Back walked the paper: the arrows may change. */
  historyChanged?: () => void
}

/** A place in a paper: how far down, and down how much. */
export interface ReaderPlace {
  top: number
  of: number
}

export interface ReaderOptions {
  /** One of several side by side: the title strip is a handle and has an ×. */
  pane?: boolean
  /** The state this reader keeps — shared with the store while it is in focus. */
  state?: ReaderState
}

/** A stretch of a page's text: where it starts and ends in the page's text. */
export interface TextRange {
  start: number
  end: number
}

/** A place found on a page, and whether it is the one being shown. */
interface FindMark extends TextRange {
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

/** Where the reader stands in a paper, for the history links make. */
interface DocumentPlace {
  page: number
  top: number
  of: number
}

/** The gutter between the two pages of a book's spread, in the window's pixels. */
const BOOK_GUTTER = 24

/** One of the five mark colours, said in the window's language. */
function colourWord(name: string): string {
  return ({
    yellow: L('노랑', 'yellow'),
    green: L('초록', 'green'),
    blue: L('파랑', 'blue'),
    pink: L('분홍', 'pink'),
    purple: L('보라', 'purple'),
  } as Record<string, string>)[name] ?? name
}

/** Which of the five a mark's colour is nearest — the one its editor rings. */
function nearestColourName(rgb: [number, number, number]): string {
  let best = MARK_COLOR_NAMES[0]
  let closest = Infinity
  for (const name of MARK_COLOR_NAMES) {
    const [r, g, b] = MARK_COLORS[name]
    const distance = (r - rgb[0]) ** 2 + (g - rgb[1]) ** 2 + (b - rgb[2]) ** 2
    if (distance < closest) {
      closest = distance
      best = name
    }
  }
  return best
}

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
  textLayer: HTMLElement
  inputSurface: HTMLElement
  tint: HTMLElement
  elements: SketchElement[] = []
  strokes: InkStroke[] = []
  marks: Mark[] = []
  /** Mid-gesture elements the input surface is drawing itself. */
  hidden = new Set<string>()
  /** Pen strokes being moved, likewise left to the surface. */
  hiddenStrokes = new Set<number>()
  /** Another page's surface drawing over this one — a selection being
   *  carried here from the page it started on. */
  guest: ((context: CanvasRenderingContext2D) => void) | null = null
  viewport: { width: number; height: number; transform: number[]; scale: number; rotation: number } | null = null
  rendered = false
  /** The render in progress or done, so a caller can wait for the words. */
  private drawing: Promise<void> | null = null
  private generation = 0
  private renderTask: { cancel: () => void } | null = null
  private textTask: { cancel: () => void } | null = null
  input: SketchInput | null = null

  constructor(
    readonly index: number,
    readonly proxy: PDFPageProxy,
    private readonly owner: Reader,
  ) {
    this.canvas = el('canvas', { class: 'page-canvas' })
    this.markCanvas = el('canvas', { class: 'mark-canvas' })
    this.findLayer = el('div', { class: 'find-layer' })
    this.drawCanvas = el('canvas', { class: 'draw-canvas' })
    this.textLayer = el('div', { class: 'text-layer' })
    this.inputSurface = el('div', { class: 'sketch-input' })
    this.tint = el('div', { class: 'page-tint' })
    this.root = el('div', { class: 'page', 'data-page': String(index) }, [
      this.canvas,
      this.markCanvas,
      this.findLayer,
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
    // What pdf.js sizes the text layer with. Every span it makes carries
    // `font-size: calc(var(--scale-factor) * Npx)`, and with the variable
    // unset that declaration is invalid and dropped — so every run in the
    // paper inherited one size, whatever the text really was. Measured before
    // this: spans asking for 6.97px, 9.96px and 14.35px all came out 13px,
    // which is why a run's box bore no relation to its words and a highlight
    // drawn on that box was half again as tall as the line.
    this.root.style.setProperty('--scale-factor', String(scale))
    this.rendered = false
    this.drawing = null
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
      this.linksRead = this.proxy.getAnnotations({ intent: 'display' })
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

  /** Page coordinates from a point in the window, kept on the page. */
  toPageFromClient(clientX: number, clientY: number): { x: number; y: number } {
    const box = this.root.getBoundingClientRect()
    const p = this.toPage(clientX - box.left, clientY - box.top)
    const view = this.proxy.getViewport({ scale: 1 }).viewBox as number[]
    return {
      x: Math.min(Math.max(p.x, view[0]), view[2]),
      y: Math.min(Math.max(p.y, view[1]), view[3]),
    }
  }

  /**
   * Draws the page and builds its text layer, once per layout. Asked again
   * while it is under way, it hands back the same promise — which is how a
   * search waits for the words of a page it has just scrolled to.
   */
  render(): Promise<void> {
    if (!this.viewport) return Promise.resolve()
    if (this.rendered && this.drawing) return this.drawing
    this.rendered = true
    const generation = (this.generation += 1)
    this.drawing = this.draw(generation)
    return this.drawing
  }

  private async draw(generation: number) {
    if (!this.viewport) return
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
      // Cancelled by a newer render, which owns the page now.
      if (generation === this.generation) {
        this.rendered = false
        this.drawing = null
      }
      return
    }
    await this.renderText(viewport)
    this.redraw()
    this.drawFind()
  }

  private async renderText(viewport: unknown) {
    this.textTask?.cancel?.()
    clear(this.textLayer)
    try {
      const source = await this.proxy.getTextContent()
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
      // The layer makes one span for every run that has a string, in order
      // — the same runs the page's text is made of.
      const items = (source.items as { str?: string; hasEOL?: boolean }[])
        .filter((item) => item.str !== undefined)
        .map((item) => ({ str: item.str!, hasEOL: Boolean(item.hasEOL) }))
      this.textItems = items
      this.textDivs = layer.textDivs
      this.textStarts = []
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

  /** Puts the found places' boxes on the page, or takes them away. */
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
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
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
   * coordinates.
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
    // A page with no marks on it costs no surface: sizing a canvas to the page
    // reserves the pixels whether or not anything is drawn, and most pages of
    // most papers are never marked.
    if (this.marks.length > 0) {
      const marks = this.surface(this.markCanvas)
      if (marks) drawMarks(this.marks, marks)
    } else if (this.markCanvas.width !== 0) {
      this.markCanvas.width = 0
      this.markCanvas.height = 0
    }
    const context = this.surface(this.drawCanvas)
    if (!context) return
    drawInk(this.hiddenStrokes.size === 0 ? this.strokes : this.strokes.filter((_, index) => !this.hiddenStrokes.has(index)), context)
    drawElements(this.hidden.size === 0 ? this.elements : this.elements.filter((element) => !this.hidden.has(element.id)), context)
    this.input?.drawOverlay(context)
    this.guest?.(context)
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
  /** Page count, page, zoom and whether the pen is out — this reader's own. */
  readonly state: ReaderState
  readonly isPane: boolean
  private observer: IntersectionObserver | null = null
  private generation = 0
  /**
   * Why what was made here stays out of the file, when it does. Said in the
   * footer, where the Mac says it, in the voice of a state and not of an
   * error: nothing was lost, and nothing needs doing.
   */
  private kept: KeptReason | null = null
  private readonly onSelectionChange = () => this.updateMarkBar()
  private readonly onMathReady = () => this.redrawAll()

  constructor(private readonly actions: ReaderActions, options: ReaderOptions = {}) {
    this.state = options.state ?? freshReaderState()
    this.isPane = options.pane ?? false
    this.scroll.append(this.pagesBox)
    // Outside the scroll view: the tool rack and the style panel belong to the
    // reader, not to the page under it, and a rack that scrolled away with the
    // paper would be gone the moment you needed it.
    this.overlayHost.className = 'reader-overlay'
    this.node = el('div', { class: 'panel reader-panel' }, [
      this.header, this.scroll, this.overlayHost, this.footer,
    ])
    if (this.isPane) this.node.classList.add('pane')
    // A press anywhere in the reader — the page, the strip, the footer —
    // makes it the one in use: the pane in focus, and a paper kept open.
    on(this.node, 'pointerdown', () => this.actions.activated?.())
    on(this.scroll, 'scroll', () => this.noteCurrentPage(), { passive: true } as never)
    on(this.scroll, 'wheel', (event: WheelEvent) => {
      // Ctrl or ⌘ with the wheel is zoom everywhere else; it should be here.
      if (!(event.ctrlKey || event.metaKey)) return
      event.preventDefault()
      this.zoomBy(event.deltaY < 0 ? 1.1 : 1 / 1.1, { soon: true })
    })
    // A click on something drawn — a shape, a card, a stroke — takes the
    // pencil out by itself and goes straight to selecting it, so what was
    // drawn is never a picture you have to unlock first. The same press then
    // goes to the page's surface, which was not there to receive it.
    on(this.pagesBox, 'pointerdown', (event: PointerEvent) => {
      if (this.state.drawing || event.button !== 0) return
      const page = this.pageContaining(event.target as Node)
      if (!page || !hitsDrawing(page, page.toPageFromClient(event.clientX, event.clientY))) return
      this.setDrawing(true)
      this.update()
      this.actions.changed()
      page.input?.press(event)
    })
    // A click on a mark — a press, not a drag across it, which is a
    // selection — brings up its controls, as the Mac's click on a mark does.
    // A press anywhere else puts them away.
    // A link in the paper goes where it points — a citation to its
    // reference, a URL to the browser — ahead of any mark under it.
    on(this.pagesBox, 'click', (event: MouseEvent) => {
      if (this.state.drawing || event.button !== 0) return
      const selection = window.getSelection()
      if (selection && !selection.isCollapsed) return
      const page = this.pageContaining(event.target as Node) ?? this.pageAtClient(event.clientX, event.clientY)
      if (!page) return this.hideMarkEditor()
      const point = page.toPageFromClient(event.clientX, event.clientY)
      void page.pageLinks().then(() => {
        const link = page.linkAt(point)
        if (link) {
          this.hideMarkEditor()
          void this.followLink(link)
          return
        }
        const mark = this.markAt(page, point)
        if (mark && !mark.id.startsWith('foreign-')) this.showMarkEditor(page, mark)
        else this.hideMarkEditor()
      })
    })
    // Over a link the pointer says so, and a URL shows where it goes.
    on(this.pagesBox, 'mousemove', (event: MouseEvent) => {
      if (this.state.drawing) return
      this.hover = { x: event.clientX, y: event.clientY, target: event.target as Node }
      if (this.hoverFrame) return
      this.hoverFrame = requestAnimationFrame(() => {
        this.hoverFrame = 0
        void this.updateHover()
      })
    })
    on(this.pagesBox, 'mouseleave', () => this.showOverLink(null))
    // A formula's picture arrives after the card was drawn; the page is
    // drawn again when it does.
    installMathProvider(this.onMathReady)
    on(document, 'selectionchange', this.onSelectionChange)
    on(this.scroll, 'scroll', () => this.hideMarkBar(), { passive: true } as never)
  }

  /** Takes the reader down for good: its pages, its document, its listeners. */
  dispose() {
    this.close()
    document.removeEventListener('selectionchange', this.onSelectionChange)
    removeMathListener(this.onMathReady)
    this.node.remove()
  }

  /** The page under a point in the window, if any is. */
  pageAtClient(clientX: number, clientY: number): PageView | null {
    for (const page of this.pages) {
      if (page.root.style.display === 'none') continue
      const box = page.root.getBoundingClientRect()
      if (clientX >= box.left && clientX <= box.right && clientY >= box.top && clientY <= box.bottom) return page
    }
    return null
  }

  /** Puts a page — or the several pages of one step — back the way an undo
   *  snapshot has them, and writes them. */
  restore(snapshot: Snapshot) {
    for (const part of pagesOf(snapshot)) {
      const page = this.pages[part.pageIndex]
      if (!page) continue
      if (part.marks) {
        // A step of the marks touches the marks and nothing else.
        page.marks = marksSnapshot(part.pageIndex, part.marks).marks ?? []
        page.redraw()
        void this.saveMarks(page)
        this.hideMarkEditor()
        this.actions.marksChanged?.()
        continue
      }
      page.elements = part.elements.map((element) => element.copy())
      page.strokes = part.strokes.map((stroke) => stroke.translated({ x: 0, y: 0 }))
      page.redraw()
      void this.save(page)
    }
  }

  get overlayContainer(): HTMLElement {
    return this.overlayHost
  }

  async open(id: string, bytes: Uint8Array, why?: Reason) {
    const generation = ++this.generation
    this.close()
    this.paperID = id
    try {
      const document = await loadDocument(bytes, (wrong) => this.askPassword(generation, wrong))
      if (!document) return
      if (generation !== this.generation) {
        document.destroy()
        return
      }
      this.document = document
      this.state.pageCount = document.numPages
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
      void this.guessKindIfAsked(generation, document)
      this.update()
    } catch (error) {
      if (generation !== this.generation) return
      const message = String(error)
      // pdf.js implements the standard handler and no other. A file locked by
      // a certificate or a company's rights server arrives here.
      if (/unknown encryption method|Unknown crypto|unsupported encryption algorithm/i.test(message)) {
        this.showLocked({ kind: 'rights', handler: rightsHandler(bytes) ?? '' })
        return
      }
      if (/giving up on the password|PasswordException/i.test(message)) return
      // pdf.js says "Invalid PDF structure." to everything it cannot find a
      // catalogue in — a file still arriving, a placeholder, a container,
      // random bytes. Saying "the file may be damaged" to all of them is what
      // sent this bug hunting for corruption in a file Acrobat opens fine.
      if (why?.trouble === 'wrapped') {
        // A container that named nobody is still a container, and the locked
        // sentence is the true one for it. Said only now, after pdf.js has
        // actually failed — the shape alone was never proof enough to refuse
        // a file with.
        this.showLocked({ kind: 'rights', handler: rightsHandler(bytes) ?? '' })
        return
      }
      if (why?.trouble) {
        this.showTrouble(why.trouble, why.size ?? bytes.length, why.again, message, headBytes(bytes), headLine(bytes))
        return
      }
      this.notice(
        L('이 PDF를 열 수 없어요', "Paper Time can't open this PDF"),
        L('파일이 깨졌을 수 있어요. 다른 뷰어에서도 안 열리면 파일 쪽 문제예요.',
          'The file may be damaged. If another reader cannot open it either, the file is the problem.'),
        message,
        why?.again ? this.againButton(why.again) : undefined,
      )
    } finally {
      // Whoever was waiting for this paper — a search sending the reader to a
      // line in it — is told it is in, or that it never will be.
      if (generation === this.generation) {
        for (const waiting of this.waiting.splice(0)) waiting(this.document !== null && this.pages.length > 0)
      }
    }
  }

  private waiting: ((opened: boolean) => void)[] = []

  /** Resolves once the paper is open — at once if it already is — with
   *  whether it opened at all. */
  whenOpen(): Promise<boolean> {
    if (this.document && this.pages.length > 0) return Promise.resolve(true)
    return new Promise((resolve) => this.waiting.push(resolve))
  }

  /**
   * What is wrong with the bytes, said in the words that fit it.
   *
   * These all arrive at pdf.js as the same six words, so the telling apart
   * happens before it is asked and the answer is handed here. The parser's
   * own sentence is kept in the fine line: it is the string that made this
   * diagnosable, and a report with nothing to grep for is a report nobody
   * can act on.
   */
  showTrouble(
    trouble: ByteTrouble, size: number, again?: () => void,
    detail?: string, head?: string, line?: string | null,
  ) {
    const megabytes = (size / 1_000_000).toFixed(1)
    const [title, body] = trouble === 'opaque' && line
      ? [
        L('PDF 자리에 글자가 들어 있어요', 'There is text where the PDF should be'),
        L('이 파일에는 PDF 대신 짧은 글자만 있어요. 원본이 다른 곳에 있다는 쪽지이거나, 회사 보안 '
          + '프로그램이 등록된 앱에만 원본을 주고 있는 거예요. 아래 첫 줄이 어느 쪽인지 말해 주니, '
          + '회사 IT에 그대로 보여주세요. 파일 탐색기에서 한 번 열어 본 뒤 «다시 열기»를 누르면 '
          + '원본이 따라오는 경우도 있어요.',
          'This file holds a short piece of text instead of a PDF. Either it is a note saying the '
          + 'real file lives somewhere else, or a security agent is giving the real file only to the '
          + 'readers your company registered. The first line below says which — show it to your IT '
          + 'desk as it stands. Opening the file once from your file manager and then pressing Try '
          + 'Again sometimes brings the real one across.'),
      ]
      : trouble === 'opaque'
      ? [
        L('이 파일을 이 앱에는 다르게 보여주고 있어요', 'Something is handing this app a different file'),
        L('파일 자리에 PDF가 아닌 것이 있어요. 같은 파일이 Acrobat에서는 열리고 여기서는 안 열린다면, '
          + '회사의 보안 프로그램이 등록된 앱에만 원본을 주고 있는 거예요. 그건 이 앱이 열 수 없어요.',
          'There is something other than a PDF where the file should be. If the same file opens in '
          + "Acrobat but not here, a security agent is giving the real file only to the readers your "
          + 'company registered — and this app cannot open what it is handed instead.'),
      ]
      : trouble === 'webpage'
      ? [
        L('이 파일은 PDF가 아니에요', 'This file is not a PDF'),
        L('PDF 자리에 웹 페이지가 들어 있어요. 회사 보안 프로그램이 원본 대신 안내문을 놓았을 수 있어요.',
          'There is a web page where the PDF should be. A security tool may have put a notice in its place.'),
      ]
      : trouble === 'empty'
        ? [
          L('이 논문은 아직 비어 있어요', 'This paper is still empty'),
          L('폴더에 이름만 있고 내용이 없어요. 클라우드에서 내려온 뒤에 다시 열어 주세요.',
            'The folder has the name but not the contents yet. Open it again once your cloud app has fetched it.'),
        ]
        : [
          L('이 논문을 아직 다 못 받았어요', 'This paper is still arriving'),
          trouble === 'placeholder'
            ? L('클라우드에서 아직 안 내려왔어요. 잠시 뒤에 다시 열어 주세요.',
                "It hasn't come down from the cloud yet. Open it again in a moment.")
            : L(`${megabytes} MB까지만 와 있어요. 잠시 뒤에 다시 열어 주세요.`,
                `Only ${megabytes} MB of it is here. Open it again in a moment.`),
        ]
    // The first bytes go in the fine line beside the parser's own words. They
    // cost nothing to send and they say which of these it is — which is the
    // difference between a day's hunting and a glance at a screenshot.
    // Bytes while it is bytes: a 249-byte stub reported as "0 KB" reads as a
    // rounding error rather than as the thing that is wrong with it.
    const measure = size < 1024
      ? `${size} B`
      : size < 1_000_000 ? `${Math.round(size / 1024)} KB` : `${megabytes} MB`
    const fine = [line ? `“${line}”` : null, head ? `${head} · ${measure}` : null, detail]
      .filter(Boolean).join('  ')
    this.notice(title, body, fine || undefined, this.troubleButtons(again))
  }

  /** One press to ask for the file again, rather than a paper to click away
   *  from — and one to go to the file itself, which is where the reader the
   *  company registered is reached from. */
  private troubleButtons(again?: () => void): HTMLElement | undefined {
    const buttons: HTMLElement[] = []
    if (this.actions.reveal) {
      const show = el('button', { class: 'plain-button', text: L('폴더에서 보기', 'Show in Folder') })
      on(show, 'click', () => this.actions.reveal?.())
      buttons.push(show)
    }
    if (again) {
      const button = el('button', { class: 'filled-button', text: L('다시 열기', 'Try Again') })
      on(button, 'click', again)
      buttons.push(button)
    }
    return buttons.length > 0 ? el('div', { class: 'fb-row' }, buttons) : undefined
  }

  private againButton(again: () => void): HTMLElement {
    return this.troubleButtons(again) ?? el('div')
  }

  /**
   * Whether this reads as a paper, worked out from the pages themselves.
   *
   * The Mac guesses when the file is imported, because it has PDFKit there.
   * Here the text arrives with pdf.js, which lives in the window, so the
   * guess is made the first time the document is opened — which is also when
   * somebody is looking at the question. It runs once per paper and never
   * overrules an answer.
   */
  private async guessKindIfAsked(generation: number, document: PDFDocumentProxy) {
    if (!this.actions.guessed) return
    try {
      const textOf = async (index: number) => {
        const page = await document.getPage(index)
        const content = await page.getTextContent()
        return content.items.map((item) => ('str' in item ? item.str : '')).join(' ')
      }
      const first = await textOf(1)
      if (generation !== this.generation) return
      // The end, and then through the second half: a paper with appendices
      // puts its bibliography in the middle, and looking only at the last
      // pages called such a paper a manual. At most a dozen pages are read.
      const count = document.numPages
      const wanted = new Set<number>()
      if (count <= 40) {
        // A paper is short enough to read all of, and its bibliography can be
        // anywhere: one of the papers this was tried on has it on page 9 of
        // 23, with appendices after it.
        for (let index = 1; index <= count; index += 1) wanted.add(index)
      } else {
        for (let index = count; index > count - 8; index -= 1) wanted.add(index)
        const step = Math.max(1, Math.floor(count / 12))
        for (let index = 1; index <= count && wanted.size < 20; index += step) wanted.add(index)
      }
      let end = ''
      for (const index of [...wanted].sort((a, b) => b - a)) end += await textOf(index)
      if (generation !== this.generation) return
      // The shape of the page, which nothing written to be read on paper has
      // and everything written to be projected does. Taken at scale 1 so it
      // is the page's own size and not the view's.
      const size = (await document.getPage(1)).getViewport({ scale: 1 })
      const guess = guessKind({
        identifier: hasIdentifier(first),
        abstract: hasAbstract(first),
        references: hasReferences(end),
        pageCount: count,
        landscape: size.width > size.height * 1.15,
        // The name on disk is the more reliable half: a deck's first page
        // often says only the week's title, while the file is lecture06.pdf.
        courseWords: namesACourse(`${this.actions.fileName?.() ?? ''} ${first.slice(0, 1200)}`),
      })
      this.actions.guessed(guess.kind)
    } catch {
      // A document whose text cannot be read is not a paper we can recognise,
      // and guessing wrong here is worse than not guessing.
    }
  }

  /**
   * What the page area says instead of staying blank.
   *
   * A reader that shows nothing teaches somebody that the app is broken. It
   * takes one sentence to say which of the three things happened, and the
   * sentence is worth more than the blank page was.
   */
  private notice(title: string, body: string, detail?: string, extra?: HTMLElement) {
    clear(this.pagesBox)
    this.pagesBox.append(el('div', { class: 'empty' }, [
      el('h2', { text: title }),
      el('p', { text: body }),
      ...(detail ? [el('p', { class: 'fine', text: detail })] : []),
      ...(extra ? [extra] : []),
    ]))
  }

  /** A file whose key is held by a rights service, not by the reader. */
  showLocked(lock: PDFLock) {
    if (lock.kind !== 'rights') return
    // A container that named nobody is still a container: the sentence works
    // without the brand, and inventing one would be worse than leaving it out.
    const name = SERVICE_NAMES[lock.handler] ?? L('회사 권한 서비스', 'a rights service')
    this.notice(
      L('회사가 보호한 논문이에요', 'This paper is protected'),
      L(`${name}가 잠근 파일이라 Paper Time은 못 열어요. 파일이 깨진 건 아니에요 — 여는 열쇠를 `
        + '회사 권한 서버가 들고 있고, 그 서버에 물어볼 수 있는 앱은 Acrobat처럼 회사가 허락한 것뿐이에요.',
        `${name} locked this file, so Paper Time can't open it. The file is not damaged — the key `
        + "lives on your company's rights server, and only a reader your company allows, such as "
        + 'Acrobat, can ask for it.'),
    )
  }

  /**
   * The password, asked for in the page area itself.
   *
   * pdf.js keeps its promise pending until somebody answers, so with no one
   * asking, a locked paper sat on a blank page forever — no page, no error,
   * nothing to click. The answer goes straight back to pdf.js and is kept
   * nowhere.
   */
  private askPassword(generation: number, wrong: boolean): Promise<string | null> {
    return new Promise((resolve) => {
      if (generation !== this.generation) return resolve(null)
      const field = el('input', {
        class: 'fb-input',
        type: 'password',
        placeholder: L('암호', 'Password'),
      }) as HTMLInputElement
      const open = el('button', { class: 'filled-button', text: L('열기', 'Open') })
      const send = () => {
        if (!field.value) return
        this.notice(L('여는 중이에요', 'Opening'), L('암호를 확인하고 있어요.', 'Checking the password.'))
        resolve(field.value)
      }
      on(open, 'click', send)
      on(field, 'keydown', (event) => {
        if ((event as KeyboardEvent).key === 'Enter') send()
      })
      this.notice(
        L('암호가 걸린 논문이에요', 'This paper is locked'),
        wrong
          ? L('암호가 맞지 않아요. 다시 넣어주세요.', "That password didn't work. Try again.")
          : L('암호를 넣으면 열어요. 어디에도 저장하지 않아요.',
              'Type the password and it opens. It is not stored anywhere.'),
        undefined,
        el('div', { class: 'fb-row' }, [field, open]),
      )
      field.focus()
    })
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
    this.kept = null
    this.state.pageCount = 0
    this.state.currentPage = 0
    this.texts = null
    this.folds.clear()
    this.pageTextCache.clear()
    this.showingPassage = false
    // The outline and the history belong to the paper that was open.
    this.outlineRead = null
    this.backPlaces = []
    this.forwardPlaces = []
    this.noteHistory()
    this.composing = null
    this.hideMarkBar()
  }

  // MARK: - Finding words

  /** Every page's text, read once per document for finding in it. */
  private texts: Promise<string[]> | null = null
  /** Each page's text folded, with the way back, made the first time a
   *  search looks at that page. */
  private readonly folds = new Map<number, Folded>()

  /**
   * The text of every page, the way the text layer holds it.
   *
   * Asked of pdf.js in its worker, page by page, so the window's thread only
   * joins the runs up; the page's own text layer is made from the same call,
   * which is why a place found here is a place the layer can show.
   */
  pageTexts(): Promise<string[]> {
    if (this.texts) return this.texts
    const generation = this.generation
    this.texts = (async () => {
      const out: string[] = []
      for (let index = 0; index < this.pages.length; index += 1) {
        if (generation !== this.generation) return []
        out.push(await this.pageText(index))
      }
      return out
    })()
    return this.texts
  }

  private readonly pageTextCache = new Map<number, Promise<string>>()

  /** One page's text, the same way — for a passage, which needs one page. */
  pageText(index: number): Promise<string> {
    const known = this.pageTextCache.get(index)
    if (known) return known
    const page = this.pages[index]
    if (!page) return Promise.resolve('')
    const made = (async () => {
      try {
        const content = await page.proxy.getTextContent()
        let text = ''
        for (const item of content.items as { str?: string; hasEOL?: boolean }[]) {
          if (item.str === undefined) continue
          text += item.str
          if (item.hasEOL) text += '\n'
        }
        return text
      } catch {
        return ''
      }
    })()
    this.pageTextCache.set(index, made)
    return made
  }

  private folded(pageIndex: number, text: string): Folded {
    let folded = this.folds.get(pageIndex)
    if (!folded) {
      folded = foldWithMap(text)
      this.folds.set(pageIndex, folded)
    }
    return folded
  }

  /**
   * Every place in the paper that says the query, folded the way the index
   * folds it — so the count here and the count the palette gave are counts
   * of the same thing, a word broken at the end of a line included.
   */
  async findAll(query: string): Promise<{ pageIndex: number; start: number; end: number }[]> {
    const needle = foldText(query.trim())
    if (!needle) return []
    const texts = await this.pageTexts()
    const found: { pageIndex: number; start: number; end: number }[] = []
    for (let pageIndex = 0; pageIndex < texts.length; pageIndex += 1) {
      const text = texts[pageIndex]
      if (!text) continue
      const folded = this.folded(pageIndex, text)
      for (let from = 0; ;) {
        const at = folded.text.indexOf(needle, from)
        if (at < 0) break
        const start = folded.map[at]
        const after = at + needle.length
        const end = after < folded.map.length ? folded.map[after] : text.length
        found.push({ pageIndex, start, end: Math.max(end, start + 1) })
        from = at + Math.max(needle.length, 1)
      }
    }
    return found
  }

  /** Whether what is marked is a passage the palette sent the reader to,
   *  which the next press in the page puts away. */
  private showingPassage = false

  /** Puts found places on their pages, one of them the current one. */
  showFound(found: { pageIndex: number; start: number; end: number }[], current: number) {
    this.showingPassage = false
    for (const page of this.pages) {
      const had = page.findMarks.length > 0
      page.findMarks = []
      if (had) page.drawFind()
    }
    for (const [index, place] of found.entries()) {
      this.pages[place.pageIndex]?.findMarks.push({ start: place.start, end: place.end, current: index === current })
    }
    for (const page of this.pages) if (page.findMarks.length > 0) page.drawFind()
  }

  clearFound() {
    this.showFound([], -1)
  }

  /**
   * Scrolls so the current found place is in the middle of the view.
   *
   * The page has to be drawn before its words have a place, so it is drawn
   * first — scrolled to, in a paper read continuously, which is what makes
   * the reader draw it.
   */
  async scrollToFound(pageIndex: number) {
    const page = this.pages[pageIndex]
    if (!page) return
    if (this.turnsPages) {
      this.ensureShowing(pageIndex)
    } else {
      const top = page.root.offsetTop
      const bottom = top + page.root.offsetHeight
      const shown = this.scroll.scrollTop
      if (bottom < shown || top > shown + this.scroll.clientHeight) this.scroll.scrollTop = top - 14
    }
    await page.render()
    page.drawFind()
    const box = page.currentBox()
    if (!box) return
    this.scroll.scrollTop = Math.max(0, page.root.offsetTop + box.y + box.height / 2 - this.scroll.clientHeight / 2)
    const wide = page.root.offsetLeft + box.x + box.width / 2 - this.scroll.clientWidth / 2
    if (this.scroll.scrollWidth > this.scroll.clientWidth) this.scroll.scrollLeft = Math.max(0, wide)
  }

  /**
   * Sends the reader to a passage the index found, and marks it.
   *
   * The index read this paper in a process of its own, with the same pdf.js
   * asked the same way, so the place it names is the place the text layer
   * has. Should the two ever read a page differently, the query is found on
   * the page afresh and the occurrence nearest the named place is the one
   * shown — a reader sent to the right page and the wrong line would not
   * know which of the two had been wrong.
   */
  async revealPassage(passage: { pageIndex: number; location: number; length: number }, query: string): Promise<boolean> {
    if (!(await this.whenOpen())) return false
    const page = this.pages[passage.pageIndex]
    if (!page) return false
    const text = await this.pageText(passage.pageIndex)
    const needle = foldText(query.trim())
    let range = { start: passage.location, end: passage.location + passage.length }
    if (needle && !foldText(text.slice(range.start, range.end)).includes(needle)) {
      const folded = this.folded(passage.pageIndex, text)
      let best: { start: number; end: number } | null = null
      for (let from = 0; ;) {
        const at = folded.text.indexOf(needle, from)
        if (at < 0) break
        const start = folded.map[at]
        const after = at + needle.length
        const end = after < folded.map.length ? folded.map[after] : text.length
        if (!best || Math.abs(start - passage.location) < Math.abs(best.start - passage.location)) best = { start, end }
        from = at + Math.max(needle.length, 1)
      }
      if (best) range = best
    }
    this.showFound([{ pageIndex: passage.pageIndex, ...range }], 0)
    this.showingPassage = true
    await this.scrollToFound(passage.pageIndex)
    // Marked until the reader does something else with the page, the way a
    // selection would be — unless a find has taken the marks over since.
    this.pagesBox.addEventListener('pointerdown', () => {
      if (this.showingPassage) this.clearFound()
    }, { once: true })
    return true
  }

  /**
   * What the process that writes the file said about this paper: why what
   * was made here stays out of the file, or null once the file has it — or
   * once there is nothing left that it could have.
   */
  noteKept(kept: KeptReason | null) {
    if (kept === this.kept) return
    this.kept = kept
    this.updateFooter()
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
    // A book fills the window with two pages across it and the gutter
    // between them, as the Mac's spread does — not two pages fitted to its
    // height and floating small in the middle.
    const across = store.settings.pageLayout === 'book' ? 2 : 1
    const available = Math.max(this.scroll.clientWidth - 40 - (across - 1) * BOOK_GUTTER, 200)
    return available / (unit.width * across)
  }

  relayout() {
    const scale = this.baseScale() * this.state.zoom
    for (const page of this.pages) {
      page.layout(scale)
      page.applyTint()
      page.setDrawing(this.state.drawing)
    }
    this.applyLayout()
    this.renderVisible()
  }

  /**
   * One page at a time, two across, or all of them.
   *
   * Single-page reading is not a smaller continuous scroll — it is a
   * different way of reading, where the page is the unit and turning it is
   * deliberate. So the others are taken out of the flow entirely rather than
   * scrolled past, and the arrow keys turn pages instead of nudging the
   * scroll by a line. A book is the same with two pages facing — the Mac's
   * spread: pages 1 and 2 face each other (a paper's first spread is its
   * title and its introduction, not a cover), and ←/→ turn the spread.
   */
  applyLayout() {
    const shown = this.shownPages()
    this.pagesBox.dataset.layout = store.settings.pageLayout
    for (const page of this.pages) {
      page.root.style.display = !shown || shown.has(page.index) ? '' : 'none'
    }
    if (shown) this.scroll.scrollTop = 0
  }

  /** Whether pages are turned (one, or a spread) rather than scrolled. */
  private get turnsPages(): boolean {
    return store.settings.pageLayout !== 'continuous'
  }

  /** The first page of what shows with a page: itself, or its spread's left page. */
  private spreadStart(index: number): number {
    return store.settings.pageLayout === 'book' ? index - (index % 2) : index
  }

  /** The pages on show when pages are turned; null when they all scroll. */
  private shownPages(): Set<number> | null {
    if (!this.turnsPages) return null
    const start = this.spreadStart(this.state.currentPage)
    return new Set(store.settings.pageLayout === 'book' ? [start, start + 1] : [start])
  }

  /** Turns to the page wanted, when pages are turned; a scroll shows them all. */
  private ensureShowing(pageIndex: number) {
    if (!this.turnsPages || this.shownPages()?.has(pageIndex)) return
    this.state.currentPage = pageIndex
    this.applyLayout()
    this.updateFooter()
  }

  /** Moves by whole pages — by spreads in a book. */
  turnPage(by: number) {
    if (!this.turnsPages) {
      const next = Math.max(0, Math.min(this.state.currentPage + by, this.pages.length - 1))
      if (next === this.state.currentPage) return
      this.state.currentPage = next
      this.scrollToPage(next)
      return
    }
    const step = store.settings.pageLayout === 'book' ? 2 : 1
    const from = this.spreadStart(this.state.currentPage)
    const next = this.spreadStart(Math.max(0, Math.min(from + by * step, this.pages.length - 1)))
    if (next === from) return
    this.state.currentPage = next
    this.applyLayout()
    for (const index of this.shownPages() ?? []) void this.pages[index]?.render()
    this.updateFooter()
  }

  setLayout(layout: 'single' | 'continuous' | 'book') {
    store.settings.pageLayout = layout
    // Laid out again: a book is two pages across the column, so its pages
    // are drawn smaller than the others are.
    this.relayout()
    this.updateFooter()
  }

  zoomBy(factor: number, options: { soon?: boolean } = {}) {
    this.state.zoom = Math.max(0.35, Math.min(this.state.zoom * factor, 6))
    if (options.soon) this.relayoutSoon()
    else this.relayout()
    this.update()
  }

  setZoom(zoom: number) {
    this.state.zoom = zoom
    this.relayout()
    this.update()
  }

  /**
   * Lays the pages out at the next frame rather than at once.
   *
   * A pinch on a trackpad arrives as a stream of wheel events — a hundred a
   * second — and each one was resizing every page in the paper and then
   * measuring them all. The pages can only be drawn once a frame anyway, so
   * the ones in between were work nobody ever saw.
   */
  private relayoutFrame = 0

  relayoutSoon() {
    if (this.relayoutFrame) return
    this.relayoutFrame = requestAnimationFrame(() => {
      this.relayoutFrame = 0
      this.relayout()
    })
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
    // The Marks tab lists what just arrived.
    this.actions.marksChanged?.()
    if (adopted.unreadable.length > 0) {
      const pages = adopted.unreadable.map((index) => index + 1).join(', ')
      this.actions.toast(L(
        `${pages}쪽 손글씨는 맥에서 쓴 거예요. 맥이 아직 PDF에는 쓰지 않았어요. 맥에서 이 논문을 한 번 열면 건너와요.`,
        `Handwriting on page ${pages} came from a Mac and is not in the PDF yet. `
        + 'Open the paper on the Mac once, and it comes across.',
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
   * The selection as marks take it: for each page it touches, its lines as
   * quads, and its words.
   *
   * The rectangles come from the text layer rather than from the PDF's own
   * text positions, because the text layer is what the reader actually
   * dragged over — so the mark lands where the pointer went, including across
   * a column break, where a run of PDF text indices would flood half the page.
   * Each rectangle goes to the page it lies on, so a selection that runs from
   * the foot of one page onto the next marks both — asked of the range's
   * common ancestor, it used to mark neither.
   */
  private selectionParts(): { page: PageView; quads: number[][]; text: string }[] {
    const selection = window.getSelection()
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) return []
    const text = selection.toString()
    const byPage = new Map<PageView, DOMRect[]>()
    for (let index = 0; index < selection.rangeCount; index += 1) {
      const range = selection.getRangeAt(index)
      const inside = range.commonAncestorContainer instanceof Element
        ? range.commonAncestorContainer
        : range.commonAncestorContainer.parentElement
      if (!inside || !this.node.contains(inside)) continue
      // The boxes as the text layer gives them. With `--scale-factor` set, a
      // run's box is its em box: measured, the words sit from a tenth of the
      // way down it to seven tenths, and the line below clears it altogether
      // — the pitch is 1.10 of the box. There is nothing to trim.
      for (const rect of range.getClientRects()) {
        if (rect.width <= 0.5 || rect.height <= 0.5) continue
        const page = this.pageAtClient(rect.left + rect.width / 2, rect.top + rect.height / 2)
        if (!page) continue
        byPage.set(page, [...(byPage.get(page) ?? []), rect])
      }
    }
    const parts: { page: PageView; quads: number[][]; text: string }[] = []
    for (const [page, rects] of byPage) {
      const quads = linesFromRuns(rects).map((line) => {
        // Two opposite corners through the page's own transform, which keeps
        // a rotated page honest, and kept on the page: the text layer's boxes
        // are the font's em boxes and some of them stand well outside the
        // paper — measured, one ran 244 points past the right edge of a
        // 612-point page, and the mark written from it was off the sheet.
        const topLeft = page.toPageFromClient(line.left, line.top)
        const bottomRight = page.toPageFromClient(line.right, line.bottom)
        return rectToQuad({
          x: Math.min(topLeft.x, bottomRight.x),
          y: Math.min(topLeft.y, bottomRight.y),
          width: Math.abs(bottomRight.x - topLeft.x),
          height: Math.abs(bottomRight.y - topLeft.y),
        })
      })
      if (quads.length > 0) parts.push({ page, quads, text })
    }
    return parts.sort((a, b) => a.page.index - b.page.index)
  }

  /** Marks whatever is selected, and clears the selection. */
  markSelection(kind: MarkKind, colorName = 'yellow', comment?: string): boolean {
    const parts = this.selectionParts()
    if (parts.length === 0) return false
    this.addMarks(parts, kind, colorName, comment)
    window.getSelection()?.removeAllRanges()
    return true
  }

  private addMarks(parts: { page: PageView; quads: number[][]; text: string }[], kind: MarkKind, colorName: string, comment?: string) {
    const color = [...(MARK_COLORS[colorName] ?? MARK_COLORS.yellow)] as [number, number, number]
    for (const { page, quads, text } of parts) {
      const mark: Mark = { id: makeUUID(), kind, quads, color, text }
      if (comment) mark.comment = comment
      this.changeMarks(page, [...page.marks, mark])
    }
  }

  /**
   * Every change to a page's marks goes through here: drawn, written to the
   * journal (and the file after it), put on the undo stack — so ⌘Z takes a
   * highlight back, or brings a removed one back, as it does on the Mac.
   */
  private changeMarks(page: PageView, next: Mark[]) {
    const paperID = this.paperID ?? undefined
    undoStack.record(marksSnapshot(page.index, page.marks, paperID), marksSnapshot(page.index, next, paperID))
    page.marks = next
    page.redraw()
    void this.saveMarks(page)
    this.actions.marksChanged?.()
  }

  /**
   * The passage selected on this reader's pages, as a note cites it: its
   * page, the box it fills there in the page's own coordinates, and its
   * words — what Command-L puts into the note (`ReaderLink.selectionAnchor`).
   */
  selectionAnchor(): { pageIndex: number; rect: { x: number; y: number; width: number; height: number }; text: string } | null {
    const selection = window.getSelection()
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null
    const text = selection.toString()
    if (!text.trim()) return null
    const range = selection.getRangeAt(0)
    const page = this.pageContaining(range.startContainer)
    if (!page || !this.node.contains(page.root)) return null
    const box = page.root.getBoundingClientRect()
    const rects = [...range.getClientRects()].filter((rect) => rect.width > 0.5 && rect.height > 0.5
      && rect.right > box.left && rect.left < box.right && rect.bottom > box.top && rect.top < box.bottom)
    if (rects.length === 0) return null
    const left = Math.min(...rects.map((rect) => rect.left))
    const right = Math.max(...rects.map((rect) => rect.right))
    const top = Math.min(...rects.map((rect) => rect.top))
    const bottom = Math.max(...rects.map((rect) => rect.bottom))
    const a = page.toPageFromClient(left, top)
    const b = page.toPageFromClient(right, bottom)
    return {
      pageIndex: page.index,
      rect: {
        x: Math.min(a.x, b.x),
        y: Math.min(a.y, b.y),
        width: Math.abs(b.x - a.x),
        height: Math.abs(b.y - a.y),
      },
      text,
    }
  }

  /** The mark under a point of a page, the topmost when two overlap. */
  markAt(page: PageView, point: { x: number; y: number }): Mark | null {
    for (let index = page.marks.length - 1; index >= 0; index -= 1) {
      const mark = page.marks[index]
      const hit = mark.quads.some((quad) => {
        const xs = [quad[0], quad[2], quad[4], quad[6]]
        const ys = [quad[1], quad[3], quad[5], quad[7]]
        // An underline is a thin line under its words: the words' box is
        // what a hand aims at, and it is the box that is kept.
        return point.x >= Math.min(...xs) && point.x <= Math.max(...xs)
          && point.y >= Math.min(...ys) && point.y <= Math.max(...ys)
      })
      if (hit) return mark
    }
    return null
  }

  /** Every mark in the paper in reading order — page by page, top to bottom. */
  marksList(): { pageIndex: number; mark: Mark }[] {
    const top = (mark: Mark) => Math.max(...mark.quads.map((quad) => Math.max(quad[1], quad[3])))
    const left = (mark: Mark) => Math.min(...mark.quads.map((quad) => Math.min(quad[0], quad[4])))
    const out: { pageIndex: number; mark: Mark }[] = []
    for (const page of this.pages) {
      // The page's y goes up, so the highest top is the first line.
      const sorted = [...page.marks].sort((a, b) => top(b) - top(a) || left(a) - left(b))
      for (const mark of sorted) out.push({ pageIndex: page.index, mark })
    }
    return out
  }

  /** Takes a mark off its page — the Marks tab's Delete, the editor's trash. */
  removeMark(pageIndex: number, id: string) {
    const page = this.pages[pageIndex]
    if (!page || !page.marks.some((mark) => mark.id === id)) return
    this.changeMarks(page, page.marks.filter((mark) => mark.id !== id))
    this.hideMarkEditor()
  }

  /** What the reader wrote about a mark: an empty note takes it away. */
  setMarkComment(pageIndex: number, id: string, comment: string) {
    const page = this.pages[pageIndex]
    if (!page) return
    const trimmed = comment.trim()
    this.changeMarks(page, page.marks.map((mark) => {
      if (mark.id !== id) return mark
      const next: Mark = { ...mark }
      if (trimmed) next.comment = trimmed
      else delete next.comment
      return next
    }))
  }

  /** A mark in another of the five colours. */
  recolorMark(pageIndex: number, id: string, colorName: string) {
    const page = this.pages[pageIndex]
    const color = MARK_COLORS[colorName]
    if (!page || !color) return
    this.changeMarks(page, page.marks.map((mark) =>
      (mark.id === id ? { ...mark, color: [...color] as [number, number, number] } : mark)))
  }

  /** The box a mark covers, in the window — where its controls stand. */
  private markClientBox(page: PageView, mark: Mark): DOMRect | null {
    const box = page.root.getBoundingClientRect()
    const points = mark.quads.flatMap((quad) => [
      page.toView(quad[0], quad[1]), page.toView(quad[2], quad[3]),
      page.toView(quad[4], quad[5]), page.toView(quad[6], quad[7]),
    ])
    if (points.length === 0) return null
    const xs = points.map((point) => point.x + box.left)
    const ys = points.map((point) => point.y + box.top)
    const left = Math.min(...xs)
    const top = Math.min(...ys)
    return new DOMRect(left, top, Math.max(...xs) - left, Math.max(...ys) - top)
  }

  /**
   * Sends the reader to a mark — a row of the Marks tab pressed — and shows
   * it with its controls over it, which is also how the eye finds it.
   */
  async revealMark(pageIndex: number, id: string) {
    const page = this.pages[pageIndex]
    const mark = page?.marks.find((one) => one.id === id)
    if (!page || !mark) return
    this.ensureShowing(pageIndex)
    await page.render()
    const tops = mark.quads.map((quad) => page.toView(quad[0], Math.max(quad[1], quad[3])).y)
    this.scroll.scrollTop = Math.max(0, page.root.offsetTop + Math.min(...tops) - this.scroll.clientHeight / 3)
    // After the scroll has been told about: a scroll puts the bar away.
    setTimeout(() => this.showMarkEditor(page, mark), 60)
  }

  // ------------------------------------------------------------- links

  private hover: { x: number; y: number; target: Node } | null = null
  private hoverFrame = 0
  private overLink: PageLink | null = null

  private async updateHover() {
    const at = this.hover
    if (!at) return
    const page = this.pageContaining(at.target)
    if (!page) return this.showOverLink(null)
    await page.pageLinks()
    this.showOverLink(page.linkAt(page.toPageFromClient(at.x, at.y)))
  }

  private showOverLink(link: PageLink | null) {
    if (link === this.overLink) return
    this.overLink = link
    this.scroll.classList.toggle('over-link', Boolean(link))
    if (link?.url) this.scroll.title = link.url
    else this.scroll.removeAttribute('title')
  }

  /**
   * Where the reader stood before a link was followed, to come back to. The
   * Mac's PDF view keeps the same history, and Back walks it before it walks
   * the papers (`goBackInHistory`): follow a citation to the references, and
   * Back is the sentence it came from.
   */
  private backPlaces: DocumentPlace[] = []
  private forwardPlaces: DocumentPlace[] = []

  get canGoBackInDocument(): boolean {
    return this.backPlaces.length > 0
  }

  get canGoForwardInDocument(): boolean {
    return this.forwardPlaces.length > 0
  }

  private here(): DocumentPlace {
    return { page: this.state.currentPage, top: this.scroll.scrollTop, of: this.scroll.scrollHeight }
  }

  private goTo(place: DocumentPlace) {
    if (this.turnsPages && !this.shownPages()?.has(place.page)) {
      this.ensureShowing(place.page)
      void this.pages[place.page]?.render()
    }
    const height = this.scroll.scrollHeight
    const moved = place.of > 0 && Math.abs(height - place.of) > 1
    this.scroll.scrollTop = moved ? Math.round(place.top * (height / place.of)) : place.top
  }

  private noteHistory() {
    this.state.canGoBack = this.backPlaces.length > 0
    this.state.canGoForward = this.forwardPlaces.length > 0
    this.actions.historyChanged?.()
  }

  goBackInDocument() {
    const place = this.backPlaces.pop()
    if (!place) return
    this.forwardPlaces.push(this.here())
    this.goTo(place)
    this.noteHistory()
  }

  goForwardInDocument() {
    const place = this.forwardPlaces.pop()
    if (!place) return
    this.backPlaces.push(this.here())
    this.goTo(place)
    this.noteHistory()
  }

  /** Goes where a link points, and remembers where from. */
  async followLink(link: PageLink) {
    if (link.url) {
      // Out to the browser; only the web's own two schemes are let through.
      void call('shell:openExternal', { url: link.url })
      return
    }
    if (link.action) {
      switch (link.action) {
        case 'NextPage': return this.turnPage(1)
        case 'PrevPage': return this.turnPage(-1)
        case 'FirstPage': return this.jumpTo(0, null)
        case 'LastPage': return this.jumpTo(this.pages.length - 1, null)
        case 'GoBack': return this.goBackInDocument()
        case 'GoForward': return this.goForwardInDocument()
      }
      return
    }
    const target = await this.destinationPlace(link.dest)
    if (target) await this.jumpTo(target.pageIndex, target.top)
  }

  /** A jump inside the paper that Back comes back from. */
  async jumpTo(pageIndex: number, top: number | null) {
    if (!this.pages[pageIndex]) return
    this.backPlaces.push(this.here())
    this.forwardPlaces = []
    await this.showPlace(pageIndex, top)
    this.noteHistory()
  }

  /**
   * Where a destination points — a link's, or a heading of the outline: its
   * page, and how far down it in the page's own coordinates when it says.
   */
  async destinationPlace(dest: unknown): Promise<{ pageIndex: number; top: number | null } | null> {
    const document = this.document
    if (!document || dest == null) return null
    try {
      const explicit = typeof dest === 'string' ? await document.getDestination(dest) : dest
      if (!Array.isArray(explicit) || explicit.length === 0) return null
      const [ref, kind, ...args] = explicit as [unknown, { name?: string } | undefined, ...unknown[]]
      const pageIndex = typeof ref === 'number'
        ? ref
        : ref && typeof ref === 'object' && 'num' in ref
          ? await document.getPageIndex(ref as never)
          : null
      if (pageIndex === null || !this.pages[pageIndex]) return null
      const name = kind?.name
      const top = name === 'XYZ' ? args[1] : name === 'FitH' || name === 'FitBH' ? args[0] : name === 'FitR' ? args[3] : null
      return { pageIndex, top: typeof top === 'number' ? top : null }
    } catch {
      return null
    }
  }

  /**
   * The outline the PDF carries — the headings a LaTeX paper's bookmarks
   * are — flattened in reading order, each with the page and height it goes
   * to. Read once a paper, since a jump back in is the common case.
   */
  private outlineRead: Promise<{ title: string; depth: number; pageIndex: number | null; top: number | null }[]> | null = null

  outline(): Promise<{ title: string; depth: number; pageIndex: number | null; top: number | null }[]> {
    const document = this.document
    if (!document) return Promise.resolve([])
    if (!this.outlineRead) {
      type Node = { title?: string; dest?: unknown; items?: Node[] }
      this.outlineRead = document.getOutline().then(async (tree: Node[] | null) => {
        const flat: { title: string; depth: number; dest: unknown }[] = []
        const walk = (nodes: Node[], depth: number) => {
          for (const node of nodes) {
            const title = (node.title ?? '').replace(/\s+/g, ' ').trim()
            if (title) flat.push({ title, depth, dest: node.dest })
            if (node.items?.length) walk(node.items, depth + 1)
          }
        }
        walk(tree ?? [], 0)
        return Promise.all(flat.map(async (entry) => {
          const place = await this.destinationPlace(entry.dest)
          return { title: entry.title, depth: entry.depth, pageIndex: place?.pageIndex ?? null, top: place?.top ?? null }
        }))
      }).catch(() => [])
    }
    return this.outlineRead
  }

  /** Shows a page, and a height on it when there is one to show. */
  async showPlace(pageIndex: number, top: number | null) {
    const page = this.pages[pageIndex]
    if (!page) return
    this.ensureShowing(pageIndex)
    await page.render()
    const y = top === null ? 0 : page.toView(0, top).y
    this.scroll.scrollTop = Math.max(0, page.root.offsetTop + y - 14)
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

  private readonly sketchHost: SketchInputHost = {
    changed: () => this.actions.changed(),
    save: (target) => void this.save(target),
  }

  setDrawing(drawing: boolean) {
    this.state.drawing = drawing
    for (const page of this.pages) {
      page.setDrawing(drawing)
      if (drawing && !page.input) page.input = attachSketchInput(page, this, this.sketchHost)
    }
    if (drawing) {
      // The panel talks to this reader's editor while the pen is out.
      sketchEditor.current = sketchEditingFor(this, this.sketchHost)
    } else {
      resetSketchInput()
      for (const page of this.pages) {
        page.input?.detach()
        page.input = null
        page.hidden = new Set()
        page.hiddenStrokes = new Set()
        page.guest = null
        page.redraw()
      }
      store.sketch.selection = null
      if (sketchEditor.current === sketchEditingFor(this, this.sketchHost)) sketchEditor.current = null
    }
  }

  /**
   * The little bar over a selection, and over a mark that was clicked.
   *
   * Marking a passage should be one gesture away from having selected it —
   * reaching for a menu breaks the reading. Over a selection it is the Mac's
   * bar: five colours, underline and strikethrough, then a note about the
   * passage and a plain copy. Over a mark already on the page it is the
   * Mac's editor for one: its colour changed, a note written on it, or the
   * mark taken off — a highlight made here used to be there for good.
   */
  private markBar: HTMLElement | null = null
  /** While a note is being written, the way to finish it. The bar stays put
   *  for that — a scroll or the selection going must not throw the words away. */
  private composing: { finish: (keep: boolean) => void } | null = null
  /** The mark whose controls are showing, when the bar is a mark's. */
  private editing: { pageIndex: number; id: string } | null = null

  private bar(): HTMLElement {
    if (!this.markBar) {
      this.markBar = el('div', { class: 'mark-bar' })
      this.overlayHost.append(this.markBar)
    }
    return this.markBar
  }

  /** One of the bar's buttons. The selection has to survive the press, so the
   *  default mousedown — which would collapse it — never happens. */
  private barButton(className: string, title: string, html: string, press: () => void): HTMLElement {
    const button = el('button', { class: className, title, 'aria-label': title, html })
    on(button, 'mousedown', (event: MouseEvent) => event.preventDefault())
    on(button, 'click', press)
    return button
  }

  private swatch(name: string, title: string, press: () => void, current = false): HTMLElement {
    const button = this.barButton('mark-swatch', title, '', press)
    button.style.background = cssColor(MARK_COLORS[name] as [number, number, number])
    if (current) button.setAttribute('aria-pressed', 'true')
    return button
  }

  /** The bar over a box in the window: above it, or under it with no room. */
  private placeBar(rect: DOMRect) {
    const bar = this.bar()
    bar.style.display = 'flex'
    const host = this.overlayHost.getBoundingClientRect()
    const size = bar.getBoundingClientRect()
    const width = size.width || 190
    let left = rect.left + rect.width / 2 - host.left - width / 2
    left = Math.max(6, Math.min(left, host.width - width - 6))
    let top = rect.top - host.top - (size.height || 31) - 7
    if (top < 4) top = rect.bottom - host.top + 8
    bar.style.left = `${left}px`
    bar.style.top = `${top}px`
  }

  private updateMarkBar() {
    // The note being written keeps the bar where it is.
    if (this.composing) return
    const selection = window.getSelection()
    if (!selection || selection.isCollapsed || selection.rangeCount === 0 || this.state.drawing) {
      if (!this.editing) this.hideMarkBar()
      return
    }
    const range = selection.getRangeAt(0)
    const inside = (range.commonAncestorContainer instanceof Element
      ? range.commonAncestorContainer
      : range.commonAncestorContainer.parentElement)?.closest('.text-layer, .reader-pages')
    // This reader's own text, not a neighbouring pane's.
    if (!inside || !this.node.contains(inside)) return this.hideMarkBar()

    const rect = range.getBoundingClientRect()
    if (rect.width === 0 && rect.height === 0) return this.hideMarkBar()
    this.editing = null
    this.fillSelectionBar()
    this.placeBar(rect)
  }

  private fillSelectionBar() {
    const bar = this.bar()
    if (bar.dataset.mode === 'selection') return
    bar.dataset.mode = 'selection'
    clear(bar)
    for (const name of MARK_COLOR_NAMES) {
      const colour = colourWord(name)
      bar.append(this.swatch(name, L(`${colour} 형광펜`, `Highlight in ${colour}`), () => {
        this.markSelection('highlight', name)
        this.hideMarkBar()
      }))
    }
    bar.append(el('span', { class: 'mark-divider' }))
    bar.append(this.barButton('mark-action', withKey(L('밑줄', 'Underline'), 'underline', platform), icon('underline'), () => {
      this.markSelection('underline', 'yellow')
      this.hideMarkBar()
    }))
    bar.append(this.barButton('mark-action', L('취소선', 'Strikethrough'), icon('strikethrough'), () => {
      this.markSelection('strikethrough', 'yellow')
      this.hideMarkBar()
    }))
    bar.append(el('span', { class: 'mark-divider' }))
    bar.append(this.barButton('mark-action', L('이 구절에 노트 달기', 'Add a note about this passage'), icon('square.and.pencil'), () => this.composeNote()))
    bar.append(this.barButton('mark-action', L('복사', 'Copy'), icon('doc.on.doc'), () => this.copySelection()))
  }

  /** Copies the selected words as they are, and says so. */
  private copySelection() {
    const text = window.getSelection()?.toString() ?? ''
    if (!text) return
    void navigator.clipboard.writeText(text)
    this.actions.toast(L('복사했어요', 'Copied'))
    window.getSelection()?.removeAllRanges()
    this.hideMarkBar()
  }

  /**
   * A note in the bar: about the selected passage — a yellow highlight with
   * the words written on it, which is what a note on the Mac is — or the note
   * of a mark already on the page. Return keeps it, Escape does not; clicking
   * away keeps what was typed rather than throwing it out.
   */
  private composeNote(target?: { pageIndex: number; id: string }) {
    const parts = target ? [] : this.selectionParts()
    const page = target ? this.pages[target.pageIndex] : null
    const mark = target ? page?.marks.find((one) => one.id === target.id) : null
    if (!target && parts.length === 0) return
    if (target && (!page || !mark)) return
    const rect = target && page && mark
      ? this.markClientBox(page, mark)
      : window.getSelection()?.getRangeAt(0).getBoundingClientRect() ?? null
    if (!rect) return
    const bar = this.bar()
    bar.dataset.mode = 'compose'
    clear(bar)
    const input = el('input', {
      type: 'text',
      class: 'mark-note-field',
      placeholder: L('노트', 'Note'),
      'aria-label': L('노트', 'Note'),
      spellcheck: 'true',
    }) as HTMLInputElement
    input.value = mark?.comment ?? ''
    const save = el('button', { class: 'mark-note-save', text: L('저장', 'Save') })
    const finish = (keep: boolean) => {
      if (!this.composing) return
      this.composing = null
      const text = input.value.trim()
      if (keep) {
        if (target) this.setMarkComment(target.pageIndex, target.id, text)
        else if (text) this.addMarks(parts, 'highlight', 'yellow', text)
      }
      window.getSelection()?.removeAllRanges()
      this.editing = null
      this.hideMarkBar()
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
    on(input, 'blur', () => finish(input.value.trim().length > 0 || Boolean(target)))
    on(save, 'mousedown', (event: MouseEvent) => event.preventDefault())
    on(save, 'click', () => finish(true))
    bar.append(input, save)
    this.composing = { finish }
    this.placeBar(rect)
    input.focus()
  }

  /** The controls for a mark already on the page, over it. */
  showMarkEditor(page: PageView, mark: Mark) {
    // A mark another app made is shown and left alone: this build writes
    // only its own marks back to the file, so an edit here would not stay.
    if (mark.id.startsWith('foreign-')) return
    const rect = this.markClientBox(page, mark)
    if (!rect) return
    this.composing = null
    const bar = this.bar()
    bar.dataset.mode = 'mark'
    clear(bar)
    const current = nearestColourName(mark.color)
    for (const name of MARK_COLOR_NAMES) {
      const colour = colourWord(name)
      bar.append(this.swatch(name, L(`색 바꾸기: ${colour}`, `Change to ${colour}`), () => {
        this.recolorMark(page.index, mark.id, name)
        this.hideMarkEditor()
      }, name === current))
    }
    bar.append(el('span', { class: 'mark-divider' }))
    bar.append(this.barButton(
      'mark-action',
      mark.comment ? L('노트 고치기', 'Edit Note') : L('노트 달기', 'Add Note'),
      icon('square.and.pencil'),
      () => this.composeNote({ pageIndex: page.index, id: mark.id }),
    ))
    bar.append(this.barButton('mark-action', L('표시 지우기', 'Remove Mark'), icon('trash'), () => this.removeMark(page.index, mark.id)))
    this.editing = { pageIndex: page.index, id: mark.id }
    this.placeBar(rect)
    this.actions.markShown?.(mark.id)
  }

  hideMarkEditor() {
    if (!this.editing) return
    this.editing = null
    this.hideMarkBar()
  }

  /** Whether the bar is up over a selection or a mark — Escape's first step. */
  get markBarShowing(): boolean {
    return this.markBar?.style.display === 'flex'
  }

  hideMarkBar() {
    if (this.composing) return
    if (this.markBar) {
      this.markBar.style.display = 'none'
      delete this.markBar.dataset.mode
    }
    this.editing = null
  }

  private noteCurrentPage() {
    // With pages turned the scroll position says nothing about which page
    // is showing; the page is whatever was turned to.
    if (this.turnsPages) return
    const middle = this.scroll.scrollTop + this.scroll.clientHeight / 2
    let current = 0
    for (const page of this.pages) {
      if (page.root.offsetTop <= middle) current = page.index
    }
    if (current !== this.state.currentPage) {
      this.state.currentPage = current
      this.updateFooter()
    }
  }

  /**
   * One page, drawn small, for the page grid.
   *
   * Its own canvas and its own render: the reader's page canvases are sized
   * for reading and scaling those down gives a blurry thumbnail.
   */
  async thumbnail(index: number, width: number): Promise<HTMLCanvasElement | null> {
    const proxy = this.pages[index]?.proxy ?? null
    if (!proxy) return null
    const base = proxy.getViewport({ scale: 1 })
    const scale = width / base.width
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const viewport = proxy.getViewport({ scale: scale * dpr })
    const canvas = document.createElement('canvas')
    canvas.width = Math.floor(viewport.width)
    canvas.height = Math.floor(viewport.height)
    canvas.style.width = `${Math.floor(viewport.width / dpr)}px`
    canvas.style.height = `${Math.floor(viewport.height / dpr)}px`
    const context = canvas.getContext('2d', { alpha: false })
    if (!context) return null
    context.fillStyle = '#ffffff'
    context.fillRect(0, 0, canvas.width, canvas.height)
    await proxy.render({ canvasContext: context, viewport }).promise
    return canvas
  }

  get pages_count(): number {
    return this.pages.length
  }

  /**
   * Where the paper is being read, so a rebuild of the window's boxes can put
   * it back. A scroll view taken out of the document comes back at the top,
   * and a reader at the top is a reader on page one.
   */
  place(): ReaderPlace {
    return { top: this.scroll.scrollTop, of: this.scroll.scrollHeight }
  }

  /**
   * Puts the paper back where it was.
   *
   * By the fraction of the way down rather than by the pixel: putting a paper
   * beside another halves its column, and a page laid out half as wide is laid
   * out half as tall, so the pixel it was at is a different place in the
   * paper. When nothing resized — which is most of the time — the two are the
   * same number.
   */
  returnTo(place: ReaderPlace) {
    if (place.top <= 0) return
    const height = this.scroll.scrollHeight
    const moved = place.of > 0 && Math.abs(height - place.of) > 1
    this.scroll.scrollTop = moved ? Math.round(place.top * (height / place.of)) : place.top
  }

  scrollToPage(index: number) {
    const page = this.pages[index]
    if (!page) return
    this.scroll.scrollTo({ top: page.root.offsetTop - 14, behavior: 'smooth' })
  }

  /** Says whether this is the pane in focus; the border shows it. */
  setFocused(focused: boolean) {
    this.node.classList.toggle('focused', focused)
    this.header.classList.toggle('focused', focused)
  }

  update() {
    clear(this.header)
    const paper = store.papers.find((entry) => entry.id === this.paperID)
    const title = el('span', { class: 'reader-title', text: paper?.meta.displayTitle ?? '' })
    this.header.append(title)
    if (paper && this.isPane) {
      // The title is the handle: drag it to another zone to move the pane.
      this.header.draggable = true
      on(this.header, 'dragstart', (event: DragEvent) => {
        if (!event.dataTransfer) return
        event.dataTransfer.setData(PAPER_DRAG_TYPE, paper.id)
        event.dataTransfer.setData('text/plain', paper.meta.displayTitle)
        event.dataTransfer.effectAllowed = 'move'
      })
    }
    if (paper) {
      const draw = el('button', {
        class: 'icon-button',
        title: withKey(L('쪽에 그리기', 'Draw on the page'), 'draw', platform),
        'aria-pressed': String(this.state.drawing),
        html: icon('pen'),
      })
      on(draw, 'click', () => {
        this.setDrawing(!this.state.drawing)
        this.update()
        this.actions.changed()
      })
      this.header.append(draw)
      if (this.isPane && this.actions.close) {
        const close = el('button', {
          class: 'icon-button pane-close',
          title: L('닫기', 'Close'),
          'aria-label': L('닫기', 'Close'),
          html: icon('xmark'),
        })
        on(close, 'click', (event: MouseEvent) => {
          event.stopPropagation()
          this.actions.close?.()
        })
        this.header.append(close)
      }
    }
    this.updateFooter()
  }

  private updateFooter() {
    clear(this.footer)
    if (!this.document) return
    // The Mac's words: «14쪽 중 1쪽», «Page 1 of 14» — and a spread's two
    // pages, «14쪽 중 1–2쪽», «Pages 1–2 of 14».
    const count = this.state.pageCount
    const left = this.spreadStart(this.state.currentPage) + 1
    const right = store.settings.pageLayout === 'book' ? Math.min(left + 1, count) : left
    const position = el('span', {
      text: left === right
        ? L(`${count}쪽 중 ${left}쪽`, `Page ${left} of ${count}`)
        : L(`${count}쪽 중 ${left}–${right}쪽`, `Pages ${left}–${right} of ${count}`),
    })
    this.footer.append(position)
    if (this.turnsPages) {
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
        turn('chevron.left', -1, left <= 1),
        turn('chevron.right', 1, right >= count),
      ]))
    }
    const zoom = el('span', { text: `${Math.round(this.state.zoom * 100)}%` })
    if (!this.kept) {
      this.footer.append(zoom)
      return
    }
    // Beside the zoom rather than between the page and the turn buttons, so
    // the footer keeps its shape. The why is one hover away; the what is
    // on the line itself, because it is the thing a person needs to know
    // before sending this file to someone.
    const why = {
      encrypted: L(
        '열쇠를 모르는 PDF에는 쓰지 않아요. 다른 앱에서는 이 표시가 안 보여요.',
        "Paper Time can't unlock this PDF, so it doesn't write into it. Other apps won't show these marks.",
      ),
      permissions: L(
        '이 PDF는 표시를 더하지 못하게 되어 있어요. 다른 앱에서는 이 표시가 안 보여요.',
        "This PDF doesn't allow annotations, so Paper Time doesn't write into it. Other apps won't show these marks.",
      ),
      structure: L(
        '이 PDF는 구조를 확실히 읽지 못해서 쓰지 않아요. 다른 앱에서는 이 표시가 안 보여요.',
        "Paper Time can't read this PDF's structure for certain, so it doesn't write into it. Other apps won't show these marks.",
      ),
    }[this.kept]
    const kept = el('span', {
      class: 'reader-kept',
      text: L('표시는 Paper Time에만 있어요', 'Marks stay in Paper Time'),
      title: why,
    })
    this.footer.append(el('span', { class: 'reader-footer-end' }, [kept, zoom]))
  }

  /** Redraws every page that has a drawing on it. */
  redrawAll() {
    for (const page of this.pages) page.redraw()
  }

  applyTint() {
    for (const page of this.pages) page.applyTint()
  }
}
