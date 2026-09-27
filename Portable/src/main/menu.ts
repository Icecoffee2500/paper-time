/**
 * The menu bar, with the same commands and the same keys as the Mac.
 *
 * `CmdOrCtrl` is Electron's way of saying "the modifier this desktop uses",
 * so ⌘K on a Mac and Ctrl+K on Windows and Linux come from one line. The keys
 * themselves come from `shared/shortcuts.ts` — the one list the settings
 * sheet and the toolbar's tooltips read too — whose letters are the Mac's
 * (`Shortcuts.swift`): someone who reads on a Mac and writes on a PC should
 * not have to learn the app twice.
 *
 * The menus are the Mac's too, in the Mac's order (`PaperTimeCommands`):
 * File, Edit, View, Library, Window, Help. On Windows and Linux nobody sees
 * them — the window is frameless, and Electron draws no menu bar in a
 * frameless window — but their keys are live, so every command worth a key
 * is here, and everything that is *only* here (Help's two rows) is in the
 * ⋯ menu as well.
 */
import { Menu, app, shell, type MenuItemConstructorOptions } from 'electron'
import { L } from '../shared/lang.js'
import { acceleratorFor, shortcut } from '../shared/shortcuts.js'
import type { MenuState } from '../shared/api.js'

const isMac = process.platform === 'darwin'

export interface MenuActions {
  send: (event: string, payload?: unknown) => void
  chooseLibrary: () => void | Promise<void>
}

export const DEFAULT_MENU_STATE: MenuState = {
  panes: { sidebar: true, paperList: true, reader: true, inspector: true },
  focus: false,
  hasPaper: false,
  layout: 'continuous',
}

/** The commands that act on the paper showing, greyed with none showing —
 *  the Mac's menu disables them the same way. */
const NEEDS_PAPER = new Set([
  'copyCitationKey', 'findInDocument', 'ultracopy', 'linkToNote', 'highlight', 'underline', 'draw', 'pages',
  'zoomIn', 'zoomOut', 'actualSize', 'nextPage', 'previousPage', 'layoutContinuous', 'layoutSinglePage', 'layoutBook',
])

