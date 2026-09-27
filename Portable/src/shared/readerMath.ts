/**
 * The reader's arithmetic, without a window or a PDF: where a point of the
 * page is on screen, which pages a spread shows, which page the middle of
 * the view is on, where a destination points, what an open error was.
 *
 * Pure, so the reader's state machines are tested (`src/test/reader.ts`)
 * rather than looked at.
 */

/** A page's shape as the file gives it: its box, its turn, its unit. */
export interface PageShape {
  /** `[x0, y0, x1, y1]`, the page's crop box in its own points. */
  view: number[]
  rotate: number
  userUnit: number
}

export interface Viewport {
  width: number
  height: number
  /** Page point → view pixel, as pdf.js's own `PageViewport` makes it. */
  transform: number[]
  scale: number
  rotation: number
}

/**
 * `PDFPageProxy.getViewport` without the page: the same numbers pdf.js's
 * `PageViewport` works out, so a page can be laid out — and a point on it
 * converted — before its proxy has been fetched, and without making a new
 * viewport on every pointer move.
 */
export function pageViewport(shape: PageShape, scale: number): Viewport {
  const { view } = shape
  const unit = scale * (shape.userUnit || 1)
  const centerX = (view[2] + view[0]) / 2
  const centerY = (view[3] + view[1]) / 2
  let rotation = shape.rotate % 360
  if (rotation < 0) rotation += 360
  const [a, b, c, d] = ({
    0: [1, 0, 0, -1],
    90: [0, 1, 1, 0],
    180: [-1, 0, 0, 1],
    270: [0, -1, -1, 0],
  } as Record<number, number[]>)[rotation] ?? [1, 0, 0, -1]
  let offsetX: number
  let offsetY: number
  let width: number
  let height: number
  if (a === 0) {
    offsetX = Math.abs(centerY - view[1]) * unit
    offsetY = Math.abs(centerX - view[0]) * unit
    width = (view[3] - view[1]) * unit
    height = (view[2] - view[0]) * unit
  } else {
    offsetX = Math.abs(centerX - view[0]) * unit
    offsetY = Math.abs(centerY - view[1]) * unit
    width = (view[2] - view[0]) * unit
    height = (view[3] - view[1]) * unit
  }
  return {
    width,
    height,
    transform: [
      a * unit, b * unit, c * unit, d * unit,
      offsetX - a * unit * centerX - c * unit * centerY,
      offsetY - b * unit * centerX - d * unit * centerY,
    ],
    scale,
    rotation,
  }
}

export function applyTransform(m: number[], x: number, y: number): { x: number; y: number } {
  return { x: m[0] * x + m[2] * y + m[4], y: m[1] * x + m[3] * y + m[5] }
}

export function applyInverseTransform(m: number[], x: number, y: number): { x: number; y: number } {
  const determinant = m[0] * m[3] - m[1] * m[2]
  return {
    x: (x * m[3] - y * m[2] + m[2] * m[5] - m[4] * m[3]) / determinant,
    y: (-x * m[1] + y * m[0] + m[4] * m[1] - m[5] * m[0]) / determinant,
  }
}

/** The device pixels a canvas is drawn at: the screen's, and at most two. */
export function devicePixels(ratio: number | undefined): number {
  return Math.min(ratio || 1, 2)
}

export type PageLayout = 'continuous' | 'single' | 'book'

/** The first page of what shows with a page: itself, or its spread's left page. */
export function spreadStart(layout: PageLayout, index: number): number {
  return layout === 'book' ? index - (index % 2) : index
}

/** The pages on show when pages are turned; null when they all scroll. */
export function shownPages(layout: PageLayout, current: number, count: number): number[] | null {
  if (layout === 'continuous') return null
  if (count <= 0) return []
  const start = spreadStart(layout, Math.min(Math.max(current, 0), count - 1))
  return layout === 'book' ? [start, start + 1].filter((one) => one < count) : [start]
}

/** Where a turn lands: whole pages, or whole spreads in a book — or nowhere. */
export function turnedTo(layout: PageLayout, current: number, by: number, count: number): number | null {
  if (count <= 0) return null
  if (layout === 'continuous') {
    const next = Math.max(0, Math.min(current + by, count - 1))
    return next === current ? null : next
  }
  const step = layout === 'book' ? 2 : 1
  const from = spreadStart(layout, current)
  const next = spreadStart(layout, Math.max(0, Math.min(from + by * step, count - 1)))
  return next === from ? null : next
}

/**
 * The page a height in the scroll view is on — the last page whose top is at
 * or above it — by halving, from the tops laid out.
 */
export function pageAtOffset(tops: number[], y: number): number {
  let low = 0
  let high = tops.length - 1
  if (high < 0) return 0
  while (low < high) {
    const middle = (low + high + 1) >> 1
    if (tops[middle] <= y) low = middle
    else high = middle - 1
  }
  return low
}

/**
 * How far down its page a destination points, in the page's own points, or
 * null when it only names the page. XYZ is `[left, top, zoom]`, FitH and
 * FitBH `[top]`, FitR `[left, bottom, right, top]`.
 */
export function destinationTop(kind: string | undefined, args: unknown[]): number | null {
  const top = kind === 'XYZ' ? args[1]
    : kind === 'FitH' || kind === 'FitBH' ? args[0]
    : kind === 'FitR' ? args[3]
    : null
  return typeof top === 'number' && Number.isFinite(top) ? top : null
}

/** One heading of a PDF's outline, flattened in reading order. */
export interface OutlineNode {
  title?: string
  dest?: unknown
  items?: OutlineNode[]
}

export function flattenOutline(tree: OutlineNode[] | null | undefined): { title: string; depth: number; dest: unknown }[] {
  const flat: { title: string; depth: number; dest: unknown }[] = []
  const walk = (nodes: OutlineNode[], depth: number) => {
    for (const node of nodes) {
      const title = (node.title ?? '').replace(/\s+/g, ' ').trim()
      if (title) flat.push({ title, depth, dest: node.dest })
      if (node.items?.length) walk(node.items, depth + 1)
    }
  }
  walk(tree ?? [], 0)
  return flat
}

/**
 * What an error from opening a document was: the handler pdf.js does not
 * implement (a rights service's), a password nobody gave, or anything else.
 * By pdf.js's own exception names first — its English messages are the
 * fallback, not the rule.
 */
export type OpenFailure = 'rights' | 'password' | 'other'

export function classifyOpenError(error: unknown): OpenFailure {
  const name = (error as { name?: unknown } | null)?.name
  if (name === 'PasswordException' || name === 'NeedsPassword') return 'password'
  const message = formatError(error)
  if (/unknown encryption method|Unknown crypto|unsupported encryption algorithm/i.test(message)) return 'rights'
  if (/giving up on the password|PasswordException|password needed|wrong password/i.test(message)) return 'password'
  return 'other'
}

/** An error as a line for the fine print: `name: message`, never `[object Object]`. */
export function formatError(error: unknown): string {
  if (error instanceof Error) return error.name && error.name !== 'Error' ? `${error.name}: ${error.message}` : error.message
  if (error && typeof error === 'object') {
    const { name, message } = error as { name?: unknown; message?: unknown }
    if (typeof message === 'string') return typeof name === 'string' && name ? `${name}: ${message}` : message
    try {
      return JSON.stringify(error)
    } catch {
      return String(error)
    }
  }
  return String(error)
}

/** Only the web's two schemes and mail leave the app from a link in a paper. */
export function isOpenableLink(url: string): boolean {
  return /^(https?:|mailto:)/i.test(url.trim())
}
