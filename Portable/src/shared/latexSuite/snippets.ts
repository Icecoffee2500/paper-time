/**
 * The bundled snippets, and what one snippet is — `LatexSuiteSnippets.swift`
 * in TypeScript.
 *
 * `LatexSuiteSnippets.json` is the file the Mac engine reads from its bundle;
 * here esbuild's JSON loader puts the same file inside the renderer's bundle,
 * so the packaged app carries its own copy and never reads the repository at
 * run time. It is generated from Latex Suite's own sources by
 * `Scripts/latex-suite-data.mjs`; its `header.format` says what each field
 * means.
 */
import raw from '../../../../Packages/PaperTimeKit/Sources/PaperCore/Resources/LatexSuiteSnippets.json'
import { PatternShape } from './regex.js'
import { hasPrefixAt, isDigit } from './text.js'
import type { Scope } from './latex.js'

export interface MacroArea {
  name: string
  arguments?: number[]
}

interface RawSnippet {
  id: number
  kind: string
  trigger?: string
  pattern?: string
  key?: string
  replacement?: string
  function?: string
  options: string
  priority: number
  description?: string
  excludedMacros?: MacroArea[]
  groupNames?: (string | null)[]
}

export interface RawSettings {
  snippetsEnabled: boolean
  removeSnippetWhitespace: boolean
  'autoDelete$': boolean
  autofractionEnabled: boolean
  autofractionSymbol: string
  autofractionBreakingChars: string
  autofractionExcludedEnvs: string[][]
  matrixShortcutsEnabled: boolean
  matrixShortcutsEnvNames: string[]
  matrixShortcutsMacroNames: string[]
  taboutEnabled: boolean
  taboutExitEquationOnlyOnEOL: boolean
  taboutClosingSymbols: string[]
  autoEnlargeBrackets: boolean
  autoEnlargeBracketsSpace: boolean
  autoEnlargeBracketsTriggers: string[]
  wordDelimiters: string
  forceMathLanguages: string[]
}

export interface RawHeader {
  version: string
  copyright: string
  credit: string
  licenceText: string
}

interface RawData {
  header: RawHeader
  settings: RawSettings
  variables: Record<string, string>
  snippets: RawSnippet[]
  macros: string[]
  symbolCommands: string[]
  environmentClasses: Record<string, string[]>
}

// MARK: - Modes

export type CodeBlockMode = false | true | { language: string }

/** `Mode` (options.ts): where a snippet may run, or where the caret is. */
export class Mode {
  text = false
  inlineMath = false
  blockMath = false
  codeMath = false
  /** false: not in one; true: any (a snippet's `c`); a language: the caret's block. */
  codeBlock: CodeBlockMode = false
  code = false
  textEnv = false
  snippetlessEnv = false

  get inMath(): boolean {
    return this.inlineMath || this.blockMath || this.codeMath
  }

  get strictlyInMath(): boolean {
    return this.inMath && !this.textEnv
  }

  /**
   * `Mode.fromSource`: the option letters; none at all means "everywhere" the
   * old way, which is every flag set (and therefore *not* plain math —
   * `textEnv` is set too).
   */
  static fromOptions(options: string): Mode {
    const mode = new Mode()
    for (const c of options) {
      switch (c) {
        case 'm': mode.inlineMath = true; mode.blockMath = true; break
        case 'n': mode.inlineMath = true; break
        case 'M': mode.blockMath = true; break
        case 't': mode.text = true; break
        case 'T': mode.textEnv = true; break
        case 'c': mode.codeBlock = true; break
        case 'C': mode.code = true; break
        default: break
      }
    }
    if (mode.textEnv && !(mode.blockMath || mode.inlineMath)) {
      mode.blockMath = true
      mode.inlineMath = true
    }
    if (!(mode.text || mode.inlineMath || mode.blockMath || mode.codeMath || mode.codeBlock !== false || mode.textEnv || mode.code)) {
      mode.text = true
      mode.inlineMath = true
      mode.blockMath = true
      mode.codeMath = true
      mode.codeBlock = true
      mode.code = true
      mode.textEnv = true
      mode.snippetlessEnv = true
    }
    return mode
  }

