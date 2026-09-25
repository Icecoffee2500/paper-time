/**
 * IEEE half precision, as the vector cache stores it.
 *
 * The Mac narrows with vImage, which rounds to nearest, ties to even, and
 * flushes nothing: a value too small for a normal half becomes a subnormal
 * one, and one too large becomes infinity. This does the same, bit for bit,
 * so a store written here reads back on the Mac as the same numbers.
 */

const f32 = new Float32Array(1)
const u32 = new Uint32Array(f32.buffer)

/** The 16-bit pattern nearest to `value`. */
export function toHalf(value: number): number {
  f32[0] = value
  const bits = u32[0]
  const sign = (bits >>> 16) & 0x8000
  const exponent = (bits >>> 23) & 0xff
  const mantissa = bits & 0x7fffff
  if (exponent === 0xff) {
    // Infinity, or NaN with its payload kept.
    return sign | 0x7c00 | (mantissa ? 0x200 | (mantissa >>> 13) : 0)
  }
  // Unbias for single, rebias for half.
  const e = exponent - 127 + 15
  if (e >= 0x1f) return sign | 0x7c00
  if (e <= 0) {
    // A subnormal half, or zero. The whole 24-bit significand shifts right
    // and what falls off decides the rounding.
    if (e < -10) return sign
    const significand = mantissa | 0x800000
    const shift = 14 - e
    const half = significand >>> shift
    const remainder = significand & ((1 << shift) - 1)
    const halfway = 1 << (shift - 1)
    if (remainder > halfway || (remainder === halfway && (half & 1))) return sign | (half + 1)
    return sign | half
  }
  let half = sign | (e << 10) | (mantissa >>> 13)
  const remainder = mantissa & 0x1fff
  // Rounding up may carry into the exponent — and from the largest normal
  // into infinity — which is what adding 1 to the pattern does.
  if (remainder > 0x1000 || (remainder === 0x1000 && (half & 1))) half += 1
  return half
}

/** The single-precision value of a 16-bit pattern. */
export function fromHalf(half: number): number {
  const sign = half & 0x8000 ? -1 : 1
  const exponent = (half >>> 10) & 0x1f
  const mantissa = half & 0x3ff
  if (exponent === 0) return sign * mantissa * 2 ** -24
  if (exponent === 0x1f) return mantissa ? NaN : sign * Infinity
  return sign * (1 + mantissa / 1024) * 2 ** (exponent - 15)
}

export function narrow(values: ArrayLike<number>, into: Uint16Array, offset = 0): void {
  for (let i = 0; i < values.length; i++) into[offset + i] = toHalf(values[i])
}

export function widen(halves: Uint16Array, from: number, count: number, into: Float32Array, offset = 0): void {
  for (let i = 0; i < count; i++) into[offset + i] = fromHalf(halves[from + i])
}
