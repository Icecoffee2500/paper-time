/**
 * What the formula OCR model says, tidied into the LaTeX Ultracopy writes —
 * the Mac's `FormulaOCRText`, function for function.
 *
 * The model (pix2text's math formula recogniser, a TrOCR) emits one token
 * per step with a space between — `\mathbf { m } _ { i }` — and spells a
 * word inside `\mathrm` letter by letter with `~` for the spaces between
 * words: `\mathrm { ~ n o d e ~ t o ~ n o d e ~ m e s s a g e }`. A paper's
 * equation number comes along at the end as `\qquad \qquad \mathrm { ( 4 ) }`.
 * Tidied, the tokens close up (a space stays only where a control word
 * would otherwise swallow the letter after it: `\alpha x`), the spelled
 * words become `\text{node to node message}`, and the number becomes the
 * `\tag` the reader writes for a numbered equation.
 *
 * The cases in `src/test/formulaOCRText.ts` are the contract with the Mac's
 * `FormulaOCRTextTests`.
 */

export interface Tidied {
  body: string
  tag: string | null
}

const isLetter = (ch: string) => /^\p{L}$/u.test(ch)
const isNumber = (ch: string) => /^\p{N}$/u.test(ch)
/** Swift's `Character.isLetter` over a whole token. */
const allLetters = (token: string) => token.length > 0 && [...token].every(isLetter)

export function tidy(raw: string): Tidied {
  let tokens = raw.split(/[ \n\t]+/).filter((one) => one.length > 0)
  let tag: string | null = null

  // The equation number at the end: `\qquad … \mathrm { ( 4 ) }`, or
  // bare `( 4 )` after the \qquads. Taken off, and written as a tag.
  const number = trailingNumber(tokens)
  if (number) {
    tag = number.tag
    tokens = tokens.slice(0, number.from)
    while (tokens.length > 0 && (tokens[tokens.length - 1] === '\\qquad' || tokens[tokens.length - 1] === '\\quad')) tokens.pop()
  }

  // Words spelled out letter by letter inside \mathrm, with ~ between;
  // function names spelled out inside \operatorname; an operator's
  // limits written as \underset; cells wrapped in braces.
  tokens = unwrappingSubstacks(tokens)
  tokens = joiningSpelledWords(tokens)
  tokens = namingOperators(tokens)
  tokens = loweringLimits(tokens)
  tokens = unwrappingCells(tokens)

  let body = ''
  let previous = ''
  for (const token of tokens) {
    const first = [...token][0]
    if (isControlWord(previous) && first !== undefined && isLetter(first)) body += ' '
    body += token
    previous = token
  }
  return { body, tag }
}

function isControlWord(token: string): boolean {
  if (!token.startsWith('\\') || token.length <= 1) return false
  return allLetters(token.slice(1))
}

/**
 * `\mathrm { ( 4 ) }` or `( 4 )` at the very end, after any \qquads:
 * where it starts, and the number inside the parentheses.
 */
function trailingNumber(tokens: string[]): { from: number; tag: string } | null {
  let end = tokens.length
  while (end > 0 && (tokens[end - 1] === '\\qquad' || tokens[end - 1] === '\\quad')) end -= 1
  if (!(end >= 3 && (tokens[end - 1] === ')' || tokens[end - 1] === '}'))) return null
  // `( digits ... )` possibly wrapped in `\mathrm { … }`.
  let close = end - 1
  let wrapped = false
  if (tokens[close] === '}') {
    if (!(close >= 4 && tokens[close - 1] === ')')) return null
    wrapped = true
    close -= 1
  }
  let open = close - 1
  const inner: string[] = []
  while (open >= 0 && tokens[open] !== '(') {
    inner.unshift(tokens[open])
    open -= 1
  }
  const plain = inner.every((token) => [...token].every((ch) => isNumber(ch) || ch === '.' || isLetter(ch)))
  const hasDigit = inner.some((token) => [...token].some(isNumber))
  if (!(open >= 0 && inner.length > 0 && plain && hasDigit)) return null
  let from = open
  if (wrapped) {
    if (!(open >= 2 && tokens[open - 1] === '{' && tokens[open - 2] === '\\mathrm')) return null
    from = open - 2
  }
  // Only at the end of a formula, after some spacing — a `(4)` that
  // is part of the formula (`f(4)`) follows a letter directly.
  const before = tokens[from - 1]
  if (!(from > 0 && (before === '\\qquad' || before === '\\quad' || before === ',' || before === '.'))) return null
  return { from, tag: inner.join('') }
}