  /** `Options.snippetShouldRunInMode`: `this` is the snippet's, `context` the caret's. */
  runs(context: Mode, ignoringSnippetlessEnv = false): boolean {
    if (context.snippetlessEnv && !ignoringSnippetlessEnv) return false
    if ((this.inlineMath && context.inlineMath) || (this.blockMath && context.blockMath)
      || ((this.inlineMath || this.blockMath) && context.codeMath)) {
      if (context.textEnv === this.textEnv) return true
    }
    if (this.text && context.text) return true
    const block = context.codeBlock
    if (typeof block === 'object') {
      if (this.codeBlock === true || (typeof this.codeBlock === 'object' && this.codeBlock.language === block.language)) return true
    }
    if (this.code && context.code) return true
    return false
  }
}

// MARK: - Snippets

export type Trigger =
  | { kind: 'string'; text: string }
  | { kind: 'regex'; regex: RegExp; shape: PatternShape; groupNames: (string | null)[] }
  | { kind: 'visual'; key: number }

export type SnippetFunction = 'autoSubscriptOrSpace' | 'disableWhileTypingMacro' | 'spaceAfterMacro' | 'identityMatrix' | 'displayMathInList'
const FUNCTIONS: SnippetFunction[] = ['autoSubscriptOrSpace', 'disableWhileTypingMacro', 'spaceAfterMacro', 'identityMatrix', 'displayMathInList']

export type Replacement = { kind: 'template'; text: string } | { kind: 'function'; fn: SnippetFunction }

/** `isMacroArgumentCount`. */
export function matchesArea(scope: Scope, macros: MacroArea[]): boolean {
  const macro = macros.find((m) => m.name === scope.name)
  if (!macro) return false
  if (!macro.arguments) return true
  return macro.arguments.includes(scope.argumentIndex)
}

export class Snippet {
  readonly id: number
  readonly trigger: Trigger
  readonly replacement: Replacement
  readonly mode: Mode
  readonly automatic: boolean
  readonly onWordBoundary: boolean
  readonly undoKey: boolean
  readonly priority: number
  readonly excludedMacros: MacroArea[]

  constructor(raw: RawSnippet) {
    this.id = raw.id
    this.mode = Mode.fromOptions(raw.options)
    this.onWordBoundary = raw.options.includes('w')
    this.undoKey = !raw.options.includes('U')
    this.priority = raw.priority
    this.excludedMacros = raw.excludedMacros ?? []
    switch (raw.kind) {
      case 'regex': {
        const pattern = raw.pattern ?? ''
        // `g` so the search can start at the window, `d` for the captures' offsets.
        this.trigger = { kind: 'regex', regex: new RegExp(pattern, 'gd'), shape: new PatternShape(pattern), groupNames: raw.groupNames ?? [] }
        this.automatic = raw.options.includes('A')
        break
      }
      case 'visual':
        this.trigger = { kind: 'visual', key: (raw.key ?? ' ').charCodeAt(0) }
        this.automatic = false
        break
      default:
        this.trigger = { kind: 'string', text: raw.trigger ?? '' }
        this.automatic = raw.options.includes('A')
    }
    if (raw.function) {
      if (!FUNCTIONS.includes(raw.function as SnippetFunction)) throw new Error(`unknown function ${raw.function}`)
      this.replacement = { kind: 'function', fn: raw.function as SnippetFunction }
    } else {
      this.replacement = { kind: 'template', text: raw.replacement ?? '' }
    }
  }

  get isVisual(): boolean {
    return this.trigger.kind === 'visual'
  }

  /**
   * `isWithinExcludedScope` (snippets.ts): environments are walked past, a
   * nested math scope ends the walk, a listed macro excludes.
   */
  isExcluded(scopes: Scope[]): boolean {
    if (this.excludedMacros.length === 0) return false
    for (const scope of scopes) {
      if (scope.kind === 'environment') continue
      if (scope.kind === 'math') return false
      if (matchesArea(scope, this.excludedMacros)) return true
    }
    return false
  }
}

