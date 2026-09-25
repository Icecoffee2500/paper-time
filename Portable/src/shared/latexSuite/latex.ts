/**
 * The structure of one equation, as far as Latex Suite asks about it —
 * `LatexSuiteLatex.swift` in TypeScript.
 *
 * Latex Suite parses every equation with a lezer LaTeX grammar (adapted from
 * Overleaf's) and asks the tree two things: which constructs enclose a
 * position — the *scope stack*, which decides `\text{}` (text mode inside
 * math), `\begin{…}` and `\color{…}` (no snippets), `\ce{}`/`\pu{}` exclusions
 * and matrix shortcuts — and which brackets pair, which decides what
 * auto-enlarge rewrites. This is a recursive-descent reading of the same
 * grammar that answers only those two questions. Where the input is broken (an
 * unclosed brace, a stray `\end`), it recovers the way the LR parser was
 * observed to: an unclosed construct runs to the end of the equation, a closer
 * that belongs further out ends everything inside it, and a closer nothing is
 * waiting for is skipped.
 */
import { isASCIILetter, isDigit, isSpace, slice, type Span } from './text.js'

export type Kind =
  | { t: 'root' }
  /** A `{…}` or `[…]` argument of `command`, `index` counting the arguments before it. */
  | { t: 'argument'; command: string; index: number; bracket: boolean }
  /** `\begin{name}` / `\end{name}`'s name group; a command scope named `begin`/`end`. */
  | { t: 'envName'; owner: string }
  | { t: 'environment'; name: string }
  | { t: 'content' }
  /** A plain `{…}` group. */
  | { t: 'group' }
  /** `$…$` or `\(…\)` nested in text. */
  | { t: 'math'; paren: boolean }
  /** `\left… \right…`. */
  | { t: 'delimited' }
  /** A command and its arguments: transparent for both questions. */
  | { t: 'command' }

type TokenKind = 'control' | 'parenOpen' | 'parenClose' | 'bracketOpen' | 'bracketClose' | 'braceClose'

type Item = { node: number } | { token: TokenKind; range: Span }

interface Node {
  kind: Kind
  from: number
  to: number
  closed: boolean
  items: Item[]
  /** For `delimited`: the `\left…` and `\right…` spans. */
  opening: Span | null
  closing: Span | null
  parent: number
  /** For environments: whether the content started (the begin part was complete). */
  hasContent: boolean
  nameRange: Span | null
  contentRange: Span | null
  /** False for an argument that is a bare command or number (`\hat\alpha`). */
  braced: boolean
}

function node(kind: Kind, from: number, to: number, parent: number, closed = false): Node {
  return { kind, from, to, closed, items: [], opening: null, closing: null, parent, hasContent: false, nameRange: null, contentRange: null, braced: true }
}

/** One entry of the scope stack (context.ts, `getEnvNameFromNode`). */
export interface Scope {
  kind: 'command' | 'environment' | 'math'
  name: string
  argumentIndex: number
  innerStart: number
  innerEnd: number
  outerStart: number
  outerEnd: number
}

export interface Pair {
  open: Span
  close: Span
}

export class Latex {
  readonly nodes: Node[]
  /** Every control sequence token, by where it ends: what `resolveInner(pos, -1)`
   *  finds when a bracket follows a command directly. */
  readonly controlEnding: Map<number, Span>

  constructor(readonly doc: string, range: Span, blanks: Span[], symbols: Set<string>, environmentClasses: Map<string, string> = new Map()) {
    let text = slice(doc, range.from, range.to)
    if (blanks.length > 0) {
      const units = text.split('')
      for (const blank of blanks) {
        for (let i = blank.from; i < blank.to; i += 1) {
          if (i >= range.from && i < range.to) units[i - range.from] = ' '
        }
      }
      text = units.join('')
    }
    const parser = new Parser(text, range.from, range.to, symbols, environmentClasses)
    parser.i = range.from
    parser.nodes = [node({ t: 'root' }, range.from, range.to, -1)]
    parser.parseList(0, 'math')
    this.nodes = parser.nodes
    this.controlEnding = parser.controls
  }

  // MARK: Questions

