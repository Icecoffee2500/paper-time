/**
 * One keystroke's worth of Latex Suite: the document, selection and tabstops
 * as they evolve through the transactions the plugin would dispatch, in the
 * order its keymap tries things (latex_suite.ts, `getKeymaps`) —
 * `LatexSuiteRun.swift` in TypeScript.
 */
import { ChangeSet, changeSetOf, compose, normalizedSelection, publicChanges, type Change, type PublicChange } from './changes.js'
import { Context, matchingBracket, matchingBracketBackwards } from './context.js'
import type { Scope } from './latex.js'
import { RegexInput } from './regex.js'
import type { LatexSettings } from './settings.js'
import {
  Library, callFunction, endsWithTrigger, expand, expandTabstops, trimmedInsert,
  type Insert, type Snippet, type TabstopSpec,
} from './snippets.js'
import { TabstopState } from './tabstops.js'
import {
  NEWLINE, isASCIILetter, isAllSpace, isEmpty, isSpace, lineEndOf, lineStartOf, overlaps, sameSpan, slice, trimmingEnd, type Span,
} from './text.js'

export type RunInput = { text: string } | 'tab' | 'shiftTab' | 'enter' | 'shiftEnter' | 'backspace'

export interface RunEdit {
  changes: PublicChange[]
  undoSteps: PublicChange[][]
  selection: Span[]
  tabstops: TabstopState
}

interface Queued {
  from: number
  to: number
  insert: Insert
  key: number | null
}

class VisualFailure extends Error {}

const SIZE_CONTROLS = new Set(['\\big', '\\Big', '\\bigg', '\\Bigg', '\\bigl', '\\Bigl', '\\biggl', '\\Biggl', '\\bigr', '\\Bigr',
  '\\biggr', '\\Biggr', '\\left', '\\right'])

/** autofraction.ts: a space after one of these names does not break the numerator. */
const FRACTION_GREEK = /(alpha|beta|gamma|Gamma|delta|Delta|epsilon|varepsilon|zeta|eta|theta|Theta|iota|kappa|lambda|Lambda|mu|nu|omicron|xi|Xi|pi|Pi|rho|sigma|Sigma|tau|upsilon|Upsilon|varphi|phi|Phi|chi|psi|Psi|omega|Omega) ([^ ])/g

const LEFT_COMMANDS = new Set(['\\left', '\\bigl', '\\Bigl', '\\biggl', '\\Biggl'])
const RIGHT_COMMANDS = new Set(['\\right', '\\bigr', '\\Bigr', '\\biggr', '\\Biggr'])
const DELIMITERS = new Set(['(', ')', '[', ']', '\\lbrack', '\\rbrack', '\\{', '\\}', '\\lbrace', '\\rbrace', '<', '>', '\\langle',
  '\\rangle', '\\lt', '\\gt', '|', '\\vert', '\\lvert', '\\rvert', '\\|', '\\Vert', '\\lVert', '\\rVert', '\\lfloor', '\\rfloor',
  '\\lceil', '\\rceil', '\\ulcorner', '\\urcorner', '/', '\\\\', '\\backslash', '\\uparrow', '\\downarrow', '\\Uparrow',
  '\\Downarrow', '.'])
const DELIMITER_PAIRS: [string, string][] = [['(', ')'], ['[', ']'], ['{', '}'], ['\\lbrack', '\\rbrack'], ['\\lbrace', '\\rbrace'],
  ['\\langle', '\\rangle'], ['\\lvert', '\\rvert'], ['\\lVert', '\\rVert'], ['\\lfloor', '\\rfloor'], ['\\lceil', '\\rceil'],
  ['\\ulcorner', '\\urcorner'], ['<', '>']]

export interface Token {
  start: number
  end: number
  text: string
}

/**
 * utils/tokenizer.ts, including what it does with a trailing backslash
 * (JavaScript tests `undefined` against `[A-Za-z]` and gets true).
 */
export function tokenize(s: string): Token[] {
  const tokens: Token[] = []
  let i = 0
  while (i < s.length) {
    const c = s.charCodeAt(i)
    if (isSpace(c)) {
      i += 1
      continue
    }
    let end = i + 1
    if (c === 37) {
      while (end < s.length && s.charCodeAt(end) !== NEWLINE) end += 1
    } else if (c === 92) {
      end = i + 2
      if (i + 1 >= s.length || isASCIILetter(s.charCodeAt(i + 1))) {
        while (end < s.length && isASCIILetter(s.charCodeAt(end))) end += 1
      }
    }
    tokens.push({ start: i, end, text: slice(s, i, end) })
    i = Math.min(end, s.length)
  }
  return tokens
}

