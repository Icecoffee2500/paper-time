/**
 * The window's one toolbar.
 *
 * Two quiet groups with the same contents and the same order as the Mac's:
 * the two left-hand panes at the left, the two right-hand ones at the right,
 * each pair sitting next to what it opens, so the button points at the thing.
 * A pane that is on says so with its colour and not with a filled square —
 * four filled squares in a row read as one block.
 */
import { icon, type IconName } from '../icons.js'
import { el, on, clear } from '../dom.js'
import { canGoBack, canGoForward, readerState, store, type InspectorTab, type Pane } from '../state.js'
import { platform } from '../bridge.js'
import { L } from '../../shared/lang.js'
import { withKey } from '../../shared/shortcuts.js'

export interface ToolbarActions {
  togglePane: (pane: Pane) => void
  back: () => void
  forward: () => void
  search: () => void
  addPapers: () => void
  setInspectorTab: (tab: InspectorTab) => void
  moreMenu: (anchor: Element) => void
  /** The settings sheet. A button of its own on Windows and Linux, where the
   *  menu bar is behind a key nobody presses and «Ctrl+,» had nothing behind
   *  it at all — and on the Mac too, because a second way in costs one icon. */
  settings: () => void
  minimize: () => void
  toggleMaximize: () => void
  close: () => void
}