  /** The scope stack at `pos`, innermost first: every construct that starts before `pos` and ends after it. */
  scopes(pos: number): Scope[] {
    const chain: number[] = []
    let current = 0
    descend: for (;;) {
      for (const item of this.nodes[current].items) {
        if ('node' in item) {
          const n = this.nodes[item.node]
          if (n.from < pos && n.to > pos) {
            chain.push(item.node)
            current = item.node
            continue descend
          }
        }
      }
      break
    }
    const result: Scope[] = []
    for (let k = chain.length - 1; k >= 0; k -= 1) {
      const n = this.nodes[chain[k]]
      const kind = n.kind
      switch (kind.t) {
        case 'argument':
          result.push({ kind: 'command', name: kind.command, argumentIndex: kind.index,
            innerStart: n.from + 1, innerEnd: n.closed ? n.to - 1 : n.to, outerStart: n.from, outerEnd: n.to })
          break
        case 'envName':
          result.push({ kind: 'command', name: kind.owner, argumentIndex: 0,
            innerStart: n.from + 1, innerEnd: n.closed ? n.to - 1 : n.to, outerStart: n.from, outerEnd: n.to })
          break
        case 'environment':
          if (!n.hasContent || !n.contentRange) break
          result.push({ kind: 'environment', name: kind.name, argumentIndex: 0,
            innerStart: n.contentRange.from, innerEnd: n.contentRange.to, outerStart: n.from, outerEnd: n.to })
          break
        case 'math': {
          if (!n.closed) break
          const delimiter = kind.paren ? 2 : 1
          result.push({ kind: 'math', name: '', argumentIndex: 0,
            innerStart: n.from + delimiter, innerEnd: n.to - delimiter, outerStart: n.from, outerEnd: n.to })
          break
        }
        default:
          break
      }
    }
    return result
  }

  /** Every bracket pair of the equation, nested ones included, in the order
   *  highlight_brackets.ts walks them (a pair before its contents). */
  pairs(): Pair[] {
    const out: Pair[] = []
    const walk = (list: Paired[]) => {
      for (const p of list) {
        if (p.kind === 'bracket' && p.close) out.push({ open: p.open, close: p.close })
        walk(p.children)
      }
    }
    walk(pairSpecs(this.specs(this.nodes[0].items)))
    return out
  }

  /** Whether the token right before `pos` is a control word — the check
   *  auto-enlarge makes to leave `\big(` and friends alone. */
  controlWord(pos: number): string | null {
    const range = this.controlEnding.get(pos)
    if (!range || range.to - range.from <= 1 || !isASCIILetter(this.doc.charCodeAt(range.from + 1))) return null
    return slice(this.doc, range.from, range.to)
  }

  // MARK: Bracket specs (traverseTree)

  private text(range: Span): string {
    return slice(this.doc, range.from, range.to)
  }

  private specs(items: Item[]): Spec[] {
    const out: Spec[] = []
    for (let i = 0; i < items.length; i += 1) {
      const item = items[i]
      if ('token' in item) {
        const range = item.range
        switch (item.token) {
          case 'control': {
            const name = this.text(range)
            if (OPENING.has(name)) out.push({ t: 'open', bracket: name, range })
            else if (CLOSING.has(name)) out.push({ t: 'close', bracket: name, range })
            break
          }
          case 'parenOpen':
            out.push({ t: 'open', bracket: '(', range })
            break
          case 'parenClose':
            out.push({ t: 'close', bracket: ')', range })
            break
          case 'bracketOpen': {
            // lezer pairs `[` with the next `]` among its siblings.
            let j = -1
            for (let k = i + 1; k < items.length; k += 1) {
              const other = items[k]
              if ('token' in other && other.token === 'bracketClose') {
                j = k
                break
              }
            }
            if (j >= 0) {
              const close = (items[j] as { range: Span }).range
              out.push({ t: 'bracket', open: range, close, children: this.specs(items.slice(i + 1, j)) })
              i = j
            } else {
              out.push({ t: 'open', bracket: '[', range })
              out.push(...this.specs(items.slice(i + 1)))
              return out
            }
            break
          }
          case 'bracketClose':
            out.push({ t: 'close', bracket: ']', range })
            break
          case 'braceClose':
            out.push({ t: 'close', bracket: '}', range })
            break
        }
        continue
      }
      const n = this.nodes[item.node]
      const kind = n.kind
      switch (kind.t) {
        case 'group':
        case 'argument':
        case 'envName':
        case 'math': {
          if (kind.t === 'math' && !kind.paren) {
            out.push(...this.specs(n.items))
            break
          }
          if (!n.braced) {
            out.push(...this.specs(n.items))
            break
          }
          const isParen = kind.t === 'math'
          const isBracket = kind.t === 'argument' && kind.bracket
          const openWidth = isParen ? 2 : 1
          const open = { from: n.from, to: n.from + openWidth }
          if (n.closed) {
            out.push({ t: 'bracket', open, close: { from: n.to - openWidth, to: n.to }, children: this.specs(n.items) })
          } else {
            out.push({ t: 'open', bracket: isParen ? '\\(' : isBracket ? '[' : '{', range: open })
            out.push(...this.specs(n.items))
          }
          break
        }
        case 'delimited':
          if (n.closed && n.opening && n.closing) {
            out.push({ t: 'bracket', open: n.opening, close: n.closing, children: this.specs(n.items) })
          } else {
            out.push(...this.specs(n.items))
          }
          break
        default:
          out.push(...this.specs(n.items))
      }
    }
    return out
  }
}

