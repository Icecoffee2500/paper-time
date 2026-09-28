/**
 * The notice that a new version is out — the Mac's `UpdateSheet` and
 * `UpdateBar`, drawn from what the main process holds (`main/updates.ts`).
 *
 * At launch it is a sheet with the new version's notes; found later, it is a
 * glass line at the bottom of the window whose «What's New» opens the same
 * sheet. On Windows «Install Now» runs the downloaded installer; on Linux
 * it is «Download» and opens the page.
 */
import { call, onEvent } from '../bridge.js'
import { clear, el, on } from '../dom.js'
import { icon } from '../icons.js'
import { L, prefersKorean } from '../../shared/lang.js'
import { NO_UPDATE, type NoteItem, type Pair, type UpdateState } from '../../shared/updates.js'
import { onThisDesktop } from './releaseNotes.js'

let state: UpdateState = { ...NO_UPDATE }
let sheet: { backdrop: HTMLElement; foot: HTMLElement; version: string } | null = null
let bar: HTMLElement | null = null
const listeners = new Set<(state: UpdateState) => void>()

const say = (pair: Pair) => onThisDesktop(prefersKorean() ? pair.ko : pair.en)
const act = (action: 'install' | 'later' | 'skip' | 'hideBar' | 'showChanges' | 'closeSheet') => void call('update:act', { action })

/** Starts listening; the main process says when anything changes. */
export function installUpdateNotice() {
  onEvent((event, payload) => {
    if (event === 'update:state') apply(payload as UpdateState)
  })
  void call('update:state').then(apply)
}

/** The state, for Settings' line — and told again whenever it changes. */
export function watchUpdates(listener: (state: UpdateState) => void): () => void {
  listeners.add(listener)
  listener(state)
  return () => listeners.delete(listener)
}

export function updateState(): UpdateState {
  return state
}

/** What the primary button says: install where this desktop installs, download elsewhere. */
function primaryLabel(): string {
  return state.installs && state.stage !== 'manual' ? L('지금 설치', 'Install Now') : L('받기', 'Download')
}

function busy(): boolean {
  return state.stage === 'installing' || state.wantsInstall
}

function apply(next: UpdateState) {
  state = next
  for (const listener of listeners) listener(state)
  drawBar()
  if (state.showsSheet && state.offer) {
    // After this version's own welcome, never on top of it.
    if (!sheet && document.querySelector('.rn-whats-new')) return waitForWelcome()
    if (!sheet || sheet.version !== state.offer.version) openSheet()
    else drawFoot()
  } else if (sheet) {
    sheet.backdrop.remove()
    sheet = null
  }
}

let waiting = false
function waitForWelcome() {
  if (waiting) return
  waiting = true
  const observer = new MutationObserver(() => {
    if (document.querySelector('.rn-whats-new')) return
    observer.disconnect()
    waiting = false
    apply(state)
  })
  observer.observe(document.body, { childList: true })
}

// MARK: - The line

function drawBar() {
  const shows = state.showsBar && !state.showsSheet && state.offer
  if (!shows) {
    bar?.remove()
    bar = null
    return
  }
  if (!bar) {
    bar = el('div', { class: 'update-bar', role: 'status' })
    document.body.append(bar)
  }
  clear(bar)
  const changes = el('button', { class: 'update-link', type: 'button', text: L('무엇이 바뀌었나요', "What's New") })
  on(changes, 'click', () => act('showChanges'))
  const primary = el('button', { class: 'filled-button small', type: 'button', text: primaryLabel() })
  primary.disabled = busy()
  on(primary, 'click', () => act('install'))
  const close = el('button', { class: 'update-close', type: 'button', title: L('닫기', 'Close'), 'aria-label': L('닫기', 'Close'), html: icon('xmark') })
  on(close, 'click', () => act('hideBar'))
  bar.append(
    el('span', { class: 'update-icon', html: icon('arrow.down.circle') }),
    el('span', { class: 'update-title', text: L(`${state.offer!.version} 버전이 나왔어요`, `Paper Time ${state.offer!.version} is available`) }),
    changes,
    primary,
    ...status(),
    close,
  )
}

