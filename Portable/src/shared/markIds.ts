/**
 * Another reader's mark, named by where it is — the Mac's
 * `TextMarkupWriter.derivedIdentifier(of:pageIndex:)` and `uuid(from:)`.
 *
 * A highlight Preview or Acrobat made has no identifier of ours. Both builds
 * name it by its subtype, its page and its rectangle rounded to the point, and
 * turn that into a UUID the same way, so a removal journaled on one desktop
 * finds the same mark on the other — and a name built from an annotation's
 * place in the page's list, which shifted whenever one was added, found
 * nothing.
 */

const MASK = (1n << 64n) - 1n

/** Swift's `rounded()`: half away from zero, not JavaScript's half up. */
function swiftRound(value: number): number {
  return value < 0 ? -Math.round(-value) : Math.round(value)
}

/** A UUID that depends only on the text given (FNV-1a twice, v4 stamped). */
export function uuidFromSeed(seed: string): string {
  let low = 0xcbf29ce484222325n
  let high = 0x9e3779b97f4a7c15n
  for (const byte of new TextEncoder().encode(seed)) {
    low = ((low ^ BigInt(byte)) * 0x100000001b3n) & MASK
    high = ((high + BigInt(byte)) * 0x9e3779b97f4a7c15n) & MASK
    high ^= high >> 29n
  }
  const bytes: number[] = []
  for (let shift = 56n; shift >= 0n; shift -= 8n) bytes.push(Number((low >> shift) & 0xffn))
  for (let shift = 56n; shift >= 0n; shift -= 8n) bytes.push(Number((high >> shift) & 0xffn))
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = bytes.map((one) => one.toString(16).padStart(2, '0')).join('').toUpperCase()
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

/** The identifier of a markup another reader made: `Subtype|page|x|y|w|h`. */
export function derivedMarkID(subtype: string, pageIndex: number, box: { x: number; y: number; width: number; height: number }): string {
  const seed = `${subtype}|${pageIndex}|${swiftRound(box.x)}|${swiftRound(box.y)}|${swiftRound(box.width)}|${swiftRound(box.height)}`
  return uuidFromSeed(seed)
}