// MARK: - The parser

type ParseMode = 'math' | 'text'
type Closer = 'brace' | 'bracket' | 'end' | 'right' | 'dollar' | 'paren'
/** `'end'` for the end of the equation, or the closer that stopped the list. */
type Stop = 'end' | { closer: Closer }
const stoppedBy = (stop: Stop, closer: Closer) => stop !== 'end' && stop.closer === closer

const DELIMITER_NAMES = new Set(['lfloor', 'rfloor', 'lceil', 'rceil', 'langle', 'rangle', 'backslash', 'uparrow',
  'Uparrow', 'Downarrow', 'updownarrow', 'Updownarrow', 'downarrow', 'lvert', 'lVert', 'rVert', 'rvert', 'vert', 'Vert',
  'lbrace', 'rbrace', 'lbrack', 'rbrack', 'lt', 'gt'])

class Parser {
  i = 0
  nodes: Node[] = []
  closers: Closer[] = []
  controls = new Map<number, Span>()

  /** `s` is the equation's text, container prefixes blanked; `s[0]` is at `base`. */
  constructor(
    readonly s: string,
    readonly base: number,
    readonly end: number,
    readonly symbols: Set<string>,
    readonly environmentClasses: Map<string, string>,
  ) {}

  c(k: number): number {
    return k < this.end && k >= this.base ? this.s.charCodeAt(k - this.base) : -1
  }

  string(from: number, to: number): string {
    return slice(this.s, from - this.base, to - this.base)
  }

  add(n: Node): number {
    this.nodes.push(n)
    const index = this.nodes.length - 1
    this.nodes[n.parent].items.push({ node: index })
    return index
  }

  token(kind: TokenKind, range: Span, parent: number) {
    this.nodes[parent].items.push({ token: kind, range })
    if (kind === 'control') this.controls.set(range.to, range)
  }

  /** A control sequence at `k`: its end and, for a control word, its name. */
  control(k: number): { end: number; name: string | null } {
    if (isASCIILetter(this.c(k + 1))) {
      let j = k + 1
      while (isASCIILetter(this.c(j))) j += 1
      return { end: j, name: this.string(k + 1, j) }
    }
    return { end: Math.min(k + 2, this.end), name: null }
  }

  skipBlanks(k: number): number {
    let j = k
    while (this.c(j) === 32 || this.c(j) === 9) j += 1
    return j
  }

  /** Whether a closer should end the current construct (someone is waiting for it) or be skipped as stray. */
  expects(kind: Closer): boolean {
    return this.closers.includes(kind)
  }

  skipComment() {
    while (this.i < this.end && this.c(this.i) !== 10) this.i += 1
    if (this.i < this.end) this.i += 1
  }

