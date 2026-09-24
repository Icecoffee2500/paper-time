#!/usr/bin/env node
/**
 * Builds the one snippet file both builds read, from a checkout of Latex Suite.
 *
 *     node Scripts/latex-suite-data.mjs <path to obsidian-latex-suite at tag 1.13.1>
 *
 * The Mac engine (PaperCore/LatexSuite) and the Portable engine import the same
 * `LatexSuiteSnippets.json`, so the two can never disagree about which
 * snippet wins. The file is generated, not transcribed, for the same reason
 * the LaTeX escape table is: a hand copy of two hundred snippets is two hundred
 * chances to be subtly wrong, and the plugin's own parse and sort already say
 * what the answer is.
 *
 * What it writes:
 *   Packages/PaperTimeKit/Sources/PaperCore/Resources/LatexSuiteSnippets.json
 *   Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/latex-suite-regex.json
 *
 * The second file pins the regex dialect. Latex Suite's triggers are
 * JavaScript regular expressions; NSRegularExpression is ICU, and the two read
 * the same pattern differently (`\d` is every Unicode digit in ICU, `$` also
 * matches before a final newline, `{` that is not a quantifier is an error,
 * `[` inside a class opens a nested set, group names cannot contain `_`). So
 * every pattern is rewritten into a small dialect both engines read the same
 * way, and the fixture records what the *original* JavaScript pattern matched
 * on a corpus of inputs — the Swift test and the TypeScript test both check
 * the rewritten pattern against it.
 */
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'

const repoRoot = path.join(import.meta.dirname, '..')
const checkout = process.argv[2]
if (!checkout) {
  console.error('usage: node Scripts/latex-suite-data.mjs <latex-suite checkout>')
  process.exit(2)
}
const read = (rel) => fs.readFileSync(path.join(checkout, rel), 'utf8')

const pkg = JSON.parse(read('package.json'))
const licence = read('LICENSE.md').replace(/\r\n/g, '\n').trimEnd()
const copyright = licence.split('\n').find((l) => l.startsWith('Copyright'))
if (!copyright) throw new Error('LICENSE.md has no copyright line')

// The dialect's building blocks, used by portable() below.
const WORD = 'A-Za-z0-9_'
// JavaScript's \s: WhiteSpace and LineTerminator (ECMA-262 §22.2.2.9). ICU's
// \s leaves out U+000B and U+FEFF, so the class is spelled out.
const SPACE = '\\t\\n\\u000b\\u000c\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff'
const BOUNDARY = `(?:(?<=[${WORD}])(?![${WORD}])|(?<![${WORD}])(?=[${WORD}]))`
const NON_BOUNDARY = `(?:(?<=[${WORD}])(?=[${WORD}])|(?<![${WORD}])(?![${WORD}]))`

// ---------------------------------------------------------------------------
// The plugin's own data, loaded the way the plugin loads it.

async function importSource(source) {
  const url = 'data:text/javascript;base64,' + Buffer.from(source).toString('base64')
  return (await import(url)).default
}
const rawSnippets = (await importSource(read('src/default_snippets.js'))).flat()
const rawVariables = await importSource(read('src/default_snippet_variables.js'))

// Variable keys may be written NAME or ${NAME}; both mean ${NAME}
// (parse.ts, parseSnippetVariables). Order is kept: substitution runs in it.
const variables = {}
for (const [name, value] of Object.entries(rawVariables)) {
  variables[name.startsWith('${') ? name : '${' + name + '}'] = value
}

