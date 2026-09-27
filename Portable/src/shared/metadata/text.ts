/**
 * `TextNormalization` and `StringSimilarity` (PaperCore), for the metadata
 * port. The fold and Jaro–Winkler were already ported for search; this adds
 * what the pipeline reads titles with.
 */

import { foldTitle } from '../textFold.js'
import { jaroWinkler } from '../searchRank.js'
import { graphemes, isNewline, isNumber, isLowercase, isWhitespace } from './chars.js'

export { foldTitle as foldedTitle, jaroWinkler }

/** `collapsingWhitespace`: runs of white space as one space, none at the
 *  ends — `split(whereSeparator: \.isWhitespace)`, a grapheme at a time. */
export function collapsingWhitespace(raw: string): string {
  const words: string[] = []
  let word = ''
  for (const character of graphemes(raw)) {
    if (isWhitespace(character)) {
      if (word) words.push(word)
      word = ''
    } else word += character
  }
  if (word) words.push(word)
  return words.join(' ')
}

/** `repairingHyphenation`: «infor-\nmation» joined, «state-of-the-art» left
 *  — only when the hyphen is followed by a line break and a lowercase letter. */
export function repairingHyphenation(raw: string): string {
  const characters = graphemes(raw)
  let result = ''
  let index = 0
  while (index < characters.length) {
    const character = characters[index]
    if (character === '-') {
      let lookahead = index + 1
      let sawNewline = false
      while (lookahead < characters.length && isWhitespace(characters[lookahead])) {
        if (isNewline(characters[lookahead])) sawNewline = true
        lookahead += 1
      }
      if (sawNewline && lookahead < characters.length && isLowercase(characters[lookahead])) {
        index = lookahead
        continue
      }
    }
    result += character
    index += 1
  }
  return result
}

/** `titleSimilarity`: Jaro–Winkler of the two folded titles. */
export function titleSimilarity(lhs: string, rhs: string): number {
  return jaroWinkler(foldTitle(lhs), foldTitle(rhs))
}

/** `CSLDate.firstYear(in:)`: the first run of four digits between 1500 and
 *  2200 — a sliding window, so «12345» finds 2345. */
export function firstYear(text: string): number | undefined {
  let digits: string[] = []
  for (const character of graphemes(text)) {
    if (isNumber(character)) {
      digits.push(character)
      if (digits.length === 4) {
        const value = swiftInt(digits.join(''))
        if (value !== undefined && value >= 1500 && value <= 2200) return value
        digits = digits.slice(1)
      }
    } else digits = []
  }
  return undefined
}

/** `Int(String)`: ASCII digits only, with an optional sign. */
export function swiftInt(text: string): number | undefined {
  return /^[+-]?[0-9]+$/.test(text) ? Number(text) : undefined
}
