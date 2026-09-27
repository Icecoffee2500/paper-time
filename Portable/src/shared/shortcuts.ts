/**
 * Every command the keyboard reaches, in one list — the Mac's `ShortcutAction`.
 *
 * The menu reads its keys from here, and so do the settings sheet's list and
 * the toolbar's tooltips, so the three cannot drift apart. On Windows and
 * Linux that is more than tidiness: the window there is frameless and
 * Electron draws no menu bar in a frameless window, so the keys work but no
 * menu ever shows them — the sheet's list and the tooltips are the only
 * places a person can find them out.
 *
 * The letters are the Mac's (`Shortcuts.swift`), written with Electron's
 * `CmdOrCtrl`, so ⌘K on a Mac is Ctrl+K on a PC. Two keep the desktop's own
 * habit instead: Back and Forward are Alt+← and Alt+→ on Windows and Linux,
 * the keys every browser there uses. (Ctrl+Alt+[ is no alias for them —
 * Ctrl+Alt is AltGr on many European keyboards, where it types.)
 */
import { L } from './lang.js'

export type ShortcutGroup = 'library' | 'reading' | 'marking' | 'panes' | 'moving' | 'app'

export interface Shortcut {
  /** The command's name, as the window's `runMenuCommand` knows it. */
  command: string
  group: ShortcutGroup
  /** In the window's language; read when the list is drawn. */
  title: () => string
  /** Electron's accelerator for the Mac. */
  mac: string
  /** …and for Windows and Linux, when it is not the same. */
  other?: string
}

export const SHORTCUTS: Shortcut[] = [
  { command: 'addPapers', group: 'library', title: () => L('논문 더하기', 'Add Papers'), mac: 'CmdOrCtrl+O' },
  { command: 'exportBibTeX', group: 'library', title: () => L('BibTeX 내보내기', 'Export BibTeX'), mac: 'CmdOrCtrl+Shift+E' },
  { command: 'copyCitationKey', group: 'library', title: () => L('인용 키 복사', 'Copy Citation Key'), mac: 'CmdOrCtrl+Shift+K' },
  { command: 'resolveMetadata', group: 'library', title: () => L('빠진 서지 채우기', 'Resolve Missing Metadata'), mac: 'CmdOrCtrl+Shift+R' },
  { command: 'refreshFolder', group: 'library', title: () => L('지금 맞추기', 'Sync Now'), mac: 'CmdOrCtrl+R' },

  { command: 'searchEverything', group: 'reading', title: () => L('전부 찾기', 'Search Everything'), mac: 'CmdOrCtrl+K' },
  { command: 'findInDocument', group: 'reading', title: () => L('이 논문에서 찾기', 'Find in Document'), mac: 'CmdOrCtrl+F' },
  // The name is the feature's own, in both languages, as on the Mac.
  { command: 'ultracopy', group: 'reading', title: () => 'Ultracopy', mac: 'CmdOrCtrl+Shift+C' },
  { command: 'linkToNote', group: 'reading', title: () => L('고른 곳을 노트로', 'Link Selection to Note'), mac: 'CmdOrCtrl+L' },
  { command: 'layoutContinuous', group: 'reading', title: () => L('이어서 보기', 'Continuous Layout'), mac: 'CmdOrCtrl+1' },
  { command: 'layoutSinglePage', group: 'reading', title: () => L('한 쪽씩 보기', 'Single Page Layout'), mac: 'CmdOrCtrl+2' },
  { command: 'layoutBook', group: 'reading', title: () => L('책처럼 보기', 'Book Layout'), mac: 'CmdOrCtrl+3' },

  { command: 'highlight', group: 'marking', title: () => L('고른 곳에 형광펜', 'Highlight Selection'), mac: 'CmdOrCtrl+Shift+H' },
  { command: 'underline', group: 'marking', title: () => L('고른 곳에 밑줄', 'Underline Selection'), mac: 'CmdOrCtrl+Shift+U' },
  { command: 'newNote', group: 'marking', title: () => L('새 노트', 'New Note'), mac: 'CmdOrCtrl+N' },
  { command: 'draw', group: 'marking', title: () => L('쪽에 그리기', 'Draw on the Page'), mac: 'CmdOrCtrl+Shift+D' },

  { command: 'sidebar', group: 'panes', title: () => L('옆 목록', 'Sidebar'), mac: 'CmdOrCtrl+[' },
  { command: 'paperList', group: 'panes', title: () => L('논문 목록', 'Paper List'), mac: 'CmdOrCtrl+P' },
  { command: 'reader', group: 'panes', title: () => L('논문', 'Paper'), mac: 'CmdOrCtrl+\\' },
  { command: 'inspector', group: 'panes', title: () => L('정보 패널', 'Inspector'), mac: 'CmdOrCtrl+]' },
  { command: 'focus', group: 'panes', title: () => L('논문에 집중', 'Focus on the Paper'), mac: 'CmdOrCtrl+Shift+F' },
  { command: 'pages', group: 'panes', title: () => L('차례', 'Table of Contents'), mac: 'CmdOrCtrl+Shift+L' },
  { command: 'openPapers', group: 'panes', title: () => L('열린 문서', 'Open Documents'), mac: 'CmdOrCtrl+Shift+O' },

  { command: 'zoomIn', group: 'moving', title: () => L('크게', 'Zoom In'), mac: 'CmdOrCtrl+Plus' },
  { command: 'zoomOut', group: 'moving', title: () => L('작게', 'Zoom Out'), mac: 'CmdOrCtrl+-' },
  { command: 'actualSize', group: 'moving', title: () => L('실제 크기', 'Actual Size'), mac: 'CmdOrCtrl+0' },
  { command: 'nextPage', group: 'moving', title: () => L('다음 쪽', 'Next Page'), mac: 'CmdOrCtrl+Down' },
  { command: 'previousPage', group: 'moving', title: () => L('이전 쪽', 'Previous Page'), mac: 'CmdOrCtrl+Up' },
  { command: 'nextPaper', group: 'moving', title: () => L('다음 논문', 'Next Paper'), mac: 'CmdOrCtrl+Alt+Down' },
  { command: 'previousPaper', group: 'moving', title: () => L('이전 논문', 'Previous Paper'), mac: 'CmdOrCtrl+Alt+Up' },
  { command: 'back', group: 'moving', title: () => L('뒤로', 'Back'), mac: 'CmdOrCtrl+Alt+[', other: 'Alt+Left' },
  { command: 'forward', group: 'moving', title: () => L('앞으로', 'Forward'), mac: 'CmdOrCtrl+Alt+]', other: 'Alt+Right' },

  { command: 'settings', group: 'app', title: () => L('설정', 'Settings'), mac: 'CmdOrCtrl+,' },
  // Off the Mac not Ctrl+Alt: that is AltGr on most European keyboards, and
  // AltGr+/ types a character there.
  { command: 'feedback', group: 'app', title: () => L('한마디 보내기', 'Send Feedback'), mac: 'CmdOrCtrl+Alt+/', other: 'Ctrl+Shift+/' },
  { command: 'closeWindow', group: 'app', title: () => L('닫기', 'Close'), mac: 'CmdOrCtrl+W' },
]

