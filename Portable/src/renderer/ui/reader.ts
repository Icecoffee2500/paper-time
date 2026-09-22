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
import { headBytes, rightsHandler, type ByteTrouble, type PDFLock } from '../../shared/pdfLock.js'
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
import {
  attachSketchInput,
  hitsDrawing,
  resetSketchInput,
  sketchEditingFor,
  type SketchInput,
  type SketchInputHost,
} from './sketchInput.js'
import { sketchEditor } from './sketchEditing.js'
import { pagesOf, type Snapshot } from './sketchUndo.js'
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

export class PageView {
  root: HTMLElement
  canvas: HTMLCanvasElement
  /** Highlights and underlines, on a surface of their own. See `redraw`. */
  markCanvas: HTMLCanvasElement
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
    this.drawCanvas = el('canvas', { class: 'draw-canvas' })
    this.textLayer = el('div', { class: 'text-layer' })
    this.inputSurface = el('div', { class: 'sketch-input' })
    this.tint = el('div', { class: 'page-tint' })
    this.root = el('div', { class: 'page', 'data-page': String(index) }, [
      this.canvas,
      this.markCanvas,
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
        this.showTrouble(why.trouble, why.size ?? bytes.length, why.again, message, headBytes(bytes))
        return
      }
      this.notice(
        L('이 PDF를 열 수 없어요', "Paper Time can't open this PDF"),
        L('파일이 깨졌을 수 있어요. 다른 뷰어에서도 안 열리면 파일 쪽 문제예요.',
          'The file may be damaged. If another reader cannot open it either, the file is the problem.'),
        message,
        why?.again ? this.againButton(why.again) : undefined,
      )
    }
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
  showTrouble(trouble: ByteTrouble, size: number, again?: () => void, detail?: string, head?: string) {
    const megabytes = (size / 1_000_000).toFixed(1)
    const [title, body] = trouble === 'opaque'
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
    const fine = [head ? `${head} · ${Math.round(size / 1024)} KB` : null, detail]
      .filter(Boolean).join('  ')
    this.notice(title, body, fine || undefined, again ? this.againButton(again) : undefined)
  }

  /** One press to ask for the file again, rather than a paper to click away from. */
  private againButton(again: () => void): HTMLElement {
    const button = el('button', { class: 'filled-button', text: L('다시 열기', 'Try Again') })
    on(button, 'click', again)
    return el('div', { class: 'fb-row' }, [button])
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
    this.state.pageCount = 0
    this.state.currentPage = 0
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
      page.root.style.display = !single || page.index === this.state.currentPage ? '' : 'none'
    }
    if (single) this.scroll.scrollTop = 0
  }

  /** Moves by whole pages. Only meaningful when one page is showing. */
  turnPage(by: number) {
    const next = Math.max(0, Math.min(this.state.currentPage + by, this.pages.length - 1))
    if (next === this.state.currentPage) return
    this.state.currentPage = next
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
      // The boxes as the text layer gives them. With `--scale-factor` set, a
      // run's box is its em box: measured, the words sit from a tenth of the
      // way down it to seven tenths, and the line below clears it altogether
      // — the pitch is 1.10 of the box. There is nothing to trim.
      const rects = [...range.getClientRects()].filter((rect) => rect.width > 0.5 && rect.height > 0.5)
      byPage.set(page, [...(byPage.get(page) ?? []), ...rects])
    }
    if (byPage.size === 0) return false

    const color = (MARK_COLORS[colorName] ?? MARK_COLORS.yellow) as [number, number, number]
    for (const [page, rects] of byPage) {
      const lines = linesFromRuns(rects)
      const quads = lines.map((line) => {
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
   * The little bar that appears over a selection.
   *
   * Marking a passage should be one gesture away from having selected it —
   * reaching for a menu breaks the reading. Five colours and an underline,
   * which is all the Mac offers too, and it goes away the moment the
   * selection does.
   */
  private markBar: HTMLElement | null = null

  private updateMarkBar() {
    const selection = window.getSelection()
    if (!selection || selection.isCollapsed || selection.rangeCount === 0 || this.state.drawing) {
      return this.hideMarkBar()
    }
    const range = selection.getRangeAt(0)
    const inside = (range.commonAncestorContainer instanceof Element
      ? range.commonAncestorContainer
      : range.commonAncestorContainer.parentElement)?.closest('.text-layer')
    // This reader's own text, not a neighbouring pane's.
    if (!inside || !this.node.contains(inside)) return this.hideMarkBar()

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
        title: L('쪽에 그리기', 'Draw on the Page'),
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
    const position = el('span', {
      text: L(
        `${this.state.currentPage + 1} / ${this.state.pageCount}쪽`,
        `Page ${this.state.currentPage + 1} of ${this.state.pageCount}`,
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
        turn('chevron.left', -1, this.state.currentPage === 0),
        turn('chevron.right', 1, this.state.currentPage >= this.state.pageCount - 1),
      ]))
    }
    this.footer.append(el('span', { text: `${Math.round(this.state.zoom * 100)}%` }))
  }

  /** Redraws every page that has a drawing on it. */
  redrawAll() {
    for (const page of this.pages) page.redraw()
  }

  applyTint() {
    for (const page of this.pages) page.applyTint()
  }
}
