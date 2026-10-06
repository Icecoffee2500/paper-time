/**
 * Fenced code in a note — the Mac's `NoteCode` (PaperCore), held to the same
 * answers (`note-code.json`, made by `Scripts/note-code-fixture.swift`).
 *
 * Fenced code is the one thing in a note whose lines mean nothing on their
 * own: inside a fence `# comment` is not a heading, `- x` is not a bullet and
 * `$x$` is not mathematics. So the fences are found first, over the whole
 * note, and every line between two of them is code. CommonMark's rules, as
 * Latex Suite reads them: three or more backticks or tildes after at most
 * three spaces; no backtick in a backtick fence's info string; closed by a
 * line of the same character, at least as long, with only spaces after; a
 * fence never closed runs to the end of the note. Offsets are UTF-16.
 */
import { lineRanges, type TextSpan } from './noteMath.js'

export interface CodeBlock {
  /** From the start of the opening fence's line to the end of the closing fence's line — or of the note. */
  range: TextSpan
  /** The opening fence's line, without its newline. */
  open: TextSpan
  /** The closing fence's line; null when the code runs to the end. */
  close: TextSpan | null
  /** The lines of code between, each without its newline. */
  lines: TextSpan[]
  /** The info string's first word — `python` — as written; '' when there is none. */
  language: string
}

export interface Fence {
  character: string
  length: number
  language: string
}

/** Every fenced block in the text, in order. */
export function codeBlocks(text: string): CodeBlock[] {
  if (!text.includes('`') && !text.includes('~')) return []
  const lines = lineRanges(text)
  const result: CodeBlock[] = []
  let index = 0
  while (index < lines.length) {
    const fence = openingFence(text.slice(lines[index].from, lines[index].to))
    if (!fence) {
      index += 1
      continue
    }
    const body: TextSpan[] = []
    let close: TextSpan | null = null
    let next = index + 1
    while (next < lines.length) {
      if (closesFence(text.slice(lines[next].from, lines[next].to), fence)) {
        close = lines[next]
        next += 1
        break
      }
      body.push(lines[next])
      next += 1
    }
    const last = close ?? body[body.length - 1] ?? lines[index]
    result.push({ range: { from: lines[index].from, to: last.to }, open: lines[index], close, lines: body, language: fence.language })
    index = next
  }
  return result
}

/** What a line of a fenced block is in it. */
export type CodeRowRole = 'header' | 'line' | 'close'

export interface CodeRow {
  block: CodeBlock
  role: CodeRowRole
  /** The row's line in the note, without its newline. */
  line: TextSpan
  /** A line of code's number, from 1; 0 for the fences. */
  number: number
  /** The block's last row: its closing fence — or, never closed, its last line (its fence when it has none). */
  isLast: boolean
  /** Where the row's line starts in the block's code (`codeOf`); 0 for the fences. */
  offset: number
}

/** Every row of every block, by where its line starts — the Mac's `NoteMarkdown.codeRows`. */
export function codeRows(text: string, blocks: CodeBlock[] = codeBlocks(text)): Map<number, CodeRow> {
  const rows = new Map<number, CodeRow>()
  for (const block of blocks) {
    const closed = block.close !== null
    rows.set(block.open.from, { block, role: 'header', line: block.open, number: 0, isLast: !closed && block.lines.length === 0, offset: 0 })
    let offset = 0
    block.lines.forEach((line, index) => {
      rows.set(line.from, { block, role: 'line', line, number: index + 1, isLast: !closed && index === block.lines.length - 1, offset })
      offset += line.to - line.from + 1
    })
    if (block.close) rows.set(block.close.from, { block, role: 'close', line: block.close, number: 0, isLast: true, offset: 0 })
  }
  return rows
}

/** The row of a fenced block the caret's line is; null outside code. */
export function codeRowAt(text: string, caret: number): CodeRow | null {
  if (!text.includes('`') && !text.includes('~')) return null
  const start = text.lastIndexOf('\n', caret - 1) + 1
  for (const block of codeBlocks(text)) {
    if (start < block.range.from) return null
    if (start > block.range.to) continue
    return codeRows(text, [block]).get(start) ?? null
  }
  return null
}

/**
 * Whether Return on a block's opening fence should close the block: when
 * nothing closes it — or what closes it is another block's closing fence,
 * which a fence typed above that block takes for its own, and that block's
 * opening fence (a language after its marks) is read as a line of code.
 */
export function wantsClosing(block: CodeBlock, text: string): boolean {
  if (block.close === null) return true
  return block.lines.some((line) => (openingFence(text.slice(line.from, line.to))?.language ?? '') !== '')
}

/** The code a block holds: its lines, as written, one to a line. */
export function codeOf(block: CodeBlock, text: string): string {
  return block.lines.map((line) => text.slice(line.from, line.to)).join('\n')
}