/**
 * `\mathrm { ~ n o d e ~ t o ~ n o d e }` → `\text{node to node}`: the
 * letters close up and the ties become spaces. A `\mathrm` without a
 * tie — one word, `\mathrm { r e c }`, `\mathrm { d x }` — closes up and
 * stays upright letters, which is how the reader writes a label.
 */
function joiningSpelledWords(tokens: string[]): string[] {
  const out: string[] = []
  let index = 0
  while (index < tokens.length) {
    if (tokens[index] === '\\mathrm' && index + 1 < tokens.length && tokens[index + 1] === '{') {
      const close = closingBrace(tokens, index + 1)
      if (close !== null) {
        // The space between words is a tie, or a spacing command —
        // the model writes `\;` between the words of a label too.
        const inner = tokens.slice(index + 2, close).map((one) => (ties.has(one) ? '~' : one))
        const spelled = inner.every((one) => one === '~' || one === '-' || one === '.'
          || ([...one].length === 1 && (isLetter(one) || isNumber(one))))
        if (spelled && inner.includes('~')) {
          // A tie at the end is the space before the formula goes
          // on (`\text{if }x`); one at the start is the model's.
          const words = inner.map((one) => (one === '~' ? ' ' : one)).join('').replace(/^\s+/u, '')
          out.push(`\\text{${words}}`)
          index = close + 1
          continue
        }
        if (spelled && inner.length > 0) {
          out.push(`\\mathrm{${inner.join('')}}`)
          index = close + 1
          continue
        }
      }
    }
    out.push(tokens[index])
    index += 1
  }
  return out
}

/**
 * The functions TeX names with a control word of their own: the model
 * spells them out as `\operatorname { s i n }` (or `\operatorname*`).
 */
const functions = new Set([
  'sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'arcsin', 'arccos', 'arctan', 'sinh', 'cosh', 'tanh', 'coth',
  'log', 'ln', 'lg', 'exp', 'det', 'dim', 'ker', 'deg', 'gcd', 'hom', 'arg', 'Pr',
  'max', 'min', 'sup', 'inf', 'lim', 'limsup', 'liminf', 'argmax', 'argmin',
])
/** The ones whose limits go under them in a display. */
const limited = new Set(['max', 'min', 'sup', 'inf', 'lim', 'limsup', 'liminf', 'argmax', 'argmin'])

/**
 * `\operatorname { t a n h }` → `\tanh`; a name TeX has no word for stays
 * `\operatorname{name}`. `{ \cal L }` → `\mathcal{L}`, `\stackrel` →
 * `\overset`.
 */
function namingOperators(tokens: string[]): string[] {
  const out: string[] = []
  let index = 0
  while (index < tokens.length) {
    const token = tokens[index]
    if ((token === '\\operatorname' || token === '\\operatorname*') && index + 1 < tokens.length && tokens[index + 1] === '{') {
      const close = closingBrace(tokens, index + 1)
      if (close !== null) {
        const inner = tokens.slice(index + 2, close)
        if (inner.every((one) => [...one].length === 1 && isLetter(one))) {
          const name = inner.join('')
          out.push(functions.has(name) ? `\\${name}` : `\\operatorname{${name}}`)
          index = close + 1
          continue
        }
      }
    }
    if (token === '{' && index + 3 < tokens.length && tokens[index + 1] === '\\cal' && tokens[index + 3] === '}'
      && [...tokens[index + 2]].length === 1) {
      out.push(`\\mathcal{${tokens[index + 2]}}`)
      index += 4
      continue
    }
    out.push(token === '\\stackrel' ? '\\overset' : token)
    index += 1
  }
  return out
}

