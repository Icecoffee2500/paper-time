/**
 * Where the pictures are on a page.
 *
 * Night turns the page's luminance over, and a photograph turned over is a
 * negative — so under night the reader draws the pictures again as printed,
 * over the inverted page. This finds them. The Mac walks the content stream
 * itself (`PageImages.swift`, `q`/`Q`/`cm` and every `Do` of an image); here
 * pdf.js has already done the walking, and its operator list says the same
 * thing in its own words: `save`, `restore` and `transform` for the matrix,
 * a begin and an end around every form and every annotation's appearance,
 * and a paint for every image.
 *
 * An image is drawn into the unit square of the matrix in force, so its
 * corners are where that square lands. Stencil masks are left out: an
 * `ImageMask` is paint in the shape of a picture — usually a glyph, a rule or
 * a logo in one colour — and it inverts with the ink around it, as it should.
 * So is a hairline drawn as an image, which is the Mac's rule too; anything
 * bigger is kept, because a figure made of small photographs — a grid of
 * video frames, a row of robot views — is the common case, and each of them
 * turned into a negative is what «the pictures are inverted too» meant.
 *
 * Pure over the operator list, with pdf.js's operator numbers handed in, so
 * the walk is tested without a window and the renderer's bundle is the only
 * place pdf.js is imported.
 */

/** pdf.js's operator list, as `PDFPageProxy.getOperatorList()` gives it. */
export interface OperatorList {
  fnArray: ArrayLike<number>
  argsArray: ArrayLike<unknown>
}

/**
 * The operator numbers the walk reads: pdf.js's `OPS`, handed in. A name the
 * installed pdf.js does not have (`paintJpegXObject` went in 3.0) is simply
 * never matched.
 */
export type ImageOps = Partial<Record<
  | 'save' | 'restore' | 'transform'
  | 'paintFormXObjectBegin' | 'paintFormXObjectEnd'
  | 'beginGroup' | 'endGroup'
  | 'beginAnnotation' | 'endAnnotation'
  | 'paintImageXObject' | 'paintInlineImageXObject' | 'paintJpegXObject'
  | 'paintImageXObjectRepeat' | 'paintInlineImageXObjectGroup',
  number
>>

/** A matrix as PDF and the canvas write it: x′ = a·x + c·y + e, y′ = b·x + d·y + f. */
export type Matrix = [number, number, number, number, number, number]

/** A rectangle in the page's own space — PDF points, y going up. */
export interface PageRect {
  x: number
  y: number
  width: number
  height: number
}

/** No bigger than this, in points, and it is a rule, not a picture — the
 *  Mac's number (`PageImages.swift`, which once kept only 40 × 24 and up). */
export const MIN_IMAGE_WIDTH = 12
export const MIN_IMAGE_HEIGHT = 12

const IDENTITY: Matrix = [1, 0, 0, 1, 0, 0]

/** `m · n`: `n` applied first, then `m` — what `ctx.transform(n)` does to a
 *  canvas whose matrix is `m`, and what `cm` does in a content stream. */
export function concat(m: ArrayLike<number>, n: ArrayLike<number>): Matrix {
  return [
    m[0] * n[0] + m[2] * n[1],
    m[1] * n[0] + m[3] * n[1],
    m[0] * n[2] + m[2] * n[3],
    m[1] * n[2] + m[3] * n[3],
    m[0] * n[4] + m[2] * n[5] + m[4],
    m[1] * n[4] + m[3] * n[5] + m[5],
  ]
}

/** Where the unit square lands under a matrix: the box round its corners. */
export function unitSquare(m: ArrayLike<number>): PageRect {
  const xs = [m[4], m[0] + m[4], m[2] + m[4], m[0] + m[2] + m[4]]
  const ys = [m[5], m[1] + m[5], m[3] + m[5], m[1] + m[3] + m[5]]
  const x = Math.min(...xs)
  const y = Math.min(...ys)
  return { x, y, width: Math.max(...xs) - x, height: Math.max(...ys) - y }
}

/** A rectangle of any matrix is only a rectangle if its numbers are. */
function isMatrix(value: unknown): value is ArrayLike<number> {
  if (!value || typeof value !== 'object' || (value as ArrayLike<number>).length !== 6) return false
  for (let i = 0; i < 6; i += 1) if (!Number.isFinite((value as ArrayLike<number>)[i])) return false
  return true
}

