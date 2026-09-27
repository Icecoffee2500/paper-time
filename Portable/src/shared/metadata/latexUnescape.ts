/**
 * `LaTeXEscaping.unescape` (Bibliography): LaTeX markup back into plain
 * Unicode — for a registrar's title filed with `$\pi_0$` or `{\"o}` in it.
 *
 * The reverse tables are derived from the same generated table the export
 * escapes with (`latexTable.ts`, itself read out of `LaTeXEscaping.swift`),
 * the way the Swift side derives them from its own dictionaries, so escaping
 * and unescaping cannot drift apart.
 */

import { LATEX_ESCAPES } from '../latexTable.js'
import { graphemes, isASCIILetter } from './chars.js'

const GREEK = /^\$\\([A-Za-z]+)\$$/

/** `bareCommandWord`: `aa` from `{\aa}`, `textdegree` from `\textdegree{}`. */
function bareCommandWord(latex: string): string | undefined {
  let body = latex
  if (body.length >= 2 && body.startsWith('{') && body.endsWith('}')) body = body.slice(1, -1)
  if (!body.startsWith('\\')) return undefined
  body = body.slice(1)
  if (body.endsWith('{}')) body = body.slice(0, -2)
  return body && /^[A-Za-z]+$/.test(body) ? body : undefined
}

/** `markLetterKey`: `'e` from `{\'e}`, `cc` from `{\c c}`. */
function markLetterKey(latex: string): string | undefined {
  let body = latex
  if (body.length >= 2 && body.startsWith('{') && body.endsWith('}')) body = body.slice(1, -1)
  if (!body.startsWith('\\')) return undefined
  body = body.slice(1)
  if (!body) return undefined
  const space = body.indexOf(' ')
  if (space >= 0) {
    const rest = body.slice(space + 1)
    return rest.length === 1 && isASCIILetter(rest) ? body.slice(0, space) + rest : undefined
  }
  if (isASCIILetter(body[0])) return undefined
  const rest = body.slice(1)
  return rest.length === 1 && isASCIILetter(rest) ? body[0] + rest : undefined
}

const ARGUMENTLESS = new Map<string, string>()
const MARK_LETTER = new Map<string, string>()
const GREEK_NAMES = new Map<string, string>()
for (const [character, latex] of Object.entries(LATEX_ESCAPES)) {
  const greek = GREEK.exec(latex)
  if (greek) {
    GREEK_NAMES.set(greek[1], character)
    continue
  }
  const word = bareCommandWord(latex)
  if (word) ARGUMENTLESS.set(word, character)
  const key = markLetterKey(latex)
  if (key) MARK_LETTER.set(key, character)
}

const MARKS = new Set(["'", '`', '^', '"', '~', '=', '.'])
const LETTER_MARKS = new Set(['u', 'v', 'k', 'H', 'd', 'c', 'r'])
const DIRECT = new Set(['&', '%', '$', '#', '_'])

function matchGreek(chars: string[], i: number): [string, number] | undefined {
  if (i + 1 >= chars.length || chars[i + 1] !== '\\') return undefined
  let j = i + 2
  let name = ''
  while (j < chars.length && isASCIILetter(chars[j])) name += chars[j++]
  const character = GREEK_NAMES.get(name)
  if (j >= chars.length || chars[j] !== '$' || character === undefined) return undefined
  return [character, j + 1]
}

function handleBackslashAt(chars: string[], backslash: number): [string, number] | undefined {
  const idx = backslash + 1
  if (idx >= chars.length) return undefined
  if (chars[idx] === '{') return ['\uE002', idx + 1]
  if (chars[idx] === '}') return ['\uE003', idx + 1]
  if (DIRECT.has(chars[idx])) return [chars[idx], idx + 1]

  let wordEnd = idx
  while (wordEnd < chars.length && isASCIILetter(chars[wordEnd])) wordEnd += 1
  const word = chars.slice(idx, wordEnd).join('')
  const replacement = ARGUMENTLESS.get(word)
  if (replacement !== undefined) {
    let end = wordEnd
    if (end + 1 < chars.length && chars[end] === '{' && chars[end + 1] === '}') end += 2
    return [replacement, end]
  }

  let mark: string
  let markEnd: number
  if (MARKS.has(chars[idx])) {
    mark = chars[idx]
    markEnd = idx + 1
  } else if (wordEnd > idx && LETTER_MARKS.has(word)) {
    mark = word
    markEnd = wordEnd
  } else return undefined

  let arg = markEnd
  if (arg < chars.length && chars[arg] === ' ') arg += 1
  let braced = false
  if (arg < chars.length && chars[arg] === '{') {
    braced = true
    arg += 1
  }
  if (arg >= chars.length || !isASCIILetter(chars[arg])) return undefined
  const letter = chars[arg]
  let end = arg + 1
  if (braced) {
    if (end >= chars.length || chars[end] !== '}') return undefined
    end += 1
  }
  const accented = MARK_LETTER.get(mark + letter)
  return accented === undefined ? undefined : [accented, end]
}

/** Plain Unicode from LaTeX markup. */
export function unescapeLaTeX(latex: string): string {
  const text = latex.replaceAll('---', '—').replaceAll('--', '–')
  const chars = graphemes(text)
  let result = ''
  let i = 0
  const shielded: boolean[] = []
  let nextShielded = false
  while (i < chars.length) {
    const c = chars[i]
    if (c === '$') {
      const greek = matchGreek(chars, i)
      if (greek) {
        result += greek[0]
        i = greek[1]
        nextShielded = false
        continue
      }
    }
    if (c === '{' && i + 1 < chars.length && chars[i + 1] === '\\') {
      const handled = handleBackslashAt(chars, i + 1)
      if (handled) {
        let end = handled[1]
        if (end < chars.length && chars[end] === '}') end += 1
        result += handled[0]
        i = end
        nextShielded = false
        continue
      }
    }
    if (c === '\\') {
      const handled = handleBackslashAt(chars, i)
      if (handled) {
        result += handled[0]
        i = handled[1]
        nextShielded = false
        continue
      }
      result += '\\'
      let j = i + 1
      while (j < chars.length && isASCIILetter(chars[j])) result += chars[j++]
      i = j
      nextShielded = true
      continue
    }
    if (c === '{') {
      shielded.push(nextShielded)
      result += nextShielded ? '\uE000' : '{'
      nextShielded = false
      i += 1
      continue
    }
    if (c === '}') {
      const was = shielded.pop() ?? false
      result += was ? '\uE001' : '}'
      nextShielded = false
      i += 1
      continue
    }
    nextShielded = false
    result += c
    i += 1
  }
  return result
    .replaceAll('{', '').replaceAll('}', '')
    .replaceAll('\uE000', '{').replaceAll('\uE001', '}')
    .replaceAll('\uE002', '{').replaceAll('\uE003', '}')
    .replaceAll('``', '“').replaceAll("''", '”')
}
