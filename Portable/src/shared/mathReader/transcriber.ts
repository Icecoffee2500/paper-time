/**
 * Reads a formula off the page the way a person does: by where things are —
 * the Mac's `MathTranscriber`, port for port. A fraction is a line with
 * something above and below; a sum is a big sign with its limits stacked
 * over and under; a subscript is a small glyph that dropped below the line.
 * Checked against the Mac's own answers (`src/test/mathReader.ts`).
 */
import { intersects, insetBy, maxX, midX, midY, minX, sameRect, type Rect } from './geometry.js'
import { isExtension, rectOf, type Glyph, type Rule } from './glyph.js'
import * as TeX from './texGlyphNames.js'

export interface Context { bodySize: number; baseline: number }

/** Asked for a glyph this cannot read: the character the page's text has there. */
let fallback: ((glyph: Glyph) => string | null) | null = null
export function setFallback(next: ((glyph: Glyph) => string | null) | null) { fallback = next }

const isLetter = (s: string | undefined) => s !== undefined && /^\p{L}/u.test(s)
const isNumber = (s: string | undefined) => s !== undefined && /^\p{N}/u.test(s)
const count = (s: string) => [...s].length
const first = (s: string) => [...s][0]
const last = (s: string) => { const all = [...s]; return all[all.length - 1] }

export function latexIn(glyphs: Glyph[], rules: Rule[], region: Rect): string {
  const box = insetBy(region, -1, -1)
  return latexOf(glyphs.filter((glyph) => intersects(box, rectOf(glyph))), rules.filter((rule) => intersects(box, rule.rect)))
}

export function latexOf(glyphs: Glyph[], rules: Rule[], context: Context | null = null): string {
  if (glyphs.length === 0) return ''
  return transcribe([...glyphs].sort((a, b) => a.x - b.x), rules, context)
}

export function spelling(glyph: Glyph): string {
  return token(glyph)
}

const familyOf = (glyph: Glyph) => TeX.family(glyph.fontName)

export function isMathFont(glyph: Glyph): boolean {
  const f = familyOf(glyph)
  return f.startsWith('CMMI') || f.startsWith('CMSY') || f.startsWith('CMEX')
    || f.startsWith('MSAM') || f.startsWith('MSBM') || f.startsWith('CMBSY')
    || f.startsWith('EUFM') || f.startsWith('RSFS')
    || f.includes('MATH') || f.includes('MATHITALIC')
}

