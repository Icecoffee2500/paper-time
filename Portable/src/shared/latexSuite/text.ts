/**
 * UTF-16 code units, the unit every offset in this engine is counted in.
 *
 * Latex Suite is JavaScript, where a string *is* its UTF-16 code units, and the
 * Mac engine counts in the same units because NSRange does. Here the string is
 * used as it is: `charCodeAt` is the unit, `slice` the copy. This is the
 * TypeScript half of `LatexSuiteText.swift`.
 */

export const NEWLINE = 10
export const BACKSLASH = 92
export const DOLLAR = 36

/** A half-open range of offsets, `from` included and `to` not. */
export interface Span {
  from: number
  to: number
}

export const span = (from: number, to: number): Span => ({ from, to })
export const isEmpty = (r: Span) => r.to <= r.from
export const sameSpan = (a: Span, b: Span) => a.from === b.from && a.to === b.to

/** Swift's `Range.overlaps`: an element in common, so an empty range overlaps nothing. */
export function overlaps(a: Span, b: Span): boolean {
  return !(b.to <= a.from || a.to <= b.from || isEmpty(a) || isEmpty(b))
}

export function clamped(r: Span, count: number): Span {
  const from = Math.min(Math.max(r.from, 0), count)
  const to = Math.min(Math.max(r.to, from), count)
  return { from, to }
}

/**
 * JavaScript's `\s` and what `trim()` removes (ECMA-262 WhiteSpace and
 * LineTerminator). Spelled out rather than asked of a regular expression,
 * because the Mac engine spells it out too and the two must agree unit by unit.
 */
export function isSpace(c: number): boolean {
  return (c >= 0x09 && c <= 0x0d) || c === 0x20 || c === 0xa0 || c === 0x1680
    || (c >= 0x2000 && c <= 0x200a) || c === 0x2028 || c === 0x2029 || c === 0x202f
    || c === 0x205f || c === 0x3000 || c === 0xfeff
}

/** lezer-markdown's `space()`: the four characters its block and inline parsers skip. */
export const isMarkdownSpace = (c: number) => c === 32 || c === 9 || c === 10 || c === 13
export const isASCIILetter = (c: number) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
export const isDigit = (c: number) => c >= 48 && c <= 57
/** JavaScript's `\w` without the `u` flag. */
export const isWord = (c: number) => isASCIILetter(c) || isDigit(c) || c === 95

/** `slice` with the bounds clamped the way the Swift engine clamps them. */
export function slice(s: string, from: number, to: number): string {
  const lower = Math.max(0, Math.min(from, s.length))
  const upper = Math.max(lower, Math.min(to, s.length))
  return upper > lower ? s.slice(lower, upper) : ''
}

/** Whether `prefix` sits at `index` — false outside the string, where `startsWith` would clamp. */
export function hasPrefixAt(s: string, prefix: string, index: number): boolean {
  if (index < 0 || index + prefix.length > s.length) return false
  return s.startsWith(prefix, index)
}

/** JavaScript's `trimEnd()`, spelled with the same space set as above. */
export function trimmingEnd(s: string): string {
  let end = s.length
  while (end > 0 && isSpace(s.charCodeAt(end - 1))) end -= 1
  return s.slice(0, end)
}

export function isAllSpace(s: string, from = 0, to = s.length): boolean {
  const upper = Math.min(to, s.length)
  for (let i = Math.max(0, from); i < upper; i += 1) {
    if (!isSpace(s.charCodeAt(i))) return false
  }
  return true
}

/**
 * Where the line holding `p` starts: just after the newline before it. By
 * `lastIndexOf`, not a step at a time — a note that is one long paragraph is
 * twenty thousand steps, and the engine asks this on every keystroke.
 */
export function lineStartOf(s: string, p: number): number {
  const i = Math.min(Math.max(0, p), s.length)
  return i === 0 ? 0 : s.lastIndexOf('\n', i - 1) + 1
}

/** Where the line holding `p` ends: at the newline after it, or the end of the text. */
export function lineEndOf(s: string, p: number): number {
  const i = Math.max(0, p)
  if (i >= s.length) return i
  const n = s.indexOf('\n', i)
  return n === -1 ? s.length : n
}

export const isHighSurrogate = (u: number) => (u & 0xfc00) === 0xd800
export const isLowSurrogate = (u: number) => (u & 0xfc00) === 0xdc00
