/**
 * The page's tint: a ground for the paper to sit on, and with it how the
 * paper is drawn — as printed, multiplied away so the ink sits on the ground,
 * or turned to night.
 *
 * The Mac's `ReaderConfiguration.PageTint`, `PageRendering` and `TintColor`,
 * case for case and colour for colour, so a tint chosen on one desktop is the
 * same page on the other. Which of the three renderings a tint gets is decided
 * by its ground, not by the case: a light ground can take the ink by
 * multiplying — the paper's white falls away to it and the ink stays ink — and
 * a dark one cannot, black ink multiplied into a dark ground being nothing, so
 * the page goes to night. Glass has no ground of its own but the panel's, so
 * what it does follows the window's appearance.
 *
 * Pure, so the rule is tested without a window (`src/test/pageTint.ts`).
 */
import { L } from './lang.js'

export type PageTint = 'none' | 'sepia' | 'dim' | 'glass' | 'custom'

/**
 * How the paper is drawn under a tint.
 *
 * - `plain`: as printed — white paper with its shadow, on the reader's ground.
 * - `multiply`: the paper's white multiplied away, so the ink sits on the
 *   ground — sepia paper, a pale colour, or the panel itself.
 * - `night`: the page's luminance inverted with every hue put back, and its
 *   black screened away into the ground — light ink on the ground, no edge
 *   where the page ends, colours keeping their hue, and the pictures drawn
 *   again as printed. The way Obsidian's «Adapt to theme» reads a paper.
 */
export type PageRendering = 'plain' | 'multiply' | 'night'

/** In the order both builds offer them. */
export const PAGE_TINTS: readonly PageTint[] = ['none', 'sepia', 'dim', 'glass', 'custom']

/** Sepia paper: the Mac's `TintColor.sepia` (0.96, 0.93, 0.86). */
export const SEPIA_GROUND = '#f5eddb'
/** The dimmed tint's ground, and the colour a custom one starts from: the
 *  app's own dark panel rather than black (`TintColor.night`). */
export const NIGHT_GROUND = '#26272b'
export const DEFAULT_TINT_COLOR = NIGHT_GROUND

/** The one filter that turns a page to night: `f(c) = 1 − M·c`, where `M` is
 *  CSS's `hue-rotate(180deg)` — luminance inverted, chroma kept. Its own
 *  inverse, save for the colours it clips. */
export const NIGHT_FILTER = 'invert(1) hue-rotate(180deg)'

/**
 * A stored tint, the old names included.
 *
 * Until the Mac's model came across this build had four washes of its own:
 * «grey» was a paler white, which is Paper White now, and «night» a blue-grey
 * multiplied over the page — black words on grey — which Dimmed replaces.
 * Anything else, or nothing, is the page as printed.
 */
export function pageTintFrom(value: unknown): PageTint {
  switch (value) {
    case 'sepia':
    case 'dim':
    case 'glass':
    case 'custom':
      return value
    case 'night':
      return 'dim'
    default:
      return 'none'
  }
}

/** `#rrggbb` (or `rrggbb`) as three channels from 0 to 1, or null. */
export function parseHex(hex: string): [number, number, number] | null {
  let text = hex.trim()
  if (text.startsWith('#')) text = text.slice(1)
  if (!/^[0-9a-fA-F]{6}$/.test(text)) return null
  const value = Number.parseInt(text, 16)
  return [((value >> 16) & 0xff) / 255, ((value >> 8) & 0xff) / 255, (value & 0xff) / 255]
}

/** Three channels from 0 to 1, written the way the settings keep them. */
export function hexOf(red: number, green: number, blue: number): string {
  const byte = (channel: number) => Math.max(0, Math.min(255, Math.round(channel * 255))).toString(16).padStart(2, '0')
  return `#${byte(red)}${byte(green)}${byte(blue)}`
}

/** A stored ground colour, lower-cased, or the default when it is not one. */
export function tintColorFrom(value: unknown): string {
  const channels = typeof value === 'string' ? parseHex(value) : null
  return channels ? hexOf(...channels) : DEFAULT_TINT_COLOR
}

/**
 * Relative luminance, 0 black to 1 white (WCAG's, over linear sRGB): what
 * decides whether the ink can be multiplied onto a ground or the page must go
 * to night. The same sum the Mac takes.
 */
export function luminance(hex: string): number {
  const channels = parseHex(hex) ?? parseHex(DEFAULT_TINT_COLOR)!
  const linear = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)
  const [r, g, b] = channels.map(linear)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/** How the page is drawn for a tint. `dark` is the window's appearance, as
 *  it is showing — what Glass does depends on it. */
export function renderingFor(tint: PageTint, color: string, dark: boolean): PageRendering {
  switch (tint) {
    case 'none':
      return 'plain'
    case 'sepia':
      return 'multiply'
    case 'dim':
      return 'night'
    // The panel behind it is light or dark with the appearance.
    case 'glass':
      return dark ? 'night' : 'multiply'
    case 'custom':
      return luminance(tintColorFrom(color)) >= 0.5 ? 'multiply' : 'night'
  }
}

/** The ground the page sits on, or null for the panel itself (and for the
 *  page as printed, which keeps the reader's own ground). */
export function groundFor(tint: PageTint, color: string): string | null {
  switch (tint) {
    case 'none':
    case 'glass':
      return null
    case 'sepia':
      return SEPIA_GROUND
    case 'dim':
      return NIGHT_GROUND
    case 'custom':
      return tintColorFrom(color)
  }
}

/** The tint's name, as the ⋯ menu and Settings both say it. */
export function tintLabel(tint: PageTint): string {
  switch (tint) {
    case 'none':
      return L('종이 흰색', 'Paper White')
    case 'sepia':
      return L('세피아', 'Sepia')
    case 'dim':
      return L('어둡게', 'Dimmed')
    case 'glass':
      return L('유리', 'Glass')
    case 'custom':
      return L('직접 고른 색', 'Custom Color')
  }
}
