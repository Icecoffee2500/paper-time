/**
 * The menu bar, with the same commands and the same keys as the Mac.
 *
 * `CmdOrCtrl` is Electron's way of saying "the modifier this desktop uses",
 * so ⌘K on a Mac and Ctrl+K on Windows and Linux come from one line. The
 * letters themselves are the Mac's, taken from `Shortcuts.swift`: someone who
 * reads on a Mac and writes on a PC should not have to learn the app twice.
 */
import { Menu, app, type MenuItemConstructorOptions } from 'electron'

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
            { label: 'Settings…', accelerator: 'CmdOrCtrl+,', click: command('settings') },
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
      label: '&File',
      submenu: [
        { label: 'Add PDFs…', accelerator: 'CmdOrCtrl+O', click: command('addPapers') },
        { label: 'Choose Library Folder…', click: () => void chooseLibrary() },
        { label: 'Refresh Folder', accelerator: 'CmdOrCtrl+R', click: command('refreshFolder') },
        { type: 'separator' },
        { label: 'New Note', accelerator: 'CmdOrCtrl+N', click: command('newNote') },
        { label: 'Export BibTeX…', accelerator: 'CmdOrCtrl+Shift+E', click: command('exportBibTeX') },
        { label: 'Copy Citation Key', accelerator: 'CmdOrCtrl+Shift+K', click: command('copyCitationKey') },
        { type: 'separator' },
        ...(isMac
          ? ([{ role: 'close' }] as MenuItemConstructorOptions[])
          : ([
              { label: 'Settings…', accelerator: 'CmdOrCtrl+,', click: command('settings') },
              { type: 'separator' },
              { role: 'quit', label: 'Exit' },
            ] as MenuItemConstructorOptions[])),
      ],
    },
    {
      label: '&Edit',
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' },
        { type: 'separator' },
        { label: 'Search Everything', accelerator: 'CmdOrCtrl+K', click: command('searchEverything') },
        { label: 'Find in Document', accelerator: 'CmdOrCtrl+F', click: command('findInDocument') },
      ],
    },
    {
      label: '&Marking',
      submenu: [
        { label: 'Highlight', accelerator: 'CmdOrCtrl+Shift+H', click: command('highlight') },
        { label: 'Underline', accelerator: 'CmdOrCtrl+Shift+U', click: command('underline') },
        { label: 'Draw on the Page', accelerator: 'CmdOrCtrl+Shift+D', click: command('draw') },
        { type: 'separator' },
        { label: 'Quote into a Note', accelerator: 'CmdOrCtrl+L', click: command('linkToNote') },
      ],
    },
    {
      label: '&View',
      submenu: [
        { label: 'Sidebar', accelerator: 'CmdOrCtrl+[', click: command('sidebar') },
        { label: 'Paper List', accelerator: 'CmdOrCtrl+P', click: command('paperList') },
        { label: 'Paper', accelerator: 'CmdOrCtrl+\\', click: command('reader') },
        { label: 'Inspector', accelerator: 'CmdOrCtrl+]', click: command('inspector') },
        { type: 'separator' },
        { label: 'Focus Mode', accelerator: 'CmdOrCtrl+Shift+F', click: command('focus') },
        { type: 'separator' },
        { label: 'Continuous', accelerator: 'CmdOrCtrl+1', click: command('layoutContinuous') },
        { label: 'Single Page', accelerator: 'CmdOrCtrl+2', click: command('layoutSinglePage') },
        { type: 'separator' },
        { label: 'Zoom In', accelerator: 'CmdOrCtrl+Plus', click: command('zoomIn') },
        { label: 'Zoom Out', accelerator: 'CmdOrCtrl+-', click: command('zoomOut') },
        { label: 'Actual Size', accelerator: 'CmdOrCtrl+0', click: command('actualSize') },
        { type: 'separator' },
        { role: 'togglefullscreen' },
        { role: 'toggleDevTools', visible: false },
      ],
    },
    {
      label: '&Go',
      submenu: [
        { label: 'Back', accelerator: isMac ? 'Cmd+Alt+[' : 'Alt+Left', click: command('back') },
        { label: 'Forward', accelerator: isMac ? 'Cmd+Alt+]' : 'Alt+Right', click: command('forward') },
      ],
    },
    {
      label: '&Window',
      submenu: isMac
        ? [{ role: 'minimize' }, { role: 'zoom' }, { type: 'separator' }, { role: 'front' }]
        : [{ role: 'minimize' }, { role: 'zoom' }],
    },
  ]

  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}
