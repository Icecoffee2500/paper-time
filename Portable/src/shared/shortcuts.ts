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
  { command: 'refreshFolder', group: 'library', title: () => L('지금 맞추기', 'Sync Now'), mac: 'CmdOrCtrl+R' },

  { command: 'searchEverything', group: 'reading', title: () => L('전부 찾기', 'Search Everything'), mac: 'CmdOrCtrl+K' },
  { command: 'findInDocument', group: 'reading', title: () => L('이 논문에서 찾기', 'Find in Document'), mac: 'CmdOrCtrl+F' },
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
  { command: 'feedback', group: 'app', title: () => L('한마디 보내기', 'Send Feedback'), mac: 'CmdOrCtrl+Alt+/' },
  { command: 'closeWindow', group: 'app', title: () => L('닫기', 'Close'), mac: 'CmdOrCtrl+W' },
]

export function groupTitle(group: ShortcutGroup): string {
  switch (group) {
    case 'library': return L('라이브러리', 'Library')
    case 'reading': return L('읽기', 'Reading')
    case 'marking': return L('표시', 'Marking')
    case 'panes': return L('창', 'Window')
    case 'moving': return L('이동', 'Navigation')
    case 'app': return L('앱', 'Application')
  }
}

/** The accelerator a desktop uses for a command. */
export function acceleratorFor(entry: Shortcut, platform: string): string {
  return platform === 'darwin' ? entry.mac : (entry.other ?? entry.mac)
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