function transcribe(glyphs: Glyph[], rules: Rule[], context: Context | null = null): string {
  if (glyphs.length === 0) return ''
  const body = context?.bodySize ?? size(glyphs)

  const bar = fractionBar(rules, glyphs)
  if (bar) {
    const r = bar.rect
    const left = glyphs.filter((g) => maxX(rectOf(g)) <= minX(r) + 0.5)
    const right = glyphs.filter((g) => minX(rectOf(g)) >= maxX(r) - 0.5)
    const over = glyphs.filter((g) => g.x > minX(r) - 0.5 && g.x < maxX(r) && g.y > midY(r))
    const under = glyphs.filter((g) => g.x > minX(r) - 0.5 && g.x < maxX(r) && g.y <= midY(r))
    const remaining = rules.filter((rule) => !sameRect(rule.rect, r))
    return join([
      transcribe(left, remaining),
      `\\frac{${transcribe(over, remaining)}}{${transcribe(under, remaining)}}`,
      transcribe(right, remaining),
    ])
  }

  const baseline = context?.baseline ?? baselineOf(glyphs, body)
  const tokens: string[] = []
  let index = 0
  const consumed = new Set<number>()
  let lastBaseSize: number | null = null
  let lastBaseline: number | null = null
  let lastGlyphIndex: number | null = null

  const limits = new Map<number, { above: Glyph[]; below: Glyph[] }>()
  glyphs.forEach((glyph, position) => {
    if (!TeX.isBigOperator(glyph.glyphName)) return
    const next = glyphs.slice(position + 1).find((one) => one.size >= body * 0.95)
    const stop = next ? minX(rectOf(next)) : Number.MAX_VALUE
    const above: Glyph[] = []
    const below: Glyph[] = []
    const g = rectOf(glyph)
    glyphs.forEach((candidate, other) => {
      if (other === position) return
      const c = rectOf(candidate)
      if (!(candidate.size < body * 0.95 && midX(c) > minX(g) - g.width * 0.5 && midX(c) < stop)) return
      if (maxX(c) <= minX(g) && Math.abs(midX(c) - midX(g)) >= g.width * 0.9) return
      if (candidate.y > baseline + body * 0.12) {
        above.push(candidate)
        consumed.add(other)
      } else if (candidate.y < baseline - body * 0.12) {
        below.push(candidate)
        consumed.add(other)
      }
    })
    limits.set(position, { above, below })
  })

  while (index < glyphs.length) {
    if (consumed.has(index)) { index += 1; continue }
    const glyph = glyphs[index]

    const stacked = limits.get(index)
    if (stacked) {
      let t = token(glyph)
      const below = group(stacked.below, rules)
      if (below !== null) t += '_' + below
      const above = group(stacked.above, rules)
      if (above !== null) t += '^' + above
      tokens.push(t)
      lastBaseSize = glyph.size
      lastBaseline = baseline
      lastGlyphIndex = index
      index += 1
      continue
    }

    const accentHere = accentName(glyph)
    if (accentHere !== null && lastGlyphIndex !== null && overlaps(glyph, glyphs[lastGlyphIndex])
      && tokens.length > 0 && tokens[tokens.length - 1] !== '') {
      tokens[tokens.length - 1] = `${accentHere}{${tokens[tokens.length - 1]}}`
      index += 1
      continue
    }
    if (accentHere !== null && index + 1 < glyphs.length && overlaps(glyph, glyphs[index + 1])) {
      consumed.add(index + 1)
      tokens.push(`${accentHere}{${token(glyphs[index + 1])}}`)
      lastGlyphIndex = index + 1
      index += 1
      continue
    }

    if (tokens.length > 0) {
      const script = scripts(index, glyphs, lastBaseline ?? baseline, lastBaseSize ?? body, consumed)
      if (script) {
        let t = ''
        const below = group(script.lowered, rules)
        if (below !== null) t += '_' + below
        const above = group(script.raised, rules)
        if (above !== null) t += '^' + above
        if (t) tokens.push(t)
        index = script.end
        continue
      }
    }

    const fenced = TeX.fence(glyph.glyphName) ?? TeX.openingDelimiter(glyph.glyphName) ?? TeX.closingDelimiter(glyph.glyphName)
    if (fenced !== null) {
      let next = index + 1
      while (next < glyphs.length && glyphs[next].glyphName === glyph.glyphName
        && Math.abs(glyphs[next].x - glyph.x) < glyph.size * 0.35) {
        consumed.add(next)
        next += 1
      }
      tokens.push(fenced)
      lastBaseSize = glyph.size
      lastBaseline = isExtension(glyph) ? baseline : glyph.y
      lastGlyphIndex = index
      index = next
      continue
    }

    const named = operatorName(index, glyphs, body, baseline, consumed)
    if (named) {
      let t = named.command
      const under = named.limits.map((i) => glyphs[i]).filter((g) => g.y < baseline)
      const over = named.limits.map((i) => glyphs[i]).filter((g) => g.y >= baseline)
      const below = group(under, rules)
      if (below !== null) t += '_' + below
      const above = group(over, rules)
      if (above !== null) t += '^' + above
      tokens.push(t)
      for (const position of named.limits) consumed.add(position)
      lastBaseSize = glyph.size
      lastBaseline = glyph.y
      lastGlyphIndex = named.end - 1
      index = named.end
      continue
    }

    const dots = dotRun(index, glyphs, consumed)
    if (dots) {
      tokens.push(dots.command)
      lastBaseSize = glyph.size
      lastBaseline = glyph.y
      lastGlyphIndex = dots.end - 1
      index = dots.end
      continue
    }

    const bold = boldRun(index, glyphs, consumed)
    if (bold) {
      tokens.push(bold.text)
      lastBaseSize = glyph.size
      lastBaseline = glyph.y
      lastGlyphIndex = bold.end - 1
      index = bold.end
      continue
    }

    const t = token(glyph)
    if (t !== '') {
      tokens.push(t)
      lastBaseSize = glyph.size
      lastBaseline = isExtension(glyph) ? baseline : glyph.y
      lastGlyphIndex = index
    }
    index += 1
  }
  return join(tokens)
}