/**
 * `/(\\begin{[^]]*}|\\\\|^)((?:\s|&)+)/` — `[^]` is "any character" in
 * JavaScript, so the first branch only takes a one-letter environment name.
 * Returns the second group with its leading whitespace trimmed.
 */
export function matrixRowPrefix(line: string): string {
  const match = /(\\begin{[^]]*}|\\\\|^)((?:\s|&)+)/.exec(line)
  if (!match) return ''
  let k = 0
  const group = match[2]
  while (k < group.length && isSpace(group.charCodeAt(k))) k += 1
  return group.slice(k)
}

/** `tabstopSpecsToTabstopGroups`: sorted by number (lowest first), equal numbers one group, renumbered without gaps. */
export function groupsFrom(specs: TabstopSpec[]): Span[][] {
  const sorted = specs.map((spec, offset) => ({ spec, offset })).sort((a, b) => {
    const x = a.spec.index
    const y = b.spec.index
    for (let k = 0; k < Math.min(x.length, y.length); k += 1) if (x[k] !== y[k]) return x[k] - y[k]
    if (x.length !== y.length) return x.length - y.length
    return a.offset - b.offset
  }).map((entry) => entry.spec)
  const groups: Span[][] = []
  let last: number[] | null = null
  for (const spec of sorted) {
    if (!last || last.length !== spec.index.length || last.some((v, k) => v !== spec.index[k])) groups.push([])
    groups[groups.length - 1].push({ from: spec.from, to: spec.to })
    last = spec.index
  }
  return groups.map((group) => group.sort((a, b) => a.from - b.from))
}

export class Run {
  doc: string
  selection: Span[]
  tabstops: TabstopState
  private readonly original: string
  private transactions: ChangeSet[] = []
  /** The typed key, committed as its own undo step before an expansion
   *  replaces it (snippet_management.ts, `handleUndoKeypresses`). */
  private echo: Change[] = []
  private cachedContext: Context | null = null

  constructor(doc: string, selection: Span[], tabstops: TabstopState, readonly settings: LatexSettings, readonly library: Library) {
    this.doc = doc
    this.selection = selection
    this.tabstops = tabstops
    this.original = doc
  }

  get context(): Context {
    if (!this.cachedContext) {
      this.cachedContext = new Context(this.doc, this.selection, this.library, this.settings.forceMathLanguages)
    }
    return this.cachedContext
  }

  private get main(): Span {
    return this.selection[0]
  }

  // MARK: The keymap

  handle(input: RunInput): boolean {
    const settings = this.settings
    if (typeof input === 'object') {
      if (input.text.length !== 1) return false
      const key = input.text.charCodeAt(0)
      if (settings.snippetsEnabled && this.runSnippets(this.library.automatic, key)) return true
      const visual = this.library.visual.get(key)
      if (settings.snippetsEnabled && visual && this.runSnippets(visual, null)) return true
      if (key === 47 && settings.autofractionEnabled && this.context.mode.strictlyInMath && this.autofraction()) return true
      if (settings.taboutEnabled && (key === 41 || key === 125 || key === 93) && isEmpty(this.main)
        && this.main.from < this.doc.length && this.doc.charCodeAt(this.main.from) === key && this.tabout()) {
        return true
      }
      return false
    }
    switch (input) {
      case 'tab':
        if (settings.snippetsEnabled && this.runSnippets(this.library.onTab, null)) return true
        if (this.jumpToTabstop(true)) return true
        if (settings.matrixShortcutsEnabled) {
          if (settings.taboutEnabled && this.matrix((scope) => this.priorityTabout(scope))) return true
          if (this.matrix(() => this.addCell())) return true
        }
        if (settings.taboutEnabled && isEmpty(this.main) && this.tabout()) return true
        return false
      case 'shiftTab':
        return this.jumpToTabstop(false)
      case 'enter':
        return settings.matrixShortcutsEnabled && this.matrix((scope) => this.newline(scope))
      case 'shiftEnter':
        return settings.matrixShortcutsEnabled && this.matrix((scope) => this.exit(scope))
      case 'backspace':
        return settings.autoDeleteDollar && this.autoDeleteDollar()
    }
  }

  // MARK: Transactions