  /** Reads elements into `parent` until the end or a closer someone expects. */
  parseList(parent: number, mode: ParseMode): Stop {
    while (this.i < this.end) {
      const ch = this.c(this.i)
      switch (ch) {
        case 92: {
          const stop = this.parseControl(parent, mode)
          if (stop) return stop
          break
        }
        case 123:
          this.parseBraced({ t: 'group' }, parent, mode)
          break
        case 125:
          if (this.expects('brace')) return { closer: 'brace' }
          this.token('braceClose', { from: this.i, to: this.i + 1 }, parent)
          this.i += 1
          break
        case 91:
          this.token('bracketOpen', { from: this.i, to: this.i + 1 }, parent)
          this.i += 1
          break
        case 93:
          if (this.expects('bracket')) return { closer: 'bracket' }
          this.token('bracketClose', { from: this.i, to: this.i + 1 }, parent)
          this.i += 1
          break
        case 36:
          if (this.expects('dollar')) return { closer: 'dollar' }
          if (mode === 'text') this.parseMathInText(parent, false)
          else this.i += 1
          break
        case 37:
          this.skipComment()
          break
        case 40:
        case 41:
          if (mode === 'math') this.token(ch === 40 ? 'parenOpen' : 'parenClose', { from: this.i, to: this.i + 1 }, parent)
          this.i += 1
          break
        default:
          this.i += 1
      }
    }
    return 'end'
  }

  /** A control sequence and whatever it opens. Returns a stop when the sequence is a closer someone is waiting for. */
  parseControl(parent: number, mode: ParseMode): Stop | null {
    const start = this.i
    const { end: cEnd, name } = this.control(this.i)
    if (name === null) {
      const sym = this.c(start + 1)
      if (sym === 40 && mode === 'text') { // \(
        this.parseMathInText(parent, true)
        return null
      }
      if (sym === 41 && this.expects('paren')) return { closer: 'paren' }
      this.token('control', { from: start, to: cEnd }, parent)
      this.i = cEnd
      if (sym === 92 && this.c(this.i) === 91) { // \\[…]
        this.parseBraced({ t: 'argument', command: '\\', index: 0, bracket: true }, parent, 'text', true)
      }
      return null
    }
    switch (name) {
      case 'begin':
        this.parseEnvironment(parent)
        return null
      case 'end':
        if (this.expects('end')) return { closer: 'end' }
        this.i = cEnd // a stray \end: its name group is read as an ordinary group
        return null
      case 'left':
        if (mode === 'math') {
          this.parseDelimited(parent)
          return null
        }
        break
      case 'right':
        if (this.expects('right')) return { closer: 'right' }
        break
      default:
        break
    }
    const command = this.add(node({ t: 'command' }, start, cEnd, parent))
    this.token('control', { from: start, to: cEnd }, command)
    this.i = cEnd
    this.parseArguments(name, command, mode)
    this.nodes[command].to = this.i
    return null
  }

