/**
 * Where the mathematics is in a note — `NoteMath.swift`, ported, and held to
 * the Mac's answers (`Fixtures/note-math.json`, `Scripts/note-math-fixture.swift`).
 *
 * A note's formulas are written the way a paper's source writes them: `$…$`
 * and `\(…\)` in a sentence, `$$…$$` and `\[…\]` on a line of their own, and
 * amsmath's environments — `\begin{align}…\end{align}` and the rest — bare.
 * The displayed ones may run over several lines, the shape Latex Suite's `dm`
 * leaves behind and the shape anybody writes an `align` in. This finds the
 * blocks that span lines, each formula in a line, and the formula under a
 * caret, so the card that shows a formula as it is typed answers the same
 * question the Mac's does. Offsets are UTF-16 code units, which is what a
 * text field counts in.
 */

export interface TextSpan {
  from: number
  to: number
}

export interface MathSpan {
  /** The whole span, delimiters included. */
  range: TextSpan
  /** The LaTeX, with the space around it taken off. An environment is its
   *  whole self, `\begin` to `\end`: that is what sets it. */
  latex: string
  display: boolean
  /** Set for a formula that opens on one line and closes on a later one. */
  isBlock: boolean
}

/** Foundation's `.whitespacesAndNewlines`, which is what the Mac trims a formula with. */
const SPACE = '[\\u0009-\\u000d \\u0085\\u00a0\\u1680\\u2000-\\u200b\\u2028\\u2029\\u202f\\u205f\\u3000]'
const TRIM = new RegExp(`^${SPACE}+|${SPACE}+$`, 'g')

/** A formula's LaTeX, trimmed as the Mac trims it. */
export function trimmed(text: string): string {
  return text.replace(TRIM, '')
}

/**
 * The environments set as a formula when they stand bare in a note: the ones
 * MathJax sets on their own. `displaymath` and `math` are LaTeX's spelling of
 * `\[…\]` and `\(…\)`, and are set as those.
 */
export const ENVIRONMENTS = [
  'equation', 'align', 'alignat', 'gather', 'multline', 'flalign', 'eqnarray',
  'xalignat', 'xxalignat', 'aligned', 'alignedat', 'gathered', 'lgathered', 'rgathered',
  'split', 'multlined', 'cases', 'dcases', 'rcases', 'drcases', 'numcases',
  'matrix', 'pmatrix', 'bmatrix', 'Bmatrix', 'vmatrix', 'Vmatrix', 'smallmatrix',
  'psmallmatrix', 'bsmallmatrix', 'Bsmallmatrix', 'vsmallmatrix', 'Vsmallmatrix',
  'array', 'subarray', 'CD', 'displaymath', 'math',
]

/**
 * A formula in a line: `$$…$$`, `$…$`, `\[…\]`, `\(…\)`, an environment from
 * `\begin` to its own `\end`, or a reference to a numbered one — `\eqref{…}`
 * is written in a sentence, as LaTeX writes it. None of them opens after a
 * backslash: `\$` is a dollar, and `\\[` is a line break. Groups: 1 `$$`,
 * 2 `$`, 3 `\[`, 4 `\(`, 5 the environment's name, 6 its star, 7 its body,
 * 8 the reference's label.
 */
const FORMULA_SOURCE = String.raw`(?<!\\)\$\$([^$]+)\$\$|(?<!\\)\$([^$\n]+)\$|(?<!\\)\\\[([\s\S]+?)\\\]`
  + String.raw`|(?<!\\)\\\(([^\n]+?)\\\)|(?<!\\)\\begin\{(`
  + ENVIRONMENTS.join('|') + String.raw`)(\*?)\}([\s\S]*?)\\end\{\5\6\}|(?<!\\)\\(?:eq)?ref\{([^{}\n]*)\}`
const FORMULA = new RegExp(FORMULA_SOURCE, 'g')
const OPENER = new RegExp(String.raw`^\\begin\{(` + ENVIRONMENTS.join('|') + String.raw`)(\*?)\}`)

function spanOf(match: RegExpExecArray, isBlock: boolean): MathSpan {
  const range = { from: match.index, to: match.index + match[0].length }
  if (match[1] !== undefined) return { range, latex: trimmed(match[1]), display: true, isBlock }
  if (match[2] !== undefined) return { range, latex: trimmed(match[2]), display: false, isBlock }
  if (match[3] !== undefined) return { range, latex: trimmed(match[3]), display: true, isBlock }
  if (match[4] !== undefined) return { range, latex: trimmed(match[4]), display: false, isBlock }
  if (match[8] !== undefined) return { range, latex: match[0], display: false, isBlock }
  // LaTeX's own names for the two delimiters are set as those.
  if (match[5] === 'displaymath') return { range, latex: trimmed(match[7]), display: true, isBlock }
  if (match[5] === 'math') return { range, latex: trimmed(match[7]), display: false, isBlock }
  return { range, latex: trimmed(match[0]), display: true, isBlock }
}

