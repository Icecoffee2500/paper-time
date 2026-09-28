/**
 * The toolbar's ⋯ menu: syncing, the list's order, the page's layout and
 * tint, the appearance — and at its end the paper's kind, sharing and help.
 */
import { call } from './bridge.js'
import { paper as findPaper, store } from './state.js'
import { isReading, reload } from './library.js'
import { kindEntries } from './actions/paper.js'
import { runCommand } from './commands.js'
import { openSettings, setLayout, setSettings, setSort } from './settingsController.js'
import { showFeedback } from './ui/feedback.js'
import { showMenu, type MenuEntry } from './ui/toolbar.js'
import { L } from '../shared/lang.js'
import { PAGE_TINTS, tintLabel } from '../shared/pageTint.js'
import { TOGETHER_URL } from '../shared/feedbackName.js'

export function showMoreMenu(anchor: Element) {
  showMenu(anchor, [
    // The Mac's word for the same errand: fetch what the folders have and
    // tell the papers to look at their files again.
    { label: L('지금 맞추기', 'Sync Now'), icon: 'arrow.clockwise', disabled: isReading(), action: () => void reload() },
    // No «Choose Library Folder…» here, as on the Mac: it is in the Library
    // menu, the settings sheet and the first-run screen.
    { separator: true },
    // A picker is a submenu, as the Mac's pickers in a menu are: the whole
    // list of choices inline made this menu taller than a small window.
    {
      label: L('정렬 기준', 'Sort By'),
      icon: 'arrow.up.arrow.down',
      children: (['title', 'author', 'year', 'added', 'opened'] as const).map((field) => ({
        label: {
          title: L('제목', 'Title'),
          author: L('저자', 'Author'),
          year: L('해', 'Year'),
          added: L('더한 날', 'Date Added'),
          opened: L('마지막으로 연 날', 'Last Opened'),
        }[field],
        checked: store.settings.sort.field === field,
        action: () => setSort(field, store.settings.sort.ascending),
      })),
    },
    {
      label: L('오름차순', 'Ascending'),
      checked: store.settings.sort.ascending,
      action: () => setSort(store.settings.sort.field, !store.settings.sort.ascending),
    },
    { separator: true },
    {
      label: L('쪽 배치', 'Page Layout'),
      icon: 'book.pages',
      children: (['continuous', 'single', 'book'] as const).map((layout) => ({
        label: { continuous: L('이어서 보기', 'Continuous'), single: L('한 쪽씩 보기', 'Single Page'), book: L('책처럼 보기', 'Book') }[layout],
        checked: store.settings.pageLayout === layout,
        action: () => setLayout(layout),
      })),
    },
    {
      label: L('쪽 색조', 'Page Tint'),
      icon: 'circle.lefthalf.filled',
      children: PAGE_TINTS.map((tint) => ({
        label: tintLabel(tint),
        checked: store.settings.pageTint === tint,
        action: () => {
          setSettings({ pageTint: tint })
          // Choosing a colour is the next thing anyone does after choosing
          // Custom Color, so Settings opens at its colour well — the Mac
          // opens its colour panel from the same item.
          if (tint === 'custom') openSettings('reading')
        },
      })),
    },
    { separator: true },
    {
      label: L('화면 모드', 'Appearance'),
      icon: 'textformat.size',
      children: (['system', 'light', 'dark'] as const).map((appearance) => ({
        label: { system: L('시스템에 따라', 'System'), light: L('밝게', 'Light'), dark: L('어둡게', 'Dark') }[appearance],
        checked: store.settings.appearance === appearance,
        action: () => setSettings({ appearance }),
      })),
    },
    ...tail(),
  ], 'right')
}

/**
 * The menu's last part, in the Mac's order: the paper's kind (one of the two
 * places it is changed — the row's menu is the other), then sharing, then
 * help.
 *
 * Help is here because on Windows and Linux it has nowhere else to be. The
 * window is frameless there, and Electron draws no menu bar in a frameless
 * window — its keys work, but an item that is only in the menu is an item
 * nobody can reach: «Built together» was one, and «Send Feedback» hid behind
 * Ctrl+Alt+/ alone.
 */
function tail(): MenuEntry[] {
  const entry = findPaper(store.selectedID)
  const kinds: MenuEntry[] = entry
    ? [{ separator: true }, { label: L('종류', 'Kind'), icon: 'text.document', children: kindEntries(entry) }]
    : []
  return [
    ...kinds,
    { separator: true },
    { label: L('BibTeX 내보내기…', 'Export BibTeX…'), icon: 'square.and.arrow.up', action: () => runCommand('exportBibTeX') },
    { separator: true },
    { label: L('한마디 보내기…', 'Send Feedback…'), action: () => void showFeedback() },
    { label: L('함께 만드는 중', 'Built together'), action: () => void call('shell:openExternal', { url: TOGETHER_URL }) },
    { label: L('Paper Time 정보', 'About Paper Time'), icon: 'info', action: () => openSettings('about') },
  ]
}