/** How far the download has got, once somebody is waiting for it. */
function status(): HTMLElement[] {
  if (state.stage === 'installing') return [el('span', { class: 'update-status', text: L('설치하는 중', 'Installing') })]
  if (state.wantsInstall) {
    const percent = state.progress == null ? '' : ` ${Math.round(state.progress * 100)}%`
    return [el('span', { class: 'update-status', text: L(`받는 중${percent}`, `Downloading${percent}`) })]
  }
  return []
}

// MARK: - The sheet

function openSheet() {
  sheet?.backdrop.remove()
  const offer = state.offer!
  const backdrop = el('div', { class: 'sheet-backdrop' })
  const box = el('div', { class: 'fb-sheet update-sheet', role: 'dialog', 'aria-modal': 'true' })
  backdrop.append(box)
  const head = el('div', { class: 'update-head' }, [
    el('span', { class: 'update-head-icon', html: icon('arrow.down.circle') }),
    el('div', {}, [
      el('h2', { class: 'update-head-title', text: L('새 버전이 나왔어요', 'A New Version Is Available') }),
      el('p', { class: 'update-head-sub', text: L(`Paper Time ${offer.version} · 지금 쓰는 버전은 ${state.current}`, `Paper Time ${offer.version} · You have ${state.current}`) }),
    ]),
  ])
  const body = el('div', { class: 'update-body' })
  for (const step of offer.steps) {
    const section = el('section', { class: 'update-step' })
    if (offer.steps.length > 1) section.append(el('h3', { class: 'update-step-version', text: step.version }))
    if (step.notes?.note) section.append(el('p', { class: 'update-note', text: say(step.notes.note) }))
    list(section, L('새로 생긴 것', 'New'), 'plus.circle', step.notes?.added)
    list(section, L('고친 것', 'Fixed'), 'checkmark.circle', step.notes?.fixed)
    if (!step.notes) section.append(el('p', { class: 'update-note secondary', text: L('이 버전의 설명은 배포 페이지에 있어요.', 'The download page describes this version.') }))
    body.append(section)
  }
  const foot = el('div', { class: 'set-foot update-foot' })
  box.append(head, body, foot)
  const onKey = (event: KeyboardEvent) => {
    if (event.key !== 'Escape' || !backdrop.isConnected) return
    event.preventDefault()
    act('later')
  }
  document.addEventListener('keydown', onKey)
  new MutationObserver((_, observer) => {
    if (backdrop.isConnected) return
    document.removeEventListener('keydown', onKey)
    observer.disconnect()
  }).observe(document.body, { childList: true })
  document.body.append(backdrop)
  sheet = { backdrop, foot, version: offer.version }
  drawFoot()
}

function list(into: HTMLElement, title: string, symbol: 'plus.circle' | 'checkmark.circle', items: NoteItem[] | null | undefined) {
  if (!items?.length) return
  into.append(el('div', { class: 'update-list-title', html: icon(symbol) }, [el('span', { text: title })]))
  for (const item of items) {
    const row = el('div', { class: 'update-item' }, [el('div', { class: 'update-item-title', text: say(item.title) })])
    if (item.detail) row.append(el('p', { class: 'update-item-detail', text: say(item.detail) }))
    into.append(row)
  }
}

function drawFoot() {
  if (!sheet) return
  const { foot } = sheet
  clear(foot)
  const skip = el('button', { class: 'update-link secondary', type: 'button', text: L('이 버전 건너뛰기', 'Skip This Version') })
  on(skip, 'click', () => act('skip'))
  const later = el('button', { class: 'plain-button', type: 'button', text: L('나중에', 'Later') })
  on(later, 'click', () => act('later'))
  const primary = el('button', { class: 'filled-button', type: 'button', text: primaryLabel() })
  primary.disabled = busy()
  on(primary, 'click', () => act('install'))
  foot.append(skip, el('span', { class: 'fb-spacer' }), ...status(), later, primary)
  if (!foot.contains(document.activeElement)) queueMicrotask(() => primary.focus())
}
