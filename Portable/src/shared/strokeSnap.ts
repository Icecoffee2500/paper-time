/**
 * A highlighter stroke read as a mark on the page's words — the Mac's
 * `StrokeSnapper`, the same judgement, in the page's own coordinates (y up).
 *
 * Over words it is a highlight fitted to them; run along under the words,
 * it is an underline. The pen never snaps — handwriting is handwriting —
 * and a highlighter in the margin, where there are no words, stays ink.
 */

export interface Box { x: number; y: number; width: number; height: number }
export interface TextRun { box: Box; text: string }

export interface SnappedStroke {
  kind: 'highlight' | 'underline'
  /** One box per line, as wide as the words the stroke covers on it. */
  boxes: Box[]
  text: string
}

const minY = (b: Box) => b.y
const maxY = (b: Box) => b.y + b.height
const midY = (b: Box) => b.y + b.height / 2
const minX = (b: Box) => b.x
const maxX = (b: Box) => b.x + b.width

function overlapsX(a: Box, b: Box) {
  return maxX(a) > minX(b) && minX(a) < maxX(b)
}

/**
 * `rect` is the stroke's box (its points with half the nib around them),
 * `lines` the page's lines of text and `runs` its pieces of text with their
 * words. Null when the stroke is not over words and should stay ink.
 */
export function snapStroke(rect: Box, lines: Box[], runs: TextRun[]): SnappedStroke | null {
  // The lines the stroke touches, or lies just under.
  const around: Box = { x: rect.x, y: rect.y - 6, width: rect.width, height: rect.height + 12 }
  const touched = lines.filter((line) => line.height > 0 && overlapsX(line, around) && maxY(line) > minY(around) && minY(line) < maxY(around))
  if (touched.length === 0) return null
  const line = touched.reduce((best, one) => (Math.abs(midY(one) - midY(rect)) < Math.abs(midY(best) - midY(rect)) ? one : best))

  // A highlighter is wide: one stroke along one line is a box taller than
  // the line. Judged by its core — the band around its centre when it is a
  // line's worth tall, the box less half a nib when it is deliberately taller.
  const core: Box = rect.height < line.height * 1.8
    ? { x: rect.x, y: midY(rect) - line.height * 0.25, width: rect.width, height: line.height * 0.5 }
    : (() => {
        const inset = Math.min(rect.height * 0.3, line.height * 0.6)
        return { x: rect.x, y: rect.y + inset, width: rect.width, height: rect.height - inset * 2 }
      })()
  const crossed = touched.filter((one) => maxY(one) > minY(core) && minY(one) < maxY(core))
  const isFlat = rect.height < line.height * 0.6
  const sitsLow = midY(rect) < minY(line) + line.height * 0.28 && midY(rect) > minY(line) - line.height * 0.7

  let kind: SnappedStroke['kind']
  let pieces: Box[]
  if (isFlat && sitsLow) {
    kind = 'underline'
    pieces = [{ x: rect.x, y: line.y, width: rect.width, height: line.height }]
  } else {
    if (crossed.length === 0 || rect.height > line.height * 2.4 * crossed.length) return null
    kind = 'highlight'
    pieces = crossed.map((one) => ({ x: rect.x, y: one.y, width: rect.width, height: one.height }))
  }

  // Only the words under the stroke, line by line.
  const boxes: Box[] = []
  const words: string[] = []
  for (const piece of pieces) {
    const inside = runs.filter((run) => overlapsX(run.box, piece) && midY(run.box) > minY(piece) && midY(run.box) < maxY(piece))
    if (inside.length === 0) continue
    let left = Infinity
    let right = -Infinity
    const said: string[] = []
    for (const run of inside.sort((a, b) => a.box.x - b.box.x)) {
      const from = Math.max(minX(piece), minX(run.box))
      const to = Math.min(maxX(piece), maxX(run.box))
      if (to <= from) continue
      left = Math.min(left, from)
      right = Math.max(right, to)
      // The characters under the stroke, by where they stand in the run.
      const count = run.text.length
      const start = Math.max(0, Math.floor(((from - minX(run.box)) / run.box.width) * count))
      const end = Math.min(count, Math.ceil(((to - minX(run.box)) / run.box.width) * count))
      said.push(run.text.slice(start, end))
    }
    const text = said.join('').trim()
    if (right <= left || !text) continue
    boxes.push({ x: left, y: piece.y, width: right - left, height: piece.height })
    words.push(text)
  }
  if (boxes.length === 0) return null
  return { kind, boxes, text: words.join(' ') }
}