function group(glyphs: Glyph[], rules: Rule[]): string | null {
  if (glyphs.length === 0) return null
  let inner = transcribe([...glyphs].sort((a, b) => a.x - b.x), rules)
  if (inner === '') return null
  if (isWord(glyphs) && count(inner) > 1 && !inner.includes('\\')) inner = `\\text{${inner}}`
  return count(inner) > 1 ? `{${inner}}` : inner
}

export function join(tokens: string[]): string {
  let result = ''
  for (const t of tokens) {
    if (t === '') continue
    const next = first(t)
    const needsSpace = (endsInCommand(result) && (isLetter(next) || isNumber(next)))
      || (endsInBareScript(result) && (isLetter(next) || isNumber(next)))
    if (needsSpace) result += ' '
    result += t
  }
  return result
}

function endsInBareScript(text: string): boolean {
  const all = [...text]
  if (all.length < 2) return false
  const l = all[all.length - 1]
  if (!(isLetter(l) || isNumber(l))) return false
  const mark = all[all.length - 2]
  return mark === '^' || mark === '_'
}

function endsInCommand(text: string): boolean {
  if (!text.includes('\\')) return false
  const all = [...text]
  let letters = 0
  while (letters < all.length && isLetter(all[all.length - 1 - letters])) letters += 1
  if (letters === 0) return false
  const at = all.length - letters
  return at > 0 && all[at - 1] === '\\'
}

function baselineOf(glyphs: Glyph[], bodySize: number): number {
  const full = glyphs.filter((g) => g.size >= bodySize * 0.92 && !isExtension(g))
  const sample = (full.length === 0 ? glyphs : full).map((g) => g.y).sort((a, b) => a - b)
  return sample[Math.floor(sample.length / 2)]
}

function accentName(glyph: Glyph): string | null {
  const named = TeX.accent(glyph.glyphName)
  if (named !== null) return named
  switch (token(glyph)) {
    case '^': case '\u02C6': case '\u0302': return '\\hat'
    case '~': case '\u02DC': case '\u0303': return '\\tilde'
    case '\u00AF': case '\u0304': return '\\bar'
    case '\u02D9': case '\u0307': return '\\dot'
    case '\u02C7': return '\\check'
    case '\u00B4': case '\u0301': return '\\acute'
    case '`': case '\u0300': return '\\grave'
    default: return null
  }
}

function overlaps(mark: Glyph, letter: Glyph): boolean {
  const reachX = Math.max(letter.width, mark.width) * 0.7
  return Math.abs(mark.x - letter.x) < reachX && Math.abs(mark.y - letter.y) < Math.max(letter.size, 1) * 0.35
}

function isWord(glyphs: Glyph[]): boolean {
  const letters = glyphs.filter((g) => { const t = token(g); return count(t) === 1 && isLetter(t) })
  if (letters.length < 2) return false
  return glyphs.every((g) => {
    const upper = familyOf(g)
    return upper.startsWith('SF') || upper.startsWith('CMR') || upper.startsWith('CMSS') || upper.startsWith('CMB')
  })
}

/** The commonest size, to the nearest half point (`MathTranscriber.size`). */
export function size(glyphs: Glyph[]): number {
  const counts = new Map<number, number>()
  for (const g of glyphs) {
    const key = Math.round(g.size * 2) / 2
    counts.set(key, (counts.get(key) ?? 0) + 1)
  }
  const floor = Math.max(2, Math.floor(glyphs.length / 8))
  const common = [...counts].filter(([, n]) => n >= floor).map(([key]) => key)
  if (common.length > 0) return Math.max(...common)
  return glyphs.length > 0 ? Math.max(...glyphs.map((g) => g.size)) : 10
}

