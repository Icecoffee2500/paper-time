/**
 * The paper itself: one document, its pages, and how they are laid out.
 *
 * Pages are laid out continuously — or one, or a book's two, at a time — and
 * drawn only when they come near the view, because a forty-page paper drawn
 * eagerly costs a second of stutter and two hundred megabytes for pages
 * nobody has scrolled to. Pages far from the view are let go of again
 * (`PageView.release`), and a page's own proxy is fetched from pdf.js the
 * first time it is needed: the paper shows as soon as its first page is in.
 *
 * What lives beside this: a page and its layers (`pageView.ts`, night's
 * pictures in `pageImagesLayer.ts`), the words (`readerText.ts`), the marks
 * and the selection (`readerMarks.ts`, the bar over them in `markBar.ts`),
 * the history a link makes (`readerHistory.ts`), the title strip and footer
 * (`readerChrome.ts`), what is said instead of a page (`readerNotices.ts`),
 * and the arithmetic of all of it (`shared/readerMath.ts`).
 */
import { clear, el, on } from '../dom.js'
import { freshReaderState, store, type ReaderState } from '../state.js'
import { PAPER_DRAG_TYPE } from '../../shared/split.js'
import { openDocument, releaseTextCaches, type Opening, type PDFDocumentProxy, type PDFPageProxy } from '../pdf.js'
import { headBytes, headLine, rightsHandler, type ByteTrouble, type PDFLock } from '../../shared/pdfLock.js'
import type { KeptReason, SaveState } from '../../shared/api.js'
import type { DocumentKind } from '../../shared/documentKind.js'
import { SketchElement } from '../../shared/sketch.js'
import { InkStroke } from '../../shared/ink.js'
import { MARK_COLORS, type Mark, type MarkKind, rectToQuad } from '../../shared/marks.js'
import { makeUUID } from '../../shared/coding.js'
import { call } from '../bridge.js'
import {
  attachSketchInput,
  hitsDrawing,
  resetSketchInput,
  sketchEditingFor,
  undoStack,
  type SketchInputHost,
} from './sketchInput.js'
import { sketchEditor } from './sketchEditing.js'
import { marksSnapshot, pagesOf, type Snapshot } from './sketchUndo.js'
import { installMathProvider, removeMathListener } from '../sketchMath.js'
import { L } from '../../shared/lang.js'
import { groundFor, renderingFor } from '../../shared/pageTint.js'
import {
  classifyOpenError,
  destinationTop,
  devicePixels,
  fitScale,
  flattenOutline,
  formatError,
  isOpenableLink,
  pageAtOffset,
  shownPages,
  spreadStart,
  turnedTo,
  type OutlineNode,
  type PageLayout,
  type PageShape,
} from '../../shared/readerMath.js'
import { PageView, type PageLink, type PageOwner } from './pageView.js'
import { DocumentText, type Found } from './readerText.js'
import { DocumentHistory, scrollFor, type DocumentPlace } from './readerHistory.js'
import { MarkBar, type SelectionPart } from './markBar.js'
import type { MenuEntry } from './menu.js'
import { markAt, markClientBox, marksInReadingOrder, selectionAnchor, selectionParts } from './readerMarks.js'
import { fillFooter, fillHeader } from './readerChrome.js'
import {
  damagedNotice, lockedNotice, noticeNode, openingNotice, passwordPrompt, troubleButtons, troubleNotice, type Notice,
} from './readerNotices.js'
import { thumbnails } from './pageThumbnails.js'
import { extentInk, extentRead, type PageInput as MathPage } from '../../shared/mathReader/reader.js'
import type { Box } from '../../shared/strokeSnap.js'
import { iconNode } from '../icons.js'
import { platform } from '../bridge.js'
import { shortcutText } from '../../shared/shortcuts.js'
import { isBlankPicture } from '../../shared/formulaOCRInput.js'

export { PageView, type PageLink, type TextRange } from './pageView.js'

/** What the main process already worked out about these bytes, if anything. */
export type Reason = { trouble?: ByteTrouble; size?: number; again?: () => void }

/** Whether the window is showing its dark appearance — what Glass does
 *  depends on it. `applyTheme` has already resolved «system» into this. */
function isDarkAppearance(): boolean {
  return document.documentElement.dataset.theme === 'dark'
}

export interface ReaderActions {
  /** Ask the window to redraw the parts that show what is selected. */
  changed: () => void
  toast: (message: string) => void
  /** A press landed in this reader: it is the one in use. */
  activated?: () => void
  /** The × in a pane's title strip: take the pane out and close the paper. */
  close?: () => void
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
  /** Ultracopy from the selection bar or its menu. */
  ultracopy?: () => void
  /** A mark on the page was clicked: the Marks tab brings its row forward. */
  markShown?: (id: string) => void
  /** A menu at a point — the right-click on a selection or a mark. */
  menu?: (anchor: Element, entries: MenuEntry[]) => void
  /** A link was followed, or Back walked the paper: the arrows may change. */
  historyChanged?: () => void
  /** The page being read changed — to be remembered for the next open. */
  pageChanged?: (index: number) => void
  /** The paper's title, for «Opening …» while it loads. */
  title?: () => string
}

/** A place in a paper: how far down, and down how much. */
export interface ReaderPlace {
  top: number
  of: number
}

export interface ReaderOptions {
  /** One of several side by side: the title strip is a handle and has an ×. */
  pane?: boolean
  /** The state this reader keeps. */
  state?: ReaderState
  /** One page, a book's two, or all of them scrolled. */
  layout?: PageLayout
}

/** The gutter between the two pages of a book's spread, in the window's pixels. */
const BOOK_GUTTER = 24

/** Pages fetched and laid out at their own size before the rest, a batch at a time. */
const SHAPE_BATCH = 16

/** Readers alive in this window — pdf.js's text caches go with the last. */
let living = 0
/** Said once per run, the first time the lasso catches something. */
let lassoExplained = false

export class Reader implements PageOwner {
  node: HTMLElement
  private header = el('div', { class: 'reader-header' })
  private scroll = el('div', { class: 'reader-scroll' })
  private pagesBox = el('div', { class: 'reader-pages' })
  private footer = el('div', { class: 'reader-footer' })
  private overlayHost = el('div')
  document: PDFDocumentProxy | null = null
  /** The load under way, so a close can stop it. */
  private opening: Opening | null = null
  pages: PageView[] = []
  paperID: string | null = null
  /** Page count, page, zoom and whether the pen is out — this reader's own. */
  readonly state: ReaderState
  private pane: boolean
  private layout: PageLayout
  /** Draws a page as it comes near; the pages near the view now. */
  private drawObserver: IntersectionObserver | null = null
  private readonly near = new Set<PageView>()
  /** Lets a page go once it is far away. */
  private releaseObserver: IntersectionObserver | null = null
  private generation = 0
  /**
   * Why what was made here stays out of the file, when it does. Said in the
   * footer, where the Mac says it, in the voice of a state and not of an
   * error: nothing was lost, and nothing needs doing.
   */
  private kept: KeptReason | null = null
  /** What the file is doing with what was made here, and whether another
   *  app's pen is on it — the footer's other end. */
  private saveState: SaveState = 'idle'
  private foreignInk = false
  /** A wheel's travel at the edge of a turned page, until it is decisive. */
  private wheelTravel = 0
  private wheelAt = 0
  private zoomBadge: HTMLElement | null = null
  private zoomBadgeTimer = 0
  private text: DocumentText | null = null
  private readonly history = new DocumentHistory()
  private readonly bar: MarkBar
  /** Whoever is waiting for the paper to be in — a search sending the
   *  reader to a line in it. */
  private waiting: ((opened: boolean) => void)[] = []
  /** Whether what is marked is a passage the palette sent the reader to,
   *  which the next press in the page puts away. */
  private showingPassage = false
  /** Which pages the turned layout shows, so the view goes to the top only
   *  when that changes — not on every zoom and every divider frame. */
  private shownKey = ''
  /** Each page's top in the scroll view, worked out once a layout. */
  private tops: number[] | null = null
  private relayoutFrame = 0
  private hover: { x: number; y: number; target: Node } | null = null
  private hoverFrame = 0
  private overLink: PageLink | null = null
  private outlineRead: Promise<{ title: string; depth: number; pageIndex: number | null; top: number | null }[]> | null = null
  private readonly onSelectionChange = () => this.bar.selectionChanged()
  private readonly onMathReady = () => this.redrawAll()
  /**
   * What the formula lasso holds: the page and the rectangle on it, in the
   * page's own coordinates — snapped to what the reader reads for it, so the
   * box on the page is exactly what Ultracopy copies (`LassoInputView.caught`).
   */
  caught: { pageIndex: number; rect: Box; needsOCR: boolean; ink: Box[] } | null = null
  /** The lasso's pointer handlers, a page at a time, taken off with the lasso. */
  private readonly lassoInputs = new Map<PageView, AbortController>()
  /** The line over the pages while the lasso is out — what it is, how it ends. */
  private lassoBanner: HTMLElement | null = null

