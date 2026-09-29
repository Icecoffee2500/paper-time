/**
 * Reads a formula off the page the way a person does: by where things are —
 * the Mac's `MathTranscriber`, port for port. A fraction is a line with
 * something above and below; a sum is a big sign with its limits stacked
 * over and under; a subscript is a small glyph that dropped below the line.
 *
 * The things that are more than one glyph are found first — matrices and
 * cases, fraction bars (not a table's rules), radicals and their roots, the
 * limits of the big operators and of the names that take them, the rules
 * over and under a run, the accents and what they cover, the relations
 * struck through — and then the formula is read left to right, each of
 * those written where its first glyph is. Checked against the Mac's own
 * answers (`src/test/mathReader.ts`), so the order things are asked in, the
 * way ties fall and what counts as a Character are the Mac's.
 */
import { NULL_RECT, intersects, insetBy, maxX, midX, midY, minX, minY, maxY, sameRect, union, type Rect } from './geometry.js'
import { extension, familyOf, rectOf, type Glyph, type Rule } from './glyph.js'
import * as TeX from './texGlyphNames.js'
import { allASCIILetters, canon, chars, count, isLetter, isNumber, isWhitespace, lastChars, same, stringSet } from './swiftText.js'

/** What the line around a fragment looks like: a word lifted out of a line
 *  is read against the line it came from. */
export interface Context { bodySize: number; baseline: number }

/** Asked for a glyph this cannot read: the character the page's text has there. */
let fallback: ((glyph: Glyph) => string | null) | null = null
/** What the page's text says for each glyph that spells nothing, while this
 *  fallback stands (see `token`). */
let borrowed = new WeakMap<Glyph, string>()
export function setFallback(next: ((glyph: Glyph) => string | null) | null) {
  fallback = next
  borrowed = new WeakMap()
}

/** Whether the page being read sets its variables in the italic of its text
 *  face — mathptmx, txfonts, pxfonts, mathpazo and fourier do — so that an
 *  italic letter can be a variable. */
let variablesInTextItalic = false
export function setVariablesInTextItalic(value: boolean) { variablesInTextItalic = value }
export function italicVariables(): boolean { return variablesInTextItalic }

const MAX = Number.MAX_VALUE

/** The LaTeX for everything drawn inside `region` of a scanned page. */
export function latexIn(glyphs: Glyph[], rules: Rule[], region: Rect): string {
  const box = insetBy(region, -1, -1)
  return latexOf(glyphs.filter((glyph) => intersects(box, rectOf(glyph))), rules.filter((rule) => intersects(box, rule.rect)))
}

/** The LaTeX for a set of glyphs that have already been chosen. */
export function latexOf(glyphs: Glyph[], rules: Rule[], context: Context | null = null): string {
  if (glyphs.length === 0) return ''
  return joiningText(transcribe(byX(glyphs), rules, context))
}

/** Glyphs in reading order: left to right, and two at the same place in the
 *  order they were drawn. */
export function byX(glyphs: Glyph[]): Glyph[] {
  return glyphs.map((glyph, offset) => ({ glyph, offset }))
    .sort((a, b) => (a.glyph.x !== b.glyph.x ? (a.glyph.x < b.glyph.x ? -1 : 1) : a.offset - b.offset))
    .map((one) => one.glyph)
}

/** A stable sort by a "comes before" test, which is what Swift's `sorted(by:)` is. */
export function sortedBy<T>(items: readonly T[], before: (a: T, b: T) => boolean): T[] {
  return [...items].sort((a, b) => (before(a, b) ? -1 : before(b, a) ? 1 : 0))
}

/** Swift's `min(by:)` and `max(by:)`: the first of the least, and the first
 *  of the greatest. */
export function minBy<T>(items: readonly T[], before: (a: T, b: T) => boolean): T | undefined {
  let result: T | undefined
  for (const item of items) if (result === undefined || before(item, result)) result = item
  return result
}
export function maxBy<T>(items: readonly T[], before: (a: T, b: T) => boolean): T | undefined {
  let result: T | undefined
  for (const item of items) if (result === undefined || before(result, item)) result = item
  return result
}
const maxOf = (values: number[]) => (values.length === 0 ? undefined : values.reduce((a, b) => (a < b ? b : a)))
const minOf = (values: number[]) => (values.length === 0 ? undefined : values.reduce((a, b) => (b < a ? b : a)))
const ascending = (values: number[]) => sortedBy(values, (a, b) => a < b)
const indices = (n: number) => Array.from({ length: n }, (_, i) => i)

/** A glyph that draws a space — Word draws them; TeX does not. Asked of what
 *  the glyph spells, not of its Unicode: TeX's symbol font keeps its left
 *  arrow at code 32. */
export function isSpace(glyph: Glyph): boolean {
  const drawn = token(glyph)
  return drawn !== '' && chars(drawn).every(isWhitespace)
}

/** Whether a word holds a subscript the way Word sets one: a glyph much
 *  smaller than the one it touches, on that glyph's baseline. */
export function hasWordSubscript(word: Glyph[], body: number): boolean {
  if (word.length < 2) return false
  for (let index = 1; index < word.length; index += 1) {
    const glyph = word[index]
    const before = word[index - 1]
    if (glyph.size <= body * 0.72 && before.size >= body * 0.92
      && Math.abs(glyph.y - before.y) <= body * 0.03
      && minX(rectOf(glyph)) - maxX(rectOf(before)) < body * 0.12
      && spelling(glyph) !== '') return true
  }
  return false
}

