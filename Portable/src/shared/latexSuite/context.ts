/**
 * Where the caret is, as Latex Suite's `Context` works it out (context.ts,
 * `updateFromView`) — `LatexSuiteContext.swift` in TypeScript.
 */
import { Latex, type Scope } from './latex.js'
import { Markdown } from './markdown.js'
import { Library, Mode, matchesArea, type MacroArea } from './snippets.js'
import { hasPrefixAt, lineEndOf, lineStartOf, slice, type Span } from './text.js'

export type BoundMode = 'inline' | 'block' | 'code'

/** A math region of the note (mathbounds.ts, `MathBounds`). */
export interface Bound {
  outerStart: number
  innerStart: number
  innerEnd: number
  outerEnd: number
  mode: BoundMode
  /** The text the LaTeX parser runs over, and the container prefixes inside it
   *  that are not part of the equation. Null when there is no tree. */
  tree: Span | null
  blanks: Span[]
}

/** default_text_areas.ts. */
const TEXT_AREAS: MacroArea[] = ['text', 'textrm', 'textup', 'textit', 'textbf', 'textsf', 'texttt', 'textnormal',
  'clap', 'textllap', 'textrlap', 'textclap', 'hbox', 'mbox', 'fbox', 'framebox'].map((name) => ({ name }))
const SNIPPETLESS_AREAS: MacroArea[] = [
  { name: 'tag' }, { name: 'begin' }, { name: 'end' }, { name: 'mmlToken' }, { name: 'unicode' },
  { name: 'textcolor', arguments: [0] }, { name: 'color' }, { name: 'colorbox' }, { name: 'fcolorbox' },
]
const ALL_TEXT_AREAS = [...TEXT_AREAS, ...SNIPPETLESS_AREAS]

function gaps(ranges: Span[]): Span[] {
  const out: Span[] = []
  for (let k = 1; k < ranges.length; k += 1) {
    if (ranges[k - 1].to < ranges[k].from) out.push({ from: ranges[k - 1].to, to: ranges[k].from })
  }
  return out
}

export class Context {
  /** The main selection's end: where the mode is read. */
  readonly pos: number
  readonly mode: Mode
  readonly markdown: Markdown
  readonly bounds: Bound[]
  private readonly trees = new Map<number, Latex>()

  constructor(
    readonly doc: string,
    readonly selection: Span[],
    readonly library: Library,
    readonly forceMathLanguages: string[],
  ) {
    this.pos = selection[0].to
    const low = Math.min(...selection.map((r) => r.from))
    const high = Math.max(...selection.map((r) => r.to))
    this.markdown = new Markdown(doc, Math.max(0, low - 2), high + 2)
    this.bounds = Context.mathBounds(this.markdown, forceMathLanguages)
    this.mode = this.computeMode()
  }

  // MARK: Math bounds

  private static mathBounds(md: Markdown, forceMathLanguages: string[]): Bound[] {
    const out: Bound[] = []
    for (const block of md.displayBlocks) {
      // getDollarBounds: the closing delimiter is the block's last child when
      // that is a `Dollar` — which, in a block with nothing after its opening
      // `$$`, is the opening delimiter itself.
      const close = block.close ?? (block.content.length === 0 && !block.hasMarkers ? block.open : { from: block.to, to: block.to })
      const bound: Bound = {
        outerStart: block.open.from, innerStart: block.open.to, innerEnd: close.from, outerEnd: close.to,
        mode: 'block', tree: null, blanks: [],
      }
      const first = block.content[0]
      const last = block.content[block.content.length - 1]
      if (first && last) {
        bound.tree = { from: first.from, to: last.to }
        bound.blanks = gaps(block.content)
      }
      out.push(bound)
    }
    for (const math of md.inlineMath) {
      out.push({
        outerStart: math.from, innerStart: math.open.to, innerEnd: math.close.from, outerEnd: math.to,
        mode: math.display ? 'block' : 'inline', tree: { from: math.open.to, to: math.close.from }, blanks: [],
      })
    }
    for (const fence of md.fences) {
      const first = fence.codeText[0]
      const last = fence.codeText[fence.codeText.length - 1]
      if (!fence.info || !forceMathLanguages.includes(md.text(fence.info)) || !first || !last) continue
      out.push({
        outerStart: fence.from, innerStart: first.from, innerEnd: last.to, outerEnd: fence.to,
        mode: 'code', tree: { from: first.from, to: last.to }, blanks: gaps(fence.codeText),
      })
    }
    return out.sort((a, b) => a.outerStart - b.outerStart)
  }