  /** The arguments the grammar gives `name` (latex.grammar, KnownCommand and the unknown-command rules). */
  parseArguments(name: string, command: number, mode: ParseMode) {
    if (this.symbols.has(name) || name === 'left' || name === 'right') return
    let index = 0
    const argument = (kind: ParseMode, bracket = false) => {
      this.parseBraced({ t: 'argument', command: name, index, bracket }, command, kind, bracket)
      index += 1
    }
    const argumentMode = mode
    switch (name) {
      case 'text': case 'tag': case 'textrm':
        this.i = this.skipBlanks(this.i)
        if (this.c(this.i) === 42) this.i += 1
        if (this.c(this.i) === 123) argument('text')
        break
      case 'textbf': case 'textit': case 'texttt': case 'textsf': case 'textup': case 'textnormal': case 'clap':
      case 'textclap': case 'textllap': case 'textrlap': case 'mbox': case 'fbox': case 'framebox': case 'fcolorbox':
        if (this.c(this.i) === 123) argument('text')
        break
      case 'hbox':
        this.i = this.skipBlanks(this.i)
        if (this.c(this.i) === 123) argument('text')
        break
      case 'textcolor': case 'colorbox':
        this.i = this.skipBlanks(this.i)
        if (this.c(this.i) !== 123) return
        argument('text')
        this.i = this.skipBlanks(this.i)
        index = this.typedArgument(argumentMode, index, name, command)
        break
      case 'emph': case 'underline':
        index = this.typedArgument(argumentMode, index, name, command)
        break
      case 'label':
        this.i = this.skipBlanks(this.i)
        if (this.c(this.i) === 123) index = this.wrappedArgument(name, index, command)
        break
      case 'ref': case 'eqref':
        if (name === 'ref' && this.c(this.i) === 42) this.i += 1
        for (let n = 0; n < 2; n += 1) {
          const k = this.skipBlanks(this.i)
          if (this.c(k) === 91) {
            this.i = k
            argument('text', true)
          }
        }
        this.i = this.skipBlanks(this.i)
        if (this.c(this.i) === 123) index = this.wrappedArgument(name, index, command)
        break
      case 'newcommand': case 'renewcommand': case 'newenvironment': case 'renewenvironment': {
        // The name (a control word, or `{…}` taken literally) is not an
        // argument node; the optional arguments and the definitions are.
        this.i = this.skipBlanks(this.i)
        if (this.c(this.i) === 92) {
          this.i += 1
          while (isASCIILetter(this.c(this.i)) || this.c(this.i) === 64) this.i += 1
        } else if (this.c(this.i) === 123) {
          while (this.i < this.end && this.c(this.i) !== 125) this.i += 1
          if (this.i < this.end) this.i += 1
        } else {
          return
        }
        for (let n = 0; n < 2; n += 1) if (this.c(this.i) === 91) argument('text', true)
        const definitions = name.endsWith('environment') ? 2 : 1
        for (let n = 0; n < definitions; n += 1) {
          let k = this.i
          if (this.c(k) === 10) k += 1
          k = this.skipBlanks(k)
          if (this.c(k) !== 123) return
          this.i = k
          argument('text')
        }
        break
      }
      case 'def': {
        this.i = this.skipBlanks(this.i)
        if (this.c(this.i) !== 92) return
        this.i = this.control(this.i).end
        for (;;) {
          const k = this.skipBlanks(this.i)
          if (this.c(k) === 35 && this.c(k + 1) >= 49 && this.c(k + 1) <= 57) {
            this.i = k + 2
          } else if (this.c(k) === 91 && this.c(k + 1) === 35 && this.c(k + 3) === 93) {
            this.i = k + 4
          } else {
            break
          }
        }
        let k = this.skipBlanks(this.i)
        if (this.c(k) === 10) k = this.skipBlanks(k + 1)
        if (this.c(k) === 123) {
          this.i = k
          argument('text')
        }
        break
      }
      case 'let':
        return
      case 'href':
        this.i = this.skipBlanks(this.i)
        if (this.c(this.i) === 123) {
          // UrlArgument: its content is taken literally, up to `}`.
          const from = this.i
          let j = this.i + 1
          while (j < this.end && this.c(j) !== 125) j += 1
          const closed = j < this.end
          const to = closed ? j + 1 : this.end
          this.add(node({ t: 'argument', command: name, index, bracket: false }, from, to, command, closed))
          index += 1
          this.i = to
          if (this.c(this.i) === 123) argument('text')
        }
        break
      case 'verb': {
        if (this.c(this.i) === 42) this.i += 1
        const delimiter = this.c(this.i)
        if (!(delimiter >= 0 && !isSpace(delimiter) && delimiter !== 42)) return
        for (let j = this.i + 1; j < this.end && this.c(j) !== 10; j += 1) {
          if (this.c(j) === delimiter) {
            this.i = j + 1
            return
          }
        }
        break
      }
      case 'hline': case 'toprule': case 'midrule': case 'bottomrule':
        this.i = this.skipBlanks(this.i)
        break
      default:
        if (mode === 'math') {
          for (;;) {
            const k = this.skipBlanks(this.i)
            if (this.c(k) !== 123) break
            this.i = k
            argument('math')
          }
        } else {
          let k = this.i
          if (this.c(k) === 32 || this.c(k) === 9) k = this.skipBlanks(k)
          if (!(this.c(k) === 123 || this.c(k) === 91)) return
          this.i = k
          while (this.c(this.i) === 123 || this.c(this.i) === 91) argument('text', this.c(this.i) === 91)
        }
    }
  }