  /**
   * Applies one transaction. With `explicit`, the selection is set (and the
   * tabstops react, §6.3); without, it is mapped through the changes.
   */
  private dispatch(changes: ChangeSet, explicit: Span[] | null = null, assoc = -1, newGroups: Span[][] | null = null, color = 0) {
    const tabstops = this.tabstops
    tabstops.map(changes)
    if (newGroups) {
      if (tabstops.index >= 0 && tabstops.index < tabstops.groups.length) {
        tabstops.groups.splice(tabstops.index, 1, ...newGroups)
        tabstops.colors.splice(tabstops.index, 1, ...newGroups.map(() => color))
      } else {
        tabstops.groups.push(...newGroups)
        tabstops.colors.push(...newGroups.map(() => color))
      }
    }
    if (explicit) {
      this.selection = normalizedSelection(explicit)
      tabstops.select(this.selection)
    } else {
      this.selection = normalizedSelection(this.selection.map((r) => changes.mapRange(r, assoc)))
    }
    this.doc = changes.apply(this.doc)
    if (!changes.isEmpty) this.transactions.push(changes)
    this.cachedContext = null
  }

  private setCursor(pos: number) {
    this.dispatch(ChangeSet.empty, [{ from: pos, to: pos }])
  }

  edit(): RunEdit {
    const changes = publicChanges(compose(this.original, this.transactions), this.original)
    let steps: PublicChange[][] = []
    if (this.echo.length > 0) {
      const echoSet = new ChangeSet(this.echo)
      const echoed = echoSet.apply(this.original)
      // The key characters as they sit in the echoed document.
      const undo: Change[] = []
      let shift = 0
      for (const change of echoSet.changes) {
        undo.push({ from: change.from + shift, to: change.from + shift + change.insert.length, insert: '' })
        shift += change.insert.length
      }
      steps.push(publicChanges(echoSet.changes, this.original))
      steps.push(publicChanges(compose(echoed, [new ChangeSet(undo), ...this.transactions]), echoed))
    } else {
      steps = changes.length === 0 ? [] : [changes]
    }
    return { changes, undoSteps: steps, selection: this.selection.map((r) => ({ ...r })), tabstops: this.tabstops }
  }

  // MARK: Snippets (run_snippets.ts)

  private runSnippets(snippets: Snippet[], key: number | null): boolean {
    if (snippets.length === 0) return false
    const ctx = this.context
    const queue: Queued[] = []
    let enlarge = false
    try {
      for (let r = ctx.selection.length - 1; r >= 0; r -= 1) {
        const found = this.runCursor(ctx, snippets, ctx.selection[r], key)
        if (!found) continue
        queue.push(found.queued)
        if (found.triggers) enlarge = true
      }
    } catch (error) {
      if (error instanceof VisualFailure) return false
      throw error
    }
    if (queue.length === 0) return false
    this.expand(queue)
    if (enlarge) this.autoEnlargeBrackets()
    return true
  }

  private runCursor(ctx: Context, snippets: Snippet[], range: Span, key: number | null): { queued: Queued; triggers: boolean } | null {
    const doc = this.doc
    const to = range.to
    const hasSelection = !isEmpty(range)
    const scopes = ctx.scopes(to)
    let regexInput: RegexInput | null = null
    const keyUnits = key === null ? '' : String.fromCharCode(key)
    for (const snippet of snippets) {
      if (!snippet.mode.runs(ctx.mode)) continue
      let triggerPos = to
      let insert: Insert
      const trigger = snippet.trigger
      switch (trigger.kind) {
        case 'string': {
          if (hasSelection || !endsWithTrigger(doc, trigger.text, to, key)) continue
          triggerPos = to + keyUnits.length - trigger.text.length
          if (snippet.replacement.kind !== 'template') continue
          insert = expand(snippet.replacement.text)
          break
        }
        case 'regex': {
          if (hasSelection) continue
          if (!regexInput) regexInput = new RegexInput(doc, to, keyUnits)
          const match = regexInput.match(trigger.regex, trigger.shape, trigger.groupNames)
          if (!match) continue
          triggerPos = match.index
          if (snippet.replacement.kind === 'template') {
            insert = expand(snippet.replacement.text, match.groups.map((g) => g ?? ''))
          } else {
            const text = callFunction(snippet.replacement.fn, match.whole, match.groups, match.named, this.library)
            if (text === null) continue
            insert = expandTabstops(text)
          }
          break
        }
        case 'visual': {
          if (!hasSelection) continue
          const parsed = this.parsedSelection(range)
          triggerPos = range.from
          if (snippet.replacement.kind !== 'template') continue
          // VisualSnippetNode throws without a selection to put in.
          if (parsed.text.length === 0) throw new VisualFailure()
          insert = expand(snippet.replacement.text, null, parsed.text)
          if (insert.tabstops.length === 0) {
            const prefix = slice(doc, range.from, parsed.from)
            insert = { text: prefix + insert.text, tabstops: [] }
            insert.tabstops = [{ index: [0], from: 0, to: insert.text.length }]
          }
          break
        }
      }
      if (snippet.isExcluded(scopes)) continue
      if (snippet.onWordBoundary && !this.isOnWordBoundary(triggerPos, to)) continue
      if (ctx.mode.inlineMath && this.settings.removeSnippetWhitespace) insert = trimmedInsert(insert, trimmingEnd)
      const echo = snippet.automatic && !snippet.isVisual && snippet.undoKey ? key : null
      const text = insert.text
      const triggers = this.settings.autoEnlargeBracketsTriggers.some((t) => text.includes(t))
      return { queued: this.queue(triggerPos, to, insert, echo), triggers }
    }
    return null
  }

