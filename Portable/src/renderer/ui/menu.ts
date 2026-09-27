/**
 * The window's own pop-up menus — the row menu, the ⋯ menu, the kind and
 * status pickers — with the keyboard a menu has: ↑ and ↓ move, → opens a
 * submenu and ← closes it, Enter and Space choose, Escape and a press
 * anywhere else put it away. A command's key stands at the row's right end,
 * read from the one shortcut list, so a menu teaches its keys as the Mac's
 * menu bar does.
 */
import { el, on, place } from '../dom.js'
import { icon, type IconName } from '../icons.js'
import { platform } from '../bridge.js'
import { keyFor } from '../../shared/shortcuts.js'

export interface MenuEntry {
  label?: string
  icon?: IconName
  caption?: string
  separator?: boolean
  checked?: boolean
  /** Shown greyed and not pressable — the Mac's `.disabled`. */
  disabled?: boolean
  action?: () => void
  /** A submenu, opened beside the item when the pointer rests on it. */
  children?: MenuEntry[]
  /** The shortcut list's command, whose key stands at the row's end. */
  key?: string
}

interface Open {
  scrim: HTMLElement
  menus: HTMLElement[]
  restore: Element | null
}

let open: Open | null = null

export function isMenuOpen(): boolean {
  return open !== null
}

/** A pop-up menu under a control, dismissed by anything else being pressed. */
export function showMenu(anchor: Element, entries: MenuEntry[], align: 'left' | 'right' = 'left') {
  closeMenu()
  const scrim = el('div', { class: 'scrim' })
  // The press that dismisses the menu is the menu's: it used to go on
  // through to whatever was under it.
  on(scrim, 'mousedown', (event: MouseEvent) => {
    event.preventDefault()
    event.stopPropagation()
    closeMenu()
  })
  document.body.append(scrim)
  open = { scrim, menus: [], restore: document.activeElement }
  const menu = buildMenu(entries, 0)
  place(menu, anchor, align)
  open.menus.push(menu)
  focusItem(menu, 0)
}

export function closeMenu() {
  if (!open) return
  const { scrim, menus, restore } = open
  open = null
  scrim.remove()
  for (const menu of menus) menu.remove()
  if (restore instanceof HTMLElement && restore.isConnected) restore.focus({ preventScroll: true })
}

function items(menu: HTMLElement): HTMLButtonElement[] {
  return [...menu.querySelectorAll<HTMLButtonElement>(':scope > button[role="menuitem"]:not([disabled])')]
}

function focusItem(menu: HTMLElement, index: number) {
  const list = items(menu)
  if (list.length === 0) {
    menu.focus()
    return
  }
  list[(index + list.length) % list.length].focus({ preventScroll: false })
}

/** Closes the submenus deeper than `depth`. */
function closeBelow(depth: number) {
  if (!open) return
  for (const menu of open.menus.splice(depth + 1)) menu.remove()
}

function buildMenu(entries: MenuEntry[], depth: number): HTMLElement {
  const menu = el('div', { class: 'menu', role: 'menu', tabindex: '-1' })
  const openSubmenu = (item: HTMLElement, entry: MenuEntry, focusFirst: boolean) => {
    if (!open) return
    const existing = open.menus[depth + 1]
    if (existing && existing.dataset.for === item.dataset.index) {
      if (focusFirst) focusItem(existing, 0)
      return
    }
    closeBelow(depth)
    const submenu = buildMenu(entry.children ?? [], depth + 1)
    submenu.dataset.for = item.dataset.index ?? ''
    submenu.classList.add('submenu')
    // On the page itself, not inside the menu: a submenu fixed inside a
    // parent that animates a transform is placed against the parent.
    document.body.append(submenu)
    open.menus.push(submenu)
    const box = item.getBoundingClientRect()
    const size = submenu.getBoundingClientRect()
    let left = box.right + 2
    if (left + size.width > window.innerWidth - 8) left = box.left - size.width - 2
    let top = box.top - 5
    if (top + size.height > window.innerHeight - 8) top = Math.max(8, window.innerHeight - size.height - 8)
    submenu.style.left = `${left}px`
    submenu.style.top = `${top}px`
    if (focusFirst) focusItem(submenu, 0)
  }

  entries.forEach((entry, index) => {
    if (entry.separator) {
      menu.append(el('div', { class: 'menu-separator', role: 'separator' }))
      return
    }
    if (entry.caption) {
      menu.append(el('div', { class: 'menu-caption', text: entry.caption }))
      return
    }
    const item = el('button', {
      role: 'menuitem',
      'data-index': String(index),
      ...(entry.checked !== undefined ? { 'aria-checked': String(Boolean(entry.checked)) } : {}),
    }, [
      el('span', { html: entry.checked ? icon('checkmark') : icon(entry.icon ?? '') || spacer() }),
      el('span', { class: 'menu-label', text: entry.label ?? '' }),
    ])
    const key = entry.key ? keyFor(entry.key, platform) : ''
    if (key) item.append(el('span', { class: 'menu-key', text: key }))
    if (entry.children) {
      item.setAttribute('aria-haspopup', 'menu')
      item.append(el('span', { class: 'menu-chevron', html: icon('chevron.right') }))
      on(item, 'mouseenter', () => openSubmenu(item, entry, false))
      on(item, 'click', () => openSubmenu(item, entry, true))
    } else {
      on(item, 'mouseenter', () => {
        closeBelow(depth)
        item.focus({ preventScroll: true })
      })
      if (entry.disabled) {
        item.setAttribute('disabled', '')
      } else {
        on(item, 'click', () => {
          closeMenu()
          entry.action?.()
        })
      }
    }
    menu.append(item)
  })

  on(menu, 'keydown', (event: KeyboardEvent) => {
    // The menu's keys are the menu's: none reach the reader under it.
    event.stopPropagation()
    const list = items(menu)
    const at = list.indexOf(document.activeElement as HTMLButtonElement)
    const current = at >= 0 ? list[at] : null
    switch (event.key) {
      case 'ArrowDown':
        event.preventDefault()
        return focusItem(menu, at + 1)
      case 'ArrowUp':
        event.preventDefault()
        return focusItem(menu, at < 0 ? -1 : at - 1)
      case 'Home':
        event.preventDefault()
        return focusItem(menu, 0)
      case 'End':
        event.preventDefault()
        return focusItem(menu, -1)
      case 'ArrowRight':
        if (current?.getAttribute('aria-haspopup')) {
          event.preventDefault()
          current.click()
        }
        return
      case 'ArrowLeft':
      case 'Escape': {
        event.preventDefault()
        if (depth > 0 && open) {
          const parent = open.menus[depth - 1]
          const opener = parent?.querySelector<HTMLElement>(`[data-index="${menu.dataset.for}"]`)
          closeBelow(depth - 1)
          opener?.focus()
          return
        }
        if (event.key === 'Escape') closeMenu()
        return
      }
      case 'Enter':
      case ' ':
        event.preventDefault()
        current?.click()
        return
      case 'Tab':
        event.preventDefault()
        return
    }
  })
  return menu
}

function spacer() {
  return '<svg viewBox="0 0 16 16" width="15" height="15"></svg>'
}
