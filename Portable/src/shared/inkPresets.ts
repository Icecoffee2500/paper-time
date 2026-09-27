/**
 * The pen's and the highlighter's own colours and widths — the Mac's
 * `InkPresets`, same fields, same defaults, same JSON.
 *
 * They used to be borrowed from the next shape's style: a red pen made the
 * next rectangle red, and the thin and regular highlighter were both ten
 * points wide. Each tool keeps its own now, and the next launch keeps them.
 */
import { MARK_COLORS } from './marks.js'
import { SketchColor } from './sketch.js'

/** The pen's palette, as a notebook offers it (`PenColor`). */
export const PEN_COLORS = {
  black: [0.10, 0.10, 0.12],
  blue: [0.12, 0.36, 0.98],
  red: [0.90, 0.20, 0.18],
  green: [0.16, 0.62, 0.32],
  purple: [0.52, 0.30, 0.88],
  orange: [0.96, 0.55, 0.12],
  grey: [0.55, 0.55, 0.58],
} as const satisfies Record<string, readonly [number, number, number]>

export type PenColorName = keyof typeof PEN_COLORS
export type MarkupColorName = 'yellow' | 'green' | 'blue' | 'pink' | 'purple'
export const PEN_COLOR_NAMES = Object.keys(PEN_COLORS) as PenColorName[]
export const MARKUP_COLOR_NAMES: MarkupColorName[] = ['yellow', 'green', 'blue', 'pink', 'purple']

export interface InkPresets {
  penColors: PenColorName[]
  penColorIndex: number
  penWidths: number[]
  penWidthIndex: number
  highlighterColors: MarkupColorName[]
  highlighterColorIndex: number
  highlighterWidths: number[]
  highlighterWidthIndex: number
  /** A highlighter stroke over words becomes a highlight fitted to them, one under them an underline. */
  fitsToText: boolean
  /** The eraser takes highlights and underlines off along with strokes. */
  eraserErasesMarks: boolean
}

export function defaultInkPresets(): InkPresets {
  return {
    penColors: ['black', 'blue', 'red'], penColorIndex: 0,
    penWidths: [1.5, 3, 5], penWidthIndex: 1,
    highlighterColors: ['yellow', 'green', 'pink'], highlighterColorIndex: 0,
    highlighterWidths: [12, 18, 26], highlighterWidthIndex: 1,
    fitsToText: true, eraserErasesMarks: true,
  }
}

/** Presets read back from the settings: anything missing or wrong is the default, field by field. */
export function inkPresetsFrom(raw: unknown): InkPresets {
  const base = defaultInkPresets()
  let value: unknown = raw
  if (typeof raw === 'string') {
    try {
      value = JSON.parse(raw)
    } catch {
      return base
    }
  }
  if (!value || typeof value !== 'object') return base
  const given = value as Record<string, unknown>
  const names = <T extends string>(list: unknown, allowed: readonly T[], fallback: T[]): T[] =>
    Array.isArray(list) && list.length === 3 && list.every((one) => allowed.includes(one as T)) ? list as T[] : fallback
  const widths = (list: unknown, fallback: number[]) =>
    Array.isArray(list) && list.length === 3 && list.every((one) => typeof one === 'number' && one > 0 && one < 100) ? list as number[] : fallback
  const index = (one: unknown, fallback: number) => (Number.isInteger(one) && (one as number) >= 0 && (one as number) < 3 ? one as number : fallback)
  return {
    penColors: names(given.penColors, PEN_COLOR_NAMES, base.penColors),
    penColorIndex: index(given.penColorIndex, base.penColorIndex),
    penWidths: widths(given.penWidths, base.penWidths),
    penWidthIndex: index(given.penWidthIndex, base.penWidthIndex),
    highlighterColors: names(given.highlighterColors, MARKUP_COLOR_NAMES, base.highlighterColors),
    highlighterColorIndex: index(given.highlighterColorIndex, base.highlighterColorIndex),
    highlighterWidths: widths(given.highlighterWidths, base.highlighterWidths),
    highlighterWidthIndex: index(given.highlighterWidthIndex, base.highlighterWidthIndex),
    fitsToText: typeof given.fitsToText === 'boolean' ? given.fitsToText : base.fitsToText,
    eraserErasesMarks: typeof given.eraserErasesMarks === 'boolean' ? given.eraserErasesMarks : base.eraserErasesMarks,
  }
}

export const penColorName = (presets: InkPresets): PenColorName => presets.penColors[Math.min(presets.penColorIndex, 2)]
export const penWidth = (presets: InkPresets): number => presets.penWidths[Math.min(presets.penWidthIndex, 2)]
export const highlighterColorName = (presets: InkPresets): MarkupColorName => presets.highlighterColors[Math.min(presets.highlighterColorIndex, 2)]
export const highlighterWidth = (presets: InkPresets): number => presets.highlighterWidths[Math.min(presets.highlighterWidthIndex, 2)]

export function penColor(presets: InkPresets): SketchColor {
  const [r, g, b] = PEN_COLORS[penColorName(presets)]
  return new SketchColor(r, g, b, 1)
}

export function highlighterColor(presets: InkPresets): SketchColor {
  const [r, g, b] = MARK_COLORS[highlighterColorName(presets)]
  return new SketchColor(r, g, b, 1)
}

/** A colour of either palette as CSS, for a swatch. */
export function swatchCSS(rgb: readonly number[]): string {
  return `rgb(${rgb.map((one) => Math.round(one * 255)).join(', ')})`
}