  private isOnWordBoundary(triggerPos: number, to: number): boolean {
    const delimiters = this.settings.wordDelimiters
    const prevOK = triggerPos <= 0 || delimiters.includes(this.doc[triggerPos - 1])
    const nextOK = to >= this.doc.length || delimiters.includes(this.doc[to])
    return prevOK && nextOK
  }

  /** `getParsedSelection`: callout markers and indentation on continuation lines are not part of the selected text. */
  private parsedSelection(range: Span): { from: number; text: string } {
    const doc = this.doc
    const originalText = slice(doc, range.from, range.to)
    const lineStart = lineStartOf(doc, range.from)
    const lineEnd = lineEndOf(doc, range.from)
    const startLine = slice(doc, lineStart, lineEnd)
    const { count: callouts, indent: indentation } = calloutPrefix(startLine, 0)
    // `\n((?:> ?)*)(\s*)`, replaced by a bare newline while every line has the
    // same callout depth and at least the first line's indentation.
    let parsed = ''
    let i = 0
    while (i < originalText.length) {
      if (originalText.charCodeAt(i) === NEWLINE) {
        const prefix = calloutPrefix(originalText, i + 1)
        if (prefix.count !== callouts || prefix.indent < indentation) return { from: range.from, text: originalText }
        parsed += '\n'
        i += 1 + prefix.length
        continue
      }
      parsed += originalText[i]
      i += 1
    }
    let from = range.from
    if (lineStart === range.from) {
      // `/^(> ?)*\s*/` on the parsed text.
      let j = 0
      while (j < parsed.length && parsed.charCodeAt(j) === 62) {
        j += 1
        if (j < parsed.length && parsed.charCodeAt(j) === 32) j += 1
      }
      while (j < parsed.length && isSpace(parsed.charCodeAt(j))) j += 1
      from += j
      parsed = parsed.slice(j)
    }
    return { from, text: parsed }
  }

  /**
   * `queueSnippet` with `keepIndentAndCallout`: every newline in the
   * replacement carries the line's callout markers and indentation, and tabs
   * right after a newline become that many indent units more.
   */
  private queue(from: number, to: number, insert: Insert, key: number | null): Queued {
    const doc = this.doc
    const lineStart = lineStartOf(doc, to)
    let j = lineStart
    while (j < doc.length && doc.charCodeAt(j) === 62) j += 1
    const callouts = slice(doc, lineStart, j)
    const indentStart = j
    while (j < doc.length && doc.charCodeAt(j) !== NEWLINE && isSpace(doc.charCodeAt(j))) j += 1
    const indentation = slice(doc, indentStart, j)
    const tabSize = Math.max(1, this.settings.tabSize)
    let column = 0
    for (let k = 0; k < indentation.length; k += 1) column += indentation.charCodeAt(k) === 9 ? tabSize - (column % tabSize) : 1
    const unit = this.settings.indentUnit
    let unitWidth = 0
    for (let k = 0; k < unit.length; k += 1) unitWidth += unit.charCodeAt(k) === 9 ? tabSize - (unitWidth % tabSize) : 1
    unitWidth = Math.max(1, unitWidth)
    const misalignment = column % unitWidth
    const tabsIndent = unit.charCodeAt(0) === 9

    const indentString = (columns: number): string => {
      let out = ''
      let n = columns
      if (tabsIndent) {
        while (n >= tabSize) {
          out += '\t'
          n -= tabSize
        }
      }
      while (n > 0) {
        out += ' '
        n -= 1
      }
      return out
    }

    let text = ''
    const tabstops = insert.tabstops.map((t) => ({ ...t }))
    let offset = 0
    let i = 0
    const source = insert.text
    while (i < source.length) {
      if (source.charCodeAt(i) === NEWLINE) {
        let k = i + 1
        while (k < source.length && source.charCodeAt(k) === 9) k += 1
        const tabs = k - (i + 1)
        const newColumn = tabs * unitWidth + column - (tabs > 0 ? misalignment : 0)
        const replacement = '\n' + callouts + indentString(newColumn)
        const added = replacement.length - (k - i)
        for (const t of tabstops) {
          if (t.from - offset > i) t.from += added
          if (t.to - offset > i) t.to += added
        }
        offset += added
        text += replacement
        i = k
        continue
      }
      text += source[i]
      i += 1
    }
    return { from, to, insert: { text, tabstops }, key }
  }