  /**
   * `\label{…}`, `\ref{…}`: an argument node around a `ShortTextArgument` node.
   * The inner one reads as a command scope too, named after its own text past
   * the brace (context.ts takes the parent's first child as the command) — a
   * name nothing matches, kept for the stack's sake.
   */
  wrappedArgument(name: string, index: number, command: number): number {
    const outerNode = node({ t: 'argument', command: name, index, bracket: false }, this.i, this.i, command)
    outerNode.braced = false
    const outer = this.add(outerNode)
    const inner = this.nodes.length
    this.parseBraced({ t: 'argument', command: '', index: 0, bracket: false }, outer, 'text')
    this.nodes[inner].kind = { t: 'argument', command: this.string(this.nodes[inner].from + 1, this.nodes[inner].to), index: 0, bracket: false }
    this.nodes[outer].to = this.nodes[inner].to
    this.nodes[outer].closed = this.nodes[inner].closed
    return index + 1
  }

  /** A `MathArgument` (or `TextArgument` in text): braces, or a single command or number standing in for them. */
  typedArgument(mode: ParseMode, index: number, name: string, command: number): number {
    if (this.c(this.i) === 123) {
      this.parseBraced({ t: 'argument', command: name, index, bracket: false }, command, mode)
      return index + 1
    }
    if (mode === 'math' && (this.c(this.i) === 92 || isDigit(this.c(this.i)))) {
      const from = this.i
      const bare = node({ t: 'argument', command: name, index, bracket: false }, from, from, command)
      bare.braced = false
      const arg = this.add(bare)
      if (this.c(this.i) === 92) {
        this.parseControl(arg, 'math')
      } else {
        while (isDigit(this.c(this.i))) this.i += 1
        if (this.c(this.i) === 46) {
          this.i += 1
          while (isDigit(this.c(this.i))) this.i += 1
        }
      }
      this.nodes[arg].to = this.i
      this.nodes[arg].closed = true
      return index + 1
    }
    return index
  }

  /** `{…}` (or `[…]`) at `i`: a group or an argument. */
  parseBraced(kind: Kind, parent: number, mode: ParseMode, bracket = false) {
    const from = this.i
    const n = this.add(node(kind, from, this.end, parent))
    this.i += 1
    const closer: Closer = bracket ? 'bracket' : 'brace'
    this.closers.push(closer)
    const stop = this.parseList(n, mode)
    this.closers.pop()
    if (stoppedBy(stop, closer)) {
      this.i += 1
      this.nodes[n].to = this.i
      this.nodes[n].closed = true
    } else {
      this.nodes[n].to = stop === 'end' ? this.end : this.i
    }
  }

  /** `$…$` or `\(…\)` inside a text argument. */
  parseMathInText(parent: number, paren: boolean) {
    const from = this.i
    const n = this.add(node({ t: 'math', paren }, from, this.end, parent))
    this.i += paren ? 2 : 1
    const closer: Closer = paren ? 'paren' : 'dollar'
    this.closers.push(closer)
    const stop = this.parseList(n, 'math')
    this.closers.pop()
    if (stoppedBy(stop, closer)) {
      this.i += paren ? 2 : 1
      this.nodes[n].to = this.i
      this.nodes[n].closed = true
    } else {
      this.nodes[n].to = stop === 'end' ? this.end : this.i
    }
  }