/** The fence a line opens, if it opens one. */
export function openingFence(line: string): Fence | null {
  // A note written on Windows ends its lines in "\r\n"; the "\r" is not part of the info string.
  const text = line.endsWith('\r') ? line.slice(0, -1) : line
  let index = 0
  while (index < text.length && text[index] === ' ' && index < 3) index += 1
  const mark = text[index]
  if (mark !== '`' && mark !== '~') return null
  let end = index
  while (end < text.length && text[end] === mark) end += 1
  if (end - index < 3) return null
  const info = text.slice(end)
  // ```x``` on a line is code in a sentence, not a fence.
  if (mark === '`' && info.includes('`')) return null
  return { character: mark, length: end - index, language: languageOf(info) }
}

/** Whether a line closes a fence: the same character, at least as long, after at most three spaces, nothing but spaces after. */
export function closesFence(line: string, fence: Fence): boolean {
  let index = 0
  while (index < line.length && line[index] === ' ' && index < 3) index += 1
  let end = index
  while (end < line.length && line[end] === fence.character) end += 1
  if (end - index < fence.length) return false
  for (let at = end; at < line.length; at += 1) {
    if (line[at] !== ' ' && line[at] !== '\t' && line[at] !== '\r') return false
  }
  return true
}

/** The first word of an info string, without the braces and dot some writers put round it (`{python}`, `{.python}`). */
export function languageOf(info: string): string {
  let word = info.split(/[ \t]+/).find((part) => part.length > 0) ?? ''
  if (word.startsWith('{')) word = word.slice(1)
  if (word.endsWith('}')) word = word.slice(0, -1)
  if (word.startsWith('.')) word = word.slice(1)
  return word
}

const GROUPS: [string, string[]][] = [
  ['Python', ['python', 'py', 'python3', 'py3']],
  ['JavaScript', ['javascript', 'js', 'jsx', 'mjs', 'cjs']],
  ['TypeScript', ['typescript', 'ts', 'tsx', 'mts', 'cts']],
  ['Swift', ['swift']],
  ['C', ['c', 'h']],
  ['C++', ['cpp', 'c++', 'cc', 'cxx', 'hpp', 'hh', 'hxx']],
  ['C#', ['csharp', 'cs', 'c#']],
  ['Objective-C', ['objectivec', 'objective-c', 'objc', 'obj-c', 'm', 'mm']],
  ['Java', ['java']],
  ['Kotlin', ['kotlin', 'kt', 'kts']],
  ['Scala', ['scala']],
  ['Rust', ['rust', 'rs']],
  ['Go', ['go', 'golang']],
  ['Shell', ['bash', 'sh', 'shell', 'zsh', 'console', 'shellsession']],
  ['PowerShell', ['powershell', 'ps1', 'pwsh']],
  ['JSON', ['json', 'jsonc', 'json5']],
  ['YAML', ['yaml', 'yml']],
  ['TOML', ['toml']],
  ['INI', ['ini', 'cfg', 'conf']],
  ['XML', ['xml', 'plist', 'svg']],
  ['HTML', ['html', 'htm', 'xhtml']],
  ['CSS', ['css']],
  ['SCSS', ['scss', 'sass']],
  ['SQL', ['sql', 'psql', 'mysql', 'sqlite']],
  ['R', ['r']],
  ['MATLAB', ['matlab']],
  ['Julia', ['julia', 'jl']],
  ['LaTeX', ['latex', 'tex']],
  ['Markdown', ['markdown', 'md']],
  ['Ruby', ['ruby', 'rb']],
  ['PHP', ['php']],
  ['Lua', ['lua']],
  ['Perl', ['perl', 'pl']],
  ['Haskell', ['haskell', 'hs']],
  ['Dart', ['dart']],
  ['Diff', ['diff', 'patch']],
  ['Dockerfile', ['dockerfile', 'docker']],
  ['Makefile', ['makefile', 'make', 'mk']],
  ['Text', ['text', 'txt', 'plaintext', 'plain']],
]
const NAMES = new Map<string, string>(GROUPS.flatMap(([name, aliases]) => aliases.map((alias) => [alias, name] as [string, string])))

/** What a language is called over its code: `py` is Python, `cpp` is C++; one not on the list is shown as written. */
export function codeLanguageName(language: string): string {
  return NAMES.get(language.toLowerCase()) ?? language
}

/**
 * A block's own colours, as the Mac paints them (`NoteCodeStyle.Block.fill`,
 * `pillFill`, `pillEdge`): a cool wash of the page — the faintest blue, and
 * in the dark the slate of Xcode's own editor — and the copy pill on it. The
 * window's `--codeblock-*` tokens are these; a test holds the three together.
 */
export const CODE_SURFACE = {
  fill: { light: 'rgba(30, 90, 200, 0.05)', dark: 'rgba(140, 170, 255, 0.085)' },
  pill: { light: 'rgba(255, 255, 255, 0.85)', dark: 'rgba(255, 255, 255, 0.08)' },
  pillEdge: { light: 'rgba(0, 0, 0, 0.06)', dark: 'transparent' },
} as const
