/**
 * The paper's contents, and every page small, summoned over the paper — ⇧⌘L.
 *
 * Two tabs, as the Mac's `ContentsPopup` has them. A paper is read by its
 * sections, so «차례» lists the headings the PDF's own outline carries, with
 * the one being read marked, and a press goes there — a jump that Back comes
 * back from. Everything else somebody reads often has no sections to list: a
 * scanned lease has no headings at all, and a two-hundred-page handbook's are
 * "Chapter 7". What those have instead is pages you recognise by sight, which
 * is «쪽», and a document with no outline opens there.
 *
 * (The Mac also reads headings off the pages when a PDF has no outline; this
 * build lists the outline alone.)
 *
 * Thumbnails are drawn as their rows come into view and kept afterwards, so
 * a long document costs what the few rows on screen cost.
 */
import { clear, el, on } from '../dom.js'
import { L } from '../../shared/lang.js'

/** One heading of the outline, flattened: how deep it sits and where it goes. */
export interface OutlineEntry {
  title: string
  depth: number
  pageIndex: number | null
  top: number | null
}

export interface PagesActions {
  /** How many pages the paper showing has, and how to draw one small. */
  pageCount: () => number
  /** The page being read, counted from zero. */
  currentPage: () => number
  /** Draws page `index` into a canvas no wider than `width`. */
  draw: (index: number, width: number) => Promise<HTMLCanvasElement | null>
  /** Go to a page. */
  go: (index: number) => void
  /** The paper's own outline, flattened in reading order; empty when it has none. */
  outline?: () => Promise<OutlineEntry[]>
  /** Go to a heading. */
  goToHeading?: (entry: OutlineEntry) => void
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

/** The heading being read: the last one at or before the page in front. */
export function currentHeading(entries: OutlineEntry[], page: number): number {
  let found = -1
  for (const [index, entry] of entries.entries()) {
    if (entry.pageIndex !== null && entry.pageIndex <= page) found = index
  }
  return found
}

export function showPages(host: HTMLElement, actions: PagesActions) {
  closePages()
  const count = actions.pageCount()
  const node = el('div', { class: 'open-papers pages-popup', role: 'dialog', 'aria-label': L('차례', 'Contents') })
  const grid = el('div', { class: 'pages-grid' })
  const list = el('div', { class: 'contents-list' })

  const tabs = el('div', { class: 'segmented contents-tabs', role: 'tablist' })
  const headingsTab = el('button', { role: 'tab', text: L('차례', 'Contents') }) as HTMLButtonElement
  const pagesTab = el('button', { role: 'tab', text: L('쪽', 'Pages') }) as HTMLButtonElement
  tabs.append(headingsTab, pagesTab)
  const hint = el('span', { class: 'open-papers-hint', text: count > 0 ? L(`${count}쪽`, `${count} pages`) : '' })
  node.append(
    el('div', { class: 'open-papers-head' }, [tabs, el('span', { class: 'toolbar-spacer' }), hint]),
    list,
    grid,
  )

  let mode: 'headings' | 'pages' = 'pages'
  const show = (next: 'headings' | 'pages') => {
    mode = next
    headingsTab.setAttribute('aria-selected', String(mode === 'headings'))
    pagesTab.setAttribute('aria-selected', String(mode === 'pages'))
    list.style.display = mode === 'headings' ? '' : 'none'
    grid.style.display = mode === 'pages' ? '' : 'none'
    if (mode === 'pages') {
      const here = cells.find((c) => c.index === actions.currentPage())
      here?.cell.parentElement?.scrollIntoView({ block: 'center' })
    } else {
      list.querySelector('[data-current="true"]')?.scrollIntoView({ block: 'center' })
    }
  }
  on(headingsTab, 'click', () => { if (!headingsTab.disabled) show('headings') })
  on(pagesTab, 'click', () => show('pages'))

  if (count === 0) {
    grid.append(el('div', { class: 'open-papers-empty', text: L('열린 문서가 없어요.', 'Nothing is open.') }))
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

  const mine = {
    node,
    dispose: () => {
      watcher.disconnect()
      window.removeEventListener('keydown', onKey, true)
      node.remove()
    },
  }
  current = mine

  // The headings, once the outline is read; with none, this paper is read by
  // sight and the popup stays on its pages.
  headingsTab.disabled = true
  list.append(el('div', { class: 'open-papers-empty', text: L('차례를 읽는 중…', 'Reading the contents…') }))
  show('pages')
  void (actions.outline?.() ?? Promise.resolve([])).then((entries) => {
    if (current !== mine) return
    clear(list)
    if (entries.length === 0) {
      headingsTab.title = L('이 PDF에는 차례가 없어요', 'This PDF has no table of contents')
      return
    }
    const here = currentHeading(entries, actions.currentPage())
    for (const [index, entry] of entries.entries()) {
      const row = el('button', {
        class: 'contents-row',
        'data-current': String(index === here),
        style: `padding-left: ${10 + Math.min(entry.depth, 4) * 14}px`,
      }, [
        el('span', { class: 'contents-title', text: entry.title }),
        el('span', { class: 'contents-page', text: entry.pageIndex === null ? '' : String(entry.pageIndex + 1) }),
      ])
      if (entry.depth === 0) row.classList.add('top')
      on(row, 'click', () => {
        actions.goToHeading?.(entry)
        closePages()
      })
      list.append(row)
    }
    headingsTab.disabled = false
    show('headings')
  })
}