  /** `\begin{name}[opt]{arg}… content \end{name}`. */
  parseEnvironment(parent: number) {
    const start = this.i
    const beginEnd = this.control(this.i).end
    const env = this.add(node({ t: 'environment', name: '' }, start, this.end, parent))
    this.token('control', { from: start, to: beginEnd }, env)
    this.i = beginEnd
    if (this.c(this.i) !== 123) {
      this.nodes[env].to = this.i
      return
    }
    const name = this.parseNameGroup('begin', env)
    if (name === null) {
      this.nodes[env].to = this.end
      return
    }
    this.nodes[env].kind = { t: 'environment', name }
    let index = 0
    if (this.c(this.i) === 91) {
      const arg = this.nodes.length
      this.parseBraced({ t: 'argument', command: 'begin', index, bracket: true }, env, 'text', true)
      index += 1
      if (!this.nodes[arg].closed) {
        this.nodes[env].to = this.nodes[arg].to
        return
      }
    }
    while (this.c(this.i) === 123) {
      const arg = this.nodes.length
      this.parseBraced({ t: 'argument', command: 'begin', index, bracket: false }, env, 'text')
      index += 1
      if (!this.nodes[arg].closed) {
        // The begin part never finished, so there is no environment.
        this.nodes[env].to = this.nodes[arg].to
        return
      }
    }
    const content = this.add(node({ t: 'content' }, this.i, this.end, env))
    this.nodes[env].hasContent = true
    this.closers.push('end')
    const stop = this.parseList(content, 'math')
    this.closers.pop()
    this.nodes[content].to = stop === 'end' ? this.end : this.i
    this.nodes[env].contentRange = { from: this.nodes[content].from, to: this.nodes[content].to }
    if (stoppedBy(stop, 'end')) {
      const endEnd = this.control(this.i).end
      this.token('control', { from: this.i, to: endEnd }, env)
      this.i = endEnd
      if (this.c(this.i) === 123) {
        // How the LR parser's error recovery reads an `\end{…}` whose name is
        // not a clean match (observed from the plugin; this is what decides
        // whether the name is snippet-less while it is being retyped). Held
        // directly by another environment, any name is taken whole.
        // Otherwise: an environment whose name has a class of its own
        // (`pmatrix`, `equation`…) ends right after `\end{` unless the name
        // starts with one of the same class (or is empty); a generic one ends
        // right after the name's letters when a character follows that starts
        // another token.
        const open = this.i
        const first = this.skipBlanks(open + 1)
        let k = first
        while (isASCIILetter(this.c(k))) k += 1
        if (k > first && this.c(k) === 42) k += 1
        if (this.nodes[parent].kind.t !== 'content') {
          const kind = this.environmentClasses.get(name)
          if (kind !== undefined) {
            if (this.c(first) !== 125 && this.environmentClasses.get(this.string(first, k)) !== kind) {
              this.i = open + 1
              this.nodes[env].to = this.i
              this.nodes[env].closed = true
              return
            }
          } else if (k > first && breaksName(this.c(k))) {
            const group = this.add(node({ t: 'envName', owner: 'end' }, open, k, env))
            this.nodes[group].nameRange = { from: open + 1, to: k }
            this.i = k
            this.nodes[env].to = this.i
            this.nodes[env].closed = true
            return
          }
        }
        this.parseNameGroup('end', env)
      }
      this.nodes[env].to = this.i
      this.nodes[env].closed = true
    } else {
      this.nodes[env].to = stop === 'end' ? this.end : this.i
    }
  }

  /** `{name}` after `\begin`/`\end`: read literally up to `}`. */
  parseNameGroup(owner: string, parent: number): string | null {
    const from = this.i
    let j = this.i + 1
    while (j < this.end && this.c(j) !== 125) j += 1
    const closed = j < this.end
    const to = closed ? j + 1 : this.end
    const group = this.add(node({ t: 'envName', owner }, from, to, parent, closed))
    this.nodes[group].nameRange = { from: from + 1, to: j }
    this.i = to
    return closed ? this.string(from + 1, j) : null
  }

  /** `\left<delim> … \right<delim>`. */
  parseDelimited(parent: number) {
    const start = this.i
    const n = this.add(node({ t: 'delimited' }, start, this.end, parent))
    const leftEnd = this.control(this.i).end
    this.i = this.skipBlanks(leftEnd)
    this.i = this.delimiterEnd(this.i) ?? this.i
    this.nodes[n].opening = { from: start, to: this.i }
    this.closers.push('right')
    const stop = this.parseList(n, 'math')
    this.closers.pop()
    if (stoppedBy(stop, 'right')) {
      const closeStart = this.i
      const rightEnd = this.control(this.i).end
      this.i = this.skipBlanks(rightEnd)
      this.i = this.delimiterEnd(this.i) ?? this.i
      this.nodes[n].closing = { from: closeStart, to: this.i }
      this.nodes[n].to = this.i
      this.nodes[n].closed = true
    } else {
      this.nodes[n].to = stop === 'end' ? this.end : this.i
    }
  }

