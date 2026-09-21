/**
 * The menu bar, with the same commands and the same keys as the Mac.
 *
 * `CmdOrCtrl` is Electron's way of saying "the modifier this desktop uses",
 * so ⌘K on a Mac and Ctrl+K on Windows and Linux come from one line. The
 * letters themselves are the Mac's, taken from `Shortcuts.swift`: someone who
 * reads on a Mac and writes on a PC should not have to learn the app twice.
 */
import { Menu, app, shell, type MenuItemConstructorOptions } from 'electron'
import { L } from '../shared/lang.js'

const isMac = process.platform === 'darwin'

export interface MenuActions {
  send: (event: string, payload?: unknown) => void
  chooseLibrary: () => void | Promise<void>
}

export function buildMenu({ send, chooseLibrary }: MenuActions) {
  const command = (event: string) => () => send('menu', event)

  const template: MenuItemConstructorOptions[] = [
    ...(isMac
      ? ([{
          label: app.name,
          submenu: [
            { role: 'about' },
            { type: 'separator' },
            { label: L('설정…', 'Settings…'), accelerator: 'CmdOrCtrl+,', click: command('settings') },
            { type: 'separator' },
            { role: 'services' },
            { type: 'separator' },
            { role: 'hide' },
            { role: 'hideOthers' },
            { role: 'unhide' },
            { type: 'separator' },
            { role: 'quit' },
          ],
        }] as MenuItemConstructorOptions[])
      : []),
    {
      label: L('파일(&F)', '&File'),
      submenu: [
        { label: L('PDF 더하기…', 'Add PDFs…'), accelerator: 'CmdOrCtrl+O', click: command('addPapers') },
        // Both halves: another folder to read beside this one, and a
        // different folder to start from.
        { label: L('라이브러리 더하기…', 'Add Library…'), click: command('addFolder') },
        { label: L('라이브러리 폴더 고르기…', 'Choose Library Folder…'), click: () => void chooseLibrary() },
        { label: L('폴더에서 새로 읽기', 'Refresh Folder'), accelerator: 'CmdOrCtrl+R', click: command('refreshFolder') },
        { type: 'separator' },
        { label: L('새 노트', 'New Note'), accelerator: 'CmdOrCtrl+N', click: command('newNote') },
        { label: L('BibTeX 내보내기…', 'Export BibTeX…'), accelerator: 'CmdOrCtrl+Shift+E', click: command('exportBibTeX') },
        { label: L('인용 키 복사', 'Copy Citation Key'), accelerator: 'CmdOrCtrl+Shift+K', click: command('copyCitationKey') },
        { type: 'separator' },
        // Not the `close` role: with papers side by side the key closes the
        // pane in focus and leaves the window standing, and only the window
        // knows how many panes it has.
        { label: L('닫기', 'Close'), accelerator: 'CmdOrCtrl+W', click: command('closeWindow') },
        ...(isMac
          ? []
          : ([
              { type: 'separator' },
              { label: L('설정…', 'Settings…'), accelerator: 'CmdOrCtrl+,', click: command('settings') },
              { type: 'separator' },
              { role: 'quit', label: L('끝내기', 'Exit') },
            ] as MenuItemConstructorOptions[])),
      ],
    },
    {
      label: L('편집(&E)', '&Edit'),
      submenu: [
        { role: 'undo', label: L('되돌리기', 'Undo') },
        { role: 'redo', label: L('다시 하기', 'Redo') },
        { type: 'separator' },
        { role: 'cut', label: L('잘라내기', 'Cut') },
        { role: 'copy', label: L('복사', 'Copy') },
        { role: 'paste', label: L('붙여넣기', 'Paste') },
        { role: 'selectAll', label: L('모두 선택', 'Select All') },
        { type: 'separator' },
        { label: L('전부 찾기', 'Search Everything'), accelerator: 'CmdOrCtrl+K', click: command('searchEverything') },
        { label: L('이 논문에서 찾기', 'Find in Document'), accelerator: 'CmdOrCtrl+F', click: command('findInDocument') },
      ],
    },
    {
      label: L('표시(&M)', '&Marking'),
      submenu: [
        { label: L('고른 곳에 형광펜', 'Highlight'), accelerator: 'CmdOrCtrl+Shift+H', click: command('highlight') },
        { label: L('고른 곳에 밑줄', 'Underline'), accelerator: 'CmdOrCtrl+Shift+U', click: command('underline') },
        { label: L('쪽에 그리기', 'Draw on the Page'), accelerator: 'CmdOrCtrl+Shift+D', click: command('draw') },
        { type: 'separator' },
        { label: L('고른 곳을 노트로', 'Quote into a Note'), accelerator: 'CmdOrCtrl+L', click: command('linkToNote') },
      ],
    },
    {
      label: L('보기(&V)', '&View'),
      submenu: [
        { label: L('옆 목록', 'Sidebar'), accelerator: 'CmdOrCtrl+[', click: command('sidebar') },
        { label: L('논문 목록', 'Paper List'), accelerator: 'CmdOrCtrl+P', click: command('paperList') },
        { label: L('논문', 'Paper'), accelerator: 'CmdOrCtrl+\\', click: command('reader') },
        { label: L('정보 패널', 'Inspector'), accelerator: 'CmdOrCtrl+]', click: command('inspector') },
        { type: 'separator' },
        { label: L('논문에 집중', 'Focus Mode'), accelerator: 'CmdOrCtrl+Shift+F', click: command('focus') },
        { type: 'separator' },
        { label: L('이어서 보기', 'Continuous'), accelerator: 'CmdOrCtrl+1', click: command('layoutContinuous') },
        { label: L('한 쪽씩 보기', 'Single Page'), accelerator: 'CmdOrCtrl+2', click: command('layoutSinglePage') },
        { type: 'separator' },
        { label: L('크게', 'Zoom In'), accelerator: 'CmdOrCtrl+Plus', click: command('zoomIn') },
        { label: L('작게', 'Zoom Out'), accelerator: 'CmdOrCtrl+-', click: command('zoomOut') },
        { label: L('실제 크기', 'Actual Size'), accelerator: 'CmdOrCtrl+0', click: command('actualSize') },
        { type: 'separator' },
        { role: 'togglefullscreen', label: L('전체 화면', 'Toggle Full Screen') },
        { role: 'toggleDevTools', visible: false },
      ],
    },
    {
      label: L('이동(&G)', '&Go'),
      submenu: [
        { label: L('뒤로', 'Back'), accelerator: isMac ? 'Cmd+Alt+[' : 'Alt+Left', click: command('back') },
        { label: L('앞으로', 'Forward'), accelerator: isMac ? 'Cmd+Alt+]' : 'Alt+Right', click: command('forward') },
      ],
    },
    {
      label: L('창(&W)', '&Window'),
      submenu: [
        { role: 'minimize', label: L('최소화', 'Minimize') },
        { role: 'zoom', label: L('확대/축소', 'Zoom') },
        { type: 'separator' },
        // The open papers, over the page — the same key as the Mac's.
        { label: L('열린 논문', 'Open Papers'), accelerator: 'CmdOrCtrl+Shift+O', click: command('openPapers') },
        // Every page, small — the way into a document with no headings.
        { label: L('쪽 보기', 'Pages'), accelerator: 'CmdOrCtrl+Shift+L', click: command('pages') },
        { label: L('새 창으로 열기', 'Open in New Window'), click: command('openInNewWindow') },
        ...(isMac ? ([{ type: 'separator' }, { role: 'front' }] as MenuItemConstructorOptions[]) : []),
      ],
    },
    {
      // Where a desktop user looks for it, and on the same key the Mac uses.
      label: L('도움말(&H)', '&Help'),
      role: 'help',
      submenu: [
        {
          label: L('한마디 보내기…', 'Send Feedback…'),
          accelerator: 'CmdOrCtrl+Alt+/',
          click: () => send('menu:feedback'),
        },
        { type: 'separator' },
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
