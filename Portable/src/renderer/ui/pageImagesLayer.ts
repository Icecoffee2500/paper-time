/**
 * Under night, a page's pictures again as printed.
 *
 * The page is inverted on its way to the screen and screened onto the
 * ground; a photograph put through that is a negative. So the pictures are
 * copied out of the page canvas — which holds the page as printed, the night
 * filter being applied on the way to the screen and not to its pixels — onto
 * a canvas of their own over the inverted page and under the words.
 */
import { OPS, type PDFPageProxy } from '../pdf.js'
import { NIGHT_FILTER } from '../../shared/pageTint.js'
import { imageRects, isInkOnWhite, pixelRect, tones, type OperatorList, type PageRect } from '../../shared/pageImages.js'

/** A picture found on the page, and — once the page has been drawn and the
 *  picture looked at — whether it is a picture at all (`isInkOnWhite`). */
interface PageImage {
  rect: PageRect
  picture?: boolean
  tones?: { paper: number; tone: number; coloured: number }
}

/** What the layer needs from its page, when it is asked to draw. */
export interface ImageSource {
  /** The page as printed, at the size it is shown. */
  canvas: HTMLCanvasElement
  markCanvas: HTMLCanvasElement
  drawCanvas: HTMLCanvasElement
  /** Page point → view pixel, for the layout the canvas was drawn at. */
  transform: number[]
  dpr: number
  hasMarks: boolean
  hasDrawing: boolean
}

export class PageImagesLayer {
  /** Zero pixels wide outside night. */
  readonly canvas: HTMLCanvasElement
  /** Where the pictures are: found the first time night meets the page and
   *  kept — they are in the page's own space, so a new zoom does not move
   *  them, and a page released and drawn again has the same pictures. */
  private images: PageImage[] | null = null
  private asked: Promise<PageImage[]> | null = null
  /** Which list they came from, for a probe: the one drawn, or one asked for. */
  private from: 'drawn' | 'asked' | null = null

  constructor() {
    this.canvas = document.createElement('canvas')
    this.canvas.className = 'image-canvas'
    this.clear()
  }

  get found(): boolean {
    return this.images !== null
  }

  clear() {
    if (this.canvas.width === 0 && this.canvas.height === 0) return
    this.canvas.width = 0
    this.canvas.height = 0
  }

  /**
   * Where the pictures are, found once per page.
   *
   * Read from the operator list pdf.js has just drawn the page with, when it
   * lets that be read — `_intentStates` is its own bookkeeping, not an API,
   * so failing that it is asked for a list of its own. The one it drew with
   * is the better answer twice over: it is exactly what is on the canvas,
   * and asking for another makes pdf.js read the page again and hand every
   * picture over a second time, decoded, to be kept as long as the page is.
   */
  find(proxy: PDFPageProxy, view: number[]): Promise<void> {
    if (this.images) return Promise.resolve()
    if (!this.asked) {
      const [x0, y0, x1, y1] = view
      const walk = (list: OperatorList) => {
        this.images = imageRects(list, OPS as never, { bounds: { x: x0, y: y0, width: x1 - x0, height: y1 - y0 } })
          .map((rect) => ({ rect }))
        return this.images
      }
      const drawn = drawnList(proxy)
      this.from = drawn ? 'drawn' : 'asked'
      this.asked = drawn
        ? Promise.resolve(walk(drawn))
        : proxy
          // The same annotations the page is drawn with: another app's stamp
          // may be a picture too.
          .getOperatorList({ annotationMode: 1 })
          .then(walk)
          .catch(() => walk({ fnArray: [], argsArray: [] }))
    }
    return this.asked.then(() => undefined)
  }