export interface ImageRectOptions {
  /** The page's box: pictures outside it are dropped and the rest are cut to it. */
  bounds?: PageRect
  minWidth?: number
  minHeight?: number
}

/**
 * Every picture's rectangle on the page, in page space, in the order drawn.
 */
export function imageRects(list: OperatorList, ops: ImageOps, options: ImageRectOptions = {}): PageRect[] {
  const code = (name: keyof ImageOps) => ops[name] ?? Number.NaN
  const SAVE = code('save')
  const RESTORE = code('restore')
  const TRANSFORM = code('transform')
  const FORM_BEGIN = code('paintFormXObjectBegin')
  const FORM_END = code('paintFormXObjectEnd')
  const GROUP_BEGIN = code('beginGroup')
  const GROUP_END = code('endGroup')
  const ANNOTATION_BEGIN = code('beginAnnotation')
  const ANNOTATION_END = code('endAnnotation')
  const IMAGE = code('paintImageXObject')
  const INLINE_IMAGE = code('paintInlineImageXObject')
  const JPEG = code('paintJpegXObject')
  const REPEAT = code('paintImageXObjectRepeat')
  const INLINE_GROUP = code('paintInlineImageXObjectGroup')

  const found: PageRect[] = []
  const stack: Matrix[] = []
  let current: Matrix = IDENTITY
  const pop = () => {
    // pdf.js ignores a restore with nothing saved, and so does this.
    const saved = stack.pop()
    if (saved) current = saved
  }

  const { fnArray, argsArray } = list
  for (let i = 0; i < fnArray.length; i += 1) {
    const fn = fnArray[i]
    const args = argsArray[i] as ArrayLike<unknown> | null | undefined
    switch (fn) {
      case SAVE:
        stack.push(current)
        break
      case RESTORE:
        pop()
        break
      case TRANSFORM:
        if (isMatrix(args)) current = concat(current, args)
        break
      case FORM_BEGIN: {
        // A form is drawn with its own matrix after ours, inside a save.
        stack.push(current)
        const matrix = args?.[0]
        if (isMatrix(matrix)) current = concat(current, matrix)
        break
      }
      case FORM_END:
        pop()
        break
      // A transparency group is a save of its own; its matrix is the form's,
      // and the form's begin, which follows it, applies it.
      case GROUP_BEGIN:
        stack.push(current)
        break
      case GROUP_END:
        pop()
        break
      case ANNOTATION_BEGIN: {
        // An appearance starts from the page's own space, whatever came
        // before it: its placement, then its form's matrix.
        stack.length = 0
        const placement = args?.[2]
        const matrix = args?.[3]
        current = IDENTITY
        if (isMatrix(placement)) current = concat(current, placement)
        if (isMatrix(matrix)) current = concat(current, matrix)
        break
      }
      case ANNOTATION_END:
        stack.length = 0
        current = IDENTITY
        break
      case IMAGE:
      case INLINE_IMAGE:
      case JPEG:
        found.push(unitSquare(current))
        break
      case REPEAT: {
        // One image at several places: [objId, scaleX, scaleY, positions].
        const scaleX = Number(args?.[1])
        const scaleY = Number(args?.[2])
        const positions = args?.[3] as ArrayLike<number> | undefined
        if (!positions || !Number.isFinite(scaleX) || !Number.isFinite(scaleY)) break
        for (let k = 0; k + 1 < positions.length; k += 2) {
          found.push(unitSquare(concat(current, [scaleX, 0, 0, scaleY, positions[k], positions[k + 1]])))
        }
        break
      }
      case INLINE_GROUP: {
        // Small inline images gathered into one call: [image, placements].
        const map = args?.[1] as ArrayLike<{ transform?: unknown }> | undefined
        if (!map) break
        for (let k = 0; k < map.length; k += 1) {
          const placement = map[k]?.transform
          if (isMatrix(placement)) found.push(unitSquare(concat(current, placement)))
        }
        break
      }
      default:
        break
    }
  }

  const minWidth = options.minWidth ?? MIN_IMAGE_WIDTH
  const minHeight = options.minHeight ?? MIN_IMAGE_HEIGHT
  const out: PageRect[] = []
  for (const rect of found) {
    const cut = options.bounds ? intersection(rect, options.bounds) : rect
    if (!cut || !(cut.width > minWidth && cut.height > minHeight)) continue
    out.push(cut)
  }
  return out
}