  /**
   * `inMathBound`, including its binary search and its special case: a caret
   * between (or right before) the two dollars of a `$$` delimiter is an empty
   * inline equation — that is how `$|$` alone on a line works.
   */
  bound(pos: number): Bound | null {
    const bounds = this.bounds
    if (bounds.length === 0) return null
    if (pos < bounds[0].outerStart || pos > bounds[bounds.length - 1].outerEnd) return null
    let left = 0
    let right = bounds.length - 1
    while (left <= right) {
      const mid = (left + right) >> 1
      const b = bounds[mid]
      if (pos < b.outerStart) {
        right = mid - 1
      } else if (pos >= b.outerEnd && b.outerEnd !== b.innerEnd) {
        left = mid + 1
      } else if (pos < b.innerStart && b.mode === 'block' && b.innerStart - b.outerStart === 2) {
        return {
          outerStart: b.outerStart, innerStart: b.outerStart + 1, innerEnd: b.outerStart + 1, outerEnd: b.outerStart + 2,
          mode: 'inline', tree: null, blanks: [],
        }
      } else if (pos < b.innerStart || pos > b.innerEnd) {
        break
      } else {
        return b
      }
    }
    return null
  }

  latex(bound: Bound): Latex | null {
    if (!bound.tree) return null
    const cached = this.trees.get(bound.outerStart)
    if (cached) return cached
    const latex = new Latex(this.doc, bound.tree, bound.blanks, this.library.symbols, this.library.environmentClasses)
    this.trees.set(bound.outerStart, latex)
    return latex
  }

  /**
   * `getEnvNames`: the scope stack at `pos`, innermost first. The walk goes on
   * past the equation's own tree into the Markdown one, so inline `$…$` ends
   * the stack with a `math` entry of its own.
   */
  scopes(pos: number): Scope[] {
    const bound = this.bound(pos)
    const latex = bound ? this.latex(bound) : null
    if (!bound || !latex) return []
    const scopes = latex.scopes(pos)
    if (bound.mode === 'inline' && bound.outerStart < pos && bound.outerEnd > pos) {
      scopes.push({ kind: 'math', name: '', argumentIndex: 0, innerStart: bound.innerStart, innerEnd: bound.innerEnd,
        outerStart: bound.outerStart, outerEnd: bound.outerEnd })
    }
    return scopes
  }

  // MARK: Mode

  private computeMode(): Mode {
    const mode = new Mode()
    // Code blocks and inline code come from the editor's own tree in Obsidian.
    // The rule used here is the one the fixtures were made with: a *closed*
    // fence, after its opening line and not past the start of its closing
    // line; inline code when the caret is after an opening backtick and at
    // most right after the closing one.
    const codeInfo = this.codeBlockLanguage(Math.min(...this.selection.map((r) => r.from)))
    const inCodeBlock = codeInfo !== null
    mode.code = inCodeBlock ? false : this.inInlineCode(this.pos)
    const forceMath = inCodeBlock && this.forceMathLanguages.includes(codeInfo)
    mode.codeMath = forceMath
    mode.codeBlock = inCodeBlock && !forceMath ? { language: codeInfo } : false
    const inMath = this.bound(this.pos)
    if (inMath) {
      mode.blockMath = inMath.mode === 'block'
      mode.inlineMath = inMath.mode === 'inline'
      const area = this.textEnvironment(this.pos)
      if (area === 'text') mode.textEnv = true
      else if (area === 'none') mode.snippetlessEnv = true
    }
    mode.text = !inCodeBlock && inMath === null
    return mode
  }

  private lineStart(p: number): number {
    return lineStartOf(this.doc, p)
  }

  private lineEnd(p: number): number {
    return lineEndOf(this.doc, p)
  }

  private codeBlockLanguage(pos: number): string | null {
    for (const fence of this.markdown.fences) {
      if (!(fence.from < pos && fence.to >= pos)) continue
      if (!fence.closeMark) return null
      if (pos <= this.lineEnd(fence.from) || pos > this.lineStart(fence.closeMark.from)) return null
      if (!fence.info) return ''
      return this.markdown.text(fence.info).split(' ')[0]
    }
    return null
  }