// MARK: - The library

/** The compiled defaults, loaded once. */
export class Library {
  readonly snippets: Snippet[]
  /** The same, split the way the keymap asks for them (latex_suite.ts). */
  readonly automatic: Snippet[]
  readonly onTab: Snippet[]
  readonly visual: Map<number, Snippet[]>
  readonly header: RawHeader
  readonly settings: RawSettings
  /** Every prefix of every name in ALL_MACROS (backslash included). */
  readonly macroPrefixes: Set<string>
  readonly greek: Set<string>
  readonly symbols: Set<string>
  /** Environment name → its token class: names in the same class close each other. */
  readonly environmentClasses: Map<string, string>

  constructor(data: RawData) {
    this.header = data.header
    this.settings = data.settings
    this.snippets = data.snippets.map((s) => new Snippet(s))
    this.automatic = this.snippets.filter((s) => s.automatic)
    this.onTab = this.snippets.filter((s) => !s.automatic && !s.isVisual)
    this.visual = new Map()
    for (const snippet of this.snippets) {
      if (snippet.trigger.kind !== 'visual') continue
      const list = this.visual.get(snippet.trigger.key) ?? []
      list.push(snippet)
      this.visual.set(snippet.trigger.key, list)
    }
    this.macroPrefixes = new Set()
    for (const name of data.macros) {
      for (let n = 1; n <= name.length; n += 1) this.macroPrefixes.add(name.slice(0, n))
    }
    const greekPattern = data.variables['${GREEK}'] ?? ''
    this.greek = new Set(greekPattern.slice(3, -1).split('|'))
    this.symbols = new Set(data.symbolCommands)
    this.environmentClasses = new Map()
    for (const [kind, names] of Object.entries(data.environmentClasses)) {
      for (const name of names) this.environmentClasses.set(name, kind)
    }
  }

  private static cached: Library | null = null

  /** Built the first time an engine needs it, not when the window opens. */
  static get shared(): Library {
    if (!Library.cached) Library.cached = new Library(raw as unknown as RawData)
    return Library.cached
  }
}

// MARK: - Replacements

export interface TabstopSpec {
  index: number[]
  from: number
  to: number
}

/** What a replacement expands to: the text, and its tabstops relative to it. */
export interface Insert {
  text: string
  tabstops: TabstopSpec[]
}

const VISUAL_MARKER = '${VISUAL}'

/**
 * `SnippetStringNode.parseSnippet`: `[[n]]` captures (regex snippets only —
 * `captures` is null otherwise), then `$n` / `${n:text}` tabstops.
 */
export function expand(template: string, captures: string[] | null = null, visual: string | null = null): Insert {
  let text = template
  if (captures) text = expandCaptures(text, captures)
  if (visual !== null) text = text.split(VISUAL_MARKER).join(visual)
  return expandTabstops(text)
}

export function expandCaptures(text: string, captures: string[]): string {
  let out = ''
  let i = 0
  while (i < text.length) {
    if (text.charCodeAt(i) === 91 && i + 1 < text.length && text.charCodeAt(i + 1) === 91) {
      let j = i + 2
      while (j < text.length && isDigit(text.charCodeAt(j))) j += 1
      if (j > i + 2 && j + 1 < text.length && text.charCodeAt(j) === 93 && text.charCodeAt(j + 1) === 93) {
        const index = Number(text.slice(i + 2, j))
        if (index < captures.length) {
          out += captures[index]
          i = j + 2
          continue
        }
      }
    }
    out += text[i]
    i += 1
  }
  return out
}