/** A pixel this light (of 255, by luma) is paper. */
export const PAPER_LUMA = 224
/** Between this and paper, a pixel is a tone — what a photograph is made of
 *  and type is not. Below it, ink. */
export const TONE_LUMA = 96
/** A pixel whose channels are this far apart (of 255) has a colour. */
export const COLOURED_CHROMA = 64

/** What a picture's pixels are, as shares of the opaque ones: paper, tone
 *  (light greys and mid-tones), and colour. */
export function tones(rgba: ArrayLike<number>): { paper: number; tone: number; coloured: number; seen: number } {
  let seen = 0
  let paper = 0
  let tone = 0
  let coloured = 0
  for (let i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue
    const r = rgba[i]
    const g = rgba[i + 1]
    const b = rgba[i + 2]
    seen += 1
    const luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    if (luma >= PAPER_LUMA) paper += 1
    else if (luma >= TONE_LUMA) tone += 1
    if (Math.max(r, g, b) - Math.min(r, g, b) >= COLOURED_CHROMA) coloured += 1
  }
  if (seen === 0) return { paper: 0, tone: 0, coloured: 0, seen }
  return { paper: paper / seen, tone: tone / seen, coloured: coloured / seen, seen }
}

/**
 * Whether what an image shows is ink on white paper rather than a picture.
 *
 * Night keeps pictures as printed so a photograph is not a negative — but a
 * scanned page is an image too, and so is a line drawing or a chart saved as
 * one, and kept as printed each is the white rectangle night exists to take
 * away. A scanned textbook in the corpus (686 pages, one image each and not
 * a word of text) read at night as a column of white cards. So an image that
 * is paper and ink and little else goes to night with the words, and turned
 * over it reads as the page around it does.
 *
 * Measured on the corpus, 64 × 64 samples each: the textbook's text blocks
 * are 78–94% paper with 1–12% tone and no colour; a light grey photograph of
 * a robot (v-jepa 2, Figure 1) is only 32% paper and 67% tone; photographs
 * and coloured figures have colour in a fifth to all of them. Hence: at least
 * three fifths paper, at most a fifth tone, at most a twentieth colour (a
 * yellowed page is still paper). The samples are single pixels, not
 * averages: averaged, a line of type is a tone.
 */
export function isInkOnWhite(rgba: ArrayLike<number>): boolean {
  const { paper, tone, coloured, seen } = tones(rgba)
  return seen > 0 && paper >= 0.6 && tone <= 0.2 && coloured <= 0.05
}

/** The part of `a` inside `b`, or null when they do not meet. */
export function intersection(a: PageRect, b: PageRect): PageRect | null {
  const x = Math.max(a.x, b.x)
  const y = Math.max(a.y, b.y)
  const right = Math.min(a.x + a.width, b.x + b.width)
  const top = Math.min(a.y + a.height, b.y + b.height)
  if (!(right > x && top > y)) return null
  return { x, y, width: right - x, height: top - y }
}

/**
 * A page-space rectangle in a canvas's pixels, through the viewport's matrix
 * and the canvas's own scale, widened to whole pixels and kept on the canvas.
 * Null when nothing of it is left.
 */
export function pixelRect(
  rect: PageRect,
  viewport: ArrayLike<number>,
  scale: number,
  canvas: { width: number; height: number },
): { x: number; y: number; width: number; height: number } | null {
  const box = unitSquare(concat(viewport, [rect.width, 0, 0, rect.height, rect.x, rect.y]))
  const left = Math.max(0, Math.floor(box.x * scale))
  const top = Math.max(0, Math.floor(box.y * scale))
  const right = Math.min(canvas.width, Math.ceil((box.x + box.width) * scale))
  const bottom = Math.min(canvas.height, Math.ceil((box.y + box.height) * scale))
  if (right <= left || bottom <= top) return null
  return { x: left, y: top, width: right - left, height: bottom - top }
}