/** Where a formula's LaTeX is between its delimiters — the caret inside it is typing it. */
function inside(match: RegExpExecArray): TextSpan {
  const start = match.index
  if (match[1] !== undefined) return { from: start + 2, to: start + 2 + match[1].length }
  if (match[2] !== undefined) return { from: start + 1, to: start + 1 + match[2].length }
  if (match[3] !== undefined) return { from: start + 2, to: start + 2 + match[3].length }
  if (match[4] !== undefined) return { from: start + 2, to: start + 2 + match[4].length }
  if (match[8] !== undefined) {
    const open = match[0].indexOf('{') + 1
    return { from: start + open, to: start + open + match[8].length }
  }
  const opener = `\\begin{${match[5]}${match[6]}}`.length
  return { from: start + opener, to: start + opener + match[7].length }
}

/** The first formula in `text` at or after `from` and before `to`. */
export function firstFormula(text: string, from = 0, to = text.length): MathSpan | null {
  const slice = to === text.length ? text : text.slice(0, to)
  FORMULA.lastIndex = from
  const match = FORMULA.exec(slice)
  return match ? spanOf(match, false) : null
}

/** Every line of the text, the last one even when empty. */
export function lineRanges(text: string): TextSpan[] {
  const result: TextSpan[] = []
  let start = 0
  for (;;) {
    const newline = text.indexOf('\n', start)
    if (newline < 0) {
      result.push({ from: start, to: text.length })
      break
    }
    result.push({ from: start, to: newline })
    start = newline + 1
    if (start === text.length) {
      result.push({ from: start, to: start })
      break
    }
  }
  return result
}

/** The displayed formulas in a text, in order: what a quotation puts on lines of their own. */
export function displayFormulas(text: string): TextSpan[] {
  const result: TextSpan[] = []
  FORMULA.lastIndex = 0
  for (let match = FORMULA.exec(text); match; match = FORMULA.exec(text)) {
    if (spanOf(match, false).display) result.push({ from: match.index, to: match.index + match[0].length })
  }
  return result
}

/** Whether a line is one displayed formula and nothing else. */
export function isDisplayLine(line: string): boolean {
  const text = trimmed(line)
  const first = displayFormulas(text)[0]
  return first !== undefined && first.from === 0 && first.to === text.length
}

/**
 * The displayed formulas that span lines, each from the start of the line
 * that opens it to the end of the line that closes it. A line opens a block
 * when it begins with `$$`, `\[` or an environment's `\begin` and does not
 * close it again on the same line. A `$$` or a `\[` closes at the first later
 * line that ends with its closer; an environment at the first later line that
 * holds its own `\end`.
 */
export function mathBlocks(text: string): TextSpan[] {
  const lines = lineRanges(text)
  const result: TextSpan[] = []
  let index = 0
  while (index < lines.length) {
    const line = trimmed(text.slice(lines[index].from, lines[index].to))
    let closes: ((line: string) => boolean) | null = null
    if (line.startsWith('$$') && !line.slice(2).includes('$$')) {
      closes = (next) => next.endsWith('$$')
    } else if (line.startsWith('\\[') && !line.slice(2).includes('\\]')) {
      closes = (next) => next.endsWith('\\]')
    } else {
      const opener = OPENER.exec(line)
      if (opener) {
        const end = `\\end{${opener[1]}${opener[2]}}`
        if (!line.slice(opener[0].length).includes(end)) closes = (next) => next.includes(end)
      }
    }
    if (!closes) {
      index += 1
      continue
    }
    let closer = -1
    for (let next = index + 1; next < lines.length; next += 1) {
      if (closes(trimmed(text.slice(lines[next].from, lines[next].to)))) {
        closer = next
        break
      }
    }
    if (closer < 0) {
      index += 1
      continue
    }
    result.push({ from: lines[index].from, to: lines[closer].to })
    index = closer + 1
  }
  return result
}

/**
 * The formula the caret is inside, if it is inside one: between the
 * delimiters, so a caret just before a `$` or just after one is not in the
 * formula it borders.
 */
export function mathSpanAt(text: string, caret: number): MathSpan | null {
  if (caret < 0 || caret > text.length) return null
  for (const block of mathBlocks(text)) {
    if (caret < block.from || caret > block.to) continue
    // The block's formula, from its opener to its closer.
    FORMULA.lastIndex = block.from
    const match = FORMULA.exec(text.slice(0, block.to))
    if (!match) return null
    const found = spanOf(match, true)
    const body = inside(match)
    if (caret < body.from || caret > body.to || !found.latex) return null
    return found
  }
  const lineStart = text.lastIndexOf('\n', caret - 1) + 1
  let lineEnd = text.indexOf('\n', caret)
  lineEnd = lineEnd < 0 ? text.length : lineEnd + 1
  const line = text.slice(0, lineEnd)
  FORMULA.lastIndex = lineStart
  for (let match = FORMULA.exec(line); match; match = FORMULA.exec(line)) {
    const body = inside(match)
    if (caret < body.from || caret > body.to) continue
    const found = spanOf(match, false)
    if (!found.latex || match[0].includes('\n')) continue
    return found
  }
  return null
}
