/**
 * What a run of a note's words is set in beyond what Markdown can say — the
 * Mac's `NoteSpanStyle` and `NoteAlignment`, the same bytes.
 *
 * A note is a Markdown file and stays one. Markdown has bold, italic and
 * code and nothing else, so the rest is written the way Markdown itself
 * allows it to be — as HTML, in the line:
 *
 *     <span style="color:#d62e54;font-size:20px">these words</span>
 *
 * The style is the handful of CSS properties below and no others: what is
 * written here is read back here, and a property nobody set is not written.
 */

export interface NoteSpanStyle {
  /** `#rrggbb`. */
  color: string | null
  /** In points. */
  size: number | null
  family: string | null
  bold: boolean
  italic: boolean
  underline: boolean
  strike: boolean
  /** Highlighted, in one of the five colours by name. */
  highlight: string | null
}

export function emptyStyle(): NoteSpanStyle {
  return { color: null, size: null, family: null, bold: false, italic: false, underline: false, strike: false, highlight: null }
}

/** What a highlight is written as in a span: a pale ground (`NoteSpanStyle.grounds`). */
export const GROUNDS: [string, string][] = [
  ['yellow', '#fff3b0'], ['green', '#cfeedd'], ['blue', '#cfe2fb'], ['pink', '#fbd3dc'], ['purple', '#e6d7f8'],
]

/** The five colours words are offered in — the highlighters' inks, by their names (`NoteSpanStyle.inks`). */
export const INKS: [string, string][] = [
  ['yellow', '#c78005'], ['green', '#219959'], ['blue', '#1f70d9'], ['pink', '#d62e54'], ['purple', '#8c47d1'],
]

export function inkNamed(name: string): string | null {
  return INKS.find(([one]) => one === name)?.[1] ?? null
}

export function inkName(hex: string | null): string | null {
  return hex === null ? null : INKS.find(([, value]) => value === hex)?.[0] ?? null
}

/** `#rrggbb` from `#rgb` or `#rrggbb`, lowercased; null for anything else. */
export function hexOf(value: string): string | null {
  let digits = value.toLowerCase()
  if (!digits.startsWith('#')) return null
  digits = digits.slice(1)
  if (digits.length === 3) digits = [...digits].map((one) => one + one).join('')
  return /^[0-9a-f]{6}$/.test(digits) ? `#${digits}` : null
}

/** The highlight a ground somebody wrote is nearest to. */
export function highlightForGround(value: string): string | null {
  const hex = hexOf(value)
  if (!hex) return null
  const wanted = parseInt(hex.slice(1), 16)
  const distance = (other: string) => {
    const v = parseInt(other.slice(1), 16)
    return [16, 8, 0].reduce((sum, shift) => {
      const d = ((wanted >> shift) & 0xff) - ((v >> shift) & 0xff)
      return sum + d * d
    }, 0)
  }
  let best: string | null = null
  let least = Infinity
  for (const [name, ground] of GROUNDS) {
    const d = distance(ground)
    if (d < least) { least = d; best = name }
  }
  return best
}

export function isEmptyStyle(style: NoteSpanStyle): boolean {
  return style.color === null && style.size === null && style.family === null && !style.bold && !style.italic
    && !style.underline && !style.strike && style.highlight === null
}

/** Whether all of it is a highlight, which is written `==`. */
export function isOnlyHighlight(style: NoteSpanStyle): boolean {
  return style.highlight !== null && isEmptyStyle({ ...style, highlight: null })
}

/** Whether Markdown's own marks can say all of it. */
export function isOnlyEmphasis(style: NoteSpanStyle): boolean {
  return style.color === null && style.size === null && style.family === null && !style.underline && !style.strike && style.highlight === null
}