function scripts(start: number, glyphs: Glyph[], baseline: number, body: number, consumed: Set<number>): { end: number; raised: Glyph[]; lowered: Glyph[] } | null {
  if (start <= 0) return null
  let end = start
  const raised: Glyph[] = []
  const lowered: Glyph[] = []
  const primary = glyphs[start].size
  let side: boolean | null = null
  while (end < glyphs.length && !consumed.has(end)) {
    const glyph = glyphs[end]
    if (!(glyph.size < body * 0.92)) break
    const offset = glyph.y - baseline
    if (end === start && Math.abs(offset) <= body * 0.12) break
    if (end > start && minX(rectOf(glyph)) - maxX(rectOf(glyphs[end - 1])) > body * 0.25) break
    const deeper = glyph.size < primary * 0.92
    const raisedHere: boolean = deeper ? (side ?? (offset > 0)) : offset > 0
    if (!deeper) side = raisedHere
    if (raisedHere) raised.push(glyph)
    else lowered.push(glyph)
    end += 1
  }
  return end > start ? { end, raised, lowered } : null
}

const OPERATOR_NAMES = new Set([
  'log', 'ln', 'lg', 'exp', 'sin', 'cos', 'tan', 'cot', 'sec', 'csc',
  'sinh', 'cosh', 'tanh', 'coth', 'arcsin', 'arccos', 'arctan',
  'min', 'max', 'inf', 'sup', 'lim', 'det', 'dim', 'ker', 'deg',
  'gcd', 'hom', 'arg', 'Pr',
])

export function isOperatorName(spelled: string): boolean {
  return OPERATOR_NAMES.has(spelled)
}

function operatorName(start: number, glyphs: Glyph[], body: number, baseline: number, consumed: Set<number>): { end: number; command: string; limits: number[] } | null {
  let end = start
  let spelled = ''
  let limits: number[] = []
  let lastLetter: number | null = null
  while (end < glyphs.length && !consumed.has(end)) {
    const glyph = glyphs[end]
    if (glyph.size < body * 0.92 && Math.abs(glyph.y - baseline) > body * 0.12 && lastLetter !== null) {
      limits.push(end)
      end += 1
      continue
    }
    const upper = familyOf(glyph)
    if (!(upper.startsWith('CMR') || upper.startsWith('CMSS') || upper.startsWith('CMB') || upper.includes('ROM') || upper.includes('TIMES'))) break
    const letter = token(glyph)
    if (!(count(letter) === 1 && isLetter(letter))) break
    if (lastLetter !== null && minX(rectOf(glyph)) - maxX(rectOf(glyphs[lastLetter])) > glyph.size * 0.22) break
    spelled += letter
    lastLetter = end
    end += 1
  }
  if (lastLetter === null || !OPERATOR_NAMES.has(spelled)) return null
  const lastIndex = lastLetter
  limits = limits.filter((i) => i < lastIndex)
  return { end: lastIndex + 1, command: '\\' + spelled, limits }
}

function dotRun(start: number, glyphs: Glyph[], consumed: Set<number>): { end: number; command: string } | null {
  const f = token(glyphs[start])
  const centred = f === '\u00B7' || f === '\\cdot'
  if (!(centred || f === '.')) return null
  let end = start + 1
  while (end < glyphs.length && !consumed.has(end) && token(glyphs[end]) === f
    && minX(rectOf(glyphs[end])) - maxX(rectOf(glyphs[end - 1])) < glyphs[end].size * 0.6) {
    end += 1
  }
  if (end - start >= 2) return { end, command: centred ? '\\cdots' : '\\ldots' }
  return centred ? { end, command: '\\cdot' } : null
}