/** ICU's `\s`: White_Space (U+0085 in, U+200B and U+FEFF out). */
const TEXT_JOIN = /\\text\{([^{}]*)\}[\t\n\v\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+\\text\{/

/** One `\text{}` for a phrase set upright, not one a word — `\text{Fuel Oil Consumption}`. */
export function joiningText(latex: string): string {
  if (!latex.includes('\\text{')) return latex
  let result = latex
  for (;;) {
    const match = TEXT_JOIN.exec(result)
    if (!match) return result
    result = result.slice(0, match.index) + `\\text{${match[1]} ` + result.slice(match.index + match[0].length)
  }
}

/** One glyph as plain text — what it spells, with no formula around it. */
export function spelling(glyph: Glyph): string {
  return token(glyph)
}

/** The first letters of the maths fonts' names, uppercased. A paper set in
 *  any of these had every formula in its prose read as words until each
 *  family was known. */
const MATH_FAMILIES = [
  'CMMI', 'CMSY', 'CMEX', 'CMBSY', 'MSAM', 'MSBM', 'EUFM', 'EUFB', 'EUSM', 'EUSB',
  'EURM', 'EURB', 'EUEX', 'RSFS', 'BBOLD', 'DSROM', 'DSSS', 'STMARY', 'WASY', 'LASY',
  'ESINT', 'CALLIGRA',
  'TXMI', 'TXSY', 'TXEX', 'TXBMI', 'TXBSY', 'PXMI', 'PXSY', 'PXEX', 'PXBMI', 'PXBSY',
  'NEWTXMI', 'NEWTXBMI', 'NEWTXSY', 'NEWPXMI', 'NEWPXBMI', 'NEWPXSY',
  'RTXMI', 'RTXBMI', 'RPXMI', 'RPXBMI', 'RTXR', 'RTXB', 'RPXR', 'RPXB',
  'RMTMI', 'MTSY', 'MTEX', 'MTMI', 'BLEX', 'MTGU',
  'STANDARDSYML',
]

const mathFonts = new Map<string, boolean>()

/** Whether a glyph came from a font that only sets mathematics — asked of
 *  the font's name once. */
export function isMathFont(glyph: Glyph): boolean {
  let known = mathFonts.get(glyph.fontName)
  if (known === undefined) {
    const upper = familyOf(glyph.fontName)
    known = upper.includes('MATH') || MATH_FAMILIES.some((prefix) => upper.startsWith(prefix))
    mathFonts.set(glyph.fontName, known)
  }
  return known
}

export const family = (glyph: Glyph) => familyOf(glyph.fontName)

// MARK: - What a glyph is

const BIG_OPERATORS = stringSet([
  '\\sum', '\\prod', '\\coprod', '\\bigcup', '\\bigcap', '\\bigoplus', '\\bigotimes',
  '\\bigodot', '\\biguplus', '\\bigsqcup', '\\bigvee', '\\bigwedge', '\\int', '\\iint',
  '\\iiint', '\\oint', '\\oiint',
])

/** A sign that takes limits: ∑, ∏, ∫, ⋃ and their kin, from whatever font. */
export function isBigOperator(glyph: Glyph): boolean {
  if (TeX.isBigOperator(glyph.glyphName)) return true
  return BIG_OPERATORS.has(token(glyph))
}

/** A bracket, a bar or a fence, at any size. */
export function isDelimiter(glyph: Glyph): boolean {
  return opening(glyph) !== null || closing(glyph) !== null
    || TeX.fence(glyph.glyphName) !== null
    || ['|', '\\|'].includes(token(glyph))
}

const OPENINGS = ['(', '[', '\\{', '\\langle', '\\lfloor', '\\lceil']
const CLOSINGS = [')', ']', '\\}', '\\rangle', '\\rfloor', '\\rceil']

/** The opening delimiter a glyph is, if it is one. */
export function opening(glyph: Glyph): string | null {
  const named = TeX.openingDelimiter(glyph.glyphName)
  if (named !== null) return named
  const drawn = token(glyph)
  return OPENINGS.includes(drawn) ? drawn : null
}

/** The closing delimiter a glyph is, if it is one. */
export function closing(glyph: Glyph): string | null {
  const named = TeX.closingDelimiter(glyph.glyphName)
  if (named !== null) return named
  const drawn = token(glyph)
  return CLOSINGS.includes(drawn) ? drawn : null
}

/** The sign of a radical. */
export function isRadical(glyph: Glyph): boolean { return token(glyph) === '\\sqrt' }

const WIDE: Record<string, number> = {
  '(': 0.5, ')': 0.5, '[': 0.45, ']': 0.45, '\\{': 0.62, '\\}': 0.62,
  '\\langle': 0.5, '\\rangle': 0.5, '\\lfloor': 0.5, '\\rfloor': 0.5,
  '\\lceil': 0.5, '\\rceil': 0.5,
}

/**
 * Whether a bracket from an OpenType maths font is one of its larger sizes,
 * grown to hold more than a line. The file says where it stands and how wide
 * it is, not how tall: a larger size stands off the line of what follows it,
 * or is far wider than the bracket of a line.
 */
export function isTallVariant(bracket: Glyph, glyphs: Glyph[], body: number): boolean {
  if (extension(bracket) || !isUnicodeMathFont(family(bracket))) return false
  const drawn = token(bracket)
  const ratio = Object.prototype.hasOwnProperty.call(WIDE, drawn) ? WIDE[drawn] : undefined
  if (ratio !== undefined && bracket.width > bracket.size * ratio) return true
  // What it holds: after an opening bracket, before a closing one.
  const b = rectOf(bracket)
  const near = glyphs.filter((one) => Math.abs(one.y - bracket.y) < body * 1.2 && !isDelimiter(one) && token(one) !== '')
  const after = minBy(near.filter((one) => minX(rectOf(one)) >= maxX(b) - 0.5 && minX(rectOf(one)) - maxX(b) < body),
    (x, y) => minX(rectOf(x)) < minX(rectOf(y)))
  const before = maxBy(near.filter((one) => maxX(rectOf(one)) <= minX(b) + 0.5 && minX(b) - maxX(rectOf(one)) < body),
    (x, y) => maxX(rectOf(x)) < maxX(rectOf(y)))
  const held = closing(bracket) !== null ? (before ?? after) : (after ?? before)
  if (held === undefined) return false
  return Math.abs(held.y - bracket.y) > body * 0.1
}

/** Whether a font is an italic or slanted face. */
export function isItalicFace(upper: string): boolean {
  return upper.includes('ITAL') || upper.includes('OBLIQUE') || upper.includes('SLANT')
    || upper.startsWith('CMTI') || upper.startsWith('CMSL') || upper.startsWith('CMBXTI')
    || upper.startsWith('CMBXSL') || upper.startsWith('SFTI') || upper.startsWith('SFSL')
    || upper.startsWith('SFBI') || upper.endsWith('-IT') || upper.endsWith('-BI')
    || upper.endsWith('-BOLDIT')
    || (upper.startsWith('LINLIBERTINE') && upper.endsWith('I'))
}

/** A letter from the italic of a text face — which, on a page that sets its
 *  variables that way, is a variable. */
export function isItalicLetter(glyph: Glyph): boolean {
  if (isMathFont(glyph) || !isItalicFace(family(glyph))) return false
  const drawn = token(glyph)
  const all = chars(drawn)
  return all.length === 1 && isLetter(all[0])
}

/** Whether a Latin letter in a formula is set upright: from a roman, sans or
 *  typewriter text face, or — in a Unicode maths font, which writes its
 *  italic letters as the Mathematical Alphanumeric Symbols — as the plain
 *  letter itself. */
export function isUprightLetter(glyph: Glyph): boolean {
  const drawn = token(glyph)
  if (!/^[A-Za-z]$/.test(drawn) || boldCommand(glyph) !== null) return false
  const upper = family(glyph)
  if (isMathFont(glyph)) {
    if (!isUnicodeMathFont(upper)) return false
    if (glyph.glyphName !== null && TeX.unicodeName(glyph.glyphName) !== null) return false
    if (glyph.unicode === null || glyph.unicode === '') return glyph.glyphName !== null && same(glyph.glyphName, drawn)
    return same(glyph.unicode, drawn)
  }
  return !isItalicFace(upper)
}

const UNICODE_FACES = ['LATINMODERNMATH', 'STIXTWOMATH', 'STIXMATH', 'XITSMATH',
  'LIBERTINUSMATH', 'CAMBRIAMATH', 'ASANAMATH', 'FIRAMATH',
  'GARAMONDMATH', 'GARAMOND-MATH', 'NEWCMMATH', 'DEJAVUMATH',
  'LUCIDABRIGHTMATH', 'EULERMATH', 'KPMATH', 'STIXGENERAL']

/** The OpenType maths fonts, and STIX's own for pdfTeX: fonts in which a
 *  plain letter is an upright letter. */
export function isUnicodeMathFont(upper: string): boolean {
  if (UNICODE_FACES.some((face) => upper.includes(face))) return true
  return upper.startsWith('TEXGYRE') && upper.includes('MATH')
}

const SANS = ['CMSS', 'SFSS', 'LMSANS', 'HELVETICA', 'NIMBUSSAN', 'HEROS', 'BIOLINUM', 'ARIAL', 'SANS']
const MONO = ['CMTT', 'SFTT', 'LMMONO', 'TXTT', 'T1XTT', 'COURIER', 'NIMBUSMON', 'CURSOR', 'MONO']

/** How an upright run of letters is written: in roman, sans or typewriter,
 *  as the face it was set in. */
export function uprightStyle(glyph: Glyph): string {
  const upper = family(glyph)
  if (SANS.some((one) => upper.startsWith(one) || upper.includes(one))) return '\\mathsf'
  if (MONO.some((one) => upper.startsWith(one) || upper.includes(one))) return '\\mathtt'
  return '\\mathrm'
}

/** The size a formula is set in: the largest of its ordinary glyphs — the
 *  signs that grow to fit are left out. */
export function ordinarySize(glyphs: Glyph[]): number {
  const ordinary = glyphs.filter((one) => !extension(one) && !isBigOperator(one) && !isDelimiter(one) && !isRadical(one))
  const size = maxOf(ordinary.map((one) => one.size))
  if (size !== undefined) return size
  return maxOf(glyphs.filter((one) => !extension(one)).map((one) => one.size)) ?? maxOf(glyphs.map((one) => one.size)) ?? 10
}

// MARK: - The recursion

/** What a script hangs from: the last thing written at full height. */
interface Base { size: number; baseline: number; index: number }

function transcribe(glyphs: Glyph[], rules: Rule[], context: Context | null = null, lineSize: number | null = null): string {
  if (glyphs.length === 0) return ''
  const body = context?.bodySize ?? ordinarySize(glyphs)
  // The size of the line the whole formula is set on, which the smallest
  // scripts are measured against.
  const line = lineSize ?? body
  // Matrices and cases first: a fraction in a cell is the cell's.
  const grids = new Map<number, Grid>()
  const gridded = new Set<number>()
  for (let index = 0; index < glyphs.length; index += 1) {
    if (gridded.has(index)) continue
    const found = grid(index, glyphs, rules, body, gridded)
    if (found === null) continue
    grids.set(index, found)
    for (const member of found.members) gridded.add(member)
  }
  const free = gridded.size === 0 ? glyphs : glyphs.filter((_, index) => !gridded.has(index))
  const found = fractionBars(rules, free)
  // The bars were found among the glyphs the grids left; their members are
  // counted in the whole formula's numbers.
  const positions = indices(glyphs.length).filter((index) => !gridded.has(index))
  const bars: Bar[] = found.map((bar) => ({
    rule: bar.rule, over: bar.over.map((at) => positions[at]), under: bar.under.map((at) => positions[at]),
  }))
  const baseline = context?.baseline ?? baselineOf(glyphs, body, bars)

  const owner = new Map<number, number>()
  bars.forEach((bar, number) => {
    for (const member of [...bar.over, ...bar.under]) owner.set(member, number)
  })
  // What the grids hold is theirs; nothing found up front may take it.
  const consumed = new Set(gridded)
  const roots = radicals(glyphs, rules, body, baseline, owner, consumed)
  const limits = operatorLimits(glyphs, body, baseline, owner, consumed)
  const names = operatorNames(glyphs, body, baseline, owner, consumed)
  const ruled = overlines(rules, glyphs, body, bars, roots, owner, consumed)
  const accented = accents(glyphs, owner, consumed)
  const struck = negations(glyphs, owner, consumed)

  const tokens: string[] = []
  let base: Base | null = null
  let index = 0

  const others = (rule: Rule) => rules.filter((one) => !sameRect(one.rect, rule.rect))
  const part = (members: number[]) => byX(members.map((member) => glyphs[member]))

  while (index < glyphs.length) {
    if (consumed.has(index) && !grids.has(index)) { index += 1; continue }
    const glyph = glyphs[index]

    // A fraction: the bar and everything over and under it, written where
    // its first glyph is. Set small and lifted well off the line it is a
    // superscript — e^{\frac{1}{2}} — and set small and dropped, a subscript.
    const number = owner.get(index)
    if (number !== undefined) {
      const bar = bars[number]
      for (const member of [...bar.over, ...bar.under]) consumed.add(member)
      const rest = others(bar.rule)
      let t = `\\frac{${transcribe(part(bar.over), rest, null, line)}}` + `{${transcribe(part(bar.under), rest, null, line)}}`
      const parts = maxOf([...bar.over, ...bar.under].map((member) => glyphs[member].size)) ?? body
      let scripted = false
      // Nothing is a script of an opening bracket.
      const opened = base !== null ? opening(glyphs[base.index]) !== null : false
      if (base !== null && tokens.length > 0 && !opened && parts < base.size * 0.8) {
        const level = midY(bar.rule.rect) - base.baseline
        if (level > base.size * 0.42) {
          t = `^{${t}}`
          scripted = true
        } else if (level < base.size * 0.1) {
          t = `_{${t}}`
          scripted = true
        }
      }
      tokens.push(t)
      if (!scripted) base = { size: body, baseline, index }
      index += 1
      continue
    }

    // A big operator takes what is stacked over and under it.
    const stacked = limits.get(index)
    if (stacked !== undefined) {
      let t = mathToken(glyph)
      const below = group(stacked.below.map((member) => glyphs[member]), rules, line)
      if (below !== null) t += '_' + below
      const above = group(stacked.above.map((member) => glyphs[member]), rules, line)
      if (above !== null) t += '^' + above
      tokens.push(t)
      base = { size: body, baseline, index }
      index += 1
      continue
    }

    // A radical: the sign, the rule over what it takes, and the root set in
    // its crook.
    const root = roots.get(index)
    if (root !== undefined) {
      for (const member of root.radicand) consumed.add(member)
      const rest = others(root.vinculum)
      const inside = transcribe(part(root.radicand), rest, { bodySize: body, baseline }, line)
      const degree = root.degree.length === 0 ? '' : transcribe(part(root.degree), rest, null, line)
      tokens.push(degree === '' ? `\\sqrt{${inside}}` : `\\sqrt[${degree}]{${inside}}`)
      base = { size: body, baseline, index }
      index += 1
      continue
    }

    // A name that takes limits, with them — "lim" with "n→∞" under it.
    const named = names.get(index)
    if (named !== undefined) {
      let t = named.command
      const below = group(named.below.map((member) => glyphs[member]), rules, line)
      if (below !== null) t += '_' + below
      const above = group(named.above.map((member) => glyphs[member]), rules, line)
      if (above !== null) t += '^' + above
      tokens.push(t)
      for (const member of named.letters) consumed.add(member)
      const last = named.letters.length > 0 ? named.letters[named.letters.length - 1] : index
      base = { size: glyphs[last].size, baseline: glyphs[last].y, index: last }
      index += 1
      continue
    }

    // A rule over a run, or under it.
    const stroke = ruled.get(index)
    if (stroke !== undefined) {
      for (const member of stroke.covered) consumed.add(member)
      const inside = transcribe(part(stroke.covered), others(stroke.rule), { bodySize: body, baseline }, line)
      tokens.push(stroke.over ? `\\overline{${inside}}` : `\\underline{${inside}}`)
      base = { size: body, baseline, index }
      index += 1
      continue
    }

    // An accent and what it covers: one letter, or — a wide accent — all of them.
    const mark = accented.get(index)
    if (mark !== undefined) {
      for (const member of mark.covered) consumed.add(member)
      let inside = mark.covered.length === 1
        ? mathToken(glyphs[mark.covered[0]])
        : transcribe(part(mark.covered), rules, { bodySize: body, baseline }, line)
      // One letter under the mark keeps its weight: ŝ in bold is
      // \hat{\boldsymbol{s}}, not \hat{s}.
      if (mark.covered.length === 1 && inside !== '') {
        const bold = boldCommand(glyphs[mark.covered[0]])
        if (bold !== null) inside = `${bold}{${inside}}`
      }
      tokens.push(`${mark.command}{${inside}}`)
      const last = maxOf(mark.covered) ?? index
      base = { size: glyphs[last].size, baseline: glyphs[last].y, index: last }
      index += 1
      continue
    }

    // A run of small glyphs off the baseline is a script on whatever came
    // before it — "small" against that, not the whole formula. Asked before
    // anything is read as a bracket: the "(" of x^{(i)} is a superscript first.
    if (base !== null && tokens.length > 0) {
      const script = scripts(index, glyphs, base.baseline, base.size, line, consumed)
      if (script !== null) {
        let t = ''
        // A prime is raised like a superscript and written like a mark.
        const marks = primes(script.raised)
        if (marks !== null) {
          t += marks
        } else {
          const above = group(script.raised, rules, line)
          if (above !== null) t += '^' + above
        }
        const below = group(script.lowered, rules, line)
        if (below !== null) t += '_' + below
        if (t !== '') tokens.push(t)
        for (let member = index; member < script.end; member += 1) consumed.add(member)
        index = script.end
        continue
      }
    }

    // A matrix, or a system of cases: rows of cells between tall brackets,
    // or after a tall brace that nothing closes.
    const table = grids.get(index)
    if (table !== undefined) {
      for (const member of table.members) consumed.add(member)
      const rows = table.cells.map((row, level) => row.map((cell) => (cell.length === 0 ? '' : transcribe(
        part(cell), rules, { bodySize: body, baseline: table.baselines[level] }, line))).join(' & '))
      tokens.push(`\\begin{${table.environment}} ` + rows.join(' \\\\ ') + ` \\end{${table.environment}}`)
      base = { size: body, baseline, index: table.close ?? index }
      index += 1
      continue
    }

    // Two things stacked in parentheses with no bar between them.
    const stack = binomial(index, glyphs, owner, consumed)
    if (stack !== null) {
      for (const member of [...stack.top, ...stack.bottom]) consumed.add(member)
      consumed.add(stack.close)
      const top = transcribe(part(stack.top), rules, null, line)
      const bottom = transcribe(part(stack.bottom), rules, null, line)
      tokens.push(`\\binom{${top}}{${bottom}}`)
      base = { size: body, baseline, index: stack.close }
      index += 1
      continue
    }

    // A tall fence or delimiter is drawn as a stack of pieces: one symbol,
    // however many pieces it took to reach that height.
    const fenced = TeX.fence(glyph.glyphName) ?? opening(glyph) ?? closing(glyph)
    if (fenced !== null) {
      let next = index + 1
      // The pieces stand one on another; two brackets side by side — the
      // "))" that closes two things at once — are two.
      while (next < glyphs.length && !consumed.has(next)
        && ((TeX.fence(glyphs[next].glyphName) ?? opening(glyphs[next]) ?? closing(glyphs[next])) === fenced
          || TeX.isDecoration(glyphs[next].glyphName))
        && extension(glyphs[next]) === extension(glyph)
        && Math.abs(glyphs[next].x - glyph.x) < glyph.size * 0.2
        && Math.abs(glyphs[next].y - glyph.y) > glyph.size * 0.2) {
        consumed.add(next)
        next += 1
      }
      tokens.push(fenced)
      // A bracket drawn from a point off the line — an extension font's, or
      // one of STIX's larger sizes — has its scripts measured from the
      // formula's own baseline.
      const offLine = extension(glyph) || Math.abs(glyph.y - baseline) > body * 0.25
      base = { size: body, baseline: offLine ? baseline : glyph.y, index }
      index = next
      continue
    }

    // Dots on the line, however many were drawn, are one symbol.
    const dots = dotRun(index, glyphs, consumed)
    if (dots !== null) {
      tokens.push(dots.command)
      base = { size: glyph.size, baseline: glyph.y, index: dots.end - 1 }
      index = dots.end
      continue
    }

    // A bold face in a formula means a bold symbol — a vector, most often.
    const bold = boldRun(index, glyphs, consumed)
    if (bold !== null) {
      tokens.push(bold.text)
      base = { size: glyph.size, baseline: glyph.y, index: bold.end - 1 }
      index = bold.end
      continue
    }

    // Upright letters in a formula are a word, and a word is written as one:
    // "softmax" is \mathrm{softmax}, not s·o·f·t·\max.
    const word = uprightRun(index, glyphs, consumed)
    if (word !== null) {
      tokens.push(word.text)
      base = { size: glyph.size, baseline: glyph.y, index: word.end - 1 }
      index = word.end
      continue
    }

    const t = struck.get(index) ?? mathToken(glyph)
    if (t !== '') {
      tokens.push(t)
      const drawnOffLine = extension(glyph) || isBigOperator(glyph)
      base = { size: glyph.size, baseline: drawnOffLine ? baseline : glyph.y, index }
    }
    index += 1
  }
  return join(tokens)
}

/**
 * A glyph as it is written inside a formula: what LaTeX cannot take as a
 * character in mathematics is written as its command, whichever font drew
 * it. In a sentence all of these stay as they were typed, which is why this
 * is not `token`.
 */
export function mathToken(glyph: Glyph): string {
  const raw = token(glyph)
  if (count(raw) === 1 || [...raw].length === 1) {
    const command = TeX.unicodeCommand(raw)
    if (command !== undefined) return command
    if (raw === '\\') return '\\setminus'
    if (raw === '$') return '\\$'
  }
  return raw
}

/** The primes a raised run is, when that is all it is: one or more. */
function primes(glyphs: Glyph[]): string | null {
  const marks = glyphs.map(token)
  if (marks.length === 0 || !marks.every((one) => /^'+$/.test(one))) return null
  return marks.join('')
}

/** One script or limit, braced when it is more than a single symbol. */
function group(glyphs: Glyph[], rules: Rule[], line: number): string | null {
  if (glyphs.length === 0) return null
  const inner = transcribe(byX(glyphs), rules, null, line)
  if (inner === '') return null
  return count(inner) > 1 ? `{${inner}}` : inner
}

/** Joins tokens, putting a space only where LaTeX needs one: after a command
 *  whose name would otherwise run into the next letter, and after a bare
 *  one-character script. */
export function join(tokens: string[]): string {
  let result = ''
  for (const t of tokens) {
    if (t === '') continue
    const next = t.codePointAt(0)!
    const alnum = isLetter(String.fromCodePoint(next)) || isNumber(String.fromCodePoint(next))
    const needsSpace = (endsInCommand(result) && alnum) || (endsInBareScript(result) && alnum)
    if (needsSpace) result += ' '
    result += t
  }
  return result
}

/** Whether the text ends in a one-character script — "^L", "_i". */
function endsInBareScript(text: string): boolean {
  if (text.length < 2) return false
  const tail = lastChars(text, 2)
  if (tail.length < 2) return false
  const [mark, last] = tail
  if (!(isLetter(last) || isNumber(last))) return false
  return mark === '^' || mark === '_'
}

/** Whether what has been built so far ends in a command name like `\alpha`,
 *  which the next letter would otherwise join. */
function endsInCommand(text: string): boolean {
  if (!text.includes('\\')) return false
  const all = chars(text)
  let letters = 0
  while (letters < all.length && isLetter(all[all.length - 1 - letters])) letters += 1
  if (letters === 0) return false
  const at = all.length - letters
  return at > 0 && all[at - 1] === '\\'
}

/** Where the formula's own baseline is: the level most of its full-size
 *  glyphs sit on — the signs drawn from off any baseline, the big operators
 *  and whatever is over or under a fraction bar left out of the vote. */
function baselineOf(glyphs: Glyph[], bodySize: number, bars: Bar[]): number {
  const barred = new Set(bars.flatMap((bar) => [...bar.over, ...bar.under]))
  const voters = ascending(indices(glyphs.length).filter((index) => {
    const glyph = glyphs[index]
    return glyph.size >= bodySize * 0.92 && !extension(glyph) && !isBigOperator(glyph)
      && !isRadical(glyph) && !barred.has(index)
  }).map((index) => glyphs[index].y))
  if (voters.length > 0) return voters[Math.floor(voters.length / 2)]
  if (bars.length > 0) return midY(bars[0].rule.rect) - bodySize * 0.25
  const full = glyphs.filter((one) => one.size >= bodySize * 0.92 && !extension(one))
  const sample = ascending((full.length === 0 ? glyphs : full).map((one) => one.y))
  return sample[Math.floor(sample.length / 2)]
}

/** Whether a glyph is an accent mark. */
export function isAccent(glyph: Glyph): boolean { return accentName(glyph) !== null }

/** What this glyph would be as an accent, if it is one. */
function accentName(glyph: Glyph): string | null {
  const named = TeX.accent(glyph.glyphName)
  if (named !== null) return named
  switch (canon(token(glyph))) {
    case '^': case '\u02C6': case '\u0302': return '\\hat'
    case '~': case '\u02DC': case '\u0303': return '\\tilde'
    case '\u00AF': case '\u0304': case '\u0305': return '\\bar'
    case '\u02D9': case '\u0307': return '\\dot'
    case '\u00A8': case '\u0308': return '\\ddot'
    case '\u02C7': case '\u030C': return '\\check'
    case '\u02D8': case '\u0306': return '\\breve'
    case '\u00B4': case '\u0301': return '\\acute'
    case '`': case '\u0300': return '\\grave'
    case '\u20D7': return '\\vec'
    default: return null
  }
}

/** The size a formula is mostly set in: the commonest size, to the nearest
 *  half point (`MathTranscriber.size`). */
export function size(glyphs: Glyph[]): number {
  const counts = new Map<number, number>()
  for (const glyph of glyphs) {
    const key = Math.round(glyph.size * 2) / 2
    counts.set(key, (counts.get(key) ?? 0) + 1)
  }
  const floor = Math.max(2, Math.floor(glyphs.length / 8))
  const common = [...counts].filter(([, n]) => n >= floor).map(([key]) => key)
  return maxOf(common) ?? maxOf(glyphs.map((one) => one.size)) ?? 10
}

/**
 * The scripts hanging from whatever came before: a run of small glyphs off
 * the baseline. A subscript and a superscript are one arrangement — TeX sets
 * them one over the other, so they arrive interleaved and are told apart by
 * height.
 */
function scripts(start: number, glyphs: Glyph[], baseline: number, body: number, line: number, consumed: Set<number>): { end: number; raised: Glyph[]; lowered: Glyph[] } | null {
  if (start <= 0) return null
  let end = start
  const raised: Glyph[] = []
  const lowered: Glyph[] = []
  // Only glyphs at the run's own size decide a side; smaller ones go wherever
  // the last of those went, and the recursion works out where they sit.
  const primary = glyphs[start].size
  // TeX has three sizes and no fourth: a script on a script's script is set
  // as small as the one it hangs from, and only its place says what it is.
  const smallest = body <= line * 0.62
  let side: boolean | null = null
  while (end < glyphs.length && !consumed.has(end)) {
    const glyph = glyphs[end]
    const offset = glyph.y - baseline
    const small = glyph.size < body * 0.92
    const asSmall = smallest && glyph.size <= body * 1.02 && Math.abs(offset) >= body * 0.2
    // A sign drawn from an extension font is never a script.
    if (!(small || asSmall) || isSpace(glyph) || extension(glyph)) break
    // Word sets a subscript small and leaves it *on* the line; TeX's are
    // always off it, if by as little as a ninth of the body.
    if (end === start && Math.abs(offset) <= body * 0.03) {
      const touching = minX(rectOf(glyph)) - maxX(rectOf(glyphs[start - 1])) < body * 0.12
      if (!(glyph.size <= body * 0.72 && touching && glyphs[start - 1].size >= body * 0.92)) break
      let run = start
      while (run < glyphs.length && !consumed.has(run) && glyphs[run].size <= body * 0.72
        && Math.abs(glyphs[run].y - baseline) <= body * 0.03
        && (run === start || minX(rectOf(glyphs[run])) - maxX(rectOf(glyphs[run - 1])) < body * 0.12)) {
        run += 1
      }
      return { end: run, raised: [], lowered: glyphs.slice(start, run) }
    }
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

/** The names TeX sets in roman inside a formula, because each is a word. */
const OPERATOR_NAMES = [
  'log', 'ln', 'lg', 'exp', 'sin', 'cos', 'tan', 'cot', 'sec', 'csc',
  'sinh', 'cosh', 'tanh', 'coth', 'arcsin', 'arccos', 'arctan',
  'min', 'max', 'inf', 'sup', 'lim', 'det', 'dim', 'ker', 'deg',
  'gcd', 'hom', 'arg', 'Pr',
]
const OPERATOR_NAME_SET = new Set(OPERATOR_NAMES)

/** The names written as two words, which a thin space joins on the page. */
const TWO_WORD_NAMES: Record<string, string> = {
  argmin: '\\arg\\min', argmax: '\\arg\\max', limsup: '\\limsup', liminf: '\\liminf',
}
const twoWordName = (name: string) => (Object.prototype.hasOwnProperty.call(TWO_WORD_NAMES, name) ? TWO_WORD_NAMES[name] : undefined)

/** The names that take limits under them in a display, as a sum does. */
const NAMES_WITH_LIMITS = new Set([
  'min', 'max', 'inf', 'sup', 'lim', 'det', 'gcd', 'Pr', 'argmin', 'argmax', 'limsup', 'liminf',
])

/** Whether a run of letters spells one of those names. */
export function isOperatorName(spelled: string): boolean {
  return OPERATOR_NAME_SET.has(spelled) || twoWordName(spelled) !== undefined
}

/** Dots in a row: three centred ones are `\cdots`, three on the line are
 *  `\ldots`, and one on its own is a product. */
function dotRun(start: number, glyphs: Glyph[], consumed: Set<number>): { end: number; command: string } | null {
  const first = canon(token(glyphs[start]))
  const centred = first === '\u00B7' || first === '\\cdot'
  if (!(centred || first === '.')) return null
  let end = start + 1
  while (end < glyphs.length && !consumed.has(end) && canon(token(glyphs[end])) === first
    && minX(rectOf(glyphs[end])) - maxX(rectOf(glyphs[end - 1])) < glyphs[end].size * 0.6) {
    end += 1
  }
  if (end - start >= 2) return { end, command: centred ? '\\cdots' : '\\ldots' }
  return centred ? { end, command: '\\cdot' } : null
}

/** A run of glyphs from a bold face, wrapped once rather than letter by letter. */
function boldRun(start: number, glyphs: Glyph[], consumed: Set<number>): { end: number; text: string } | null {
  const command = boldCommand(glyphs[start])
  if (command === null) return null
  let end = start + 1
  while (end < glyphs.length && !consumed.has(end) && boldCommand(glyphs[end]) === command
    && Math.abs(glyphs[end].y - glyphs[start].y) < 0.01
    && minX(rectOf(glyphs[end])) - maxX(rectOf(glyphs[end - 1])) < glyphs[end].size * 0.22) {
    end += 1
  }
  const inner = join(glyphs.slice(start, end).map(mathToken))
  if (inner === '') return null
  return { end, text: `${command}{${inner}}` }
}

export function boldCommand(glyph: Glyph): string | null {
  // A glyph named by its code point carries its own weight and style.
  if (glyph.glyphName !== null && TeX.unicodeName(glyph.glyphName) !== null) return null
  // An alphabet of its own — mathpazo's bold blackboard — is that alphabet.
  if (TeX.letterStyle(glyph.fontName) !== null) return null
  const upper = family(glyph)
  if (upper.startsWith('CMMIB') || upper.startsWith('CMBSY') || upper.startsWith('RMTMIB')
    || upper.includes('BMI') || upper.includes('BSY') || upper.startsWith('EURB')
    || (upper.includes('MATH') && (upper.includes('BOLD') || upper.endsWith('-B')))) {
    return '\\boldsymbol'
  }
  // Libertine's bold faces are LinLibertineTB and, for \mathbf, the semibold
  // LinLibertineTZ.
  if (upper.startsWith('LINLIBERTINET') && (upper.slice(13).startsWith('B') || upper.slice(13).startsWith('Z'))) {
    return upper.endsWith('I') ? '\\boldsymbol' : '\\mathbf'
  }
  if (upper.startsWith('CMBX') || upper.startsWith('SFBX') || upper.includes('-BOLD')
    || upper.endsWith('-BD') || upper.includes('-MEDI') || upper.endsWith('-B')
    || upper.endsWith('BOLD') || upper.endsWith('-BOL') || upper.startsWith('CMB10')
    || upper.startsWith('RTXB') || upper.startsWith('RPXB')) {
    return '\\mathbf'
  }
  return null
}

/** Upright letters set touching, as one word: \mathrm{softmax}, \mathrm{d},
 *  \mathsf{T}. Nil when the glyph is not an upright letter. */
function uprightRun(start: number, glyphs: Glyph[], consumed: Set<number>): { end: number; text: string } | null {
  const first = glyphs[start]
  // A ligature is letters too: Libertine sets the "ft" of "softmax" as one glyph.
  const upright = (glyph: Glyph) => {
    if (isUprightLetter(glyph)) return true
    const drawn = token(glyph)
    return drawn.length >= 2 && drawn.length <= 3 && allASCIILetters(drawn)
      && !isMathFont(glyph) && !isItalicFace(family(glyph)) && boldCommand(glyph) === null
  }
  if (!upright(first)) return null
  const style = uprightStyle(first)
  const continues = (at: number) => {
    const glyph = glyphs[at]
    return !consumed.has(at) && uprightStyle(glyph) === style
      && Math.abs(glyph.y - first.y) < first.size * 0.1
      && Math.abs(glyph.size - first.size) < first.size * 0.1
      && minX(rectOf(glyph)) - maxX(rectOf(glyphs[at - 1])) < glyph.size * 0.22
  }
  let end = start + 1
  let hyphenated = false
  while (end < glyphs.length && continues(end)) {
    if (upright(glyphs[end])) {
      end += 1
      continue
    }
    // A hyphen between two letters is part of the word: "teacher-forcing".
    if (isMathFont(glyphs[end]) || token(glyphs[end]) !== '-' || !(end + 1 < glyphs.length)
      || !upright(glyphs[end + 1]) || !continues(end + 1)) break
    hyphenated = true
    end += 2
  }
  const letters = glyphs.slice(start, end).map(token).join('')
  if (hyphenated) return { end, text: `\\text{${letters}}` }
  if (style === '\\mathrm') {
    const spelledNames = namesIn(letters)
    if (spelledNames !== null && spelledNames.length > 0) {
      return { end, text: spelledNames.map((name) => twoWordName(name) ?? '\\' + name).join('') }
    }
  }
  return { end, text: `${style}{${letters}}` }
}

// MARK: - Structures

/** A fraction bar, and which glyphs are over it and under it. */
interface Bar { rule: Rule; over: number[]; under: number[] }

/** Whether a glyph is across the width of a rule. */
function spans(rule: Rule, glyph: Glyph): boolean {
  const middle = midX(rectOf(glyph))
  return middle > minX(rule.rect) - 0.5 && middle < maxX(rule.rect) + 0.5
}

function extent(glyphs: Glyph[]): Rect {
  if (glyphs.length === 0) return NULL_RECT
  return glyphs.slice(1).reduce((box, one) => union(box, rectOf(one)), rectOf(glyphs[0]))
}

/**
 * The fraction bars: rules with something over them and something under,
 * each owning what is across its width — the widest first, so that a
 * fraction inside a fraction belongs to the numerator it is in. A bar is as
 * wide as what it divides, and a hair more; a table's \hline is not one.
 */
function fractionBars(rules: Rule[], glyphs: Glyph[]): Bar[] {
  const bars: Bar[] = []
  const owned = new Set<number>()
  for (const rule of sortedBy(rules, (a, b) => a.rect.width > b.rect.width)) {
    if (!(rule.rect.width > 1 && rule.rect.height < rule.rect.width && !isVinculumOf(rule, glyphs))) continue
    const inside = indices(glyphs.length).filter((at) => !owned.has(at) && spans(rule, glyphs[at]))
    const over = inside.filter((at) => glyphs[at].y > midY(rule.rect))
    const under = inside.filter((at) => glyphs[at].y <= midY(rule.rect))
    if (over.length === 0 || under.length === 0) continue
    const parts = extent(inside.map((at) => glyphs[at]))
    if (!(minX(rule.rect) > minX(parts) - 4 && maxX(rule.rect) < maxX(parts) + 4)) continue
    bars.push({ rule, over, under })
    for (const at of inside) owned.add(at)
  }
  return bars
}

/** Whether a rule is the roof of a radical: it starts where a radical sign
 *  ends, at the sign's top. */
function isVinculumOf(rule: Rule, glyphs: Glyph[]): boolean {
  return glyphs.some((sign) => isVinculum(rule, sign))
}

function isVinculum(rule: Rule, sign: Glyph): boolean {
  if (!isRadical(sign)) return false
  return Math.abs(minX(rule.rect) - maxX(rectOf(sign))) < Math.max(1, sign.size * 0.15)
    && midY(rule.rect) > sign.y - sign.size * 3
    && midY(rule.rect) < sign.y + sign.size * 2.5
}

/** A radical, what its rule covers, and the root in its crook. */
interface Root { vinculum: Rule; radicand: number[]; degree: number[] }

/** The radicals, keyed by their sign; their roots are taken up front, because
 *  a root is written before its sign when it is wider than the crook. */
function radicals(glyphs: Glyph[], rules: Rule[], body: number, baseline: number, owned: Map<number, number>, consumed: Set<number>): Map<number, Root> {
  const found = new Map<number, Root>()
  glyphs.forEach((sign, index) => {
    if (!(isRadical(sign) && !owned.has(index) && !consumed.has(index))) return
    const s = rectOf(sign)
    const vinculum = minBy(rules.filter((rule) => isVinculum(rule, sign)),
      (a, b) => Math.abs(minX(a.rect) - maxX(s)) < Math.abs(minX(b.rect) - maxX(s)))
    if (vinculum === undefined) return
    const radicand = indices(glyphs.length).filter((at) => at !== index && !consumed.has(at)
      && spans(vinculum, glyphs[at]) && glyphs[at].y < midY(vinculum.rect))
    const full = radicand.map((at) => glyphs[at]).filter((one) => one.size >= body * 0.92 && !extension(one))
    const floor = full.length === 0 ? baseline : ascending(full.map((one) => one.y))[Math.floor(full.length / 2)]
    const within = new Set(radicand)
    const degree = indices(glyphs.length).filter((other) => {
      const glyph = glyphs[other]
      const g = rectOf(glyph)
      return other !== index && !consumed.has(other) && !within.has(other)
        && !owned.has(other) && glyph.size < body * 0.8
        && maxX(g) <= minX(vinculum.rect) + 0.5
        && maxX(g) > minX(s) + 1
        && minX(g) > minX(s) - body * 1.5
        && glyph.y > floor + body * 0.25
    })
    for (const at of degree) consumed.add(at)
    found.set(index, { vinculum, radicand, degree })
  })
  return found
}

/** Glyphs that follow one another closely, as runs. */
function runs(members: number[], glyphs: Glyph[], gap: number): number[][] {
  const ordered = [...members].sort((a, b) => {
    const ax = minX(rectOf(glyphs[a]))
    const bx = minX(rectOf(glyphs[b]))
    return ax !== bx ? (ax < bx ? -1 : 1) : a - b
  })
  const out: number[][] = []
  for (const member of ordered) {
    const lastRun = out[out.length - 1]
    const last = lastRun?.[lastRun.length - 1]
    if (last !== undefined && minX(rectOf(glyphs[member])) - maxX(rectOf(glyphs[last])) < gap) lastRun.push(member)
    else out.push([member])
  }
  return out
}

/**
 * The limits of each big operator, found before anything else is read:
 * stacked over and under the sign in a display, beside it in running text,
 * and either way arriving before the sign or interleaved with the other
 * limit. Each operator takes, on each side, the run of small glyphs centred
 * on it or starting at its right edge; what one took, the next cannot.
 */
function operatorLimits(glyphs: Glyph[], body: number, baseline: number, owned: Map<number, number>, consumed: Set<number>): Map<number, { above: number[]; below: number[] }> {
  const limits = new Map<number, { above: number[]; below: number[] }>()
  glyphs.forEach((sign, position) => {
    if (!(isBigOperator(sign) && !owned.has(position) && !consumed.has(position))) return
    // Whatever full-size thing comes next is where the limits stop.
    const s = rectOf(sign)
    let stop = MAX
    for (let next = position + 1; next < glyphs.length; next += 1) {
      if (consumed.has(next) || !(glyphs[next].size >= body * 0.95)) continue
      stop = minX(rectOf(glyphs[next]))
      // Another sign with limits of its own right after this one: the limits
      // under the two run into each other — "i=1" and "j∈Bᵢ" under ∑∑ are
      // one row of small glyphs — and are parted halfway between the signs.
      // It is the next sign that is asked whether it is an integral, as the
      // Mac asks.
      if (isBigOperator(glyphs[next]) && !token(glyphs[next]).includes('int')) {
        stop = (maxX(s) + minX(rectOf(glyphs[next]))) / 2
      }
      break
    }
    const candidates = indices(glyphs.length).filter((other) => {
      const glyph = glyphs[other]
      const g = rectOf(glyph)
      return other !== position && !consumed.has(other) && !owned.has(other)
        && glyph.size < body * 0.95 && midX(g) < stop && !extension(glyph)
        && maxX(g) > minX(s) - body * 3
    })
    const take = (side: number[]) => {
      for (const run of runs(side, glyphs, body * 0.4)) {
        const span = extent(run.map((at) => glyphs[at]))
        const stackedHere = minX(span) < maxX(s) && maxX(span) > minX(s)
          && Math.abs(midX(span) - midX(s)) < Math.max(span.width, s.width) * 0.5 + 1
        // An integral's lower limit tucks in under its tail.
        const beside = minX(span) >= midX(s) && minX(span) - maxX(s) < body * 0.5
        if (stackedHere || beside) return run
      }
      return [] as number[]
    }
    const above = take(candidates.filter((at) => glyphs[at].y > baseline + body * 0.12))
    const below = take(candidates.filter((at) => glyphs[at].y < baseline - body * 0.12))
    for (const at of [...above, ...below]) consumed.add(at)
    limits.set(position, { above, below })
  })
  return limits
}

/** A name set in roman that takes limits under it in a display, and them. */
interface Named { letters: number[]; command: string; below: number[]; above: number[] }

/**
 * The names that take limits — "lim", "max", "arg min" — found with the
 * limits under them before anything is read: a limit centred under a word
 * arrives shuffled in among its letters.
 */
function operatorNames(glyphs: Glyph[], body: number, baseline: number, owned: Map<number, number>, consumed: Set<number>): Map<number, Named> {
  const found = new Map<number, Named>()
  const letter = (index: number) => {
    const glyph = glyphs[index]
    return !consumed.has(index) && !owned.has(index) && glyph.size >= body * 0.92
      && isUprightLetter(glyph) && uprightStyle(glyph) === '\\mathrm'
  }
  const limited = (name: string, letters: number[]): Named | null => {
    if (!NAMES_WITH_LIMITS.has(name)) return null
    const command = twoWordName(name) ?? '\\' + name
    const span = extent(letters.map((at) => glyphs[at]))
    const candidates = indices(glyphs.length).filter((other) => {
      const glyph = glyphs[other]
      const g = rectOf(glyph)
      return !consumed.has(other) && !owned.has(other) && glyph.size < body * 0.92
        && !extension(glyph)
        && maxX(g) > minX(span) - body * 3 && minX(g) < maxX(span) + body * 3
    })
    // Only a limit stacked under the name: a subscript beside it is a script.
    let below: number[] = []
    for (const run of runs(candidates.filter((at) => glyphs[at].y < baseline - body * 0.3), glyphs, body * 0.4)) {
      const under = extent(run.map((at) => glyphs[at]))
      if (minX(under) < maxX(span) && maxX(under) > minX(span)
        && Math.abs(midX(under) - midX(span)) < Math.max(under.width, span.width) * 0.5 + 1) {
        below = run
        break
      }
    }
    if (below.length === 0) return null
    for (const at of below) consumed.add(at)
    return { letters, command, below, above: [] }
  }
  let index = 0
  while (index < glyphs.length) {
    if (!letter(index)) { index += 1; continue }
    const letters = [index]
    let next = index + 1
    while (next < glyphs.length) {
      const glyph = glyphs[next]
      if (consumed.has(next) || glyph.size < body * 0.92) { next += 1; continue }
      if (!letter(next) || !(minX(rectOf(glyph)) - maxX(rectOf(glyphs[letters[letters.length - 1]])) <= glyph.size * 0.22)) break
      letters.push(next)
      next += 1
    }
    index = letters[letters.length - 1] + 1
    // Two names side by side — \min_G\max_D — are one run of letters with a
    // thin space in it; each takes its own limit.
    const spelledNames = namesIn(letters.map((at) => token(glyphs[at])).join(''))
    if (spelledNames === null) continue
    let offset = 0
    for (const name of spelledNames) {
      const own = letters.slice(offset, offset + count(name))
      offset += count(name)
      const named = limited(name, own)
      if (named !== null) found.set(own[0], named)
    }
  }
  return found
}

const KNOWN_NAMES = new Set([...OPERATOR_NAMES, ...Object.keys(TWO_WORD_NAMES)])

/** A run of letters as the names it spells one after another — "minmax" is
 *  min and max — or nil when it is not only names. */
export function namesIn(spelled: string): string[] | null {
  if (spelled === '') return []
  const all = chars(spelled)
  for (let length = Math.min(all.length, 6); length >= 2; length -= 1) {
    const head = all.slice(0, length).join('')
    if (!KNOWN_NAMES.has(head)) continue
    const rest = namesIn(all.slice(length).join(''))
    if (rest === null) continue
    return [head, ...rest]
  }
  return null
}

/** A rule over a run of glyphs, or under it. */
interface Ruled { rule: Rule; covered: number[]; over: boolean }

/** The rules that are not fraction bars and not the roofs of radicals —
 *  \overline and \underline — keyed by the first glyph they cover. */
function overlines(rules: Rule[], glyphs: Glyph[], body: number, bars: Bar[], roots: Map<number, Root>, owned: Map<number, number>, consumed: Set<number>): Map<number, Ruled> {
  const found = new Map<number, Ruled>()
  const taken = new Set<number>()
  const used = [...bars.map((bar) => bar.rule.rect), ...[...roots.values()].map((root) => root.vinculum.rect)]
  for (const rule of sortedBy(rules, (a, b) => a.rect.width > b.rect.width)) {
    if (!(rule.rect.width > 1 && rule.rect.height < rule.rect.width
      && !used.some((rect) => sameRect(rect, rule.rect)) && !isVinculumOf(rule, glyphs))) continue
    const inside = indices(glyphs.length).filter((at) => !consumed.has(at) && !taken.has(at) && !owned.has(at)
      && spans(rule, glyphs[at]))
    if (inside.length === 0) continue
    const under = inside.filter((at) => glyphs[at].y < midY(rule.rect))
    const over = inside.filter((at) => glyphs[at].y >= midY(rule.rect))
    if ((under.length === 0) === (over.length === 0)) continue
    const span = extent(inside.map((at) => glyphs[at]))
    if (!(minX(rule.rect) > minX(span) - 2 && maxX(rule.rect) < maxX(span) + 2)) continue
    const isOver = under.length > 0
    const heights = inside.map((at) => glyphs[at].y)
    const near = isOver
      ? midY(rule.rect) - (maxOf(heights) ?? 0) < body * 1.3
      : (minOf(heights) ?? 0) - midY(rule.rect) < body * 0.6
    const first = minOf(inside)
    if (!near || first === undefined) continue
    found.set(first, { rule, covered: inside, over: isOver })
    for (const at of inside) taken.add(at)
  }
  return found
}

/** An accent and the glyphs under it. */
interface Accent { command: string; covered: number[] }

/**
 * The accents, keyed by the first glyph each covers. TeX does not lift an
 * accent — the glyph carries its own height — so an accent is a mark drawn
 * on top of what it accents, at nearly the same baseline, covering each glyph
 * it lies across for half the narrower of the two.
 */
function accents(glyphs: Glyph[], owned: Map<number, number>, consumed: Set<number>): Map<number, Accent> {
  const found = new Map<number, Accent>()
  glyphs.forEach((mark, index) => {
    if (consumed.has(index) || owned.has(index)) return
    const command = accentName(mark)
    if (command === null) return
    let covered: number[]
    const m = rectOf(mark)
    if (mark.width < 0.05) {
      // A combining mark takes no room: its ink hangs to the left of where it
      // is drawn, over the full-size glyph it follows.
      const before = indices(glyphs.length).filter((other) => {
        const glyph = glyphs[other]
        const g = rectOf(glyph)
        return other !== index && !consumed.has(other) && !owned.has(other)
          && accentName(glyph) === null && !isSpace(glyph)
          && glyph.size >= mark.size * 0.9
          && Math.abs(glyph.y - mark.y) < Math.max(glyph.size, 1) * 0.35
          && maxX(g) <= mark.x + mark.size * 0.1
          && maxX(g) > mark.x - mark.size * 0.6
      })
      const nearest = maxBy(before, (a, b) => maxX(rectOf(glyphs[a])) < maxX(rectOf(glyphs[b])))
      covered = nearest === undefined ? [] : [nearest]
    } else {
      covered = indices(glyphs.length).filter((other) => {
        const glyph = glyphs[other]
        if (other === index || consumed.has(other) || owned.has(other)
          || accentName(glyph) !== null || isSpace(glyph)
          || !(Math.abs(glyph.y - mark.y) < Math.max(glyph.size, 1) * 0.35)) return false
        const g = rectOf(glyph)
        const overlap = Math.min(maxX(g), maxX(m)) - Math.max(minX(g), minX(m))
        return overlap > Math.min(glyph.width, mark.width) * 0.5
      })
    }
    const first = minOf(covered)
    if (first === undefined) {
      // A combining mark with nothing under it is dropped: written out, it
      // would sit on whatever came before.
      if (mark.width < 0.05 && [...token(mark)].every((one) => /^\p{Mn}$/u.test(one))) consumed.add(index)
      return
    }
    const wide = TeX.isWideAccent(mark.glyphName) || covered.length > 1
    const written = !wide ? command
      : command === '\\tilde' ? '\\widetilde' : command === '\\hat' ? '\\widehat' : command
    consumed.add(index)
    found.set(first, { command: written, covered })
  })
  return found
}

/** Relations struck through — `\not` over `=`, a slash across `\in` —
 *  written as the one relation they make, keyed by the relation. */
function negations(glyphs: Glyph[], owned: Map<number, number>, consumed: Set<number>): Map<number, string> {
  const found = new Map<number, string>()
  glyphs.forEach((stroke, index) => {
    if (consumed.has(index) || owned.has(index)) return
    const drawn = token(stroke)
    if (!(drawn === '\\not' || drawn === '/')) return
    for (const other of [index + 1, index - 1]) {
      if (other < 0 || other >= glyphs.length) continue
      const relation = glyphs[other]
      if (consumed.has(other) || owned.has(other) || found.has(other)
        || !(Math.abs(relation.y - stroke.y) < relation.size * 0.2)) continue
      let crossed: boolean
      if (drawn === '\\not') {
        crossed = Math.abs(relation.x - stroke.x) < relation.size * 0.3
      } else {
        const r = rectOf(relation)
        const s = rectOf(stroke)
        const overlap = Math.min(maxX(r), maxX(s)) - Math.max(minX(r), minX(s))
        crossed = overlap > Math.min(relation.width, stroke.width) * 0.7
      }
      if (!crossed) continue
      const written = negated(mathToken(relation), drawn)
      if (written === null) continue
      found.set(other, written)
      consumed.add(index)
      break
    }
  })
  return found
}

const NEGATED = new Map(Object.entries({
  '=': '\\neq', '\\in': '\\notin', '<': '\\nless', '>': '\\ngtr',
  '\\leq': '\\nleq', '\\geq': '\\ngeq', '\\sim': '\\nsim', '\\cong': '\\ncong',
  '\\subseteq': '\\nsubseteq', '\\supseteq': '\\nsupseteq', '\\mid': '\\nmid',
  '|': '\\nmid', '\\parallel': '\\nparallel', '\\|': '\\nparallel',
  '\\exists': '\\nexists', '\\equiv': '\\not\\equiv', '\\subset': '\\not\\subset',
  '\\supset': '\\not\\supset', '\\approx': '\\not\\approx', '\\ni': '\\not\\ni',
  '\\prec': '\\nprec', '\\succ': '\\nsucc', '\\vdash': '\\nvdash',
}))

/** The relation `\not` makes of another, as a person would write it. */
function negated(relation: string, stroke: string): string | null {
  const named = NEGATED.get(relation)
  if (named !== undefined) return named
  // A slash is only a negation across a relation; across anything else it
  // is the slash it looks like.
  return stroke === '\\not' && relation !== '' ? '\\not' + relation : null
}

/** Whether a glyph is one piece of a bracket built up tall: ⎛ ⎜ ⎝ and their
 *  kind in OpenType, "parenlefttp" and "parenleftex" in TeX's extension
 *  fonts, "parenlefttpA" in newtx's. A whole bracket — a "(" of any size — is
 *  none. */
export function isPiece(glyph: Glyph): boolean {
  if (isSilentPiece(glyph)) return true
  if (glyph.unicode !== null) {
    const scalars = [...glyph.unicode]
    if (scalars.length === 1) {
      const value = scalars[0].codePointAt(0)!
      if (value >= 0x239b && value <= 0x23b3) return true
    }
  }
  if (glyph.glyphName === null) return false
  let name = glyph.glyphName
  const dot = name.indexOf('.')
  if (dot >= 0) name = name.slice(0, dot)
  if (TeX.isDecoration(name)) return true
  if (['tpA', 'btA', 'exA', 'midA'].some((suffix) => name.endsWith(suffix))) name = name.slice(0, -1)
  const bracket = ['paren', 'bracket', 'brace', 'floor', 'ceiling', 'angle', 'bar', 'vextend'].some((prefix) => name.startsWith(prefix))
  return bracket && ['tp', 'bt', 'ex', 'mid'].some((suffix) => name.endsWith(suffix))
}

/**
 * The pieces of one bracket, grown out from one of them through the ones
 * above and below it: its box, and which glyphs it took. A bracket's own
 * segments are set closer than a line, and two brackets on two lines are a
 * line apart at least; a named piece belongs to its neighbours two lines
 * away. Nearness is between their points — a piece's box is not its ink.
 */
export function stack(start: number, glyphs: Glyph[], candidates: number[]): { box: Rect; members: number[] } {
  let box = rectOf(glyphs[start])
  const members = [start]
  const size = glyphs[start].size
  let grew = true
  while (grew) {
    grew = false
    for (const other of candidates) {
      if (members.includes(other)) continue
      const distance = minOf(members.map((member) => Math.abs(glyphs[member].y - glyphs[other].y))) ?? Infinity
      if (!(distance < size * 0.8 || (isPiece(glyphs[other]) && distance < size * 2.2))) continue
      box = union(box, rectOf(glyphs[other]))
      members.push(other)
      grew = true
    }
  }
  return { box, members }
}

/**
 * Rows of cells: a matrix between tall brackets, or cases after a tall
 * brace. What the brackets hold is two lines or more, a line apart — not a
 * superscript and a subscript — and a line breaks into cells where TeX put a
 * column's space, which nothing inside a cell is spaced by.
 */
interface Grid {
  environment: string
  cells: number[][][]
  baselines: number[]
  members: Set<number>
  close: number | null
}

const MATRICES = new Map<string, { close: string; environment: string }>([
  ['(', { close: ')', environment: 'pmatrix' }], ['[', { close: ']', environment: 'bmatrix' }],
  ['\\{', { close: '\\}', environment: 'Bmatrix' }], ['|', { close: '|', environment: 'vmatrix' }],
  ['\\|', { close: '\\|', environment: 'Vmatrix' }], ['\\mid', { close: '\\mid', environment: 'vmatrix' }],
])

function grid(start: number, glyphs: Glyph[], rules: Rule[], body: number, consumed: Set<number>): Grid | null {
  const open = glyphs[start]
  const openToken = token(open)
  const opener = opening(open) ?? TeX.fence(open.glyphName)
    ?? (['|', '\\|', '\\mid'].includes(openToken) ? openToken : null)
  if (opener === null) return null
  const kind = MATRICES.get(opener)
  if (kind === undefined) return null
  const o = rectOf(open)
  const sameSize = (other: Glyph) => extension(other) === extension(open) && Math.abs(other.size - open.size) < 0.5
    && Math.abs(other.y - open.y) < Math.max(1, open.size * 0.15)
  const closes = (other: Glyph) => (closing(other) ?? TeX.fence(other.glyphName) ?? token(other)) === kind.close
  let close: number | null = null
  for (let at = 0; at < glyphs.length; at += 1) {
    if (at > start && !consumed.has(at) && closes(glyphs[at]) && sameSize(glyphs[at])) { close = at; break }
  }
  // A bracket is drawn in pieces one over another; the ones below the top
  // are the bracket too.
  const pieces = (x: number) => indices(glyphs.length).filter((other) => !consumed.has(other)
    && Math.abs(glyphs[other].x - x) < open.size * 0.2
    && (TeX.isDecoration(glyphs[other].glyphName) || token(glyphs[other]) === ''
      || opening(glyphs[other]) === opener || closing(glyphs[other]) === kind.close
      || token(glyphs[other]) === opener || token(glyphs[other]) === kind.close))
  // Only this bracket's own pieces: another bracket at the same place on
  // another line is not this one (`stack`).
  const frame = [
    ...stack(start, glyphs, pieces(open.x)).members,
    ...(close !== null ? stack(close, glyphs, pieces(glyphs[close].x)).members : []),
  ]
  let reach = frame.map((at) => rectOf(glyphs[at])).reduce((box, one) => union(box, one), o)
  // One OpenType glyph, of a size the file does not give: as tall as two
  // lines either side of it, when it is one of its larger sizes.
  if (frame.length <= 2 && isTallVariant(open, glyphs, body)) {
    reach = union(reach, { x: minX(o), y: open.y - body * 2.2, width: o.width, height: body * 4.4 })
  }
  const right = close !== null ? minX(rectOf(glyphs[close])) + 0.5 : MAX
  // Cases has no closing brace; what it holds is what is beside it.
  if (close === null && opener !== '\\{') return null
  const framed = new Set(frame)
  // Between the brackets, and as high as they reach — a little lower, since
  // the last line's descenders and subscripts hang below them.
  const content = indices(glyphs.length).filter((other) => {
    const glyph = glyphs[other]
    const g = rectOf(glyph)
    return other !== start && !consumed.has(other) && !framed.has(other)
      && minX(g) >= maxX(o) - 0.5 && maxX(g) <= right
      && glyph.y > minY(reach) - body * 1.0 && glyph.y < maxY(reach) + body * 0.3
      && token(glyph) !== ''
  })
  if (content.length < 2) return null
  const largest = maxOf(content.map((at) => glyphs[at].size)) ?? body
  // Brackets that hold two lines are as tall as two lines.
  if (!(reach.height >= largest * 1.7)) return null
  // The lines, by where the glyphs at the content's own size sit. A radical
  // hangs from where it stands, so where it stands is not a line.
  const levels: number[] = []
  for (const other of sortedBy(content, (a, b) => glyphs[a].y > glyphs[b].y)) {
    const glyph = glyphs[other]
    if (!(glyph.size >= largest * 0.8 && !isBigOperator(glyph) && !isRadical(glyph) && !extension(glyph))) continue
    const height = glyph.y
    if (levels.length > 0 && levels[levels.length - 1] - height < largest * 0.45) continue
    levels.push(height)
  }
  if (levels.length < 2) return null
  for (let at = 0; at + 1 < levels.length; at += 1) {
    if (levels[at] - levels[at + 1] < largest * 0.9) return null
  }
  // A bar between two of the lines makes them a fraction's numerator and
  // denominator, whatever brackets stand round them.
  const span = extent(content.map((at) => glyphs[at]))
  if (rules.some((rule) => rule.rect.width > 1 && rule.rect.height < rule.rect.width
    && maxX(rule.rect) > minX(span) && minX(rule.rect) < maxX(span)
    && midY(rule.rect) < levels[0] && midY(rule.rect) > levels[levels.length - 1]
    && minX(rule.rect) > minX(o) - 1 && maxX(rule.rect) < right + 1)) return null
  const rows: number[][] = levels.map(() => [])
  for (const other of content) {
    const height = glyphs[other].y
    const nearest = minBy(indices(levels.length), (a, b) => Math.abs(levels[a] - height) < Math.abs(levels[b] - height)) ?? 0
    rows[nearest].push(other)
  }
  // A line's cells, where a column's space cuts it.
  const cells = rows.map((row) => {
    const result: { members: number[]; span: Rect }[] = []
    for (const other of sortedBy(row, (a, b) => minX(rectOf(glyphs[a])) < minX(rectOf(glyphs[b])))) {
      const rect = rectOf(glyphs[other])
      const last = result[result.length - 1]
      if (last !== undefined && minX(rect) - maxX(last.span) < body * 0.6) {
        last.members.push(other)
        last.span = union(last.span, rect)
      } else {
        result.push({ members: [other], span: rect })
      }
    }
    return result
  })
  // The columns, from where the cells of all the lines stand.
  let columns: Rect[] = []
  for (const cell of sortedBy(cells.flat(), (a, b) => minX(a.span) < minX(b.span))) {
    const at = columns.findIndex((column) => maxX(column) > minX(cell.span) && minX(column) < maxX(cell.span))
    if (at >= 0) columns[at] = union(columns[at], cell.span)
    else columns.push(cell.span)
  }
  columns = sortedBy(columns, (a, b) => minX(a) < minX(b))
  // Two things over each other in parentheses, as far apart as \binom sets
  // them, with nothing beside them, are a \binom.
  if (kind.environment === 'pmatrix' && levels.length === 2 && columns.length === 1
    && (largest < body * 0.8 || levels[0] - levels[1] >= largest * 1.28)) return null
  const environment = close === null ? 'cases' : kind.environment
  const table: number[][][] = []
  for (const row of cells) {
    const lineCells: number[][] = columns.map(() => [])
    for (const cell of row) {
      const found = columns.findIndex((column) => maxX(column) > minX(cell.span) && minX(column) < maxX(cell.span))
      lineCells[found >= 0 ? found : 0].push(...cell.members)
    }
    // Cells after the last one written are not written at all.
    while (lineCells.length > 1 && lineCells[lineCells.length - 1].length === 0) lineCells.pop()
    table.push(lineCells)
  }
  const members = new Set([...content, ...frame])
  members.add(start)
  if (close !== null) members.add(close)
  return { environment, cells: table, baselines: levels, members, close }
}

/** Two things stacked in parentheses with no bar between them — \binom,
 *  which sets its halves where \frac would and draws no rule. */
function binomial(start: number, glyphs: Glyph[], owned: Map<number, number>, consumed: Set<number>): { top: number[]; bottom: number[]; close: number } | null {
  const open = glyphs[start]
  if (opening(open) !== '(') return null
  let close: number | null = null
  for (let at = 0; at < glyphs.length; at += 1) {
    if (at > start && !consumed.has(at) && closing(glyphs[at]) === ')'
      && Math.abs(glyphs[at].size - open.size) < 0.5
      && Math.abs(glyphs[at].y - open.y) < Math.max(1, open.size * 0.1)
      && extension(glyphs[at]) === extension(open)) { close = at; break }
  }
  if (close === null) return null
  // The pieces of the brackets that draw nothing are not what they hold.
  const inside: number[] = []
  for (let at = start + 1; at < close; at += 1) if (!consumed.has(at) && token(glyphs[at]) !== '') inside.push(at)
  if (inside.length < 2 || !inside.every((at) => !owned.has(at) && !isBigOperator(glyphs[at])
    && !isRadical(glyphs[at]) && !isDelimiter(glyphs[at]))) return null
  const heights = ascending(inside.map((at) => glyphs[at].y))
  let gap = 0
  let cut = 0
  for (let at = 0; at + 1 < heights.length; at += 1) {
    const low = heights[at]
    const high = heights[at + 1]
    if (high - low > gap) {
      gap = high - low
      cut = (low + high) / 2
    }
  }
  const largest = maxOf(inside.map((at) => glyphs[at].size)) ?? open.size
  if (!(gap > largest * 0.6)) return null
  const top = inside.filter((at) => glyphs[at].y > cut)
  const bottom = inside.filter((at) => glyphs[at].y < cut)
  const over = extent(top.map((at) => glyphs[at]))
  const under = extent(bottom.map((at) => glyphs[at]))
  if (!(minX(over) < maxX(under) && minX(under) < maxX(over)
    && Math.abs(midX(over) - midX(under)) < Math.max(over.width, under.width) * 0.35 + 1)) return null
  return { top, bottom, close }
}

// MARK: - Glyphs

/** A piece of a tall bracket that draws nothing of its own — the middle and
 *  lower pieces of OpenType's ⎛ ⎜ ⎝ — known by its code point, or by a name
 *  that is one. It spells nothing and is not unreadable. */
export function isSilentPiece(glyph: Glyph): boolean {
  if (glyph.unicode !== null && TeX.unicodeCommand(glyph.unicode) === '') return true
  if (glyph.glyphName === null) return false
  const scalars = TeX.unicodeName(glyph.glyphName)
  if (scalars === null || scalars.length !== 1) return false
  const value = scalars[0]
  if (value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false
  return TeX.unicodeCommand(String.fromCodePoint(value)) === ''
}

/** What each glyph spells by its font and its name, and whether it is a
 *  silent piece: neither depends on the page, so each is asked once. */
const spelled = new WeakMap<Glyph, { name: string; silent: boolean }>()

/** What a glyph spells. What the page's own text says is asked for last —
 *  only when the name spells nothing and the glyph is not a silent piece —
 *  and is not kept past the page: it is about where the glyph is. */
function token(glyph: Glyph): string {
  let known = spelled.get(glyph)
  if (known === undefined) {
    known = { name: named(glyph), silent: isSilentPiece(glyph) }
    spelled.set(glyph, known)
  }
  if (known.name !== '' || known.silent) return known.name
  let value = borrowed.get(glyph)
  if (value === undefined) {
    value = fallback?.(glyph) ?? ''
    borrowed.set(glyph, value)
  }
  return value
}

/** What a glyph spells by its font and its name alone. */
function named(glyph: Glyph): string {
  if (isSilentPiece(glyph)) return ''
  // STIX Two Math, set by LuaTeX, labels the script-size σ as the final
  // sigma ς. The ς is the narrower of the two by far.
  if (glyph.unicode === '\u{1D70D}' && glyph.width > glyph.size * 0.52 && family(glyph).includes('STIXTWOMATH')) {
    return '\\sigma'
  }
  const fenced = TeX.fence(glyph.glyphName)
  if (fenced !== null) return fenced
  const opened = TeX.openingDelimiter(glyph.glyphName)
  if (opened !== null) return opened
  const closed = TeX.closingDelimiter(glyph.glyphName)
  if (closed !== null) return closed
  const latex = TeX.latex(glyph.glyphName, glyph.code, glyph.fontName, glyph.unicode, glyph.isSymbolic)
  if (latex !== null && latex !== '') {
    // A symbol a maths font drew is written as the command for it. The same
    // character in a sentence is left as it was typed.
    if (isMathFont(glyph)) {
      const command = TeX.unicodeCommand(latex)
      if (command !== undefined) return command
    }
    return latex
  }
  return ''
}

/** Whether a glyph is one this cannot read at all: it spells nothing, and is
 *  neither a space nor a piece of a drawing. An accent is not one of them. */
export function isUnreadable(glyph: Glyph): boolean {
  return spelling(glyph) === '' && !isSpace(glyph) && !TeX.isDecoration(glyph.glyphName)
    && !TeX.isWideAccent(glyph.glyphName) && TeX.accent(glyph.glyphName) === null
    && !isSilentPiece(glyph)
}
