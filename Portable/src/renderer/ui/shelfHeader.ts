/**
 * The head every left column wears — the table of any shelf, a plan, the
 * week, the search results, the slip-box: a tinted tile with the shelf's
 * sidebar symbol, the name, one line about it, and the column's own
 * controls at the end. One shape, so moving between shelves reads as moving
 * within one place (the Mac's `ShelfHeader`, 2026-11-16, the user's ask).
 */
import { el } from '../dom.js'
import { iconNode, type IconName } from '../icons.js'
import type { Shelf } from '../state.js'

/** The colour the sidebar lights a shelf in — the Mac's `ShelfTitle.tint`. */
export type ShelfTone = 'accent' | 'reading' | 'read' | 'favorites' | 'review'

/** The symbol the sidebar gives the shelf (`ShelfTitle.symbol`). */
export function shelfSymbol(shelf: Shelf): IconName {
  switch (shelf.kind) {
    case 'all': return 'tray.full'
    case 'kind': return shelf.of === 'paper' ? 'text.document' : 'doc'
    case 'folder': return 'folder'
    case 'open': return 'rectangle.on.rectangle'
    case 'notes': return 'note'
    case 'search': return 'magnifyingglass'
    case 'status': return shelf.status === 'read' ? 'checkmark.circle' : shelf.status === 'reading' ? 'circle.lefthalf.filled' : 'circle'
    case 'favorites': return 'star'
    case 'review': return 'exclamationmark.triangle'
    case 'collection': return 'folder'
    case 'tag': return 'tag'
    case 'author': return 'person'
    case 'plan': return 'point.topleft.down.to.point.bottomright.curvepath'
    case 'week': return 'calendar'
  }
}

export function shelfTone(shelf: Shelf): ShelfTone {
  if (shelf.kind === 'status' && shelf.status === 'reading') return 'reading'
  if (shelf.kind === 'status' && shelf.status === 'read') return 'read'
  if (shelf.kind === 'favorites') return 'favorites'
  if (shelf.kind === 'review') return 'review'
  return 'accent'
}

export interface ShelfHeadOptions {
  icon: IconName
  tone?: ShelfTone
  title: string
  subtitle?: string
  /** The column's own controls, at the end. */
  trailing?: Node[]
}

/** One head: tile, name, line, controls. */
export function shelfHeader(options: ShelfHeadOptions): HTMLElement {
  const glyph = iconNode(options.icon)
  const titles = el('div', { class: 'shelf-titles' }, [el('h2', { text: options.title, title: options.title })])
  if (options.subtitle) titles.append(el('p', { class: 'shelf-sub', text: options.subtitle, title: options.subtitle }))
  return el('div', { class: 'shelf-head', 'data-tone': options.tone ?? 'accent' }, [
    el('span', { class: 'shelf-tile', 'aria-hidden': 'true' }, glyph ? [glyph] : []),
    titles,
    el('div', { class: 'shelf-trailing' }, options.trailing ?? []),
  ])
}