function boldRun(start: number, glyphs: Glyph[], consumed: Set<number>): { end: number; text: string } | null {
  const command = boldCommand(glyphs[start])
  if (command === null) return null
  let end = start + 1
  while (end < glyphs.length && !consumed.has(end) && boldCommand(glyphs[end]) === command
    && Math.abs(glyphs[end].y - glyphs[start].y) < 0.01
    && minX(rectOf(glyphs[end])) - maxX(rectOf(glyphs[end - 1])) < glyphs[end].size * 0.22) {
    end += 1
  }
  const inner = join(glyphs.slice(start, end).map(token))
  if (inner === '') return null
  return { end, text: `${command}{${inner}}` }
}

function boldCommand(glyph: Glyph): string | null {
  const upper = familyOf(glyph)
  if (upper.startsWith('CMMIB') || upper.startsWith('CMBSY')) return '\\boldsymbol'
  if (upper.startsWith('CMBX')) return '\\mathbf'
  return null
}

function fractionBar(rules: Rule[], glyphs: Glyph[]): Rule | null {
  let best: Rule | null = null
  for (const rule of rules) {
    const r = rule.rect
    const above = glyphs.some((g) => g.y > midY(r) && g.x > minX(r) - 1 && g.x < maxX(r) + 1)
    const below = glyphs.some((g) => g.y < midY(r) && g.x > minX(r) - 1 && g.x < maxX(r) + 1)
    if (!(above && below)) continue
    if (best === null || best.rect.width < r.width) best = rule
  }
  return best
}

const COMMANDS: Record<string, string> = {
  '\u00B7': '\\cdot', '\u00D7': '\\times', '\u00F7': '\\div',
  '\u00B1': '\\pm', '\u2213': '\\mp', '\u2212': '-',
  '\u2264': '\\leq', '\u2265': '\\geq', '\u2260': '\\neq',
  '\u2248': '\\approx', '\u223C': '\\sim', '\u2261': '\\equiv',
  '\u2208': '\\in', '\u2209': '\\notin', '\u2282': '\\subset',
  '\u2286': '\\subseteq', '\u221E': '\\infty', '\u2202': '\\partial',
  '\u2207': '\\nabla', '\u221A': '\\sqrt', '\u2192': '\\to',
  '\u2190': '\\leftarrow', '\u21D2': '\\Rightarrow', '\u2200': '\\forall',
  '\u2203': '\\exists', '\u2225': '\\|', '\u2032': "'",
  '\u00B5': '\\mu', '\u03BC': '\\mu', '\u03B1': '\\alpha',
  '\u03B2': '\\beta', '\u03B3': '\\gamma', '\u03B4': '\\delta',
  '\u03B5': '\\epsilon', '\u03B6': '\\zeta', '\u03B7': '\\eta',
  '\u03B8': '\\theta', '\u03BB': '\\lambda', '\u03BD': '\\nu',
  '\u03BE': '\\xi', '\u03C0': '\\pi', '\u03C1': '\\rho',
  '\u03C3': '\\sigma', '\u03C4': '\\tau', '\u03C6': '\\phi',
  '\u03C7': '\\chi', '\u03C8': '\\psi', '\u03C9': '\\omega',
  '\u0394': '\\Delta', '\u03A3': '\\Sigma', '\u03A9': '\\Omega',
  '\u2211': '\\sum', '\u220F': '\\prod', '\u222B': '\\int',
  '\u2299': '\\odot', '\u2295': '\\oplus', '\u2297': '\\otimes',
}

function token(glyph: Glyph): string {
  const fenced = TeX.fence(glyph.glyphName)
  if (fenced !== null) return fenced
  const opening = TeX.openingDelimiter(glyph.glyphName)
  if (opening !== null) return opening
  const closing = TeX.closingDelimiter(glyph.glyphName)
  if (closing !== null) return closing
  const latex = TeX.latex(glyph.glyphName, glyph.code, glyph.fontName, glyph.unicode, glyph.isSymbolic)
  if (latex !== null && latex !== '') {
    if (isMathFont(glyph) && COMMANDS[latex] !== undefined) return COMMANDS[latex]
    return latex
  }
  return fallback?.(glyph) ?? ''
}

export { last as lastCharacter }