/** A TypeScript array or object literal's string keys/items, read from source. */
function literalBlock(source, marker) {
  const at = source.indexOf(marker)
  if (at < 0) throw new Error('missing ' + marker)
  const open = source.slice(at).search(/[[{]/) + at
  const close = source.indexOf(source[open] === '[' ? '\n]' : '\n};', open)
  return source.slice(open + 1, close)
    .split('\n')
    .filter((line) => !/^\s*\/\//.test(line))
    .join('\n')
}
const macrosSource = read('src/snippets/luasnip_api/macros.ts')
const macros = [...literalBlock(macrosSource, 'export const ALL_MACROS').matchAll(/"((?:[^"\\]|\\.)*)"/g)]
  .map((m) => JSON.parse('"' + m[1] + '"'))

// The LaTeX grammar gives a command no arguments when its name is in the
// conceal maps (latex_tokens.ts, specializeCtrlSeq → SymbolCtrlSeq): that is
// why `\sqrt{x}` is a symbol followed by a plain group, and `\hat{x}` is a
// command with an argument. The lookup is `cmd_symbols[name] || greek[name]`
// on plain objects, so the names on Object.prototype count too.
const concealSource = read('src/editor_extensions/conceal_maps.ts')
const symbolNames = new Set()
for (const map of ['export const cmd_symbols', 'export const greek']) {
  for (const m of literalBlock(concealSource, map).matchAll(/^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"/gm)) {
    const name = JSON.parse('"' + m[1] + '"')
    if (/^[A-Za-z]+$/.test(name) && JSON.parse('"' + m[2] + '"') !== '') symbolNames.add(name)
  }
}
for (const name of Object.getOwnPropertyNames(Object.prototype)) {
  if (/^[A-Za-z]+$/.test(name)) symbolNames.add(name)
}

// Environment names the grammar gives a token of their own (latex_tokens.ts,
// specializeEnvName). A `\begin{…}` of one class is only closed by an
// `\end{…}` of the same class; otherwise, unless another environment holds
// it, the error recovery ends the environment right after `\end{` — which
// decides whether that name is snippet-less while it is being retyped.
const tokensSource = read('src/parser/mathjax/latex_tokens.ts')
const nameSet = (marker) => [...literalBlock(tokensSource, marker).matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((m) => JSON.parse('"' + m[1] + '"'))
const environmentClasses = {
  equation: nameSet('const equationEnvNames'),
  array: nameSet('const equationArrayEnvNames'),
}
if (!environmentClasses.equation.includes('matrix') || !environmentClasses.array.includes('pmatrix')) {
  throw new Error('latex_tokens.ts no longer lists the environment name classes where this script looks')
}

// ---------------------------------------------------------------------------
// Snippets, parsed and sorted as parse.ts and sort.ts do.

/** The five defaults whose replacement is code. The engines port each by
 * hand, so a changed body must stop the build rather than ship stale code. */
const FUNCTIONS = {
  autoSubscriptOrSpace: '4bc09a905d36',
  disableWhileTypingMacro: 'e357eca5c111',
  spaceAfterMacro: '8e894693adf6',
  identityMatrix: '0dc236b839d8',
  displayMathInList: '790b8384ce49',
}
const fingerprint = (fn) => crypto.createHash('sha256').update(fn.toString().replace(/\s+/g, '')).digest('hex').slice(0, 12)
function functionName(raw) {
  const t = raw.trigger instanceof RegExp ? raw.trigger.source : raw.trigger
  if (t === '(\\\\?)([A-Za-z]+)(\\d)') return 'autoSubscriptOrSpace'
  if (t === '\\\\[A-Za-z]{2,}') return raw.options.includes('U') ? 'disableWhileTypingMacro' : 'spaceAfterMacro'
  if (t === 'iden(\\d)') return 'identityMatrix'
  if (t.startsWith('(?<positive_lookbehind>')) return 'displayMathInList'
  throw new Error('Unknown function snippet ' + t + ': port it to both engines, then name it here.')
}

// src/snippets/environment.ts: triggers that never run inside some macros.
const EXCLUSIONS = { '([A-Za-z])(\\d)': [{ name: 'ce' }, { name: 'pu' }], '->': [{ name: 'ce' }] }

const substitute = (s) => Object.entries(variables).reduce((t, [k, v]) => t.replaceAll(k, v), s)
const macroList = (list = []) => list.map((m) => (typeof m === 'string' ? { name: m } : m))

const functionPrints = {}
const parsed = rawSnippets.map((raw, index) => {
  const options = raw.options
  const priority = raw.priority ?? 0
  const base = { id: index, options, priority }
  if (raw.description !== undefined) base.description = raw.description
  if (raw.flags) throw new Error(`snippet ${index}: flags are not supported by the portable dialect`)
  for (const unsupported of ['triggerAfter', 'triggerKey', 'language', 'excludedEnvironments', 'includedMacros']) {
    if (raw[unsupported] !== undefined) throw new Error(`snippet ${index}: ${unsupported} is not ported yet`)
  }
  let replacement
  if (typeof raw.replacement === 'function') {
    const name = functionName(raw)
    functionPrints[name] = fingerprint(raw.replacement)
    replacement = { function: name }
  } else {
    replacement = { replacement: raw.replacement }
  }
  const isRegex = options.includes('r') || raw.trigger instanceof RegExp
  if (isRegex) {
    const source = substitute(raw.trigger instanceof RegExp ? raw.trigger.source : raw.trigger)
    const excluded = [...(EXCLUSIONS[source] ?? []), ...macroList(raw.excludedMacros)]
    const compiled = new RegExp(`(?:${source})$`)
    const { pattern, groupNames } = portable(compiled.source)
    const entry = { ...base, kind: 'regex', trigger: source, pattern, ...replacement }
    if (groupNames.some((n) => n !== null)) entry.groupNames = groupNames
    if (excluded.length) entry.excludedMacros = excluded
    return { entry, length: compiled.source.length, compiled }
  }
  const trigger = substitute(raw.trigger)
  const excluded = [...(EXCLUSIONS[trigger] ?? []), ...macroList(raw.excludedMacros)]
  const visual = options.includes('v') ||
    (typeof raw.replacement === 'string' && raw.replacement.includes('${VISUAL}') && trigger.length <= 1)
  if (visual) {
    if (trigger.length !== 1) throw new Error(`snippet ${index}: a visual snippet needs a one-character trigger`)
    const entry = { ...base, kind: 'visual', key: trigger, ...replacement }
    if (excluded.length) entry.excludedMacros = excluded
    return { entry, length: 0 }
  }
  const entry = { ...base, kind: 'string', trigger, ...replacement }
  if (excluded.length) entry.excludedMacros = excluded
  return { entry, length: trigger.length }
})
const changed = Object.entries(functionPrints).filter(([name, print]) => FUNCTIONS[name] !== print)
if (changed.length) {
  throw new Error('These replacement functions changed: ' +
    changed.map(([name, print]) => `${name} (now ${print})`).join(', ') +
    '. Port the change to LSFunction (PaperCore/LatexSuite/LatexSuiteSnippets.swift) and the TypeScript engine, then update FUNCTIONS.')
}
// Array.prototype.sort is stable: ties keep file order (sort.ts).
const sorted = parsed.map((p, i) => ({ ...p, i }))
  .sort((a, b) => (b.entry.priority - a.entry.priority) || (b.length - a.length) || (a.i - b.i))
for (const s of sorted) s.entry.sortLength = s.length

// ---------------------------------------------------------------------------
// The portable regex dialect.


/**
 * Rewrites a JavaScript (non-`u`) pattern into the dialect both engines read
 * the same way: ASCII classes spelled out, `.` and the anchors as explicit
 * classes and lookarounds, literal braces escaped, named groups numbered (the
 * names travel beside the pattern — ICU does not allow `_` in them).
 */
function portable(source) {
  let out = ''
  const groupNames = []
  const groups = [] // open groups: does each contain a capture?
  const escapeNames = new Map()
  let i = 0
  const quantifierAt = (j) => {
    const c = source[j]
    if (c === '*' || c === '+') return true
    const m = /^\{(\d+)(,(\d*))?\}/.exec(source.slice(j))
    return !!m && (m[2] === undefined ? Number(m[1]) > 1 : m[3] === '' || Number(m[3]) > 1)
  }
  while (i < source.length) {
    const c = source[i]
    if (c === '\\') {
      const n = source[i + 1]
      i += 2
      if (n === 'd') out += '[0-9]'
      else if (n === 'D') out += '[^0-9]'
      else if (n === 'w') out += `[${WORD}]`
      else if (n === 'W') out += `[^${WORD}]`
      else if (n === 's') out += `[${SPACE}]`
      else if (n === 'S') out += `[^${SPACE}]`
      else if (n === 'b') out += BOUNDARY
      else if (n === 'B') out += NON_BOUNDARY
      else if (n === 'n' || n === 'r' || n === 't') out += '\\' + n
      else if (n === 'f') out += '\\u000c'
      else if (n === 'v') out += '\\u000b'
      else if (n === 'u' && /^[0-9a-fA-F]{4}$/.test(source.slice(i, i + 4))) { out += '\\u' + source.slice(i, i + 4); i += 4 }
      else if (n === 'x' && /^[0-9a-fA-F]{2}$/.test(source.slice(i, i + 2))) { out += '\\u00' + source.slice(i, i + 2); i += 2 }
      else if (n === 'k') throw new Error('named backreferences are not supported: ' + source)
      else if (/[1-9]/.test(n)) out += '\\' + n
      else if (/[A-Za-z0-9]/.test(n)) throw new Error(`\\${n} has no portable spelling: ${source}`)
      else if (n === '/') out += '/'
      else out += '\\' + n
    } else if (c === '[') {
      // In JavaScript the first `]` closes the class, even right after `[`.
      let j = i + 1
      let body = ''
      if (source[j] === '^') { body += '^'; j++ }
      if (source[j] === ']') {
        out += body === '^' ? '[\\s\\S]' : '(?!)'
        i = j + 1
        continue
      }
      while (j < source.length && source[j] !== ']') {
        const d = source[j]
        if (d === '\\') {
          const n = source[j + 1]
          j += 2
          if (n === 'd') body += '0-9'
          else if (n === 'w') body += WORD
          else if (n === 's') body += SPACE
          else if ('DWSbB'.includes(n)) throw new Error(`\\${n} inside a class has no portable spelling: ${source}`)
          else if (n === 'n' || n === 'r' || n === 't') body += '\\' + n
          else if (n === 'f') body += '\\u000c'
          else if (n === 'v') body += '\\u000b'
          else if (n === 'u' && /^[0-9a-fA-F]{4}$/.test(source.slice(j, j + 4))) { body += '\\u' + source.slice(j, j + 4); j += 4 }
          else if (/[A-Za-z0-9]/.test(n)) throw new Error(`\\${n} inside a class has no portable spelling: ${source}`)
          else body += '\\' + n
        } else if (d === '[' || d === '&' || d === '{' || d === '}') {
          // ICU reads `[` as a nested set and `&&` as intersection.
          body += '\\' + d
          j++
        } else {
          body += d
          j++
        }
      }
      if (source[j] !== ']') throw new Error('unterminated class: ' + source)
      out += '[' + body + ']'
      i = j + 1
    } else if (c === '(') {
      if (source.startsWith('(?:', i) || source.startsWith('(?=', i) || source.startsWith('(?!', i) ||
          source.startsWith('(?<=', i) || source.startsWith('(?<!', i)) {
        const head = source.startsWith('(?<', i) ? 4 : 3
        out += source.slice(i, i + head)
        i += head
        groups.push(false)
      } else if (source.startsWith('(?<', i)) {
        const end = source.indexOf('>', i)
        const name = source.slice(i + 3, end)
        escapeNames.set(name, groupNames.length + 1)
        groupNames.push(name)
        out += '('
        i = end + 1
        groups.push(true)
      } else if (source.startsWith('(?', i)) {
        throw new Error('unsupported group: ' + source)
      } else {
        groupNames.push(null)
        out += '('
        i++
        groups.push(true)
      }
    } else if (c === ')') {
      const captures = groups.pop()
      if (captures && quantifierAt(i + 1)) {
        // JavaScript clears a repeated group's captures on every pass; ICU keeps them.
        throw new Error('a capture inside a repeated group reads differently in ICU: ' + source)
      }
      if (captures && groups.length) groups[groups.length - 1] = true
      out += ')'
      i++
    } else if (c === '.') {
      out += '[^\\n\\r\\u2028\\u2029]'
      i++
    } else if (c === '$') {
      out += '(?![\\s\\S])'
      i++
    } else if (c === '^') {
      out += '(?<![\\s\\S])'
      i++
    } else if (c === '{') {
      const m = /^\{\d+(,\d*)?\}/.exec(source.slice(i))
      if (m) { out += m[0]; i += m[0].length } else { out += '\\{'; i++ }
    } else if (c === '}' || c === ']') {
      out += '\\' + c
      i++
    } else {
      out += c
      i++
    }
  }
  return { pattern: out, groupNames }
}

// ---------------------------------------------------------------------------
// Settings: DEFAULT_SETTINGS after processLatexSuiteSettings (settings.ts).

// The object literal is plain JavaScript once its two imports are stubbed out,
// so it is evaluated rather than picked apart: the escapes inside its strings
// and template literals then mean what they mean to the plugin.
const settingsFile = read('src/settings/settings.ts')
const settingsAt = settingsFile.indexOf('{', settingsFile.indexOf('export const DEFAULT_SETTINGS'))
const settingsEnd = settingsFile.indexOf('\n};', settingsAt)
const defaults = new Function('DEFAULT_SNIPPETS', 'DEFAULT_SNIPPET_VARIABLES',
  'return (' + settingsFile.slice(settingsAt, settingsEnd + 2) + ')')(null, null)
const list = (s) => s.replace(/\s/g, '').split(',')
const settings = {
  snippetsEnabled: defaults.snippetsEnabled,
  removeSnippetWhitespace: defaults.removeSnippetWhitespace,
  autoDelete$: defaults.autoDelete$,
  autofractionEnabled: defaults.autofractionEnabled,
  autofractionSymbol: defaults.autofractionSymbol,
  autofractionBreakingChars: defaults.autofractionBreakingChars,
  autofractionExcludedEnvs: JSON.parse(defaults.autofractionExcludedEnvs),
  matrixShortcutsEnabled: defaults.matrixShortcutsEnabled,
  matrixShortcutsEnvNames: list(defaults.matrixShortcutsEnvNames),
  matrixShortcutsMacroNames: list(defaults.matrixShortcutsMacroNames),
  taboutEnabled: defaults.taboutEnabled,
  taboutExitEquationOnlyOnEOL: defaults.taboutExitEquationOnlyOnEOL,
  taboutClosingSymbols: list(defaults.taboutClosingSymbols),
  autoEnlargeBrackets: defaults.autoEnlargeBrackets,
  autoEnlargeBracketsSpace: defaults.autoEnlargeBracketsSpace,
  autoEnlargeBracketsTriggers: list(defaults.autoEnlargeBracketsTriggers)
    .map((t) => (/[A-Za-z]+/.test(t) ? '\\' + t : t)),
  // run_snippets.ts turns the two characters `\n` into a newline before use.
  wordDelimiters: defaults.wordDelimiters.replace('\\n', '\n'),
  forceMathLanguages: list(defaults.forceMathLanguages),
}
for (const [key, value] of Object.entries(settings)) {
  if (value === undefined) throw new Error('DEFAULT_SETTINGS has no ' + key)
}

// ---------------------------------------------------------------------------
// Output.

const data = {
  header: {
    title: 'Latex Suite default snippets',
    source: 'https://github.com/artisticat1/obsidian-latex-suite',
    version: pkg.version,
    licence: 'MIT',
    copyright,
    credit: `Default LaTeX snippets and behaviour adapted from Latex Suite by artisticat1 (https://github.com/artisticat1/obsidian-latex-suite), MIT License, ${copyright}.`,
    licenceText: licence,
    generatedBy: 'Scripts/latex-suite-data.mjs — do not edit by hand; re-run it against a Latex Suite checkout.',
    format: [
      'snippets are in the order they are tried (priority descending, then trigger length descending, ties in file order — sort.ts); `sortLength` is the length that ordering used and `id` the index in src/default_snippets.js.',
      'kind "string": `trigger` must end the text before the caret plus the typed key. kind "visual": runs on `key` with a selection. kind "regex": `pattern` must match there; `trigger` is the original JavaScript source for reference only.',
      '`pattern` is already anchored at the end and written in a dialect NSRegularExpression and JavaScript RegExp (no flags) read the same way: no \\d \\w \\s \\b . ^ $, no named groups (their names are in `groupNames`, by group number starting at 1), literal braces escaped.',
      '`replacement` uses Latex Suite syntax ($n, ${n:text}, [[n]] for regex captures, ${VISUAL}); `function` names a replacement the engines implement by hand.',
      '`options` are Latex Suite option letters, unparsed (t m n M T c C A r v w U).',
      '`settings` are DEFAULT_SETTINGS after processLatexSuiteSettings. `macros` is ALL_MACROS. `symbolCommands` are the control words the LaTeX grammar gives no arguments. `environmentClasses` are the environment names the grammar gives tokens of their own (an `\\end{…}` must be of the same class as its `\\begin{…}`).',
    ],
  },
  settings,
  variables,
  snippets: sorted.map((s) => s.entry),
  macros,
  symbolCommands: [...symbolNames].sort(),
  environmentClasses,
}

/** One entry per line: the file is read by people in diffs, not only by code. */
function format(value) {
  const lines = ['{']
  const keys = Object.keys(value)
  keys.forEach((key, k) => {
    const v = value[key]
    const comma = k < keys.length - 1 ? ',' : ''
    if (Array.isArray(v)) {
      lines.push(`  ${JSON.stringify(key)}: [`)
      v.forEach((item, n) => lines.push('    ' + JSON.stringify(item) + (n < v.length - 1 ? ',' : '')))
      lines.push('  ]' + comma)
    } else {
      const body = JSON.stringify(v, null, 2).split('\n').map((l, n) => (n ? '  ' + l : l)).join('\n')
      lines.push(`  ${JSON.stringify(key)}: ${body}${comma}`)
    }
  })
  lines.push('}')
  return lines.join('\n') + '\n'
}

const resource = path.join(repoRoot, 'Packages/PaperTimeKit/Sources/PaperCore/Resources/LatexSuiteSnippets.json')
fs.mkdirSync(path.dirname(resource), { recursive: true })
fs.writeFileSync(resource, format(data))

// ---------------------------------------------------------------------------
// The regex fixture: what each original pattern matched, on inputs chosen to
// hit the places where the two dialects disagree.

const corpus = [
  // What the defaults are for.
  'x2', 'xy2', '\\alpha2', '\\leq1', '\\R1', 'x_{2}3', '\\alpha_{12}3', '\\hat{x}2', '\\hat{x}_{1}2',
  '\\dot{\\vec{a}}3', '\\dot{\\vec{a}}_{3}4', '\\hat{\\alpha}_{2}4', 'foo dm', 'a dm', '(a dm', 'foodm', 'dm',
  '- item dm', '1. item dm', '  - a dm', 'x\n  - a dm', '> - a dm', '> > dm', '- a\ndm', '12) b dm',
  '\n"', '\n   "', 'x\n\n  "', 'a"', '3rt', 'ee', 'xee', ' ee', '(ee', '_ee', 'alpha', ' alpha', '\\alpha', 'epsi',
  'xii', '\\xii', 'sin', 'xsin', '\\sin', 'arcsin', 'arcsec', 'arccot', 'exp', 'ln', '\\ln', 'det', 'xhat',
  'x,.', 'x.,', '\\alpha,.', '\\beta.,', '\\alpha hat', '\\alpha sr', '\\partial cb', '\\nabla rd', '\\theta und',
  'int', '\\int', 'aint', 'par2', 'parn', 'paxy', 'pmat', 'bmat', 'matrix', 'cases', 'align', 'array',
  'x beg', ' beg', '\\beg', 'xbeg', 'iden3', 'iden0', 'nexists', 'e\\xi sts', 'ne\\xi sts', '\\mathbb', '\\mathbbR',
  '\\sinx', '\\to', '\\top', '\\tox', '\\mathrm', 'a\\ce', 'context', 'epsilon', 'theta', 'omega', 'dagger',
  'propto', 'nabla', 'Re',
  // Where ICU and JavaScript part ways.
  'é2', 'ß2', 'Ωhat', 'ǅhat', '٣rt', 'x١', '١2', 'x²', ' dm', 'x dm', ' "', '\n "',
  'x\u0085dm', '\u0085"', 'a\u000bdm', '\n\u000b"', 'a﻿dm', '\n﻿"', 'a​dm', '日本dm', '日本 dm',
  'é dm', 'éee', 'ée', 'éee', '_́ee', '- é dm', '- a dm', '1. a dm', ' - a dm',
  'a\r\n- b dm', 'x\r"', '٠rt', '১rt', 'Ⅳ2', 'ⅷhat', 'ℏ2', 'µ2', 'ǆ2', '\\αhat', 'x\n',
  'x_{١}2', '\\hat{é}2', 'a　dm', 'kKdm',
  // Characters outside the BMP: ICU reads a surrogate pair as one character,
  // JavaScript (without `u`) as two, so a class like [^\\] starts the match
  // somewhere else unless the engine hides the pairs from ICU.
  '😀alpha', '😀 dm', 'a 😀dm', '😀dm', '𝑥2', '😀sin', 'x😀hat', '- 😀 dm', '😀\n"', '\\😀2', '😀,.', '\\alpha😀',
]
const cases = []
for (const s of sorted) {
  if (s.entry.kind !== 'regex') continue
  // `d` only adds the capture offsets; it changes nothing about the match.
  // Offsets rather than the captured text, because a capture can be half a
  // surrogate pair, and no JSON decoder has to accept that as a string.
  const original = new RegExp(s.compiled.source, s.compiled.flags + 'd')
  const rewritten = new RegExp(s.entry.pattern, 'd')
  const matches = []
  corpus.forEach((text, index) => {
    const a = original.exec(text)
    const b = rewritten.exec(text)
    const shape = (m) => (m ? [m.index, ...m.indices.slice(1).map((r) => r ?? null)] : null)
    if (JSON.stringify(shape(a)) !== JSON.stringify(shape(b))) {
      throw new Error(`the rewritten pattern of snippet ${s.entry.id} reads ${JSON.stringify(text)} differently`)
    }
    if (a) matches.push([index, ...shape(a)])
  })
  cases.push({ id: s.entry.id, matches })
}
const fixture = {
  header: {
    title: 'Latex Suite regex dialect fixture',
    note: 'For every regex snippet (`id` as in LatexSuiteSnippets.json), the inputs of `corpus` its original JavaScript pattern matched, as [corpus index, match index, [from, to] of capture 1, of capture 2, …] in UTF-16 units (null for a group that did not take part). Every input not listed did not match. The rewritten `pattern` gives the same answer in JavaScript (the generator checks) and in NSRegularExpression once each surrogate is shown to it as U+FFFD (the Swift test checks). Generated by Scripts/latex-suite-data.mjs from Latex Suite ' + pkg.version + '.',
  },
  corpus,
  cases,
}
const fixturePath = path.join(repoRoot, 'Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/latex-suite-regex.json')
fs.mkdirSync(path.dirname(fixturePath), { recursive: true })
fs.writeFileSync(fixturePath, JSON.stringify(fixture, null, 1) + '\n')

console.log(`${data.snippets.length} snippets, ${macros.length} macros, ${data.symbolCommands.length} symbol commands, ` +
  `${cases.length} regex patterns checked against ${corpus.length} inputs`)