  constructor(private readonly actions: ReaderActions, options: ReaderOptions = {}) {
    this.state = options.state ?? freshReaderState()
    this.pane = options.pane ?? false
    this.layout = options.layout ?? 'continuous'
    living += 1
    this.scroll.append(this.pagesBox)
    // Outside the scroll view: the tool rack and the style panel belong to the
    // reader, not to the page under it, and a rack that scrolled away with the
    // paper would be gone the moment you needed it.
    this.overlayHost.className = 'reader-overlay'
    this.node = el('div', { class: 'panel reader-panel' }, [
      this.header, this.scroll, this.overlayHost, this.footer,
    ])
    this.node.classList.toggle('pane', this.pane)
    this.bar = new MarkBar({
      overlay: this.overlayHost,
      node: this.node,
      scroll: this.scroll,
      drawing: () => this.state.drawing,
      page: (index) => this.pages[index],
      selectionParts: () => this.selectionParts(),
      markSelection: (kind, colour) => void this.markSelection(kind, colour),
      addMarks: (parts, kind, colour, comment) => this.addMarks(parts, kind, colour, comment),
      setMarkComment: (pageIndex, id, comment) => this.setMarkComment(pageIndex, id, comment),
      recolorMark: (pageIndex, id, colour) => this.recolorMark(pageIndex, id, colour),
      removeMark: (pageIndex, id) => this.removeMark(pageIndex, id),
      markClientBox,
      ultracopy: () => this.actions.ultracopy?.(),
      toast: (message) => this.actions.toast(message),
      markShown: (id) => this.actions.markShown?.(id),
    })
    // A press anywhere in the reader — the page, the strip, the footer —
    // makes it the one in use: the pane in focus, and a paper kept open.
    on(this.node, 'pointerdown', () => this.actions.activated?.())
    on(this.scroll, 'scroll', () => {
      this.noteCurrentPage()
      this.bar.followScroll()
    }, { passive: true } as never)
    on(this.scroll, 'wheel', (event: WheelEvent) => {
      // Ctrl or ⌘ with the wheel is zoom everywhere else; it should be here.
      if (event.ctrlKey || event.metaKey) {
        event.preventDefault()
        this.zoomBy(event.deltaY < 0 ? 1.1 : 1 / 1.1, { soon: true })
        return
      }
      this.wheelTurn(event)
    })
    // The title is the handle in a pane: dragged to another zone, the pane
    // moves. Bound once — `update` redraws the strip on every change.
    on(this.header, 'dragstart', (event: DragEvent) => {
      const paper = this.paperID ? store.papers.find((entry) => entry.id === this.paperID) : null
      if (!this.pane || !paper || !event.dataTransfer) return
      event.dataTransfer.setData(PAPER_DRAG_TYPE, paper.id)
      event.dataTransfer.setData('text/plain', paper.meta.displayTitle)
      event.dataTransfer.effectAllowed = 'move'
    })
    // A passage the palette marked stays marked until the reader does
    // something else with the page, the way a selection would.
    on(this.pagesBox, 'pointerdown', () => {
      if (this.showingPassage) this.clearFound()
    })
    // A click on something drawn — a shape, a card, a stroke — takes the
    // pencil out by itself and goes straight to selecting it, so what was
    // drawn is never a picture you have to unlock first. The same press then
    // goes to the page's surface, which was not there to receive it.
    on(this.pagesBox, 'pointerdown', (event: PointerEvent) => {
      // The lasso is out: the press is its.
      if (this.state.drawing || this.state.lasso || event.button !== 0) return
      const page = this.pageContaining(event.target as Node)
      if (!page || !hitsDrawing(page, page.toPageFromClient(event.clientX, event.clientY))) return
      this.setDrawing(true)
      this.update()
      this.actions.changed()
      page.input?.press(event)
    })
    // A click on a mark — a press, not a drag across it, which is a
    // selection — brings up its controls, as the Mac's click on a mark does.
    // A link in the paper goes where it points ahead of any mark under it.
    // A press anywhere else puts the controls away.
    on(this.pagesBox, 'click', (event: MouseEvent) => {
      if (this.state.drawing || this.state.lasso || event.button !== 0) return
      const selection = window.getSelection()
      if (selection && !selection.isCollapsed) return
      const page = this.pageAtClient(event.clientX, event.clientY)
      const point = page?.pointOnPage(event.clientX, event.clientY)
      if (!page || !point) return this.bar.hideMark()
      void page.pageLinks().then(() => {
        const link = page.linkAt(point)
        if (link) {
          this.bar.hideMark()
          void this.followLink(link)
          return
        }
        const mark = markAt(page.marks, point)
        if (mark) this.bar.showMark(page, mark)
        else this.bar.hideMark()
      })
    })
    // A right-click on a mark offers its colour and its removal; on a
    // selection, the marks and a note (`MarkupCapablePDFView.menu(for:)`).
    on(this.pagesBox, 'contextmenu', (event: MouseEvent) => {
      if (this.state.drawing || this.state.lasso) return
      const page = this.pageAtClient(event.clientX, event.clientY)
      const point = page?.pointOnPage(event.clientX, event.clientY)
      const mark = page && point ? markAt(page.marks, point) : null
      const selection = window.getSelection()
      const selected = selection && !selection.isCollapsed && this.selectionParts().length > 0
      if (!mark && !selected) return
      event.preventDefault()
      const anchor = { getBoundingClientRect: () => new DOMRect(event.clientX, event.clientY, 0, 0) } as Element
      this.actions.menu?.(anchor, mark && page ? this.bar.markMenu(page, mark) : this.bar.selectionMenu())
    })
    // Over a link the pointer says so, and a URL shows where it goes.
    on(this.pagesBox, 'mousemove', (event: MouseEvent) => {
      if (this.state.drawing || this.state.lasso) return
      this.hover = { x: event.clientX, y: event.clientY, target: event.target as Node }
      if (this.hoverFrame) return
      this.hoverFrame = requestAnimationFrame(() => {
        this.hoverFrame = 0
        void this.updateHover()
      })
    })
    on(this.pagesBox, 'mouseleave', () => {
      this.showOverLink(null)
      this.hoverMark(null, null)
    })
    // A formula's picture arrives after the card was drawn; the page is
    // drawn again when it does.
    installMathProvider(this.onMathReady)
    on(document, 'selectionchange', this.onSelectionChange)
  }

  get isPane(): boolean {
    return this.pane
  }

  /** In a pane, or the whole page area: the strip changes, the reader stays
   *  — and so does the document it holds, which used to be read again. */
  setPane(pane: boolean) {
    if (pane === this.pane) return
    this.pane = pane
    this.node.classList.toggle('pane', pane)
    this.update()
  }

  /** Takes the reader down for good: its pages, its document, its listeners. */
  dispose() {
    if (this.paperID) undoStack.forget(this.paperID)
    this.generation += 1
    this.close()
    if (this.relayoutFrame) cancelAnimationFrame(this.relayoutFrame)
    if (this.hoverFrame) cancelAnimationFrame(this.hoverFrame)
    this.relayoutFrame = 0
    this.hoverFrame = 0
    for (const waiting of this.waiting.splice(0)) waiting(false)
    document.removeEventListener('selectionchange', this.onSelectionChange)
    this.bar.dispose()
    removeMathListener(this.onMathReady)
    this.node.remove()
    living -= 1
    if (living === 0) releaseTextCaches()
  }

  get overlayContainer(): HTMLElement {
    return this.overlayHost
  }

  // ---------------------------------------------------------------- pages

  /** A page's proxy, from the document the reader has open. */
  fetchPage(index: number): Promise<PDFPageProxy | null> {
    const document = this.document
    if (!document) return Promise.resolve(null)
    return document.getPage(index + 1).catch(() => null)
  }

  /** A page turned out another size than the first: the tops move, and a
   *  page near the view is drawn at its own size. */
  pageResized(page: PageView) {
    this.tops = null
    if (page.wanted) void page.render()
  }

  /** The page under a point in the window, if any is — from the tops laid
   *  out, not by measuring every page. */
  pageAtClient(clientX: number, clientY: number): PageView | null {
    if (this.pages.length === 0) return null
    const box = this.scroll.getBoundingClientRect()
    const y = clientY - box.top + this.scroll.scrollTop - this.pagesBox.offsetTop
    const guess = this.pages[pageAtOffset(this.pageTops(), y)]
    for (const page of [guess, this.pages[guess.index + 1], this.pages[guess.index - 1]]) {
      if (!page || page.root.style.display === 'none') continue
      const rect = page.root.getBoundingClientRect()
      if (clientX >= rect.left && clientX <= rect.right && clientY >= rect.top && clientY <= rect.bottom) return page
    }
    // A book's spread has two pages at one height.
    for (const page of this.pages) {
      if (page.root.style.display === 'none') continue
      const rect = page.root.getBoundingClientRect()
      if (clientX >= rect.left && clientX <= rect.right && clientY >= rect.top && clientY <= rect.bottom) return page
    }
    return null
  }