  /**
   * `expandSnippets`: all queued replacements in one change set; with
   * tabstops, their groups spliced in place of the current one and group 0
   * selected.
   */
  private expand(queue: Queued[]) {
    const changes = changeSetOf(queue.map((q) => ({ from: q.from, to: q.to, insert: q.insert.text })), this.doc)
    if (this.echo.length === 0 && this.transactions.length === 0) {
      this.echo = queue.filter((q) => q.key !== null).map((q) => ({ from: q.to, to: q.to, insert: String.fromCharCode(q.key as number) }))
    }
    const undone = Run.undoneKeypresses(queue, this.doc)
    const specs: TabstopSpec[] = queue.flatMap((q) => {
      const from = undone.mapped(q.from, 1)
      return q.insert.tabstops.map((t) => ({ index: t.index, from: from + t.from, to: from + t.to }))
    })
    const mapped = this.selection.map((r) => changes.mapRange(r, 1))
    if (specs.length === 0) {
      this.dispatch(changes, mapped)
      return
    }
    const groups = groupsFrom(specs)
    const color = this.tabstops.takeColor()
    this.dispatch(changes, groups[0], -1, groups, color)
  }

  /**
   * Where the plugin measures each snippet's tabstops from
   * (snippet_management.ts, `handleUndoKeypresses` and `applyChange`): the
   * typed keys are put in and taken out again for Undo, and each snippet's
   * start is mapped through that taking-out — as if it were a position in the
   * text with the keys in, which it is not, and without the other snippets of
   * the same keystroke. With one caret this changes nothing. With several, the
   * placeholders of all but the first land where the other carets' keys and
   * expansions push them, not on their own text; that is what Latex Suite
   * users get, so it is kept.
   */
  private static undoneKeypresses(queue: Queued[], doc: string): ChangeSet {
    const presses = new ChangeSet(queue.filter((q) => q.key !== null).map((q) => {
      // `prevChar + key` over `[to - 1, to)`, so carets land after the key.
      const from = q.to === 0 ? 0 : q.to - 1
      return { from, to: q.to, insert: slice(doc, from, q.to) + String.fromCharCode(q.key as number) }
    }))
    if (presses.isEmpty) return ChangeSet.empty
    const inverse: Change[] = []
    let shift = 0
    for (const press of presses.changes) {
      const from = press.from + shift
      inverse.push({ from, to: from + press.insert.length, insert: slice(doc, press.from, press.to) })
      shift += press.insert.length - (press.to - press.from)
    }
    return new ChangeSet(inverse)
  }

  // MARK: Tabstops (snippet_management.ts, setSelectionToNextTabstop)

  private jumpToTabstop(forward: boolean): boolean {
    const direction = forward ? 1 : -1
    let next = this.tabstops.index + direction
    while (next >= 0 && next < this.tabstops.groups.length) {
      const group = this.tabstops.groups[next]
      let target = normalizedSelection(group)
      const contains = this.selection.every((r) => group.some((g) => g.from <= r.from && g.to >= r.to))
      if (contains) target = normalizedSelection(target.map((r) => ({ from: r.to, to: r.to })))
      if (target.length === this.selection.length && target.every((r, k) => sameSpan(r, this.selection[k]))) {
        next += direction
        continue
      }
      this.dispatch(ChangeSet.empty, target)
      return true
    }
    return false
  }

  // MARK: Auto-enlarge brackets (auto_enlarge_brackets.ts)