/** A group's heading — in English in both languages, as the Mac's list has
 *  them: they are the menus' own names, not sentences. */
export function groupTitle(group: ShortcutGroup): string {
  switch (group) {
    case 'library': return 'Library'
    case 'reading': return 'Reading'
    case 'marking': return 'Marking'
    case 'panes': return 'Window'
    case 'moving': return 'Navigation'
    case 'app': return 'Application'
  }
}

/** The accelerator a command has out of the box. */
export function defaultAcceleratorFor(entry: Shortcut, platform: string): string {
  return platform === 'darwin' ? entry.mac : (entry.other ?? entry.mac)
}

// MARK: - The keys a person chose

/**
 * The keys somebody changed, by command — the Mac's `paneShortcuts`. An
 * empty string is a command left with no key (its key was given to another).
 * Kept here, not passed around, so every menu, tooltip and list that reads a
 * key reads the chosen one; each process sets it from the settings.
 */
export type ShortcutOverrides = Record<string, string>

let overrides: ShortcutOverrides = {}

export function setShortcutOverrides(next: ShortcutOverrides) {
  overrides = { ...next }
}

export function shortcutOverrides(): ShortcutOverrides {
  return { ...overrides }
}

/** The settings' `shortcuts` (JSON), read back: only known commands and strings. */
export function parseShortcutOverrides(raw: unknown): ShortcutOverrides {
  let value = raw
  if (typeof raw === 'string') {
    try {
      value = JSON.parse(raw)
    } catch {
      return {}
    }
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {}
  const out: ShortcutOverrides = {}
  for (const [command, accelerator] of Object.entries(value as Record<string, unknown>)) {
    if (typeof accelerator === 'string' && shortcut(command)) out[command] = accelerator
  }
  return out
}

/** The accelerator a desktop uses for a command: the one chosen, or the one it came with. */
export function acceleratorFor(entry: Shortcut, platform: string, using: ShortcutOverrides = overrides): string {
  const chosen = using[entry.command]
  return chosen !== undefined ? chosen : defaultAcceleratorFor(entry, platform)
}

/** Whether a command has a key at all — one taken away to another command has none. */
export function hasShortcut(command: string, platform: string, using: ShortcutOverrides = overrides): boolean {
  const entry = shortcut(command)
  return Boolean(entry && acceleratorFor(entry, platform, using))
}

/** Two accelerators for the same keys: the modifiers in any order and any spelling. */
export function sameAccelerator(a: string, b: string, platform: string): boolean {
  const key = (accelerator: string) => {
    if (!accelerator) return ''
    const parts = accelerator.split('+')
    const last = parts.pop() || 'Plus'
    const mods = parts.map((part) => {
      const name = part.toLowerCase()
      if (name === 'cmdorctrl' || name === 'commandorcontrol') return platform === 'darwin' ? 'cmd' : 'ctrl'
      if (name === 'command' || name === 'cmd' || name === 'super' || name === 'meta') return 'cmd'
      if (name === 'control') return 'ctrl'
      if (name === 'option') return 'alt'
      return name
    })
    return `${[...new Set(mods)].sort().join('+')}|${last.toLowerCase()}`
  }
  return key(a) !== '' && key(a) === key(b)
}

/**
 * The overrides with a key given to a command — taken away from any other
 * command that had it, which is left with none (`AppModel.setShortcut`: a
 * key belongs to one command). Back to its own key is no override at all.
 */
export function assignShortcut(using: ShortcutOverrides, command: string, accelerator: string, platform: string): ShortcutOverrides {
  const entry = shortcut(command)
  if (!entry) return using
  const next: ShortcutOverrides = { ...using }
  if (accelerator) {
    for (const other of SHORTCUTS) {
      if (other.command === command) continue
      if (sameAccelerator(acceleratorFor(other, platform, next), accelerator, platform)) next[other.command] = ''
    }
  }
  if (accelerator && sameAccelerator(accelerator, defaultAcceleratorFor(entry, platform), platform)) delete next[command]
  else next[command] = accelerator
  return next
}

const CODE_KEYS: Record<string, string> = {
  BracketLeft: '[', BracketRight: ']', Backslash: '\\', Comma: ',', Period: '.', Slash: '/', Minus: '-',
  Equal: '=', Semicolon: ';', Quote: "'", Backquote: '`', Space: 'Space', Enter: 'Enter', NumpadEnter: 'Enter',
  Tab: 'Tab', Backspace: 'Backspace', Delete: 'Delete', Escape: 'Escape', Home: 'Home', End: 'End',
  PageUp: 'PageUp', PageDown: 'PageDown', ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right',
  NumpadAdd: 'Plus', NumpadSubtract: '-',
}

/**
 * The accelerator a key press spells — `CmdOrCtrl+Shift+K` — by the key's
 * place on the keyboard (`code`), so ⇧ does not turn `K` into «K» or `1`
 * into «!». Null for a press of modifiers alone, and for a plain key with no
 * modifier (a letter alone would take the letter away from every field),
 * but for the function keys.
 */
export function acceleratorFromEvent(
  event: { key: string; code?: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean },
  platform: string,
): string | null {
  const code = event.code ?? ''
  let key = ''
  if (/^Key[A-Z]$/.test(code)) key = code.slice(3)
  else if (/^Digit[0-9]$/.test(code)) key = code.slice(5)
  else if (/^Numpad[0-9]$/.test(code)) key = code.slice(6)
  else if (/^F([1-9]|1[0-9]|2[0-4])$/.test(code)) key = code
  else if (CODE_KEYS[code]) key = CODE_KEYS[code]
  else if (event.key.length === 1 && !/\s/.test(event.key)) key = event.key.toUpperCase()
  if (!key || ['Shift', 'Control', 'Alt', 'Meta'].includes(event.key)) return null
  const mods: string[] = []
  const mac = platform === 'darwin'
  if (mac ? event.metaKey : event.ctrlKey) mods.push('CmdOrCtrl')
  if (mac && event.ctrlKey) mods.push('Ctrl')
  if (event.altKey) mods.push('Alt')
  if (event.shiftKey) mods.push('Shift')
  const functionKey = /^F\d+$/.test(key)
  if (mods.length === 0 && !functionKey) return null
  // Shift alone with a letter types a capital: not a shortcut either.
  if (mods.length === 1 && mods[0] === 'Shift' && !functionKey) return null
  return [...mods, key === '+' ? 'Plus' : key].join('+')
}

/** Whether a key press is the key a command has now — for the keys the window catches itself. */
export function eventIs(
  command: string,
  event: { key: string; code?: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean },
  platform: string,
): boolean {
  const entry = shortcut(command)
  const pressed = acceleratorFromEvent(event, platform)
  return Boolean(entry && pressed && sameAccelerator(acceleratorFor(entry, platform), pressed, platform))
}

/**
 * The commands a search on the Shortcuts page finds: by name in either
 * language's words, or — when a key was pressed in the field — the one
 * command on that key (`shortcutSearchBar`).
 */
export function matchingShortcuts(query: string, pressed: string | null, platform: string): Shortcut[] {
  if (pressed) return SHORTCUTS.filter((entry) => sameAccelerator(acceleratorFor(entry, platform), pressed, platform))
  const terms = query.trim().toLowerCase()
  if (!terms) return SHORTCUTS
  return SHORTCUTS.filter((entry) => entry.title().toLowerCase().includes(terms) || entry.command.toLowerCase().includes(terms)
    || displayAccelerator(acceleratorFor(entry, platform), platform).toLowerCase().includes(terms))
}

export function shortcut(command: string): Shortcut | undefined {
  return SHORTCUTS.find((entry) => entry.command === command)
}

const KEY_NAMES: Record<string, string> = {
  Plus: '+', Up: '↑', Down: '↓', Left: '←', Right: '→', Space: 'Space', Escape: 'Esc',
}

/**
 * An accelerator the way the desktop writes one: `⇧⌘E` on a Mac, in the
 * order ⌃⌥⇧⌘ the Mac always uses, and `Ctrl+Shift+E` elsewhere.
 */
export function displayAccelerator(accelerator: string, platform: string): string {
  if (!accelerator) return ''
  const parts = accelerator.split('+')
  // `CmdOrCtrl++` would split into an empty key; `Plus` is how it is written.
  const key = parts.pop() ?? ''
  const shown = KEY_NAMES[key] ?? (key.length === 1 ? key.toUpperCase() : key)
  const has = (name: string) => parts.some((part) => part.toLowerCase() === name.toLowerCase())
  const command = has('CmdOrCtrl') || has('CommandOrControl') || has('Cmd') || has('Command')
  const control = has('Ctrl') || has('Control')
  const alt = has('Alt') || has('Option')
  const shift = has('Shift')
  if (platform === 'darwin') {
    return `${control ? '⌃' : ''}${alt ? '⌥' : ''}${shift ? '⇧' : ''}${command ? '⌘' : ''}${shown}`
  }
  const words: string[] = []
  if (command || control) words.push('Ctrl')
  if (alt) words.push('Alt')
  if (shift) words.push('Shift')
  words.push(shown)
  return words.join('+')
}

/** A command's key, as this desktop writes it — or '' when it has none. */
export function keyFor(command: string, platform: string): string {
  const entry = shortcut(command)
  return entry ? displayAccelerator(acceleratorFor(entry, platform), platform) : ''
}

/** A button's tooltip the Mac's way: what it does, and its key in brackets. */
export function withKey(label: string, command: string, platform: string): string {
  const key = keyFor(command, platform)
  return key ? `${label} (${key})` : label
}

/**
 * A key written the Mac's way — `⇧⌘G`, `⌫` — the way this desktop writes
 * it: the same on a Mac, `Ctrl+Shift+G` and `Delete` elsewhere. For the
 * drawing's keys, which are the page's own and not in the list above, so a
 * tooltip on Windows does not name keys the keyboard does not have.
 */
export function shortcutText(glyphs: string, platform: string): string {
  if (platform === 'darwin') return glyphs
  const words: string[] = []
  let rest = glyphs
  const has = (glyph: string) => {
    if (!rest.includes(glyph)) return false
    rest = rest.replace(glyph, '')
    return true
  }
  const control = has('⌃')
  const alt = has('⌥')
  const shift = has('⇧')
  const command = has('⌘')
  if (command || control) words.push('Ctrl')
  if (alt) words.push('Alt')
  if (shift) words.push('Shift')
  const names: Record<string, string> = { '⌫': 'Delete', '↩': 'Enter', '⎋': 'Esc', '⇥': 'Tab' }
  words.push(names[rest] ?? rest.toUpperCase())
  return words.join('+')
}