/**
 * `\underset { w } { \min }` → `\min _ { w }`: the way the reader writes
 * a limit under an operator. (Only for the operators that take limits;
 * `\underset` under anything else is what it says.)
 */
function loweringLimits(tokens: string[]): string[] {
  const out: string[] = []
  let index = 0
  while (index < tokens.length) {
    if (tokens[index] === '\\underset' && index + 1 < tokens.length && tokens[index + 1] === '{') {
      const underClose = closingBrace(tokens, index + 1)
      if (underClose !== null && underClose + 1 < tokens.length && tokens[underClose + 1] === '{') {
        const overClose = closingBrace(tokens, underClose + 1)
        const operator = tokens[underClose + 2]
        if (overClose !== null && overClose - underClose === 3
          && operator.startsWith('\\') && limited.has(operator.slice(1))) {
          out.push(operator)
          out.push('_')
          out.push(...tokens.slice(index + 1, underClose + 1))
          index = overClose + 1
          continue
        }
      }
    }
    out.push(tokens[index])
    index += 1
  }
  return out
}

/**
 * `\begin{cases} { x } & { y } \\ \end{cases}` → `\begin{cases} x & y \end{cases}`:
 * the model wraps every cell in braces and ends the last row with `\\`;
 * the reader writes neither.
 */
function unwrappingCells(tokens: string[]): string[] {
  const out: string[] = []
  let index = 0
  let inside = 0
  const isBreak = (token: string | undefined) => token === '&' || token === '\\\\'
  while (index < tokens.length) {
    const token = tokens[index]
    if (token.startsWith('\\begin{')) inside += 1
    if (token.startsWith('\\end{')) {
      inside -= 1
      // A row break right before the end is the model's habit.
      if (out[out.length - 1] === '\\\\') out.pop()
    }
    if (inside > 0 && token === '{') {
      const close = closingBrace(tokens, index)
      if (close !== null && index > 0 && (isBreak(tokens[index - 1]) || tokens[index - 1].startsWith('\\begin{'))
        && close + 1 < tokens.length && (isBreak(tokens[close + 1]) || tokens[close + 1].startsWith('\\end{'))) {
        out.push(...tokens.slice(index + 1, close))
        index = close + 1
        continue
      }
    }
    out.push(token)
    index += 1
  }
  return out
}

const ties = new Set(['~', '\\;', '\\,', '\\:', '\\ ', '\\quad', '\\qquad'])

/**
 * `\substack { X }` with one row is just `X`: the model wraps a brace's
 * label in one for no reason.
 */
function unwrappingSubstacks(tokens: string[]): string[] {
  const out: string[] = []
  let index = 0
  while (index < tokens.length) {
    if (tokens[index] === '\\substack' && index + 1 < tokens.length && tokens[index + 1] === '{') {
      const close = closingBrace(tokens, index + 1)
      if (close !== null && !tokens.slice(index + 2, close).includes('\\\\')) {
        // Alone inside a group — `_ { \substack { … } }` — its own
        // braces go too, or the group is braced twice.
        const alone = out[out.length - 1] === '{' && close + 1 < tokens.length && tokens[close + 1] === '}'
        out.push(...(alone ? tokens.slice(index + 2, close) : tokens.slice(index + 1, close + 1)))
        index = close + 1
        continue
      }
    }
    out.push(tokens[index])
    index += 1
  }
  return out
}

function closingBrace(tokens: string[], open: number): number | null {
  let depth = 0
  for (let index = open; index < tokens.length; index += 1) {
    if (tokens[index] === '{') depth += 1
    if (tokens[index] === '}') {
      depth -= 1
      if (depth === 0) return index
    }
  }
  return null
}
