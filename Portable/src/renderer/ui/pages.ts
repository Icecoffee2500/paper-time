/**
 * Every page of what is open, small, summoned over the paper — ⇧⌘L.
 *
 * A paper is read by its sections, and the Mac lists those. Everything else
 * somebody reads often has no sections to list: a scanned lease has no
 * headings at all, and a two-hundred-page handbook's are "Chapter 7". What
 * those have instead is pages you recognise by sight, which is why every
 * reader that opens more than papers has a page grid.
 *
 * Thumbnails are drawn as their rows come into view and kept afterwards, so
 * a long document costs what the few rows on screen cost.
 */
import { clear, el, on } from '../dom.js'
import { L } from '../../shared/lang.js'

export interface PagesActions {
  /** How many pages the paper showing has, and how to draw one small. */
  pageCount: () => number
  /** The page being read, counted from zero. */
  currentPage: () => number
  /** Draws page `index` into a canvas no wider than `width`. */
  draw: (index: number, width: number) => Promise<HTMLCanvasElement | null>
  /** Go to a page. */
  go: (index: number) => void
}

let current: { node: HTMLElement; dispose: () => void } | null = null

export function isPagesShowing(): boolean {
  return current !== null
}

export function closePages() {
  current?.dispose()
  current = null
}

export function togglePages(host: HTMLElement, actions: PagesActions) {
  if (current) return closePages()
  showPages(host, actions)
}

const THUMB_WIDTH = 132

export function showPages(host: HTMLElement, actions: PagesActions) {
  closePages()
  const count = actions.pageCount()
  const node = el('div', { class: 'open-papers pages-popup', role: 'dialog', 'aria-label': L('쪽', 'Pages') })
  const grid = el('div', { class: 'pages-grid' })
  node.append(
    el('div', { class: 'open-papers-head' }, [
      el('span', { text: L('쪽', 'Pages') }),
      el('span', { class: 'toolbar-spacer' }),
      el('span', { class: 'open-papers-hint', text: count > 0 ? L(`${count}쪽`, `${count} pages`) : '' }),
    ]),
    grid,
  )

  if (count === 0) {
    grid.append(el('div', { class: 'open-papers-empty', text: L('열린 논문이 없어요.', 'Nothing is open.') }))
  }

  const cells: { cell: HTMLElement; index: number; drawn: boolean }[] = []
  for (let index = 0; index < count; index += 1) {
    const box = el('div', { class: 'pages-thumb' })
    const cell = el('button', { class: 'pages-cell', 'data-current': String(index === actions.currentPage()) }, [
      box,
      el('span', { class: 'pages-number', text: String(index + 1) }),
    ])
    on(cell, 'click', () => {
      actions.go(index)
      closePages()
    })
    grid.append(cell)
    cells.push({ cell: box, index, drawn: false })
  }

  // Drawn when a row comes near, the way the reader draws its own pages.
  const watcher = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue
      const found = cells.find((c) => c.cell === entry.target)
      if (!found || found.drawn) continue
      found.drawn = true
      void actions.draw(found.index, THUMB_WIDTH).then((canvas) => {
        if (canvas) { clear(found.cell); found.cell.append(canvas) }
      })
    }
  }, { root: grid, rootMargin: '300px' })
  for (const { cell } of cells) watcher.observe(cell)

  host.append(node)
  const onKey = (event: KeyboardEvent) => {
    if (event.key === 'Escape') { event.preventDefault(); closePages() }
  }
  window.addEventListener('keydown', onKey, true)

  current = {
    node,
    dispose: () => {
      watcher.disconnect()
      window.removeEventListener('keydown', onKey, true)
      node.remove()
    },
  }
  // Open where the reader is.
  const here = cells.find((c) => c.index === actions.currentPage())
  here?.cell.parentElement?.scrollIntoView({ block: 'center' })
}