  /** latex.grammar's MathDelimiter. */
  delimiterEnd(k: number): number | null {
    const ch = this.c(k)
    if ([47, 124, 40, 41, 91, 93, 60, 62, 46].includes(ch)) return k + 1
    if (ch !== 92) return null
    const { end, name } = this.control(k)
    if (name !== null) return DELIMITER_NAMES.has(name) ? end : null
    const sym = this.c(k + 1)
    return sym === 123 || sym === 125 || sym === 124 ? k + 2 : null
  }
}

/**
 * A character that starts a token of its own after an environment name's
 * letters (latex.grammar: Number, Whitespace, MathSpecialChar, the script
 * signs, `&`, `~`, brackets and braces). Observed from the plugin, like the
 * exception: a second `*` does not.
 */
function breaksName(ch: number): boolean {
  switch (ch) {
    case 48: case 49: case 50: case 51: case 52: case 53: case 54: case 55: case 56: case 57:
    case 32: case 9: case 10: case 13: case 95: case 94: case 61: case 60: case 62: case 40: case 41:
    case 45: case 43: case 47: case 38: case 126: case 91: case 93: case 123:
      return true
    default:
      return false
  }
}

// MARK: - highlight_brackets.ts: `pairBrackets` over the specs `traverseTree` makes

/**
 * `bracket_delimiters`, verbatim — including its two oddities: `[` is listed
 * as closing with `}`, and `\langle ` carries a trailing space, so
 * `\langle … \rangle` never pairs.
 */
const BRACKET_PAIRS: [string, string][] = [
  ['{', '}'], ['[', '}'], ['(', ')'], ['\\{', '\\}'], ['\\left<', '\\right>'], ['\\langle ', '\\rangle'],
  ['\\lvert', '\\rvert'], ['\\lVert', '\\rVert'], ['\\right\\lt', '\\right\\gt'], ['\\lbrace', '\\rbrace'],
  ['\\lbrack', '\\rbrack'], ['\\lceil', '\\rceil'], ['\\lfloor', '\\rfloor'], ['\\lgroup', '\\rgroup'],
  ['\\llcorner', '\\lrcorner'], ['\\lmoustache', '\\rmoustache'], ['\\lparen', '\\rparen'],
]
const OPENING = new Map<string, string>()
for (const [open, close] of BRACKET_PAIRS) if (!OPENING.has(open)) OPENING.set(open, close)
/** `Object.fromEntries` of the reversed pairs: a later entry wins, so `}` → `[`. */
const CLOSING = new Map<string, string>()
for (const [open, close] of BRACKET_PAIRS) CLOSING.set(close, open)

type Spec =
  | { t: 'open'; bracket: string; range: Span }
  | { t: 'close'; bracket: string; range: Span }
  | { t: 'bracket'; open: Span; close: Span; children: Spec[] }

interface Paired {
  kind: 'open' | 'close' | 'bracket'
  bracket: string
  open: Span
  close: Span | null
  children: Paired[]
  parent: Paired | null
}

function pairSpecs(specs: Spec[]): Paired[] {
  const paired: Paired[] = []
  let parent: Paired | null = null
  const stack: Paired[] = []
  const place = (p: Paired) => {
    p.parent = parent
    if (parent) parent.children.push(p)
    else paired.push(p)
  }
  for (const spec of specs) {
    switch (spec.t) {
      case 'open': {
        const p: Paired = { kind: 'open', bracket: spec.bracket, open: spec.range, close: null, children: [], parent: null }
        place(p)
        stack.push(p)
        parent = p
        break
      }
      case 'close': {
        const wanted = CLOSING.get(spec.bracket)
        let index = -1
        if (wanted !== undefined) {
          for (let k = stack.length - 1; k >= 0; k -= 1) {
            if (stack[k].bracket === wanted) {
              index = k
              break
            }
          }
        }
        if (index >= 0) {
          const open = stack[index]
          stack.splice(index)
          open.kind = 'bracket'
          open.close = spec.range
          parent = open.parent
        } else {
          place({ kind: 'close', bracket: spec.bracket, open: spec.range, close: null, children: [], parent: null })
        }
        break
      }
      case 'bracket': {
        const p: Paired = { kind: 'bracket', bracket: '', open: spec.open, close: spec.close, children: [], parent: null }
        place(p)
        for (const child of pairSpecs(spec.children)) {
          child.parent = p
          p.children.push(child)
        }
        break
      }
    }
  }
  return paired
}