  private autoEnlargeBrackets() {
    if (!this.settings.autoEnlargeBrackets) return
    const ctx = this.context
    const pos = this.main.to
    const bound = ctx.bounds.find((b) => b.tree !== null && b.innerStart <= pos && b.innerEnd >= pos)
    const latex = bound ? ctx.latex(bound) : null
    if (!latex) return
    const doc = this.doc
    const space = this.settings.autoEnlargeBracketsSpace ? ' ' : ''
    const triggers = this.settings.autoEnlargeBracketsTriggers
    const queue: Queued[] = []
    const taken: Span[] = []
    for (const pair of latex.pairs()) {
      const open = slice(doc, pair.open.from, pair.open.to)
      const close = slice(doc, pair.close.from, pair.close.to)
      if (open === '{' || open === '\\(' || open.startsWith('\\left') || close.startsWith('\\right')) continue
      const word = latex.controlWord(pair.open.from)
      if (word !== null && SIZE_CONTROLS.has(word)) continue
      const content = slice(doc, pair.open.to, pair.close.from)
      if (triggers.every((t) => !content.includes(t))) continue
      if (taken.some((r) => overlaps(r, pair.open) || overlaps(r, pair.close))) continue
      taken.push(pair.open, pair.close)
      queue.push(this.queue(pair.open.from, pair.open.to, { text: '\\left' + open + space, tabstops: [] }, null))
      queue.push(this.queue(pair.close.from, pair.close.to, { text: space + '\\right' + close, tabstops: [] }, null))
    }
    if (queue.length === 0) return
    this.expand(queue)
  }

  // MARK: Autofraction (autofraction.ts)

  private autofraction(): boolean {
    const ctx = this.context
    const queue: Queued[] = []
    for (let r = ctx.selection.length - 1; r >= 0; r -= 1) {
      const q = this.fraction(ctx, ctx.selection[r])
      if (q) queue.push(q)
    }
    if (queue.length === 0) return false
    this.expand(queue)
    this.autoEnlargeBrackets()
    return true
  }

  private fraction(ctx: Context, range: Span): Queued | null {
    const doc = this.doc
    const from = range.from
    const to = range.to
    for (const env of this.settings.autofractionExcludedEnvironments) {
      if (env.length !== 2) continue
      if (ctx.isWithinEnvironment(to, env[0], env[1])) return null
    }
    const bound = ctx.equation
    if (!bound) return null
    const eqnStart = bound.innerStart
    let start = eqnStart
    if (from !== to) {
      start = from
    } else {
      // A space after a Greek name does not break the numerator.
      const line = (to > eqnStart ? slice(doc, eqnStart, to) : '').replace(FRACTION_GREEK, '$1#$2')
      const breaking = ' $([{\n' + this.settings.autofractionBreakingChars
      let k = line.length - 1
      while (k >= 0) {
        const c = line.charCodeAt(k)
        if (c === 41 || c === 93 || c === 125) {
          const open = c === 41 ? 40 : c === 93 ? 91 : 123
          const j = matchingBracketBackwards(line, k, open, c)
          if (j === null) return null
          k = j
        }
        // The character read before the jump: a closing bracket never breaks,
        // and the opener it jumped to is not looked at again.
        if (breaking.includes(String.fromCharCode(c))) {
          start = k + 1 + eqnStart
          break
        }
        k -= 1
      }
    }
    // Nothing to take (the plugin's `start === to`). `start > to` is the caret
    // right before the `$$` of `$$x$$`, which Latex Suite counts as inside an
    // empty inline equation that starts after it: the plugin throws a
    // RangeError there and leaves a stray `/` in the text. The engine lets the
    // key through instead.
    if (start >= to) return null
    let numerator = slice(doc, start, to)
    if (numerator.charCodeAt(0) === 40 && numerator.charCodeAt(numerator.length - 1) === 41
      && matchingBracket(numerator, 0, '(', ')') === numerator.length - 1) {
      numerator = numerator.slice(1, -1)
    }
    let text = this.settings.autofractionSymbol + '{'
    const tabstops: TabstopSpec[] = []
    if (numerator.length === 0) tabstops.push({ index: [0], from: text.length, to: text.length })
    else text += numerator
    text += '}{'
    tabstops.push({ index: [1], from: text.length, to: text.length })
    text += '}'
    tabstops.push({ index: [2], from: text.length, to: text.length })
    return this.queue(start, to, { text, tabstops }, from !== to ? null : 47)
  }