export function buildMenu({ send, chooseLibrary }: MenuActions, state: MenuState = DEFAULT_MENU_STATE) {
  const command = (event: string) => () => send('menu', event)

  /** A command from the shared list: its key, and a label (the list's own
   *  name unless the menu writes it with an ellipsis). */
  const item = (name: string, label?: string, extra: MenuItemConstructorOptions = {}): MenuItemConstructorOptions => {
    const entry = shortcut(name)
    return {
      label: label ?? entry?.title() ?? name,
      accelerator: entry ? acceleratorFor(entry, process.platform) : undefined,
      click: command(name),
      enabled: !NEEDS_PAPER.has(name) || state.hasPaper,
      ...extra,
    }
  }
  /** A column's item says what pressing it does now, as the Mac's does. */
  const pane = (name: 'sidebar' | 'paperList' | 'reader' | 'inspector', ko: string, en: string) => {
    const shown = state.panes[name] && !(name === 'reader' && state.focus)
    return item(name, shown ? L(`${ko} 숨기기`, `Hide ${en}`) : L(`${ko} 보기`, `Show ${en}`))
  }
  const layout = (name: string, value: MenuState['layout'], label: string) =>
    item(name, label, { type: 'radio', checked: state.layout === value })
  const separator: MenuItemConstructorOptions = { type: 'separator' }

  const template: MenuItemConstructorOptions[] = [
    ...(isMac
      ? ([{
          label: app.name,
          submenu: [
            // The app's own About — the settings' About page — not Electron's panel.
            { label: L('Paper Time 정보', 'About Paper Time'), click: command('about') },
            separator,
            item('settings', L('설정…', 'Settings…')),
            separator,
            { role: 'services' },
            separator,
            { role: 'hide' },
            { role: 'hideOthers' },
            { role: 'unhide' },
            separator,
            { role: 'quit' },
          ],
        }] as MenuItemConstructorOptions[])
      : []),
    {
      label: L('파일(&F)', '&File'),
      submenu: [
        item('addPapers', L('논문 더하기…', 'Add Papers…')),
        separator,
        item('exportBibTeX', L('BibTeX 내보내기…', 'Export BibTeX…')),
        item('copyCitationKey'),
        separator,
        // Not the `close` role: with papers side by side the key closes the
        // pane in focus and leaves the window standing, and only the window
        // knows how many panes it has.
        item('closeWindow'),
        ...(isMac
          ? []
          : ([
              separator,
              item('settings', L('설정…', 'Settings…')),
              separator,
              { role: 'quit', label: L('끝내기', 'Exit') },
            ] as MenuItemConstructorOptions[])),
      ],
    },
    {
      label: L('편집(&E)', '&Edit'),
      submenu: [
        { role: 'undo', label: L('되돌리기', 'Undo') },
        { role: 'redo', label: L('다시 하기', 'Redo') },
        separator,
        { role: 'cut', label: L('잘라내기', 'Cut') },
        { role: 'copy', label: L('복사', 'Copy') },
        { role: 'paste', label: L('붙여넣기', 'Paste') },
        { role: 'selectAll', label: L('모두 선택', 'Select All') },
        separator,
        item('searchEverything', L('전부 찾기…', 'Search Everything…')),
        item('findInDocument', L('이 논문에서 찾기…', 'Find in Document…')),
        item('ultracopy'),
        item('linkToNote'),
        separator,
        item('highlight'),
        item('underline'),
        item('newNote'),
        item('draw'),
      ],
    },
    {
      label: L('보기(&V)', '&View'),
      submenu: [
        pane('sidebar', '옆 목록', 'Sidebar'),
        pane('paperList', '논문 목록', 'Paper List'),
        pane('reader', '논문', 'Paper'),
        pane('inspector', '정보 패널', 'Inspector'),
        item('focus', state.focus ? L('집중 끝내기', 'Exit Focus') : undefined),
        item('pages'),
        item('openPapers'),
        separator,
        layout('layoutContinuous', 'continuous', L('이어서 보기', 'Continuous')),
        layout('layoutSinglePage', 'single', L('한 쪽씩 보기', 'Single Page')),
        layout('layoutBook', 'book', L('책처럼 보기', 'Book')),
        separator,
        item('zoomIn'),
        item('zoomOut'),
        item('actualSize'),
        separator,
        item('nextPage'),
        item('previousPage'),
        item('nextPaper'),
        item('previousPaper'),
        item('back'),
        item('forward'),
        separator,
        { role: 'togglefullscreen', label: L('전체 화면', 'Toggle Full Screen') },
        { role: 'toggleDevTools', visible: false },
      ],
    },
    {
      label: L('라이브러리(&L)', '&Library'),
      submenu: [
        item('resolveMetadata'),
        item('refreshFolder'),
        separator,
        // Both halves: another folder to read beside this one, and a
        // different folder to start from.
        { label: L('라이브러리 더하기…', 'Add Library…'), click: command('addFolder') },
        { label: L('라이브러리 폴더 바꾸기…', 'Change Library Folder…'), click: () => void chooseLibrary() },
      ],
    },
    {
      label: L('창(&W)', '&Window'),
      submenu: [
        { role: 'minimize', label: L('최소화', 'Minimize') },
        // The Mac's window zoom; elsewhere the maximise button is that.
        ...(isMac ? ([{ role: 'zoom', label: L('확대/축소', 'Zoom') }] as MenuItemConstructorOptions[]) : []),
        separator,
        { label: L('새 창으로 열기', 'Open in New Window'), click: command('openInNewWindow'), enabled: state.hasPaper },
        ...(isMac ? ([separator, { role: 'front' }] as MenuItemConstructorOptions[]) : []),
      ],
    },
    {
      // Where a desktop user looks for it, and on the same key the Mac uses.
      label: L('도움말(&H)', '&Help'),
      role: 'help',
      submenu: [
        {
          label: L('한마디 보내기…', 'Send Feedback…'),
          accelerator: acceleratorFor(shortcut('feedback')!, process.platform),
          click: () => send('menu:feedback'),
        },
        separator,
        {
          label: L('함께 만드는 중', 'Built together'),
          click: () => {
            void shell.openExternal('https://icecoffee2500.github.io/paper-time/#together')
          },
        },
      ],
    },
  ]

  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}
