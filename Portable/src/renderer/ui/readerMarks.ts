/**
 * Marks and the selection, as the reader reads them off its pages.
 */
import { linesFromRuns } from '../../shared/textLines.js'
import { rectToQuad, type Mark } from '../../shared/marks.js'
import type { PageView } from './pageView.js'
import type { SelectionPart } from './markBar.js'

/**
 * The selection as marks take it: for each page it touches, its lines as
 * quads, and its words.
 *
 * The rectangles come from the text layer rather than from the PDF's own
 * text positions, because the text layer is what the reader actually dragged
 * over — so the mark lands where the pointer went, including across a column
 * break, where a run of PDF text indices would flood half the page. Each
 * rectangle goes to the page it lies on, so a selection that runs from the
 * foot of one page onto the next marks both.
 */
export function selectionParts(inside: HTMLElement, pageAt: (x: number, y: number) => PageView | null): SelectionPart[] {
  const selection = window.getSelection()
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return []
  const byPage = new Map<PageView, DOMRect[]>()
  const ranges: Range[] = []
  for (let index = 0; index < selection.rangeCount; index += 1) {
    const range = selection.getRangeAt(index)
    const common = range.commonAncestorContainer instanceof Element
      ? range.commonAncestorContainer
      : range.commonAncestorContainer.parentElement
    if (!common || !inside.contains(common)) continue
    ranges.push(range)
    // The boxes as the text layer gives them. With `--scale-factor` set, a
    // run's box is its em box: measured, the words sit from a tenth of the
    // way down it to seven tenths, and the line below clears it altogether
    // — the pitch is 1.10 of the box. There is nothing to trim.
    for (const rect of range.getClientRects()) {
      if (rect.width <= 0.5 || rect.height <= 0.5) continue
      const page = pageAt(rect.left + rect.width / 2, rect.top + rect.height / 2)
      if (!page) continue
      const list = byPage.get(page)
      if (list) list.push(rect)
      else byPage.set(page, [rect])
    }
  }
  const parts: SelectionPart[] = []
  for (const [page, rects] of byPage) {
    const quads = linesFromRuns(rects).map((line) => {
      // Two opposite corners through the page's own transform, which keeps a
      // rotated page honest, and kept on the page: the text layer's boxes are
      // the font's em boxes and some of them stand well outside the paper —
      // measured, one ran 244 points past the right edge of a 612-point
      // page, and the mark written from it was off the sheet.
      const topLeft = page.toPageFromClient(line.left, line.top)
      const bottomRight = page.toPageFromClient(line.right, line.bottom)
      return rectToQuad({
        x: Math.min(topLeft.x, bottomRight.x),
        y: Math.min(topLeft.y, bottomRight.y),
        width: Math.abs(bottomRight.x - topLeft.x),
        height: Math.abs(bottomRight.y - topLeft.y),
      })
    })
    // Each page's own words — the part of the selection inside that page —
    // not the whole selection twice (`textByPage`).
    if (quads.length > 0) parts.push({ page, quads, text: textOnPage(ranges, page.root) })
  }
  return parts.sort((a, b) => a.page.index - b.page.index)
}

/**
 * The passage selected on these pages, as a note cites it: its page, the box
 * it fills there in the page's own coordinates, and its words — what
 * Command-L puts into the note (`ReaderLink.selectionAnchor`).
 */
export function selectionAnchor(
  inside: HTMLElement,
  pageOf: (node: Node) => PageView | null,
): { pageIndex: number; rect: { x: number; y: number; width: number; height: number }; text: string } | null {
  const selection = window.getSelection()
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null
  const text = selection.toString()
  if (!text.trim()) return null
  const range = selection.getRangeAt(0)
  const page = pageOf(range.startContainer)
  if (!page || !inside.contains(page.root)) return null
  const box = page.root.getBoundingClientRect()
  const rects = [...range.getClientRects()].filter((rect) => rect.width > 0.5 && rect.height > 0.5
    && rect.right > box.left && rect.left < box.right && rect.bottom > box.top && rect.top < box.bottom)
  if (rects.length === 0) return null
  const left = Math.min(...rects.map((rect) => rect.left))
  const right = Math.max(...rects.map((rect) => rect.right))
  const top = Math.min(...rects.map((rect) => rect.top))
  const bottom = Math.max(...rects.map((rect) => rect.bottom))
  const a = page.toPageFromClient(left, top)
  const b = page.toPageFromClient(right, bottom)
  return {
    pageIndex: page.index,
    rect: { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(b.x - a.x), height: Math.abs(b.y - a.y) },
    text,
  }
}

/** The mark under a point of a page, the topmost when two overlap. An
 *  underline is a thin line under its words: the words' box is what a hand
 *  aims at, and it is the box that is kept. */
export function markAt(marks: Mark[], point: { x: number; y: number }): Mark | null {
  for (let index = marks.length - 1; index >= 0; index -= 1) {
    const mark = marks[index]
    const hit = mark.quads.some((quad) => {
      const xs = [quad[0], quad[2], quad[4], quad[6]]
      const ys = [quad[1], quad[3], quad[5], quad[7]]
      return point.x >= Math.min(...xs) && point.x <= Math.max(...xs)
        && point.y >= Math.min(...ys) && point.y <= Math.max(...ys)
    })
    if (hit) return mark
  }
  return null
}

/** Every mark in reading order — page by page, top to bottom (the page's y
 *  goes up, so the highest top is the first line), then left to right. */
export function marksInReadingOrder(pages: { index: number; marks: Mark[] }[]): { pageIndex: number; mark: Mark }[] {
  const top = (mark: Mark) => Math.max(...mark.quads.map((quad) => Math.max(quad[1], quad[3])))
  const left = (mark: Mark) => Math.min(...mark.quads.map((quad) => Math.min(quad[0], quad[4])))
  const out: { pageIndex: number; mark: Mark }[] = []
  for (const page of pages) {
    const sorted = [...page.marks].sort((a, b) => top(b) - top(a) || left(a) - left(b))
    for (const mark of sorted) out.push({ pageIndex: page.index, mark })
  }
  return out
}

/** The box a mark covers, in the window — where its controls stand. */
export function markClientBox(page: PageView, mark: Mark): DOMRect | null {
  const box = page.root.getBoundingClientRect()
  const points = mark.quads.flatMap((quad) => [
    page.toView(quad[0], quad[1]), page.toView(quad[2], quad[3]),
    page.toView(quad[4], quad[5]), page.toView(quad[6], quad[7]),
  ])
  if (points.length === 0) return null
  const xs = points.map((point) => point.x + box.left)
  const ys = points.map((point) => point.y + box.top)
  const left = Math.min(...xs)
  const top = Math.min(...ys)
  return new DOMRect(left, top, Math.max(...xs) - left, Math.max(...ys) - top)
}

/** The words of the selection that lie inside one page. */
export function textOnPage(ranges: Range[], root: HTMLElement): string {
  const words: string[] = []
  for (const range of ranges) {
    const part = range.cloneRange()
    const box = document.createRange()
    box.selectNodeContents(root)
    // Clamped to the page: a range that starts before it begins at its top,
    // one that runs past it ends at its foot.
    if (part.compareBoundaryPoints(Range.START_TO_START, box) < 0) part.setStart(box.startContainer, box.startOffset)
    if (part.compareBoundaryPoints(Range.END_TO_END, box) > 0) part.setEnd(box.endContainer, box.endOffset)
    if (part.compareBoundaryPoints(Range.START_TO_END, part) < 0 || part.collapsed) continue
    const said = part.toString()
    if (said.trim()) words.push(said)
  }
  return words.join(' ').trim()
}