  // MARK: Tabout (tabout.ts)

  private isClosingDelimiter(tokens: Token[], i: number, closing: Set<string>): boolean {
    if (i > 0) {
      const prev = tokens[i - 1].text
      if (RIGHT_COMMANDS.has(prev) && DELIMITERS.has(tokens[i].text)) return true
      if (LEFT_COMMANDS.has(prev) && DELIMITERS.has(tokens[i].text)) return false
    }
    return closing.has(tokens[i].text)
  }

  private isUnmatchedRightCommand(tokens: Token[], i: number): boolean {
    if (!RIGHT_COMMANDS.has(tokens[i].text)) return false
    if (i + 1 >= tokens.length) return true
    return !DELIMITERS.has(tokens[i + 1].text)
  }

  private lineStart(p: number): number {
    return lineStartOf(this.doc, p)
  }

  private lineEnd(p: number): number {
    return lineEndOf(this.doc, p)
  }

  private isMultiline(from: number, to: number): boolean {
    return this.lineStart(from) !== this.lineStart(to)
  }

  private tabout(): boolean {
    const ctx = this.context
    const bound = ctx.equation
    if (!ctx.mode.inMath || !bound || !(bound.outerEnd > ctx.pos)) return false
    const doc = this.doc
    const cursor = this.main.to
    const relative = cursor - bound.innerStart
    const tokens = tokenize(slice(doc, bound.innerStart, bound.innerEnd))
    const closing = new Set(this.settings.taboutClosingSymbols)
    let startIndex = tokens.findIndex((t) => t.end > relative)
    if (startIndex === -1) startIndex = tokens.length
    for (let i = startIndex; i < tokens.length; i += 1) {
      if (this.isClosingDelimiter(tokens, i, closing) || this.isUnmatchedRightCommand(tokens, i)) {
        this.setCursor(bound.innerStart + tokens[i].end)
        return true
      }
    }
    const atEnd = isAllSpace(slice(doc, cursor, bound.innerEnd))
    if (!atEnd && this.settings.taboutExitEquationOnlyOnEOL) return false
    if (!this.isMultiline(bound.outerStart, bound.outerEnd)) {
      this.setCursor(bound.outerEnd)
      return true
    }
    const endLineStart = this.lineStart(bound.outerEnd)
    const endLineEnd = this.lineEnd(endLineStart)
    const startLine = slice(doc, this.lineStart(bound.outerStart), this.lineEnd(bound.outerStart))
    let indentCount = 0
    while (indentCount < startLine.length && isSpace(startLine.charCodeAt(indentCount))) indentCount += 1
    const indent = startLine.slice(0, indentCount)
    const changes: Change[] = []
    let target: number
    if (endLineEnd >= doc.length) {
      changes.push({ from: endLineEnd, to: endLineEnd, insert: '\n' + indent })
      target = endLineEnd + 1 + indent.length
    } else {
      const afterStart = endLineEnd + 1
      const afterEnd = this.lineEnd(afterStart)
      if (isAllSpace(slice(doc, afterStart, afterEnd))) {
        changes.push({ from: afterStart, to: afterEnd, insert: indent })
        target = endLineEnd + 1 + indent.length
      } else {
        target = endLineEnd + 1
      }
    }
    // Trailing whitespace on the caret's line goes in the same transaction;
    // the caret, set by the first spec, moves back by what it removes.
    const currentStart = this.lineStart(cursor)
    const currentEnd = this.lineEnd(cursor)
    const current = slice(doc, currentStart, currentEnd)
    const trimmed = trimmingEnd(current)
    if (trimmed.length !== current.length) {
      changes.unshift({ from: currentStart, to: currentEnd, insert: trimmed })
      if (currentEnd <= target) target -= current.length - trimmed.length
    }
    this.dispatch(new ChangeSet(changes), [{ from: target, to: target }])
    return true
  }

  // MARK: Matrix shortcuts (matrix_shortcuts.ts)

  private matrix(shortcut: (scope: Scope) => boolean): boolean {
    const ctx = this.context
    if (!ctx.mode.strictlyInMath || !ctx.equation) return false
    const scope = ctx.scopes(ctx.pos)[0]
    if (!scope) return false
    switch (scope.kind) {
      case 'environment':
        if (!this.settings.matrixShortcutsEnvironments.includes(scope.name)) return false
        break
      case 'command':
        if (!this.settings.matrixShortcutsMacros.includes(scope.name)) return false
        break
      case 'math':
        return false
    }
    return shortcut(scope)
  }

