/**
 * Swift's strings, as MathReader leans on them. The Mac walks a token a
 * `Character` (a grapheme) at a time, asks each one what it is by its first
 * scalar, and compares strings by canonical equivalence — so a dictionary
 * keyed by "Ω" answers for the ohm sign, and a string that ends in a letter
 * with an accent mark on it ends in a letter. JavaScript does none of that by
 * habit; these do it the Mac's way, and do nothing extra for the ASCII that
 * almost every token is.
 */
import { graphemes } from '../textFold.js'
import { isLetter, isNumber, isWhitespace } from '../metadata/chars.js'

export { isLetter, isNumber, isWhitespace }

/** Plain ASCII with no carriage return: one code unit, one Character. */
const simple = (text: string) => {
  for (let at = 0; at < text.length; at += 1) {
    const unit = text.charCodeAt(at)
    if (unit >= 0x80 || unit === 0x0d) return false
  }
  return true
}

/** The string's Characters. */
export function chars(text: string): string[] {
  return simple(text) ? text.split('') : graphemes(text)
}

/** `String.count`. */
export function count(text: string): number {
  return simple(text) ? text.length : graphemes(text).length
}

/** `String.first`. */
export function firstChar(text: string): string | undefined {
  if (text === '') return undefined
  if (text.length === 1 || simple(text.slice(0, 2))) return text[0]
  return graphemes(text)[0]
}

/** `String.last`. */
export function lastChar(text: string): string | undefined {
  return lastChars(text, 1)[0]
}

/** The last `n` Characters, first to last. The tail is looked at alone
 *  when a grapheme cannot reach into it from before: three plain code units
 *  are three Characters whatever precedes them. */
export function lastChars(text: string, n: number): string[] {
  if (text.length > n && simple(text.slice(-(n + 1)))) return text.slice(-n).split('')
  const all = chars(text)
  return all.slice(Math.max(0, all.length - n))
}

/**
 * The form two canonically equivalent strings share — how the Mac compares
 * and hashes them. Everything below U+0300 is its own normal form, and so
 * is every token of a TeX paper but the odd one.
 */
export function canon(text: string): string {
  for (let at = 0; at < text.length; at += 1) {
    if (text.charCodeAt(at) >= 0x300) return text.normalize('NFC')
  }
  return text
}

/** `==` between two strings. */
export const same = (a: string, b: string) => a === b || canon(a) === canon(b)

/** A table keyed the way a Swift dictionary is. */
export function keyed<T>(entries: Iterable<[string, T]>): Map<string, T> {
  const map = new Map<string, T>()
  for (const [key, value] of entries) map.set(canon(key), value)
  return map
}

/** A set of strings, looked up by canonical equivalence. */
export function stringSet(values: Iterable<string>): { has(value: string): boolean } {
  const set = new Set<string>()
  for (const value of values) set.add(canon(value))
  return { has: (value: string) => set.has(canon(value)) }
}

/** Swift's `split(separator:)`: the pieces, with the empty ones left out. */
export function splitOmittingEmpty(text: string, separator: string): string[] {
  return text.split(separator).filter((piece) => piece !== '')
}

/** `trimmingCharacters(in: CharacterSet(charactersIn: set))`, for a set of
 *  a few plain characters. */
export function trimSet(text: string, set: string): string {
  let from = 0
  let to = text.length
  while (from < to && set.includes(text[from])) from += 1
  while (to > from && set.includes(text[to - 1])) to -= 1
  return text.slice(from, to)
}

/** Every Character is an ASCII letter (`$0.isASCII && $0.isLetter`). */
export const allASCIILetters = (text: string) => /^[A-Za-z]*$/.test(text)
