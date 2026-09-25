/**
 * Where the mathematics is in a note — `NoteMath.swift`, ported.
 *
 * A note's formulas are `$…$` on a line and `$$…$$` either on a line or
 * across several, the shape Latex Suite's `dm` leaves behind. This finds
 * the blocks that span lines and the span under a caret, so the card that
 * shows a formula as it is typed answers the same question the Mac's does.
 * Offsets are UTF-16 code units, which is what a textarea counts in.
 */

export interface TextSpan {
  from: number
  to: number
}

export interface MathSpan {
  /** The whole span, delimiters included. */
  range: TextSpan
  /** The LaTeX, with the space around it taken off. */
  latex: string
  display: boolean
  /** Set for a `$$` that opens on one line and closes on a later one. */
  isBlock: boolean
}

/** Every line of the text, the last one even when empty. */
export function lineRanges(text: string): TextSpan[] {
  const result: TextSpan[] = []
  let start = 0
  for (;;) {
    const newline = text.indexOf('\n', start)
    if (newline < 0) {
      result.push({ from: start, to: text.length })
      break
    }
    result.push({ from: start, to: newline })
    start = newline + 1
    if (start === text.length) {
      result.push({ from: start, to: start })
      break
    }
  }
  return result
}

/**
 * The `$$` blocks that span lines, each from the start of the line that
 * opens it to the end of the line that closes it. A line opens a block when
 * it begins with `$$` and does not close it on the same line; the block
 * closes at the first later line that ends with `$$`.
 */
export function mathBlocks(text: string): TextSpan[] {
  const lines = lineRanges(text)
  const result: TextSpan[] = []
  let index = 0
  while (index < lines.length) {
    const line = text.slice(lines[index].from, lines[index].to).trim()
    if (!line.startsWith('$$') || line.slice(2).includes('$$')) {
      index += 1
      continue
    }
    let closer = -1
    for (let next = index + 1; next < lines.length; next += 1) {
      if (text.slice(lines[next].from, lines[next].to).trim().endsWith('$$')) {
        closer = next
        break
      }
    }
    if (closer < 0) {
      index += 1
      continue
    }
    result.push({ from: lines[index].from, to: lines[closer].to })
    index = closer + 1
  }
  return result
}

const INLINE = /\$\$([^$\n]+)\$\$|\$([^$\n]+)\$/g

/**
 * The formula the caret is inside, if it is inside one: between the
 * delimiters, so a caret just before a `$` or just after one is not in the
 * formula it borders.
 */
export function mathSpanAt(text: string, caret: number): MathSpan | null {
  if (caret < 0 || caret > text.length) return null
  for (const block of mathBlocks(text)) {
    if (caret < block.from || caret > block.to) continue
    const from = block.from + 2
    const to = block.to - 2
    if (caret < from || caret > to) return null
    return { range: block, latex: text.slice(from, to).trim(), display: true, isBlock: true }
  }
  const lineStart = text.lastIndexOf('\n', caret - 1) + 1
  let lineEnd = text.indexOf('\n', caret)
  if (lineEnd < 0) lineEnd = text.length
  const line = text.slice(lineStart, lineEnd)
  INLINE.lastIndex = 0
  for (let match = INLINE.exec(line); match; match = INLINE.exec(line)) {
    const display = match[1] !== undefined
    const body = display ? match[1] : match[2]
    const delimiter = display ? 2 : 1
    const from = lineStart + match.index + delimiter
    const to = from + body.length
    if (caret < from || caret > to) continue
    return {
      range: { from: lineStart + match.index, to: lineStart + match.index + match[0].length },
      latex: body.trim(),
      display,
      isBlock: false,
    }
  }
  return null
}