  /**
   * Draws the pictures as printed onto the layer's canvas, with what lies
   * over each laid over it again the way it looks beside it: the marks
   * multiplied as they are on paper, and the drawing turned to night and
   * screened onto the ground, so a stroke that runs across a photograph is
   * one colour all the way and a white card over it is the ground's colour,
   * as it is everywhere else.
   *
   * The canvas is only as big as the pictures together, placed over them in
   * fractions of the page — a page canvas's worth of pixels for a photograph
   * a tenth of its size would be most of the cost of night.
   */
  compose(source: ImageSource, ground: string) {
    const images = this.images
    if (!images) return
    const page = source.canvas
    const boxes: { x: number; y: number; width: number; height: number }[] = []
    for (const image of images) {
      if (image.picture === false) continue
      const box = pixelRect(image.rect, source.transform, source.dpr, page)
      if (!box) continue
      if (image.picture === undefined) image.picture = isPicture(image, page, box)
      if (image.picture) boxes.push(box)
    }
    if (boxes.length === 0) return this.clear()
    const left = Math.min(...boxes.map((box) => box.x))
    const top = Math.min(...boxes.map((box) => box.y))
    const right = Math.max(...boxes.map((box) => box.x + box.width))
    const bottom = Math.max(...boxes.map((box) => box.y + box.height))
    const target = this.canvas
    if (target.width !== right - left || target.height !== bottom - top) {
      target.width = right - left
      target.height = bottom - top
    }
    Object.assign(target.style, {
      left: `${(100 * left) / page.width}%`,
      top: `${(100 * top) / page.height}%`,
      width: `${(100 * (right - left)) / page.width}%`,
      height: `${(100 * (bottom - top)) / page.height}%`,
      right: 'auto',
      bottom: 'auto',
    })
    const context = target.getContext('2d')!
    context.setTransform(1, 0, 0, 1, 0, 0)
    context.globalCompositeOperation = 'source-over'
    context.filter = 'none'
    context.clearRect(0, 0, target.width, target.height)
    // Only what is there to lay over: most pages have neither.
    const marks = source.hasMarks && source.markCanvas.width === page.width && source.markCanvas.height === page.height
    const drawing = source.hasDrawing && source.drawCanvas.width === page.width && source.drawCanvas.height === page.height
    for (const { x, y, width: w, height: h } of boxes) {
      const [dx, dy] = [x - left, y - top]
      context.drawImage(page, x, y, w, h, dx, dy, w, h)
      if (marks) {
        context.globalCompositeOperation = 'multiply'
        context.drawImage(source.markCanvas, x, y, w, h, dx, dy, w, h)
        context.globalCompositeOperation = 'source-over'
      }
      if (drawing) {
        // Night, then screened onto the ground — and the drawing's own
        // coverage put back, so the ground shows only where it is drawn.
        const scratch = scratchContext(w, h)
        scratch.setTransform(1, 0, 0, 1, 0, 0)
        scratch.globalCompositeOperation = 'copy'
        scratch.filter = NIGHT_FILTER
        scratch.drawImage(source.drawCanvas, x, y, w, h, 0, 0, w, h)
        scratch.filter = 'none'
        scratch.globalCompositeOperation = 'screen'
        scratch.fillStyle = ground
        scratch.fillRect(0, 0, w, h)
        scratch.globalCompositeOperation = 'destination-in'
        scratch.drawImage(source.drawCanvas, x, y, w, h, 0, 0, w, h)
        scratch.globalCompositeOperation = 'source-over'
        context.drawImage(scratch.canvas, 0, 0, w, h, dx, dy, w, h)
      }
    }
  }

  /** For a probe: the pictures this page found, and which of them it keeps
   *  as printed (null until the page has been drawn under night). */
  report(): { from: string | null; rect: PageRect; picture: boolean | null; tones: { paper: number; tone: number; coloured: number } | null }[] | null {
    if (!this.images) return null
    return this.images.map((image) => ({ from: this.from, rect: image.rect, picture: image.picture ?? null, tones: image.tones ?? null }))
  }
}

/** The finished operator list pdf.js drew this page with, if it has one and
 *  lets it be seen. `pdfListIsReadable` checks once that it still does. */
export function drawnList(proxy: PDFPageProxy): OperatorList | null {
  const states = (proxy as unknown as { _intentStates?: unknown })._intentStates
  if (!(states instanceof Map)) return null
  for (const state of states.values()) {
    const list = (state as { operatorList?: OperatorList & { lastChunk?: boolean } } | null)?.operatorList
    if (list?.lastChunk && Array.isArray(list.fnArray) && Array.isArray(list.argsArray)) return list
  }
  return null
}

let warnedUnreadable = false

/**
 * Says once, in the console, when this pdf.js no longer lets the list it
 * drew with be read: every page under night then asks for a second list and
 * holds its pictures twice. Silent, that would be a doubling of memory
 * nobody knew had happened — the day pdf.js renames its bookkeeping.
 */
export function noteDrawnListMissing(proxy: PDFPageProxy) {
  if (warnedUnreadable || drawnList(proxy)) return
  warnedUnreadable = true
  console.warn('pageImages - pdf.js keeps no readable operator list; pictures are found from a second list')
}

/** A canvas for laying the drawing over a picture, shared by every page. */
let scratch: HTMLCanvasElement | null = null

function scratchContext(width: number, height: number): CanvasRenderingContext2D {
  const canvas = (scratch ??= document.createElement('canvas'))
  if (canvas.width < width || canvas.height < height) {
    canvas.width = Math.max(canvas.width, width)
    canvas.height = Math.max(canvas.height, height)
  }
  return canvas.getContext('2d')!
}

/** And a small one to look at a picture through — its own, because a canvas
 *  that is read back is moved off the graphics card, and the one above has
 *  filters to run. */
let looking: CanvasRenderingContext2D | null = null

/**
 * Whether a picture is one, looked at in the page as drawn. Ink on white — a
 * scanned page of text, a line drawing, a black-and-white chart — goes to
 * night with the words, because kept as printed it is the white rectangle
 * night exists to take away (`isInkOnWhite`).
 */
function isPicture(image: PageImage, page: HTMLCanvasElement, box: { x: number; y: number; width: number; height: number }): boolean {
  const side = 64
  if (!looking) {
    const canvas = document.createElement('canvas')
    canvas.width = side
    canvas.height = side
    looking = canvas.getContext('2d', { willReadFrequently: true })
  }
  const context = looking
  if (!context) return true
  // Single pixels, not averages: a line of type averaged is grey.
  context.globalCompositeOperation = 'copy'
  context.imageSmoothingEnabled = false
  context.drawImage(page, box.x, box.y, box.width, box.height, 0, 0, side, side)
  context.globalCompositeOperation = 'source-over'
  try {
    const pixels = context.getImageData(0, 0, side, side).data
    image.tones = tones(pixels)
    return !isInkOnWhite(pixels)
  } catch {
    return true
  }
}