  private inInlineCode(pos: number): boolean {
    return this.markdown.inlineCode.some((r) => r.from < pos && r.to >= pos)
  }

  /** `inTextEnvironment`: "text" inside a text macro, "none" inside a snippet-less one, null otherwise. */
  private textEnvironment(pos: number): 'text' | 'none' | null {
    const scope = this.withinMacros(pos, ALL_TEXT_AREAS)
    if (!scope) return null
    return SNIPPETLESS_AREAS.some((area) => area.name === scope.name) ? 'none' : 'text'
  }

  /** `isWithinMacros`: the first listed macro on the way out, stopping at a nested equation and walking past environments. */
  withinMacros(pos: number, macros: MacroArea[]): Scope | null {
    for (const scope of this.scopes(pos)) {
      if (scope.kind === 'environment') continue
      if (scope.kind === 'math') return null
      if (matchesArea(scope, macros)) return scope
    }
    return null
  }

  // MARK: Bounds for the features

  /** `getBounds()` at the main caret: the equation it is in. */
  get equation(): Bound | null {
    return this.bound(this.pos)
  }

  /**
   * `getInnerEquationBounds`, including its quirk: it searches the equation's
   * text for `$` with the caret's *document* offset, so outside the first
   * lines of a note it finds nothing and returns the equation.
   */
  innerEquation(): { innerStart: number; innerEnd: number } | null {
    if (this.mode.codeMath) {
      const b = this.equation
      return b ? { innerStart: b.innerStart, innerEnd: b.innerEnd } : null
    }
    const b = this.bound(this.pos)
    if (!b) return null
    const text = slice(this.doc, b.innerStart, b.innerEnd).replace(/\\\$/g, '\\R')
    const left = text.lastIndexOf('$', this.pos - 1)
    const right = text.indexOf('$', this.pos)
    if (left === -1 || right === -1) return { innerStart: b.innerStart, innerEnd: b.innerEnd }
    return { innerStart: left + 1, innerEnd: right }
  }

  /** `isWithinEnvironment` for one `[open, close]` pair of `autofractionExcludedEnvs`. */
  isWithinEnvironment(position: number, open: string, close: string): boolean {
    if (!this.mode.inMath) return false
    const bounds = this.innerEquation()
    if (!bounds) return false
    const start = bounds.innerStart
    const text = bounds.innerEnd > start ? slice(this.doc, start, bounds.innerEnd) : ''
    const pos = position - start
    if (open.length === 0) return false
    const openBracket = open[open.length - 1]
    const closeBracket = openBracket === '{' ? '}' : openBracket === '[' ? ']' : openBracket === '(' ? ')' : null
    let offset: number
    let search: string
    if (closeBracket !== null && close === closeBracket) {
      offset = open.length - 1
      search = openBracket
    } else {
      offset = 0
      search = open
    }
    let left = lastIndexOf(text, open, pos - 1)
    while (left !== -1) {
      const right = matchingBracket(text, left + offset, search, close)
      if (right === null) return false
      if (right >= pos && pos >= left + open.length) return true
      if (left <= 0) return false
      left = lastIndexOf(text, open, left - 1)
    }
    return false
  }
}

/** The Swift engine's `lastIndex(of:from:)`, which is JavaScript's `lastIndexOf` except for an empty needle. */
function lastIndexOf(text: string, needle: string, from: number): number {
  if (text.length < needle.length) return -1
  return text.lastIndexOf(needle, Math.max(0, from))
}

/** `findMatchingBracket(text, start, open, close, false)`. */
export function matchingBracket(text: string, start: number, open: string, close: string): number | null {
  let depth = 0
  for (let i = Math.max(0, start); i < text.length; i += 1) {
    if (hasPrefixAt(text, open, i)) {
      depth += 1
    } else if (hasPrefixAt(text, close, i)) {
      depth -= 1
      if (depth === 0) return i
    }
  }
  return null
}

/** The same, backwards from a closing bracket at `start` (single characters). */
export function matchingBracketBackwards(text: string, start: number, open: number, close: number): number | null {
  let depth = 0
  for (let i = start; i >= 0; i -= 1) {
    const c = text.charCodeAt(i)
    if (c === close) {
      depth += 1
    } else if (c === open) {
      depth -= 1
      if (depth === 0) return i
    }
  }
  return null
}