/** `/\$(\d)|\$\{(\d+):([^}]*)\}/g`: `$N` takes one digit; there is no escape. */
export function expandTabstops(text: string): Insert {
  let out = ''
  const tabstops: TabstopSpec[] = []
  let i = 0
  while (i < text.length) {
    if (text.charCodeAt(i) === 36) {
      if (i + 1 < text.length && isDigit(text.charCodeAt(i + 1))) {
        tabstops.push({ index: [text.charCodeAt(i + 1) - 48], from: out.length, to: out.length })
        i += 2
        continue
      }
      if (i + 1 < text.length && text.charCodeAt(i + 1) === 123) {
        let j = i + 2
        while (j < text.length && isDigit(text.charCodeAt(j))) j += 1
        if (j > i + 2 && j < text.length && text.charCodeAt(j) === 58) {
          let k = j + 1
          while (k < text.length && text.charCodeAt(k) !== 125) k += 1
          if (k < text.length) {
            const placeholder = text.slice(j + 1, k)
            const parsed = Number(text.slice(i + 2, j))
            const index = Number.isSafeInteger(parsed) ? parsed : 0
            tabstops.push({ index: [index], from: out.length, to: out.length + placeholder.length })
            out += placeholder
            i = k + 1
            continue
          }
        }
      }
    }
    out += text[i]
    i += 1
  }
  return { text: out, tabstops }
}

/** `trimWhitespace` (run_snippets.ts): inline math loses trailing space. */
export function trimmedInsert(insert: Insert, trimEnd: (s: string) => string): Insert {
  const text = trimEnd(insert.text)
  return {
    text,
    tabstops: insert.tabstops.map((t) => ({ index: t.index, from: Math.min(t.from, text.length), to: Math.min(t.to, text.length) })),
  }
}

// MARK: - The five function replacements

/**
 * The defaults whose replacement is JavaScript, ported by hand. The generator
 * fingerprints each body and refuses to run when one changes, so these cannot
 * silently fall behind the plugin. Null is "does not apply, keep trying" (the
 * JavaScript `false`).
 */
export function callFunction(fn: SnippetFunction, match: string, groups: (string | null)[], named: Map<string, string>, library: Library): string | null {
  switch (fn) {
    case 'autoSubscriptOrSpace': {
      const isMacro = groups[0] === '\\'
      const digit = groups[2] ?? ''
      const name = groups[1] ?? ''
      if (!isMacro) return `${name}_{${digit}}`
      if (library.greek.has(name)) return `\\${name}_{${digit}}`
      return `\\${name} ${digit}`
    }
    case 'disableWhileTypingMacro':
      return library.macroPrefixes.has(match) ? match : null
    case 'spaceAfterMacro': {
      if (library.macroPrefixes.has(match)) return null
      const trigger = match.slice(1)
      return `\\${trigger.slice(0, -1)} ${trigger.slice(-1)}`
    }
    case 'identityMatrix': {
      const parsed = Number(groups[0] ?? '')
      const n = Number.isSafeInteger(parsed) ? parsed : 0
      const rows: string[] = []
      for (let j = 0; j < n; j += 1) {
        const cells: string[] = []
        for (let i = 0; i < n; i += 1) cells.push(i === j ? '1' : '0')
        rows.push(cells.join(' & '))
      }
      return `\\begin{pmatrix}\n${rows.join(' \\\\\n')}\n\\end{pmatrix}`
    }
    case 'displayMathInList': {
      const lookbehind = named.get('positive_lookbehind') ?? ''
      const marker = named.get('marker') ?? ''
      const whitespace = named.get('whitespace') ?? ''
      const text = named.get('text') ?? ''
      const firstLine = marker + whitespace + text
      const indent = ' '.repeat(marker.length) + whitespace
      return `${lookbehind}${firstLine}\n${indent}$$\n${indent}$0\n${indent}$$`
    }
  }
}

/** Whether `trigger` ends the text before `to` (plus `key`, when one is typed). */
export function endsWithTrigger(doc: string, trigger: string, to: number, key: number | null): boolean {
  const n = trigger.length
  if (key !== null) {
    if (!(n >= 1 && trigger.charCodeAt(n - 1) === key && n - 1 <= to)) return n === 0
    return hasPrefixAt(doc, trigger.slice(0, n - 1), to - (n - 1))
  }
  if (n > to) return false
  return hasPrefixAt(doc, trigger, to - n)
}
