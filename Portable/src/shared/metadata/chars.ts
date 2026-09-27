/**
 * Swift's `Character` properties, for the metadata port. The pipeline walks
 * text a Character (a grapheme) at a time and asks each one what it is; these
 * answer the way Swift does — from the grapheme's first scalar, with the
 * Unicode property Swift reads, not the one a JavaScript habit would reach
 * for (`\s` is not White_Space, `\p{N}` is not Numeric_Type).
 */

import { graphemes } from '../textFold.js'

export { graphemes }

/** Scalars with a numeric value outside the N categories — the Han numerals
 *  and a few cuneiform signs (`numericType != nil`), listed from Swift. */
const HAN_NUMBERS: (number | [number, number])[] = [
  0x3405, 0x3483, 0x382A, 0x3B4D, 0x4E00, 0x4E03, 0x4E07, 0x4E09, 0x4E24, 0x4E5D, 0x4E8C, 0x4E94, 0x4E96, 0x4EAC,
  [0x4EBF, 0x4EC0], 0x4EDF, 0x4EE8, 0x4F0D, 0x4F70, 0x4FE9, 0x5006, 0x5104, 0x5146, 0x5169, 0x516B, 0x516D, 0x5341,
  [0x5343, 0x5345], 0x534C, [0x53C1, 0x53C4], 0x56DB, 0x58F1, 0x58F9, 0x5E7A, [0x5EFE, 0x5EFF], [0x5F0C, 0x5F0E],
  0x5F10, 0x62D0, 0x62FE, 0x634C, 0x67D2, 0x6D1E, 0x6F06, 0x7396, 0x767E, 0x7695, 0x79ED, 0x8086, 0x842C, 0x8CAE,
  0x8CB3, 0x8D30, 0x920E, 0x94A9, 0x9621, 0x9646, 0x964C, 0x9678, 0x96F6, 0xF96B, 0xF973, 0xF978, 0xF9B2, 0xF9D1,
  0xF9D3, 0xF9FD, [0x12038, 0x12039], 0x12079, 0x12226, 0x1222B, 0x1230B, 0x1230D, 0x12399, 0x20001, 0x20064,
  0x200E2, 0x20121, 0x2092A, 0x20983, 0x2098C, 0x2099C, 0x20AEA, 0x20AFD, 0x20B19, 0x22390, 0x22998, 0x23B1B,
  0x2626D, 0x2F890,
]
const HAN_NUMBER_SET = new Set(HAN_NUMBERS.flatMap((one) => {
  if (typeof one === 'number') return [one]
  const out: number[] = []
  for (let value = one[0]; value <= one[1]; value += 1) out.push(value)
  return out
}))

const first = (character: string): number => character.codePointAt(0) ?? 0
const firstScalar = (character: string): string => String.fromCodePoint(first(character))

/** `Character.isNumber`: the first scalar has a numeric type. */
export function isNumber(character: string): boolean {
  if (!character) return false
  return /\p{N}/u.test(firstScalar(character)) || HAN_NUMBER_SET.has(first(character))
}

/** `Character.isLetter`: the first scalar is Alphabetic. */
export function isLetter(character: string): boolean {
  return !!character && /\p{Alphabetic}/u.test(firstScalar(character))
}

/** `Character.isWhitespace`: the first scalar is White_Space. */
export function isWhitespace(character: string): boolean {
  return !!character && /\p{White_Space}/u.test(firstScalar(character))
}

const NEWLINES = new Set([0x0a, 0x0b, 0x0c, 0x0d, 0x85, 0x2028, 0x2029])

/** `Character.isNewline`: a line break, «\r\n» included. */
export function isNewline(character: string): boolean {
  return !!character && NEWLINES.has(first(character))
}

/** `Character.isUppercase`: one scalar with Uppercase, or a cluster that
 *  uppercases to itself and lowercases to something else. */
export function isUppercase(character: string): boolean {
  if (!character) return false
  if ([...character].length === 1) return /\p{Uppercase}/u.test(character)
  return character.toUpperCase() === character && character.toLowerCase() !== character
}

/** `Character.isLowercase`, the other way round. */
export function isLowercase(character: string): boolean {
  if (!character) return false
  if ([...character].length === 1) return /\p{Lowercase}/u.test(character)
  return character.toLowerCase() === character && character.toUpperCase() !== character
}

/** `isASCII && isLetter`. */
export function isASCIILetter(character: string): boolean {
  return /^[A-Za-z]$/.test(character)
}