  private priorityTabout(_scope: Scope): boolean {
    const pos = this.context.pos
    const rest = slice(this.doc, pos, this.lineEnd(pos))
    const tokens = tokenize(rest)
    const closingSymbols = new Set(this.settings.taboutClosingSymbols)
    const closing = new Set(DELIMITER_PAIRS.map((p) => p[1]).filter((c) => closingSymbols.has(c)))
    const opening = new Set(DELIMITER_PAIRS.filter((p) => closing.has(p[1])).map((p) => p[0]))
    let depth = 0
    for (const token of tokens) {
      if (closing.has(token.text)) {
        if (depth === 0) {
          this.setCursor(pos + token.end)
          return true
        }
        depth -= 1
      } else if (opening.has(token.text)) {
        depth += 1
      }
    }
    return false
  }

  private addCell(): boolean {
    if (!isEmpty(this.main)) return false
    this.replaceSelection(' & ')
    return true
  }

  /** `view.state.replaceSelection`: every range replaced, the caret after it. */
  private replaceSelection(text: string) {
    const changes = new ChangeSet(this.selection.map((r) => ({ from: r.from, to: r.to, insert: text })))
    const carets = this.selection.map((r) => {
      const p = changes.mapped(r.from, -1) + text.length
      return { from: p, to: p }
    })
    this.dispatch(changes, carets)
  }

  private newline(scope: Scope): boolean {
    const pos = this.context.pos
    const line = slice(this.doc, this.lineStart(pos), this.lineEnd(pos))
    const cells = matrixRowPrefix(line)
    if (this.isMultiline(scope.outerStart, scope.outerEnd)) {
      const text = ' \\\\\n' + cells
      const insert: Insert = { text, tabstops: [{ index: [0], from: text.length, to: text.length }] }
      this.expand([this.queue(pos, pos, insert, null)])
    } else {
      this.replaceSelection(' \\\\  ' + cells)
    }
    return true
  }

  private exit(scope: Scope): boolean {
    const pos = this.context.pos
    if (this.isMultiline(scope.outerStart, scope.outerEnd)) {
      const end = this.lineEnd(pos)
      if (end >= this.doc.length) return false
      const nextStart = end + 1
      const nextEnd = this.lineEnd(nextStart)
      const next = slice(this.doc, nextStart, nextEnd)
      let to = nextEnd
      const at = next.indexOf('\\end{')
      if (at !== -1) {
        let j = at + 5
        while (j < next.length && next.charCodeAt(j) !== 125) j += 1
        if (j < next.length) {
          const name = next.slice(at + 5, j)
          if (name.length > 0 && this.settings.matrixShortcutsEnvironments.includes(name)) to = nextStart + j + 1
        }
      }
      this.setCursor(to)
    } else {
      this.setCursor(scope.outerEnd)
    }
    return true
  }

  // MARK: Auto-delete $ (latex_suite.ts, autoDelete$)

  /**
   * Backspace between the dollars of an empty `$$` line deletes both. The
   * plugin asks its tree for a `Dollar` node with nothing before it and
   * nothing but another `Dollar` after it — true only for the opening run of a
   * `$$` block that has no content yet (never for inline math, whose empty
   * content still carries a zero-length LaTeX node).
   */
  private autoDeleteDollar(): boolean {
    const pos = this.main.to
    const doc = this.doc
    if (!(pos > 0 && pos < doc.length && doc.charCodeAt(pos - 1) === 36 && doc.charCodeAt(pos) === 36)) return false
    const block = this.context.markdown.displayBlocks.find((b) => b.open.from < pos && b.open.to > pos)
    if (!block || block.content.length > 0 || block.hasMarkers) return false
    this.dispatch(new ChangeSet([{ from: pos - 1, to: pos + 1, insert: '' }]))
    this.tabstops.clear()
    return true
  }
}

/** A calloutPrefix result: `(?:> ?)*` then `\s*` from a start — the total length, the number of `>`, the length of the whitespace. */
function calloutPrefix(text: string, start: number): { length: number; count: number; indent: number } {
  let j = start
  let count = 0
  while (j < text.length && text.charCodeAt(j) === 62) {
    count += 1
    j += 1
    if (j < text.length && text.charCodeAt(j) === 32) j += 1
  }
  const indentStart = j
  while (j < text.length && isSpace(text.charCodeAt(j))) j += 1
  return { length: j - start, count, indent: j - indentStart }
}