  private pageContaining(node: Node): PageView | null {
    const element = node instanceof Element ? node : node.parentElement
    const root = element?.closest('.page') as HTMLElement | null
    if (!root) return null
    return this.pages[Number(root.dataset.page)] ?? null
  }

  /** Each page's top, relative to the pages' box. */
  private pageTops(): number[] {
    if (!this.tops) this.tops = this.pages.map((page) => page.root.offsetTop)
    return this.tops
  }

  /** Puts a page — or the several pages of one step — back the way an undo
   *  snapshot has them, and writes them. */
  restore(snapshot: Snapshot) {
    for (const part of pagesOf(snapshot)) {
      const page = this.pages[part.pageIndex]
      if (!page) continue
      if (part.marks) {
        // A step of the marks touches the marks and nothing else.
        const before = page.marks
        page.marks = marksSnapshot(part.pageIndex, part.marks).marks ?? []
        page.redraw()
        void this.saveMarks(page, before)
        this.bar.hideMark()
        this.actions.marksChanged?.()
        continue
      }
      page.elements = part.elements.map((element) => element.copy())
      page.strokes = part.strokes.map((stroke) => stroke.translated({ x: 0, y: 0 }))
      page.redraw()
      void this.save(page)
    }
  }

  // --------------------------------------------------------------- opening

  async open(id: string, bytes: Uint8Array, why?: Reason, startAt = 0) {
    const generation = ++this.generation
    this.close()
    this.paperID = id
    // Something to look at while it loads, as the Mac says it — a blank page
    // reads as a paper that failed.
    const title = this.actions.title?.() ?? ''
    this.notice({
      title: title ? L(`${title} 여는 중`, `Opening ${title}`) : L('여는 중이에요', 'Opening'),
      body: '',
    }, el('span', { class: 'spinner' }))
    try {
      const opening = openDocument(bytes, (wrong) => this.askPassword(generation, wrong))
      this.opening = opening
      const document = await opening.promise
      if (generation !== this.generation) {
        void document.destroy()
        return
      }
      this.opening = null
      this.document = document
      this.state.pageCount = document.numPages
      // The first page, and every other laid out at its size until its own
      // arrives: most papers are one size throughout, and the paper shows
      // without waiting for the other five hundred to be asked for.
      const first = document.numPages > 0 ? await document.getPage(1) : null
      if (generation !== this.generation) return
      const shape: PageShape = first
        ? { view: [...(first.view as number[])], rotate: first.rotate, userUnit: (first as { userUnit?: number }).userUnit ?? 1 }
        : { view: [0, 0, 612, 792], rotate: 0, userUnit: 1 }
      this.pages = Array.from({ length: document.numPages }, (_, index) => new PageView(index, shape, this))
      if (first) void this.pages[0].fetchProxy()
      this.text = new DocumentText(this.pages)
      clear(this.pagesBox)
      for (const page of this.pages) this.pagesBox.append(page.root)
      this.relayout()
      // Where it was being read, as the Mac reopens it (`restoreReadingPosition`).
      if (startAt > 0 && startAt < this.pages.length) this.goToPage(startAt)
      this.watchVisibility()
      this.update()
      // Behind the first screenful: every page's own size, and the drawings.
      void this.fetchShapes(generation)
      void this.loadDrawings(id, generation)
    } catch (error) {
      if (generation !== this.generation) return
      this.opened(error, bytes, why)
    } finally {
      // Whoever was waiting for this paper is told it is in, or that it
      // never will be.
      if (generation === this.generation) {
        for (const waiting of this.waiting.splice(0)) waiting(this.document !== null && this.pages.length > 0)
      }
    }
  }

  /** Why a document did not open, said. */
  private opened(error: unknown, bytes: Uint8Array, why?: Reason) {
    const failure = classifyOpenError(error)
    // pdf.js implements the standard handler and no other. A file locked by
    // a certificate or a company's rights server arrives here.
    if (failure === 'rights') return this.showLocked({ kind: 'rights', handler: rightsHandler(bytes) ?? '' })
    if (failure === 'password') return
    // pdf.js says "Invalid PDF structure." to everything it cannot find a
    // catalogue in — a file still arriving, a placeholder, a container,
    // random bytes. Saying "the file may be damaged" to all of them is what
    // sent this bug hunting for corruption in a file Acrobat opens fine.
    if (why?.trouble === 'wrapped') {
      // A container that named nobody is still a container, and the locked
      // sentence is the true one for it. Said only now, after pdf.js has
      // actually failed.
      return this.showLocked({ kind: 'rights', handler: rightsHandler(bytes) ?? '' })
    }
    const message = formatError(error)
    if (why?.trouble) {
      return this.showTrouble(why.trouble, why.size ?? bytes.length, why.again, message, headBytes(bytes), headLine(bytes))
    }
    this.notice(damagedNotice(message), troubleButtons({ reveal: this.actions.reveal, again: why?.again }))
  }

  /** Every page's own size, a batch at a time behind the first screen. */
  private async fetchShapes(generation: number) {
    for (let from = 1; from < this.pages.length; from += SHAPE_BATCH) {
      if (generation !== this.generation) return
      await Promise.all(this.pages.slice(from, from + SHAPE_BATCH).map((page) => page.fetchProxy()))
      // A breath between batches, for the pages being drawn.
      await new Promise((resolve) => setTimeout(resolve, 0))
    }
  }

  /** Resolves once the paper is open — at once if it already is — with
   *  whether it opened at all. */
  whenOpen(): Promise<boolean> {
    if (this.document && this.pages.length > 0) return Promise.resolve(true)
    return new Promise((resolve) => this.waiting.push(resolve))
  }

  /** What is wrong with the bytes, said in the words that fit it. */
  showTrouble(
    trouble: ByteTrouble, size: number, again?: () => void,
    detail?: string, head?: string, line?: string | null,
  ) {
    this.notice(troubleNotice(trouble, size, detail, head, line), troubleButtons({ reveal: this.actions.reveal, again }))
  }

  /** A file whose key is held by a rights service, not by the reader. */
  showLocked(lock: PDFLock) {
    if (lock.kind !== 'rights') return
    // The next thing to try is the reader the company allows, and it is
    // reached from the folder.
    this.notice(lockedNotice(lock.handler), troubleButtons({ reveal: this.actions.reveal }))
  }

  private notice(notice: Notice, extra?: HTMLElement) {
    clear(this.pagesBox)
    this.pagesBox.append(noticeNode(notice, extra))
  }

  /** The password, asked for in the page area itself — and answered only to
   *  the paper that asked: a prompt left from a paper since replaced sends
   *  nothing. */
  private askPassword(generation: number, wrong: boolean): Promise<string | null> {
    return new Promise((resolve) => {
      if (generation !== this.generation) return resolve(null)
      const prompt = passwordPrompt(wrong, (password) => {
        if (generation !== this.generation) return resolve(null)
        this.notice(openingNotice())
        resolve(password)
      })
      this.notice(prompt.notice, prompt.node)
      prompt.focus()
    })
  }

  close() {
    this.caught = null
    for (const controller of this.lassoInputs.values()) controller.abort()
    this.lassoInputs.clear()
    this.drawObserver?.disconnect()
    this.drawObserver = null
    this.releaseObserver?.disconnect()
    this.releaseObserver = null
    this.near.clear()
    for (const page of this.pages) page.destroy()
    this.pages = []
    this.tops = null
    this.shownKey = ''
    clear(this.pagesBox)
    this.opening?.destroy()
    this.opening = null
    void this.document?.destroy()
    this.document = null
    this.text?.close()
    this.text = null
    this.paperID = null
    this.kept = null
    this.saveState = 'idle'
    this.foreignInk = false
    this.state.pageCount = 0
    this.state.currentPage = 0
    this.showingPassage = false
    // The outline and the history belong to the paper that was open.
    this.outlineRead = null
    this.history.clear()
    this.noteHistory()
    this.bar.reset()
  }

  // ---------------------------------------------------------- drawing pages