export function styleFromCSS(css: string): NoteSpanStyle {
  const style = emptyStyle()
  for (const declaration of css.split(';')) {
    const colon = declaration.indexOf(':')
    if (colon < 0) continue
    const name = declaration.slice(0, colon).trim().toLowerCase()
    const value = declaration.slice(colon + 1).trim()
    if (!name || !value) continue
    const lower = value.toLowerCase()
    switch (name) {
      case 'color': {
        const hex = hexOf(value)
        if (hex) style.color = hex
        break
      }
      case 'background-color':
      case 'background':
        style.highlight = highlightForGround(value)
        break
      case 'font-size': {
        const text = lower.replaceAll('px', '').replaceAll('pt', '')
        const points = /^[+-]?(\d+\.?\d*|\.\d+)$/.test(text) ? Number(text) : NaN
        if (points >= 4 && points <= 400) style.size = points
        break
      }
      case 'font-family': {
        const family = (value.split(',')[0] ?? '').replace(/^['" ]+|['" ]+$/g, '')
        if (family) style.family = family
        break
      }
      case 'font-weight':
        style.bold = lower === 'bold' || (/^-?\d+$/.test(value) && Number(value) >= 600)
        break
      case 'font-style':
        style.italic = lower === 'italic' || lower === 'oblique'
        break
      case 'text-decoration':
      case 'text-decoration-line':
        style.underline = lower.includes('underline')
        style.strike = lower.includes('line-through')
        break
      default:
        break
    }
  }
  return style
}

/** The declarations, in one order, so the same style is the same bytes. */
export function cssOf(style: NoteSpanStyle): string {
  const parts: string[] = []
  if (style.color !== null) parts.push(`color:${style.color}`)
  const ground = style.highlight === null ? undefined : GROUNDS.find(([name]) => name === style.highlight)
  if (ground) parts.push(`background-color:${ground[1]}`)
  if (style.size !== null) parts.push(`font-size:${Number.isInteger(style.size) ? String(style.size) : style.size.toFixed(1)}px`)
  if (style.family !== null) parts.push(`font-family:${style.family}`)
  if (style.bold) parts.push('font-weight:bold')
  if (style.italic) parts.push('font-style:italic')
  if (style.underline || style.strike) {
    parts.push(`text-decoration:${[style.underline ? 'underline' : '', style.strike ? 'line-through' : ''].filter(Boolean).join(' ')}`)
  }
  return parts.join(';')
}

export const SPAN_CLOSE = '</span>'
export function spanOpen(style: NoteSpanStyle): string {
  return `<span style="${cssOf(style)}">`
}

const SPACE = /^\p{White_Space}$/u
function edgeIsSpace(words: string): boolean {
  const first = [...words][0] ?? ''
  const last = [...words].at(-1) ?? ''
  return SPACE.test(first) || SPACE.test(last)
}

/** The words in this style, as the note holds them: a span, Markdown's own marks when those say all of it, or the words alone. */
export function wrapping(style: NoteSpanStyle, words: string): string {
  if (isEmptyStyle(style) || words === '') return words
  // A highlight and nothing else is `==`, with its colour named: that form
  // reads wherever it stands, inside a word too.
  if (isOnlyHighlight(style) && !words.includes('==') && !words.startsWith('=') && !words.endsWith('=') && !edgeIsSpace(words)) {
    return `=={${style.highlight}}${words}==`
  }
  if (isOnlyEmphasis(style)) {
    const mark = style.bold && style.italic ? '***' : style.bold ? '**' : '*'
    // Markdown's marks do not hold a star, or a space at either end.
    if (!words.includes('*') && !edgeIsSpace(words)) return mark + words + mark
  }
  return spanOpen(style) + words + SPAN_CLOSE
}

// MARK: - Alignment

export type NoteAlignment = 'left' | 'center' | 'right' | 'justify'
export const ALIGNMENTS: NoteAlignment[] = ['left', 'center', 'right', 'justify']
export const ALIGN_CLOSE = '</p>'
export function alignOpen(alignment: NoteAlignment): string {
  return `<p align="${alignment}">`
}

const ALIGN_HEAD = /^<p align="(left|center|right|justify)">/

/** The alignment a line's words are wrapped in, and where the words themselves are in it; null for a line that is not wrapped. */
export function readAlignment(content: string): { alignment: NoteAlignment; from: number; to: number } | null {
  if (!content.startsWith('<p align=') || !content.endsWith(ALIGN_CLOSE)) return null
  const match = ALIGN_HEAD.exec(content)
  if (!match || content.length < match[0].length + ALIGN_CLOSE.length) return null
  return { alignment: match[1] as NoteAlignment, from: match[0].length, to: content.length - ALIGN_CLOSE.length }
}

/** What a span's style is as CSS on the page: the ink by its name where it is one of ours (a dark page has a lighter shade), and no ground — the highlight is a class. */
export function inlineCSS(style: NoteSpanStyle): string {
  const parts: string[] = []
  if (style.color !== null) {
    const name = inkName(style.color)
    parts.push(`color:${name ? `var(--hl-${name}-ink)` : style.color}`)
  }
  if (style.size !== null) parts.push(`font-size:${style.size}px`)
  if (style.family !== null) parts.push(`font-family:${JSON.stringify(style.family)}, var(--font)`)
  if (style.bold) parts.push('font-weight:700')
  if (style.italic) parts.push('font-style:italic')
  if (style.underline || style.strike) {
    parts.push(`text-decoration:${[style.underline ? 'underline' : '', style.strike ? 'line-through' : ''].filter(Boolean).join(' ')}`)
  }
  return parts.join(';')
}
