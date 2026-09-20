/**
 * Writing the files Swift writes, byte for byte.
 *
 * The library folder is shared — the same folder is opened on a Mac, on
 * Windows and on Linux, often through a cloud drive. If this port wrote the
 * same record with different spacing, every file it touched would come back
 * to the Mac as a whole-file change: a noisy diff, a pointless sync, and a
 * conflict where there was none. So the output here matches Swift's
 * `JSONEncoder` with `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`
 * exactly, down to the space before the colon and the blank line inside an
 * empty array.
 *
 * Two date shapes, because Swift uses two:
 *  - the library's records (`library.json`, `meta.json`, `state.json`) go
 *    through `JSONCoding`, which is `.iso8601` — `"2026-09-19T06:21:28Z"`.
 *  - the sketch sidecars and the `/PTSketch` payload use a plain `JSONEncoder`,
 *    whose default is `.deferredToDate`: seconds since 2001-01-01 UTC.
 * Getting these the wrong way round would not fail loudly; it would silently
 * date every drawing to 1970 or 2057. Hence two named functions and no default.
 */

/** Seconds between the Unix epoch and Apple's reference date, 2001-01-01. */
export const APPLE_EPOCH_OFFSET = 978307200

/** A `Date` as Swift's default strategy writes it: seconds since 2001-01-01. */
export function appleTimestamp(date: Date): number {
  return date.getTime() / 1000 - APPLE_EPOCH_OFFSET
}

/** The inverse: an Apple reference-date number back to a `Date`. */
export function dateFromAppleTimestamp(seconds: number): Date {
  return new Date((seconds + APPLE_EPOCH_OFFSET) * 1000)
}

/**
 * A `Date` as `.iso8601` writes it — whole seconds, `Z`, no fraction.
 * `toISOString()` always includes milliseconds, which Swift's plain `.iso8601`
 * never does, so the fraction is cut rather than rounded.
 */
export function isoTimestamp(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

/** Reads either shape of ISO date, with or without a fraction, as Swift does. */
export function dateFromISO(raw: string): Date {
  const parsed = new Date(raw)
  if (Number.isNaN(parsed.getTime())) throw new Error(`Unrecognised date: ${raw}`)
  return parsed
}

type Json = null | boolean | number | string | Json[] | { [key: string]: Json }

/**
 * Serialises with Swift's pretty-printing rather than `JSON.stringify`'s.
 *
 * The differences are small and all of them matter for a clean diff:
 * two-space indent (same), `" : "` between key and value (not `": "`), keys
 * sorted by their UTF-8 bytes, and an empty array or object written open
 * bracket, blank line, closing bracket at the parent's indent.
 */
export function encodeSwiftJSON(value: unknown): string {
  // No trailing newline: `JSONEncoder` writes none, and a file that differed
  // by one byte would be a change to every sync client that saw it.
  return write(value as Json, 0)
}

function write(value: Json, depth: number): string {
  const pad = '  '.repeat(depth)
  const inner = '  '.repeat(depth + 1)
  if (value === null) return 'null'
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  if (typeof value === 'number') return writeNumber(value)
  if (typeof value === 'string') return writeString(value)
  if (Array.isArray(value)) {
    if (value.length === 0) return `[\n\n${pad}]`
    const parts = value.map((item) => inner + write(item, depth + 1))
    return `[\n${parts.join(',\n')}\n${pad}]`
  }
  // `undefined` members are dropped, the way a nil Optional is simply absent.
  const keys = Object.keys(value)
    .filter((key) => value[key] !== undefined)
    .sort(compareUTF8)
  if (keys.length === 0) return `{\n\n${pad}}`
  const parts = keys.map((key) => `${inner}${writeString(key)} : ${write(value[key], depth + 1)}`)
  return `{\n${parts.join(',\n')}\n${pad}}`
}

/**
 * Swift sorts keys by their UTF-8 bytes, which for anything above ASCII is not
 * JavaScript's default UTF-16 code-unit order. Compare the encoded bytes.
 */
const utf8 = new TextEncoder()
function compareUTF8(a: string, b: string): number {
  if (a === b) return 0
  const left = utf8.encode(a)
  const right = utf8.encode(b)
  const shared = Math.min(left.length, right.length)
  for (let i = 0; i < shared; i += 1) {
    if (left[i] !== right[i]) return left[i] - right[i]
  }
  return left.length - right.length
}

function writeNumber(value: number): string {
  if (!Number.isFinite(value)) throw new Error(`Cannot write ${value} as JSON`)
  // Both sides are IEEE-754 doubles printed at shortest round-trip precision,
  // so this agrees with Swift for every value either can hold — including the
  // 700.0000000000009 that a drag through a zoomed page produces.
  return Object.is(value, -0) ? '-0' : String(value)
}

const ESCAPES: Record<string, string> = {
  '"': '\\"',
  '\\': '\\\\',
  '\n': '\\n',
  '\r': '\\r',
  '\t': '\\t',
  '\b': '\\b',
  '\f': '\\f',
}

/**
 * `.withoutEscapingSlashes` means `/` stays a slash; non-ASCII stays itself,
 * as UTF-8. Only the seven named escapes and the other control characters are
 * written as escapes, which is what Swift does.
 */
function writeString(value: string): string {
  let out = '"'
  for (const character of value) {
    const escape = ESCAPES[character]
    if (escape) {
      out += escape
      continue
    }
    const code = character.codePointAt(0)!
    if (code < 0x20) {
      out += `\\u${code.toString(16).padStart(4, '0')}`
    } else {
      out += character
    }
  }
  return out + '"'
}

/** A lowercase UUID string as Swift writes it: uppercase, hyphenated. */
export function uuidString(value: string): string {
  return value.toUpperCase()
}

/** A fresh UUID in Swift's uppercase spelling. */
export function makeUUID(): string {
  return crypto.randomUUID().toUpperCase()
}