  private watchVisibility() {
    this.drawObserver?.disconnect()
    this.releaseObserver?.disconnect()
    this.drawObserver = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const page = this.pages[Number((entry.target as HTMLElement).dataset.page)]
          if (!page) continue
          if (entry.isIntersecting) {
            this.near.add(page)
            page.wanted = true
            void page.render()
          } else {
            this.near.delete(page)
          }
        }
      },
      // A screen either side, so scrolling meets a page already drawn.
      { root: this.scroll, rootMargin: '150% 0px' },
    )
    this.releaseObserver = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) continue
          const page = this.pages[Number((entry.target as HTMLElement).dataset.page)]
          if (page && (page.rendered || page.canvas.width > 0)) page.release()
        }
      },
      // Farther than it is drawn from, so a page scrolled back and forth
      // across the line is not drawn and dropped each time.
      { root: this.scroll, rootMargin: '400% 0px' },
    )
    for (const page of this.pages) {
      this.drawObserver.observe(page.root)
      this.releaseObserver.observe(page.root)
    }
  }

  /** Draws the pages near the view: the observer's set, not every page measured. */
  private renderNear() {
    for (const page of this.near) void page.render()
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
    const [x0, y0, x1, y1] = first.shape.view
    const turned = first.shape.rotate % 180 !== 0
    const unit = first.shape.userUnit || 1
    // A book fills the window with two pages across it and the gutter
    // between them, as the Mac's spread does — and fits the height too: a
    // spread fitted to the width alone ran off the foot of a wide window.
    return fitScale(
      { width: (turned ? y1 - y0 : x1 - x0) * unit, height: (turned ? x1 - x0 : y1 - y0) * unit },
      { width: this.scroll.clientWidth, height: this.scroll.clientHeight },
      this.layout,
      BOOK_GUTTER,
    )
  }

  /**
   * Lays every page out at the reader's scale, and keeps the place: the line
   * in the middle of the view stays in the middle. A zoom used to send the
   * paper somewhere else — the pixel it had been at, at the new size.
   */
  relayout() {
    // What the bar stood over has moved under it: it goes, the way the Mac's
    // does on a scale change — a note being written stays.
    this.bar.hideMark()
    if (!this.bar.isComposing) this.bar.hide()
    const anchor = this.anchor()
    const scale = this.baseScale() * this.state.zoom
    for (const page of this.pages) {
      page.layout(scale)
      page.setDrawing(this.state.drawing)
      this.syncLasso(page)
    }
    this.tops = null
    this.applyTint()
    this.applyLayout()
    if (anchor) this.returnToAnchor(anchor)
    this.renderNear()
  }

  /** The page in the middle of the view, and how far down it the middle is. */
  private anchor(): { index: number; fraction: number } | null {
    if (this.turnsPages || this.pages.length === 0 || this.scroll.scrollTop <= 0) return null
    const middle = this.scroll.scrollTop + this.scroll.clientHeight / 2 - this.pagesBox.offsetTop
    const index = pageAtOffset(this.pageTops(), middle)
    const page = this.pages[index]
    const height = page.root.offsetHeight
    if (height <= 0) return null
    return { index, fraction: (middle - page.root.offsetTop) / height }
  }

  private returnToAnchor(anchor: { index: number; fraction: number }) {
    const page = this.pages[anchor.index]
    if (!page) return
    const middle = page.root.offsetTop + anchor.fraction * page.root.offsetHeight
    this.scroll.scrollTop = Math.max(0, middle + this.pagesBox.offsetTop - this.scroll.clientHeight / 2)
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
    const shown = shownPages(this.layout, this.state.currentPage, this.pages.length)
    this.pagesBox.dataset.layout = this.layout
    const showing = shown ? new Set(shown) : null
    for (const page of this.pages) {
      page.root.style.display = !showing || showing.has(page.index) ? '' : 'none'
    }
    this.tops = null
    // To the top of the page only when another page is shown: a zoom, a
    // resize and a dragged divider lay out the same page again.
    const key = shown ? `${this.layout}:${shown.join(',')}` : 'all'
    if (shown && key !== this.shownKey) this.scroll.scrollTop = 0
    this.shownKey = key
  }

  /** Whether pages are turned (one, or a spread) rather than scrolled. */
  private get turnsPages(): boolean {
    return this.layout !== 'continuous'
  }

  /** Turns to the page wanted, when pages are turned; a scroll shows them all. */
  private ensureShowing(pageIndex: number) {
    if (!this.turnsPages || shownPages(this.layout, this.state.currentPage, this.pages.length)?.includes(pageIndex)) return
    this.setCurrentPage(pageIndex)
    this.applyLayout()
  }

  /** The page being read: said in the footer, and remembered for next time. */
  private setCurrentPage(index: number) {
    if (index === this.state.currentPage) return
    this.state.currentPage = index
    this.updateFooter()
    this.actions.pageChanged?.(index)
  }

  /** Goes to a page, at its top — with pages turned, turns to it. */
  goToPage(index: number) {
    const page = this.pages[index]
    if (!page) return
    if (this.turnsPages) {
      this.setCurrentPage(index)
      this.applyLayout()
      return
    }
    this.scroll.scrollTop = Math.max(0, page.root.offsetTop + this.pagesBox.offsetTop - 14)
    this.setCurrentPage(index)
  }

  /**
   * The wheel, where pages are turned. A book's spread is fitted and does not
   * scroll, so the wheel turns it; one page scrolls until its edge, and past
   * the edge the wheel turns — it used to stop dead there. Accumulated until
   * decisive, with the Mac's thresholds: 60 points of a trackpad, three
   * notches of a wheel (`turnPage(with:in:)`).
   */
  private wheelTurn(event: WheelEvent) {
    if (!this.turnsPages || this.state.drawing) return
    const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY
    if (delta === 0) return
    const atBottom = this.scroll.scrollTop + this.scroll.clientHeight >= this.scroll.scrollHeight - 1
    const atTop = this.scroll.scrollTop <= 0
    const pastEdge = this.layout === 'book' || (delta > 0 ? atBottom : atTop)
    if (!pastEdge) {
      this.wheelTravel = 0
      return
    }
    event.preventDefault()
    const now = performance.now()
    if (now - this.wheelAt > 400 || Math.sign(delta) !== Math.sign(this.wheelTravel)) this.wheelTravel = 0
    this.wheelAt = now
    // A line is about 40 pixels; a mouse notch is a hundred or three lines.
    const pixels = event.deltaMode === 1 ? delta * 40 : event.deltaMode === 2 ? delta * this.scroll.clientHeight : delta
    this.wheelTravel += pixels
    const threshold = event.deltaMode === 0 && Math.abs(event.deltaY) < 50 ? 60 : 3 * 40
    if (Math.abs(this.wheelTravel) < threshold) return
    const by = this.wheelTravel > 0 ? 1 : -1
    this.wheelTravel = 0
    this.turnPage(by)
    // One page turned onto shows its top when it was turned forward, its
    // foot when back — where the wheel was going.
    if (this.layout === 'single') this.scroll.scrollTop = by > 0 ? 0 : this.scroll.scrollHeight
  }

  /** Waits for the browser to lay out a page just shown, so what is measured
   *  on it is where it is now. */
  private settled(): Promise<void> {
    return new Promise((resolve) => requestAnimationFrame(() => resolve()))
  }

  /** Moves by whole pages — by spreads in a book. */
  turnPage(by: number) {
    const next = turnedTo(this.layout, this.state.currentPage, by, this.pages.length)
    if (next === null) return
    this.setCurrentPage(next)
    if (!this.turnsPages) {
      this.scrollToPage(next)
      return
    }
    this.applyLayout()
  }

  setLayout(layout: PageLayout) {
    if (layout === this.layout) return
    // The page being read stays the page being read: a paper switched to a
    // book used to open its spread at the front.
    const page = this.state.currentPage
    this.layout = layout
    // Laid out again: a book is two pages across the column, so its pages
    // are drawn smaller than the others are.
    this.relayout()
    this.goToPage(page)
    this.updateFooter()
  }

  zoomBy(factor: number, options: { soon?: boolean } = {}) {
    this.state.zoom = this.clampedZoom(this.state.zoom * factor)
    if (options.soon) this.relayoutSoon()
    else this.relayout()
    this.update()
    this.showZoom()
  }

  setZoom(zoom: number) {
    this.state.zoom = this.clampedZoom(zoom)
    this.relayout()
    this.update()
    this.showZoom()
  }

  /** Actual size: a point of the page as a point of the screen — 96 pixels
   *  to the inch against the page's 72 — not the fit to the column. */
  actualSize() {
    this.setZoom((96 / 72) / this.baseScale())
  }

  /** The Mac's limits, on the page's own scale rather than on the fit:
   *  a tenth of actual size to eight times. */
  private clampedZoom(zoom: number): number {
    const base = this.baseScale()
    return Math.min(Math.max(zoom, 0.1 / base), 8 / base)
  }

  /** The zoom, said for a moment over the page — the footer no longer
   *  carries it. */
  private showZoom() {
    if (!this.zoomBadge) {
      this.zoomBadge = el('div', { class: 'reader-zoom' })
      this.overlayHost.append(this.zoomBadge)
    }
    this.zoomBadge.textContent = `${Math.round(this.state.zoom * this.baseScale() * 72 / 96 * 100)}%`
    this.zoomBadge.dataset.on = 'true'
    clearTimeout(this.zoomBadgeTimer)
    this.zoomBadgeTimer = window.setTimeout(() => { if (this.zoomBadge) this.zoomBadge.dataset.on = 'false' }, 1600)
  }

  /**
   * Lays the pages out at the next frame rather than at once.
   *
   * A pinch on a trackpad arrives as a stream of wheel events — a hundred a
   * second — and a window being resized as a stream of its own; each one was
   * resizing every page in the paper and drawing the ones in view. The pages
   * can only be drawn once a frame anyway, so the ones in between were work
   * nobody ever saw.
   */
  relayoutSoon() {
    if (this.relayoutFrame) return
    this.relayoutFrame = requestAnimationFrame(() => {
      this.relayoutFrame = 0
      this.relayout()
    })
  }

  private noteCurrentPage() {
    // With pages turned the scroll position says nothing about which page
    // is showing; the page is whatever was turned to.
    if (this.turnsPages || this.pages.length === 0) return
    const middle = this.scroll.scrollTop + this.scroll.clientHeight / 2 - this.pagesBox.offsetTop
    this.setCurrentPage(pageAtOffset(this.pageTops(), middle))
  }

  // ------------------------------------------------------------- drawings

  /**
   * Loads the pages' drawings, and takes what is in the file when this
   * machine has no sidecar for it yet — a paper annotated on a Mac, opened
   * here for the first time. The pages are already showing; each drawn page
   * redraws when its drawing lands.
   */
  private async loadDrawings(id: string, generation: number) {
    const [drawings, marks] = await Promise.all([
      call('drawing:loadAll', { id }),
      call('marks:load', { id }),
    ])
    if (generation !== this.generation) return
    for (const [index, drawing] of Object.entries(drawings.pages)) {
      const page = this.pages[Number(index)]
      if (!page) continue
      page.elements = drawing.elements.map(SketchElement.from)
      page.strokes = drawing.strokes.map(InkStroke.from)
      page.redraw()
    }
    for (const [index, list] of Object.entries(marks)) {
      const page = this.pages[Number(index)]
      if (!page) continue
      page.marks = list
      page.redraw()
    }
    this.marksLoaded = true
    // The Marks tab lists what just arrived.
    this.actions.marksChanged?.()
    if (drawings.foreignInk !== this.foreignInk) {
      this.foreignInk = drawings.foreignInk
      this.updateFooter()
    }
    if (drawings.unreadable.length > 0) {
      const pages = drawings.unreadable.map((index) => index + 1).join(', ')
      this.actions.toast(L(
        `${pages}쪽 손글씨는 맥에서 쓴 거예요. 맥이 아직 PDF에는 쓰지 않았어요. 맥에서 이 논문을 한 번 열면 건너와요.`,
        `Handwriting on page ${pages} came from a Mac and is not in the PDF yet. `
        + 'Open the paper on the Mac once, and it comes across.',
      ))
    }
  }

  /** Saves one page's drawing, sidecar first; the PDF follows behind. A
   *  save that fails says so — it used to vanish, and the drawing with it at
   *  the next open. */
  async save(page: PageView) {
    if (!this.paperID) return
    const id = this.paperID
    try {
      await Promise.all([
        call('sketch:save', { id, pageIndex: page.index, elements: page.elements.map((element) => element.encode()) }),
        call('ink:save', { id, pageIndex: page.index, strokes: page.strokes.map((stroke) => stroke.encode()) }),
      ])
    } catch {
      this.actions.toast(L('그림을 저장하지 못했어요.', "Paper Time couldn't save the drawing."))
    }
  }

  /** Whether the marks have been read — the Marks tab says «opening» until then. */
  marksLoaded = false

  /**
   * Marks another device made while the paper is open: its journal arrived
   * in the folder, and the pages take what it says (`reloadFromDisk` →
   * `reconcile`). A page whose note is being written is left for now.
   */
  async reloadMarks() {
    const id = this.paperID
    if (!id || !this.marksLoaded) return
    const generation = this.generation
    const marks = await call('marks:load', { id })
    if (generation !== this.generation || id !== this.paperID) return
    let changedAny = false
    this.pages.forEach((page, index) => {
      const next = marks[index] ?? []
      if (JSON.stringify(next) === JSON.stringify(page.marks)) return
      if (this.bar.isComposing) return
      page.marks = next
      page.redraw()
      changedAny = true
    })
    if (changedAny) {
      this.bar.hideMark()
      this.actions.marksChanged?.()
    }
  }

  async saveMarks(page: PageView, before: Mark[]) {
    if (!this.paperID) return
    // The other pages' marks, so a mark moved off this page is not taken
    // for one removed.
    const elsewhere = this.pages.filter((other) => other !== page).flatMap((other) => other.marks.map((mark) => mark.id))
    try {
      await call('marks:save', { id: this.paperID, pageIndex: page.index, marks: page.marks, before, elsewhere })
    } catch {
      this.actions.toast(L('표시를 저장하지 못했어요.', "Paper Time couldn't save the mark."))
    }
  }

  private readonly sketchHost: SketchInputHost = {
    changed: () => this.actions.changed(),
    save: (target) => void this.save(target),
  }

  setDrawing(drawing: boolean) {
    // The pen and the lasso are two modes of one page: the pen out, the
    // lasso goes away with its catch.
    if (drawing && this.state.lasso) this.setLasso(false)
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

  /** Redraws every drawn page's marks and drawing. */
  redrawAll() {
    for (const page of this.pages) page.redraw()
  }

  /** Only the gesture layers — the selection changed, nothing on a page did. */
  redrawOverlays() {
    for (const page of this.near) page.redrawOverlay()
  }

  // ---------------------------------------------------------------- marks

  private selectionParts(): SelectionPart[] {
    return selectionParts(this.node, (x, y) => this.pageAtClient(x, y))
  }

  /** Marks whatever is selected, and clears the selection. */
  markSelection(kind: MarkKind, colorName = 'yellow', comment?: string): boolean {
    const parts = this.selectionParts()
    if (parts.length === 0) return false
    this.addMarks(parts, kind, colorName, comment)
    window.getSelection()?.removeAllRanges()
    return true
  }

  private addMarks(parts: SelectionPart[], kind: MarkKind, colorName: string, comment?: string) {
    const color = [...(MARK_COLORS[colorName] ?? MARK_COLORS.yellow)] as [number, number, number]
    const name = comment ? L('노트 더하기', 'Add Note')
      : kind === 'highlight' ? L('형광펜', 'Highlight') : kind === 'underline' ? L('밑줄', 'Underline') : L('취소선', 'Strikethrough')
    for (const { page, quads, text } of parts) {
      const mark: Mark = { id: makeUUID(), kind, quads, color, text }
      if (comment) mark.comment = comment
      this.changeMarks(page, [...page.marks, mark], name)
    }
  }

  /** A highlighter stroke fitted to the words it covered (`StrokeSnapper`):
   *  a mark like any other, on the marks' undo. */
  markFromStroke(page: PageView, kind: 'highlight' | 'underline', boxes: { x: number; y: number; width: number; height: number }[], text: string, colorName: string): boolean {
    if (boxes.length === 0) return false
    const color = [...(MARK_COLORS[colorName] ?? MARK_COLORS.yellow)] as [number, number, number]
    const mark: Mark = { id: makeUUID(), kind, quads: boxes.map(rectToQuad), color, text }
    this.changeMarks(page, [...page.marks, mark], kind === 'highlight' ? L('형광펜', 'Highlight') : L('밑줄', 'Underline'))
    return true
  }

  /**
   * Every change to a page's marks goes through here: drawn, written to the
   * journal (and the file after it), put on the undo stack — so ⌘Z takes a
   * highlight back, or brings a removed one back, as it does on the Mac.
   */
  private changeMarks(page: PageView, next: Mark[], name?: string) {
    const paperID = this.paperID ?? undefined
    const before = page.marks
    undoStack.record(marksSnapshot(page.index, before, paperID, name), marksSnapshot(page.index, next, paperID, name))
    page.marks = next
    page.redraw()
    void this.saveMarks(page, before)
    this.actions.marksChanged?.()
  }

  // MARK: - The formula lasso

  /**
   * The formula lasso out or away (`ReaderConfiguration.mode == .lasso`). Out,
   * every page's lasso surface takes the mouse in place of the text layer, the
   * pen is put away and the selection cleared, as the Mac does
   * (`updateCanvasInteraction`). Away, the catch goes with it: a rectangle
   * nobody can see is not a selection anybody meant.
   */
  setLasso(on: boolean) {
    if (on && this.state.drawing) this.setDrawing(false)
    this.state.lasso = on
    if (on) {
      this.bar.hideMark()
      this.bar.hide()
      window.getSelection()?.removeAllRanges()
    } else {
      this.dropCatch()
    }
    for (const page of this.pages) this.syncLasso(page)
    this.showLassoBanner(on)
    // The header's lasso button lights with the mode, whichever way it was switched.
    this.update()
  }

  /**
   * The lasso says it is out. A crosshair alone does not: nothing on the
   * page changes when the mode is switched on, so a line stands over the
   * pages — glass, as the zoom badge is — saying what the mode is and how it
   * ends. It takes no mouse; the page under it is still the lasso's.
   */
  private showLassoBanner(on: boolean) {
    if (!on) {
      this.lassoBanner?.remove()
      this.lassoBanner = null
      return
    }
    if (this.lassoBanner) return
    const banner = el('div', { class: 'reader-lasso-banner', role: 'status' })
    const mark = iconNode('lasso')
    if (mark) banner.append(mark)
    banner.append(el('span', {
      text: L('수식 올가미 — 끌어서 수식을 잡아요. Esc로 끝내요.', 'Formula Lasso — drag around a formula. Press Esc to finish.'),
    }))
    this.overlayHost.append(banner)
    this.lassoBanner = banner
  }

  /** The lasso lets go of what it holds; the box goes off the page. */
  dropCatch() {
    this.caught = null
    for (const page of this.pages) page.showLasso(null)
  }

  /** A page's surface and handlers kept in step with the mode. */
  private syncLasso(page: PageView) {
    page.setLasso(this.state.lasso)
    if (this.state.lasso && !this.lassoInputs.has(page)) this.lassoInputs.set(page, this.attachLasso(page))
    if (!this.state.lasso) {
      this.lassoInputs.get(page)?.abort()
      this.lassoInputs.delete(page)
    }
  }

  /**
   * The drag: a rectangle from the press to the release, kept on the page.
   * A click — under two points either way — lets go of the catch; a drag
   * catches what is under it (`LassoInputView.mouseUp`).
   */
  private attachLasso(page: PageView): AbortController {
    const controller = new AbortController()
    const signal = controller.signal
    const surface = page.lassoSurface
    let origin: { x: number; y: number } | null = null
    const rectFrom = (a: { x: number; y: number }, b: { x: number; y: number }) => ({
      x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(b.x - a.x), height: Math.abs(b.y - a.y),
    })
    surface.addEventListener('pointerdown', (event: PointerEvent) => {
      if (event.button !== 0) return
      event.preventDefault()
      surface.setPointerCapture(event.pointerId)
      origin = page.toPageFromClient(event.clientX, event.clientY)
      // The catch stays while the next rectangle is drawn; the drawing shows over it.
      page.showLasso(rectFrom(origin, origin), 'drag')
    }, { signal })
    surface.addEventListener('pointermove', (event: PointerEvent) => {
      if (!origin) return
      page.showLasso(rectFrom(origin, page.toPageFromClient(event.clientX, event.clientY)), 'drag')
    }, { signal })
    surface.addEventListener('pointerup', (event: PointerEvent) => {
      if (!origin) return
      const rect = rectFrom(origin, page.toPageFromClient(event.clientX, event.clientY))
      origin = null
      if (rect.width < 2 || rect.height < 2) {
        this.dropCatch()
        return
      }
      void this.catchRect(page.index, rect)
    }, { signal })
    surface.addEventListener('pointercancel', () => {
      origin = null
      this.restoreLassoBox(page)
    }, { signal })
    return controller
  }

  /** The box as the catch has it — after a drawing that was abandoned. */
  private restoreLassoBox(page: PageView) {
    const caught = this.caught && this.caught.pageIndex === page.index ? this.caught : null
    page.showLasso(caught ? caught.rect : null, 'caught', caught?.needsOCR ?? false, caught?.ink ?? [])
  }

  /**
   * Catches what the rectangle reaches, snapped to it (`LassoInputView.catch`):
   * the whole formula touched, limits and bar and number included, or the
   * words inside — or the rectangle as drawn when the page cannot be read.
   * The first time in a run, says what the catch is for.
   */
  async catchRect(pageIndex: number, rect: Box) {
    const page = this.pages[pageIndex]
    if (!page) return null
    const input = await this.mathInput(page, [this.lassoBoxOf(rect)], '', true)
    // What the reader will read for the rectangle, and where the ink of it
    // is — a box a glyph, and the rules among them. Both in the page's own
    // coordinates, as the scanner's glyphs are. The ink is what the page
    // shows: those letters, and no others, turn the accent colour.
    const snapped = extentRead(input, rect)
    const ink = snapped ? extentInk(input, rect) ?? [] : []
    if (!this.state.lasso || this.pages[pageIndex] !== page) return null
    // Nothing to snap to — a scanned page, a formula pasted in as a picture,
    // glyphs without meanings: the rectangle stays as drawn, dashed, and the
    // picture is read instead when it is copied (`LassoInputView.catch`).
    const needsOCR = snapped === null
    const held = snapped ?? rect
    this.caught = { pageIndex, rect: held, needsOCR, ink }
    for (const other of this.pages) other.showLasso(other === page ? held : null, 'caught', needsOCR, other === page ? ink : [])
    if (!lassoExplained) {
      lassoExplained = true
      this.actions.toast(L('수식을 잡았어요. ⇧⌘C로 LaTeX을 복사하고, ⌘L로 노트에 넣어요.', 'Caught. ⇧⌘C copies it as LaTeX; ⌘L quotes it in the note.')
        .replace('⇧⌘C', shortcutText('⇧⌘C', platform)).replace('⌘L', shortcutText('⌘L', platform)))
    }
    return held
  }

  /** The catch as a line box: a point wider either side, as the selection's are. */
  private lassoBoxOf(rect: { x: number; y: number; width: number; height: number }) {
    return { x: rect.x - 1, y: rect.y, width: rect.width + 2, height: rect.height }
  }

  /** The catch as the Mac's MathReader takes it: one page, the rectangle
   *  where the selection's lines would go. Nothing without a catch. */
  async lassoForMath(): Promise<MathPage[]> {
    const caught = this.caught
    const page = caught ? this.pages[caught.pageIndex] : undefined
    if (!caught || !page) return []
    return [await this.mathInput(page, [this.lassoBoxOf(caught.rect)], '', true)]
  }

  /**
   * The catch read off a picture of the page — the formula OCR model, in
   * the main process's worker (`FormulaOCR.read(page:rect:)`). The catch's
   * rectangle is what is drawn; the picture is padded a little round it.
   * Null when the model read nothing, or the page could not be drawn.
   */
  async readCaughtByOCR(): Promise<{ latex: string; tokens: number; seconds: number } | null> {
    const caught = this.caught
    const page = caught ? this.pages[caught.pageIndex] : undefined
    if (!caught || !page) return null
    return this.readByOCR(page, caught.rect)
  }

  /** A rectangle of a page read by the formula OCR model, catch or not. */
  async readByOCR(page: PageView, rect: { x: number; y: number; width: number; height: number }): Promise<{ latex: string; tokens: number; seconds: number } | null> {
    const pixels = await page.ocrPixels(rect)
    // Blank paper is answered here: the model, shown nothing, makes something up.
    if (!pixels || isBlankPicture(pixels)) return null
    return call('ocr:read', { pixels })
  }

  /** The catch as a note cites it — the rectangle, with no words of its own. */
  lassoAnchor(): { pageIndex: number; rect: { x: number; y: number; width: number; height: number }; text: string } | null {
    return this.caught ? { pageIndex: this.caught.pageIndex, rect: this.caught.rect, text: '' } : null
  }

  /** For a probe: the mode, whether its banner stands, the catch and its ink. */
  lassoReport() {
    return {
      lasso: this.state.lasso,
      banner: this.lassoBanner !== null && this.lassoBanner.isConnected,
      caught: this.caught,
      ink: this.caught?.ink.length ?? 0,
      boxes: this.pages.map((page) => page.lassoReport()).filter((one) => one !== null),
    }
  }

  // MARK: - Reading mathematics

  /**
   * One page as the Mac's MathReader takes it: the page's glyphs and rules
   * (read in the main process by the same scanner), the boxes the selection
   * covers — or the lasso's one — and the text layer's characters near them.
   * A page the scanner could not read comes with no glyphs, and the reader
   * falls back to the words. `byInk` for the lasso: a glyph is inside its
   * rectangle when the middle of its ink is, where a selection's line boxes
   * hold the glyphs whose baselines they hold (the Mac's `Region.byInk`).
   */
  private async mathInput(page: PageView, lineBoxes: { x: number; y: number; width: number; height: number }[], selectionString: string, byInk = false): Promise<MathPage> {
    const id = this.paperID
    const scanned = id ? await call('math:page', { id, pageIndex: page.index }).catch(() => null) : null
    const reachBox = lineBoxes.reduce((all, one) => ({
      x: Math.min(all.x, one.x), y: Math.min(all.y, one.y),
      width: Math.max(all.x + all.width, one.x + one.width) - Math.min(all.x, one.x),
      height: Math.max(all.y + all.height, one.y + one.height) - Math.min(all.y, one.y),
    }))
    const reach = { x: reachBox.x - 40, y: reachBox.y - 40, width: reachBox.width + 80, height: reachBox.height + 80 }
    return {
      glyphs: scanned?.glyphs ?? [],
      rules: scanned?.rules ?? [],
      lineBoxes,
      characters: page.characterBoxes(reach),
      pageText: page.layerText() ?? '',
      selectionString,
      cropBox: scanned?.cropBox ?? { x: 0, y: 0, width: 612, height: 792 },
      italicElsewhere: scanned?.italicElsewhere ?? null,
      byInk,
    }
  }

  /**
   * The selection as the Mac's MathReader takes it, page by page: the
   * selection's lines on each page, and what `mathInput` adds. Nothing when
   * there is no selection.
   */
  async selectionForMath(): Promise<MathPage[]> {
    const parts = this.selectionParts()
    if (!this.paperID || parts.length === 0) return []
    const pages: MathPage[] = []
    for (const part of parts) {
      const lineBoxes = part.quads.map((quad) => {
        const xs = [quad[0], quad[2], quad[4], quad[6]]
        const ys = [quad[1], quad[3], quad[5], quad[7]]
        const x = Math.min(...xs)
        const y = Math.min(...ys)
        // A point wider either side, as the Mac's line boxes are.
        return { x: x - 1, y, width: Math.max(...xs) - x + 2, height: Math.max(...ys) - y }
      })
      pages.push(await this.mathInput(part.page, lineBoxes, part.text))
    }
    return pages
  }

  /** The passage selected on this reader's pages, as a note cites it. */
  selectionAnchor() {
    return selectionAnchor(this.node, (node) => this.pageContaining(node))
  }

  /** Every mark in the paper in reading order. */
  marksList(): { pageIndex: number; mark: Mark }[] {
    return marksInReadingOrder(this.pages)
  }

  /** Takes a mark off its page — the Marks tab's Delete, the editor's trash. */
  removeMark(pageIndex: number, id: string, name = L('표시 지우기', 'Delete Mark')) {
    const page = this.pages[pageIndex]
    if (!page || !page.marks.some((mark) => mark.id === id)) return
    this.changeMarks(page, page.marks.filter((mark) => mark.id !== id), name)
    this.bar.hideMark()
  }

  /** The pen's eraser over a mark takes it off, as the Mac's does — one
   *  step back with ⌘Z («Erase Mark»). */
  eraseMarkAt(page: PageView, point: { x: number; y: number }): boolean {
    const mark = markAt(page.marks, point)
    if (!mark) return false
    this.removeMark(page.index, mark.id, L('표시 지우기', 'Erase Mark'))
    return true
  }

  /** The mark under the pointer draws lighter with an edge, and the pointer
   *  is a hand — the Mac's `MarkHover`. */
  private hoverMark(page: PageView | null, point: { x: number; y: number } | null) {
    const mark = page && point ? markAt(page.marks, point) : null
    const id = mark?.id ?? null
    for (const other of this.near) {
      const wanted = other === page ? id : null
      if (other.hoveredMarkID === wanted) continue
      other.hoveredMarkID = wanted
      other.redraw()
    }
    this.scroll.classList.toggle('over-mark', Boolean(mark))
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
    }), L('노트', 'Note'))
  }

  /** A mark in another of the five colours. */
  recolorMark(pageIndex: number, id: string, colorName: string) {
    const page = this.pages[pageIndex]
    const color = MARK_COLORS[colorName]
    if (!page || !color) return
    this.changeMarks(page, page.marks.map((mark) =>
      (mark.id === id ? { ...mark, color: [...color] as [number, number, number] } : mark)), L('표시 색', 'Mark Colour'))
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
    await this.settled()
    page.wanted = true
    await page.render()
    const tops = mark.quads.map((quad) => page.toView(quad[0], Math.max(quad[1], quad[3])).y)
    this.scroll.scrollTop = Math.max(0, page.root.offsetTop + Math.min(...tops) - this.scroll.clientHeight / 3)
    await this.settled()
    this.bar.showMark(page, mark)
  }

  hideMarkEditor() {
    this.bar.hideMark()
  }

  /** Whether the bar is up over a selection or a mark — Escape's first step. */
  get markBarShowing(): boolean {
    return this.bar.showing
  }

  hideMarkBar() {
    this.bar.hide()
  }

  // ---------------------------------------------------------- finding words

  /** Every page's text, read once per document. */
  pageTexts(): Promise<string[]> {
    return this.text?.every() ?? Promise.resolve([])
  }

  /** One page's text — for a passage, which needs one page. */
  pageText(index: number): Promise<string> {
    return this.text?.page(index) ?? Promise.resolve('')
  }

  /** Every place in the paper that says the query. */
  findAll(query: string): Promise<Found[]> {
    return this.text?.findAll(query) ?? Promise.resolve([])
  }

  /** Puts found places on their pages, one of them the current one. */
  showFound(found: Found[], current: number) {
    this.showingPassage = false
    for (const page of this.pages) {
      const had = page.findMarks.length > 0
      page.findMarks = []
      if (had) page.drawFind()
    }
    for (const [index, place] of found.entries()) {
      this.pages[place.pageIndex]?.findMarks.push({ start: place.start, end: place.end, current: index === current })
    }
    // Drawn on the pages that are drawn; the others draw theirs when they are.
    for (const page of this.near) if (page.findMarks.length > 0) page.drawFind()
  }

  clearFound() {
    this.showFound([], -1)
  }

  /**
   * Scrolls so the current found place is in the middle of the view.
   *
   * The page has to be drawn before its words have a place, so it is shown
   * and drawn first, and measured once the browser has laid it out.
   */
  async scrollToFound(pageIndex: number) {
    const page = this.pages[pageIndex]
    if (!page) return
    if (this.turnsPages) {
      this.ensureShowing(pageIndex)
      await this.settled()
    } else {
      const top = page.root.offsetTop
      const bottom = top + page.root.offsetHeight
      const shown = this.scroll.scrollTop
      if (bottom < shown || top > shown + this.scroll.clientHeight) this.scroll.scrollTop = top - 14
    }
    page.wanted = true
    await page.render()
    page.drawFind()
    const box = page.currentBox()
    if (!box) return
    this.scroll.scrollTop = Math.max(0, page.root.offsetTop + box.y + box.height / 2 - this.scroll.clientHeight / 2)
    const wide = page.root.offsetLeft + box.x + box.width / 2 - this.scroll.clientWidth / 2
    if (this.scroll.scrollWidth > this.scroll.clientWidth) this.scroll.scrollLeft = Math.max(0, wide)
  }

  /** Sends the reader to a passage the index found, and marks it. */
  async revealPassage(passage: { pageIndex: number; location: number; length: number }, query: string): Promise<boolean> {
    if (!(await this.whenOpen())) return false
    if (!this.pages[passage.pageIndex] || !this.text) return false
    const range = await this.text.passage(passage, query)
    this.showFound([{ pageIndex: passage.pageIndex, ...range }], 0)
    this.showingPassage = true
    await this.scrollToFound(passage.pageIndex)
    return true
  }

  // ---------------------------------------------------------------- links

  private async updateHover() {
    const at = this.hover
    if (!at) return
    const page = this.pageContaining(at.target)
    const point = page?.pointOnPage(at.x, at.y)
    if (!page || !point) {
      this.hoverMark(null, null)
      return this.showOverLink(null)
    }
    await page.pageLinks()
    const link = page.linkAt(point)
    this.showOverLink(link)
    this.hoverMark(link ? null : page, link ? null : point)
  }

  private showOverLink(link: PageLink | null) {
    if (link === this.overLink) return
    this.overLink = link
    this.scroll.classList.toggle('over-link', Boolean(link))
    if (link?.url) this.scroll.title = link.url
    else this.scroll.removeAttribute('title')
  }

  get canGoBackInDocument(): boolean {
    return this.history.canGoBack
  }

  get canGoForwardInDocument(): boolean {
    return this.history.canGoForward
  }

  private here(): DocumentPlace {
    return { page: this.state.currentPage, top: this.scroll.scrollTop, of: this.scroll.scrollHeight }
  }

  private async goTo(place: DocumentPlace) {
    if (this.turnsPages) {
      this.ensureShowing(place.page)
      await this.settled()
    }
    this.scroll.scrollTop = scrollFor(place, this.scroll.scrollHeight)
  }

  private noteHistory() {
    this.state.canGoBack = this.history.canGoBack
    this.state.canGoForward = this.history.canGoForward
    this.actions.historyChanged?.()
  }

  goBackInDocument() {
    const place = this.history.goBack(this.here())
    if (!place) return
    void this.goTo(place)
    this.noteHistory()
  }

  goForwardInDocument() {
    const place = this.history.goForward(this.here())
    if (!place) return
    void this.goTo(place)
    this.noteHistory()
  }

  /** Goes where a link points, and remembers where from. */
  async followLink(link: PageLink) {
    if (link.url) {
      // Out to the browser or the mail app, and nothing else: a link in a
      // paper is written by whoever wrote the paper.
      if (isOpenableLink(link.url)) void call('shell:openExternal', { url: link.url })
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
    this.history.leave(this.here())
    await this.showPlace(pageIndex, top)
    this.noteHistory()
  }

  /**
   * A passage a note quotes: its page, with room above it — the Mac pads the
   * jump so the line is not against the top edge — and the passage lit for a
   * moment so the eye finds it (`flashRect`).
   */
  async jumpToPassage(pageIndex: number, rect: { x: number; y: number; width: number; height: number }) {
    const page = this.pages[pageIndex]
    if (!page) return
    await this.jumpTo(pageIndex, rect.y + rect.height + 24)
    const a = page.toView(rect.x, rect.y + rect.height)
    const b = page.toView(rect.x + rect.width, rect.y)
    const flash = el('div', { class: 'passage-flash' })
    Object.assign(flash.style, {
      left: `${Math.min(a.x, b.x) - 3}px`,
      top: `${Math.min(a.y, b.y) - 3}px`,
      width: `${Math.abs(b.x - a.x) + 6}px`,
      height: `${Math.abs(b.y - a.y) + 6}px`,
    })
    page.root.append(flash)
    setTimeout(() => flash.remove(), 1400)
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
      return { pageIndex, top: destinationTop(kind?.name, args) }
    } catch {
      return null
    }
  }

  /**
   * The outline the PDF carries — the headings a LaTeX paper's bookmarks
   * are — flattened in reading order, each with the page and height it goes
   * to. Read once a paper, since a jump back in is the common case.
   */
  outline(): Promise<{ title: string; depth: number; pageIndex: number | null; top: number | null }[]> {
    const document = this.document
    if (!document) return Promise.resolve([])
    if (!this.outlineRead) {
      this.outlineRead = document.getOutline().then(async (tree: OutlineNode[] | null) =>
        Promise.all(flattenOutline(tree).map(async (entry) => {
          const place = await this.destinationPlace(entry.dest)
          return { title: entry.title, depth: entry.depth, pageIndex: place?.pageIndex ?? null, top: place?.top ?? null }
        }))).catch(() => [])
    }
    return this.outlineRead
  }

  /** Shows a page, and a height on it when there is one to show. */
  async showPlace(pageIndex: number, top: number | null) {
    const page = this.pages[pageIndex]
    if (!page) return
    this.ensureShowing(pageIndex)
    await this.settled()
    page.wanted = true
    await page.render()
    const y = top === null ? 0 : page.toView(0, top).y
    this.scroll.scrollTop = Math.max(0, page.root.offsetTop + y - 14)
  }

  scrollToPage(index: number) {
    const page = this.pages[index]
    if (!page) return
    this.scroll.scrollTo({ top: page.root.offsetTop - 14, behavior: 'smooth' })
  }

  // ------------------------------------------------------------ the chrome

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

  /** Says whether this is the pane in focus; the border shows it. */
  setFocused(focused: boolean) {
    this.node.classList.toggle('focused', focused)
    this.header.classList.toggle('focused', focused)
  }

  update() {
    const paper = store.papers.find((entry) => entry.id === this.paperID)
    fillHeader(this.header, {
      title: paper ? paper.meta.displayTitle : null,
      drawing: this.state.drawing,
      pane: this.pane,
      toggleDrawing: () => {
        this.setDrawing(!this.state.drawing)
        this.update()
        this.actions.changed()
      },
      lasso: this.state.lasso,
      // The same path as the `lasso` command (`commands.ts`): the mode, the
      // header again, and the window told.
      toggleLasso: () => {
        this.setLasso(!this.state.lasso)
        this.update()
        this.actions.changed()
      },
      close: this.actions.close,
    })
    this.updateFooter()
  }

  private updateFooter() {
    clear(this.footer)
    if (!this.document) return
    const count = this.state.pageCount
    const left = spreadStart(this.layout, this.state.currentPage) + 1
    fillFooter(this.footer, {
      count,
      left,
      right: this.layout === 'book' ? Math.min(left + 1, count) : left,
      book: this.layout === 'book',
      turns: this.turnsPages,
      kept: this.kept,
      saveState: this.saveState,
      foreignInk: this.foreignInk,
      turn: (by) => this.turnPage(by),
    })
  }

  /** What the file is doing with what was made here (`paper:saveState`). */
  noteSaveState(state: SaveState) {
    if (state === this.saveState) return
    this.saveState = state
    this.updateFooter()
  }

  /**
   * One page, drawn small, for the page grid — queued two at a time and kept
   * (`pageThumbnails.ts`). Its own canvas and its own render: the reader's
   * page canvases are sized for reading and scaling those down gives a
   * blurry thumbnail.
   */
  thumbnail(index: number, width: number): Promise<HTMLCanvasElement | null> {
    const page = this.pages[index]
    if (!page || !this.paperID) return Promise.resolve(null)
    const generation = this.generation
    return thumbnails.draw(`${this.paperID}:${index}:${width}`, async () => {
      const proxy = await page.fetchProxy()
      if (!proxy || generation !== this.generation) return null
      const base = proxy.getViewport({ scale: 1 })
      const dpr = devicePixels(window.devicePixelRatio)
      const viewport = proxy.getViewport({ scale: (width / base.width) * dpr })
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
    })
  }

  /**
   * Where the paper is being read, so a rebuild of the window's boxes can put
   * it back. A scroll view taken out of the document comes back at the top,
   * and a reader at the top is a reader on page one.
   */
  place(): ReaderPlace {
    return { top: this.scroll.scrollTop, of: this.scroll.scrollHeight }
  }

  /** Puts the paper back where it was (`scrollFor`). */
  returnTo(place: ReaderPlace) {
    if (place.top <= 0) return
    this.scroll.scrollTop = scrollFor(place, this.scroll.scrollHeight)
  }

  // ------------------------------------------------------------------ tint

  /**
   * Draws the paper for the reader's tint (`shared/pageTint.ts`).
   *
   * The ground is the whole reading area and not the page: under multiply
   * and night the pages have no background and no shadow of their own, so
   * the gap between two pages is the same colour as the paper they are
   * printed on and a page does not read as a card. Glass has no ground of
   * its own — the area is clear and the panel shows. Asked again whenever
   * the tint, its colour or the window's appearance changes.
   */
  applyTint() {
    const { pageTint, pageTintColor } = store.settings
    const rendering = renderingFor(pageTint, pageTintColor, isDarkAppearance())
    const ground = groundFor(pageTint, pageTintColor)
    this.node.dataset.rendering = rendering
    if (ground) this.node.style.setProperty('--tint-ground', ground)
    else this.node.style.removeProperty('--tint-ground')
    // What night screens onto — under Glass the panel's own colour, which the
    // stylesheet knows and the canvas does not.
    const under = rendering !== 'night' ? '#000000' : ground ?? (getComputedStyle(this.node).backgroundColor || '#000000')
    for (const page of this.pages) page.applyTint(rendering, under)
  }

  /** For a probe: how the paper is drawn now, and each page's pictures. */
  tintReport() {
    return {
      rendering: this.node.dataset.rendering ?? null,
      ground: getComputedStyle(this.scroll).backgroundColor,
      pages: this.pages.map((page) => page.imageReport()),
    }
  }

  /** For a probe: what the reader holds — pages drawn, pages with a proxy,
   *  canvas pixels, text runs. */
  memoryReport() {
    let pixels = 0
    let drawn = 0
    let proxies = 0
    let runs = 0
    for (const page of this.pages) {
      for (const canvas of [page.canvas, page.markCanvas, page.drawCanvas, page.images.canvas]) pixels += canvas.width * canvas.height
      if (page.rendered) drawn += 1
      if (page.proxy) proxies += 1
      runs += page.textRunCount
    }
    return { pages: this.pages.length, drawn, proxies, near: this.near.size, megapixels: Math.round(pixels / 1e5) / 10, runs }
  }
}
