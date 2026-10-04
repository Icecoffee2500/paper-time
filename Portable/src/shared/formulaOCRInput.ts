/**
 * The picture the formula OCR model takes, and how it is made from a
 * rectangle of a page — the Mac's `FormulaOCR.picture(of:rect:)` and
 * `pixelValues(of:)`, as numbers rather than as a bitmap context.
 *
 * The rectangle is drawn three times its size on white, grown a little
 * (letters pressed against the picture's edge came back wrong — «messace»),
 * stretched — not fitted — to the model's 384×384 square, as the model was
 * trained, and normalised to (x/255 − 0.5)/0.5 with the planes CHW. The
 * drawing itself needs a canvas; everything that can be said in arithmetic
 * is said here and tested (`src/test/formulaOCRInput.ts`).
 */

/** The model's square. */
export const OCR_SIDE = 384
/** How many times the page's size the rectangle is drawn at. */
export const OCR_SCALE = 3
/** The margin round the rectangle, in page points: 6 across, 5 up and down. */
export const OCR_MARGIN = { x: 6, y: 5 }
/** What the model takes: `[1, 3, 384, 384]`. */
export const OCR_SHAPE = [1, 3, OCR_SIDE, OCR_SIDE] as const

export interface Box { x: number; y: number; width: number; height: number }

/**
 * The rectangle grown by the margin, kept inside the page — the picture
 * is padded; the catch itself is not.
 */
export function paddedForOCR(rect: Box, page: Box, margin = OCR_MARGIN): Box {
  const left = Math.max(page.x, rect.x - margin.x)
  const top = Math.max(page.y, rect.y - margin.y)
  const right = Math.min(page.x + page.width, rect.x + rect.width + margin.x)
  const bottom = Math.min(page.y + page.height, rect.y + rect.height + margin.y)
  return { x: left, y: top, width: Math.max(0, right - left), height: Math.max(0, bottom - top) }
}

/** The picture's size in pixels for a rectangle drawn at `scale` — never empty. */
export function pictureSize(rect: Box, scale = OCR_SCALE): { width: number; height: number } {
  return {
    width: Math.max(1, Math.round(rect.width * scale)),
    height: Math.max(1, Math.round(rect.height * scale)),
  }
}

/** Where the picture lands on the model's square: all of it, aspect be damned. */
export function stretchTarget(side = OCR_SIDE): Box {
  return { x: 0, y: 0, width: side, height: side }
}

/** One channel value as the model takes it. */
export function normalised(value: number): number {
  return (value / 255 - 0.5) / 0.5
}

/**
 * RGBA pixels of a `side`×`side` picture as the model's tensor: three
 * planes — red, green, blue — each `side`×`side`, row-major, normalised.
 * The alpha is ignored: the picture is drawn on white.
 */
export function pixelValues(rgba: ArrayLike<number>, side = OCR_SIDE): Float32Array {
  const plane = side * side
  if (rgba.length < plane * 4) throw new Error(`the picture has ${rgba.length} bytes, not ${plane * 4}`)
  const out = new Float32Array(3 * plane)
  for (let i = 0; i < plane; i += 1) {
    const p = i * 4
    out[i] = normalised(rgba[p])
    out[plane + i] = normalised(rgba[p + 1])
    out[2 * plane + i] = normalised(rgba[p + 2])
  }
  return out
}

/**
 * Whether the picture has anything in it. The model, shown blank paper,
 * does not say so — it writes `\newcommand{\R}{\mathbb R}…` with a straight
 * face — so a rectangle on an empty margin is answered here, before the
 * model: nothing to read. Ink is anything darker than near-white in any
 * channel; `least` is how many such values make a picture (a 384×384 square
 * holds 442,368 values, and a thin fraction bar alone is a few hundred).
 */
export function isBlankPicture(pixels: Float32Array, least = 64): boolean {
  let inked = 0
  // Near-white is 0.9 and above once normalised (≈ 242/255).
  for (let i = 0; i < pixels.length; i += 1) {
    if (pixels[i] < 0.9 && (inked += 1) >= least) return false
  }
  return true
}