export function buildToolbar(actions: ToolbarActions): { node: HTMLElement; update: () => void } {
  const node = el('div', { class: 'toolbar' })

  const button = (
    name: string,
    label: string,
    click: (event: MouseEvent) => void,
    options: { pressed?: boolean } = {},
  ) => {
    const b = el('button', {
      class: 'icon-button',
      title: label,
      'aria-label': label,
      html: icon(name),
    })
    if (options.pressed !== undefined) b.setAttribute('aria-pressed', String(options.pressed))
    on(b, 'click', click)
    return b
  }

  const paneButton = (pane: Pane, name: string, label: string) =>
    button(name, label, () => actions.togglePane(pane), { pressed: store.settings.panes[pane] })

  /**
   * A pane button's tooltip the Mac's way: what pressing it does now, and its
   * key — «옆 목록 숨기기 (Ctrl+[)». On Windows and Linux there is no menu bar
   * to read a key off, so the tooltip is where a person learns it.
   */
  const paneTip = (pane: Pane, title: string) => {
    const on = store.settings.panes[pane]
    return withKey(
      L(`${title} ${on ? '숨기기' : '보이기'}`, `${on ? 'Hide' : 'Show'} the ${title.toLowerCase()}`),
      pane, platform,
    )
  }
  const tip = (b: HTMLElement, text: string) => {
    b.title = text
    b.setAttribute('aria-label', text)
  }

  // ------------------------------------------------------------- leading
  const sidebarButton = paneButton('sidebar', 'sidebar.left', L('옆 목록', 'Sidebar'))
  const listButton = paneButton('paperList', 'list.bullet.rectangle.portrait', L('논문 목록', 'Paper List'))
  const backButton = button('chevron.left', withKey(L('왔던 논문으로 돌아가기', 'Back to the paper you came from'), 'back', platform), actions.back)
  const forwardButton = button('chevron.right', withKey(L('다시 앞으로', 'Forward again'), 'forward', platform), actions.forward)

  node.append(
    el('div', { class: 'toolbar-group' }, [
      sidebarButton,
      listButton,
      el('div', { class: 'toolbar-divider' }),
      backButton,
      forwardButton,
    ]),
    el('div', { class: 'toolbar-spacer' }),
  )

  // ------------------------------------------------------------ trailing
  const readerButton = paneButton('reader', 'text.page', L('논문', 'Paper'))
  const inspectorButton = paneButton('inspector', 'sidebar.right', L('정보 패널', 'Inspector'))
  const moreButton = button('ellipsis', L('맞추기·정렬·쪽 배치·공유', 'Sync, sort, page layout, share'), (event) =>
    actions.moreMenu(event.currentTarget as Element))
  const settingsButton = button('gear', withKey(L('설정', 'Settings'), 'settings', platform), actions.settings)

  const tabs = el('div', { class: 'segmented', role: 'tablist', title: L('정보 패널에 보일 것', 'What the inspector shows'), 'aria-label': L('정보 패널에 보일 것', 'What the inspector shows') })
  const tabButtons: Record<string, HTMLElement> = {}
  // The four names are English whatever language the window is in, as they
  // are on the Mac: they are the panel's proper names, not sentences.
  for (const [tab, label] of [
    ['details', 'Info'],
    ['marks', 'Marks'],
    ['note', 'Notes'],
    ['tools', 'Tools'],
  ] as const) {
    const b = el('button', { role: 'tab', text: label })
    on(b, 'click', () => actions.setInspectorTab(tab))
    tabButtons[tab] = b
    tabs.append(b)
  }

  node.append(
    el('div', { class: 'toolbar-group' }, [
      button('magnifyingglass', withKey(L('논문과 노트에서 찾기', 'Search papers and notes'), 'searchEverything', platform), actions.search),
      button('plus', withKey(L('라이브러리에 PDF 더하기', 'Add PDFs to the library'), 'addPapers', platform), actions.addPapers),
      el('div', { class: 'toolbar-divider' }),
      readerButton,
      inspectorButton,
      el('div', { class: 'toolbar-divider' }),
      settingsButton,
      moreButton,
      tabs,
    ]),
  )

  // The window's own buttons, where this desktop puts them. A Mac keeps the
  // real traffic lights, which the frame draws for us.
  const windowButtons = el('div', { class: 'window-buttons' })
  if (platform !== 'darwin') {
    const wb = (name: IconName, label: string, click: () => void, extra = '') => {
      const b = el('button', { class: extra, title: label, 'aria-label': label, html: icon(name, 'width="11" height="11"') })
      on(b, 'click', click)
      return b
    }
    windowButtons.append(
      wb('window.minimize', L('최소화', 'Minimise'), actions.minimize),
      wb('window.maximize', L('최대화', 'Maximise'), actions.toggleMaximize),
      wb('window.close', L('닫기', 'Close'), actions.close, 'close'),
    )
    node.append(windowButtons)
  }

  function update() {
    sidebarButton.setAttribute('aria-pressed', String(store.settings.panes.sidebar))
    listButton.setAttribute('aria-pressed', String(store.settings.panes.paperList))
    // In focus mode the paper is all there is; the button says focus is on
    // by being off, and pressing it leaves focus.
    readerButton.setAttribute('aria-pressed', String(store.settings.panes.reader && !store.focus.on))
    inspectorButton.setAttribute('aria-pressed', String(store.settings.panes.inspector))
    tip(sidebarButton, paneTip('sidebar', L('옆 목록', 'Sidebar')))
    tip(listButton, paneTip('paperList', L('논문 목록', 'Paper List')))
    tip(readerButton, paneTip('reader', L('논문', 'Paper')))
    tip(inspectorButton, paneTip('inspector', L('정보 패널', 'Inspector')))
    // Back walks the paper's own history first — a followed link — and then
    // the papers, as on the Mac.
    backButton.toggleAttribute('disabled', !(canGoBack() || readerState().canGoBack))
    forwardButton.toggleAttribute('disabled', !(canGoForward() || readerState().canGoForward))
    for (const [tab, b] of Object.entries(tabButtons)) {
      b.setAttribute('aria-selected', String(store.settings.inspectorTab === tab))
    }
    // Only with a paper to be about, as on the Mac: with nothing chosen the
    // four names point at nothing.
    tabs.style.display = store.settings.panes.inspector && store.selectedID ? '' : 'none'
    // The maximise button changes shape when the window is already maximised,
    // the way both desktops draw it.
    const maximise = windowButtons.children[1]
    if (maximise) {
      maximise.innerHTML = icon(
        store.windowState.maximized ? 'window.restore' : 'window.maximize',
        'width="11" height="11"',
      )
    }
  }

  update()
  return { node, update }
}

export { closeMenu, isMenuOpen, showMenu, showMenuAt, type MenuEntry } from './menu.js'

let toastShowing: { node: HTMLElement; text: string; timer: number } | null = null

/**
 * A sentence at the bottom of the window for a moment. The same sentence
 * again keeps it up longer rather than making it blink; another replaces it.
 * Each used to bring its own timer, so the third of three quick toasts was
 * taken down by the first one's.
 */
export function toast(message: string) {
  if (toastShowing && toastShowing.text !== message) {
    toastShowing.node.remove()
    toastShowing = null
  }
  if (!toastShowing) {
    const node = el('div', { class: 'toast', text: message })
    document.body.append(node)
    toastShowing = { node, text: message, timer: 0 }
  }
  const showing = toastShowing
  clearTimeout(showing.timer)
  delete showing.node.dataset.leaving
  // The Mac's moment: a second and a half to read, then it fades.
  showing.timer = window.setTimeout(() => {
    showing.node.dataset.leaving = 'true'
    if (toastShowing === showing) toastShowing = null
    setTimeout(() => showing.node.remove(), 260)
  }, 1600)
}

export { clear }
