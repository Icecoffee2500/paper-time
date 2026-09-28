/**
 * What each version brought, and the few things worth showing — the Mac's
 * Log, About showcase, What's New sheet and «All Features and Keys», read
 * from the Mac's own release notes (`src/shared/releaseNotes.json`, written
 * by `tools/generate-release-notes.mjs` from `ReleaseNotes.swift`).
 *
 * The demonstrations are the landing page's (`Website/demos.js`), shown in a
 * frame of their own (`demos.html`) — the same working pieces a person saw
 * before downloading, not a second set that would drift from them.
 */
import { clear, el, on } from '../dom.js'
import { icon } from '../icons.js'
import { L, prefersKorean } from '../../shared/lang.js'
import { platform } from '../bridge.js'
import { keyFor, shortcut, shortcutText } from '../../shared/shortcuts.js'
import notes from '../../shared/releaseNotes.json'

interface Text2 { ko: string; en: string }
interface Entry { title: Text2; detail: Text2; action?: string; demo?: string; featured?: boolean; devices: string[] }
interface Release { version: string; date: Text2; note: Text2; added: Entry[]; removed: Entry[]; fixed: Entry[] }
interface Highlight { symbol: string; title: Text2; detail: Text2; tier: string; action?: string; demo?: string }
interface Feature { title: Text2; detail: Text2; action?: string }
interface Group { title: Text2; symbol: string; features: Feature[] }

const data = notes as unknown as { releases: Release[]; highlights: Highlight[]; groups: Group[]; contributors: { name: string; reports: number }[]; unnamedReports: number }

/** Keys named in the Mac's words — «⌘K», «⇧⌘L» — as this desktop names them. */
export function onThisDesktop(text: string): string {
  if (platform === 'darwin') return text
  // The Mac's notes speak of «this Mac»; here it is this computer.
  text = text.replace(/이 맥/g, '이 컴퓨터').replace(/\bthis Mac\b/g, 'this computer')
  return text.replace(/[⌃⌥⇧⌘]+(?:[A-Z0-9]|[[\]\\,./←→↑↓↩⌫]|Return|Space)/g, (glyphs) => shortcutText(glyphs, platform))
}

const say = (text: Text2) => onThisDesktop(prefersKorean() ? text.ko : text.en)

/** The Mac's command names, as this build's; `floatingList` is the contents (`pages`). */
const COMMAND_FOR: Record<string, string> = { floatingList: 'pages' }

function keyChip(action?: string): HTMLElement | null {
  if (!action) return null
  const command = COMMAND_FOR[action] ?? action
  if (!shortcut(command)) return null
  const key = keyFor(command, platform)
  return key ? el('span', { class: 'rn-key', text: key }) : null
}

/** A Mac demonstration, by the website's name for the same piece — or none. */
const WEB_DEMO: Record<string, string> = {
  search: 'searchEverything', ultracopy: 'ultracopy', book: 'bookMode', bookReading: 'bookMode',
  annotations: 'fittedHighlight', passageLink: 'passageToNote', slipBox: 'noteLinks', panes: 'papersSideBySide',
  crossPlatform: 'everyDesktop', sync: 'threeDevices', sketch: 'figmaDrawing', kindQuestion: 'paperOrDocument',
  folderTree: 'manyLibraries', express: 'draftToManuscript',
}

/** The demonstration in its own frame, as tall as it turns out to be. */
export function demoFrame(demo: string | undefined): HTMLElement | null {
  const web = demo ? WEB_DEMO[demo] : undefined
  if (!web) return null
  const frame = el('iframe', {
    class: 'rn-demo',
    src: `demos.html?demo=${encodeURIComponent(web)}&lang=${prefersKorean() ? 'ko' : 'en'}`,
    title: L('작동하는 예시', 'A working example'),
  }) as HTMLIFrameElement
  const listen = (event: MessageEvent) => {
    if (!frame.isConnected) return window.removeEventListener('message', listen)
    const answer = event.data as { paperTimeDemo?: string; height?: number }
    if (event.source !== frame.contentWindow || answer?.paperTimeDemo !== web || !answer.height) return
    frame.style.height = `${Math.min(Math.max(answer.height, 240), 560)}px`
  }
  window.addEventListener('message', listen)
  return frame
}

// MARK: - The Log

const DEVICE_NAME: Record<string, string> = { mac: 'Mac', ipad: 'iPad', iphone: 'iPhone' }

/**
 * Every release, newest first: what came, what went, what was mended —
 * counted in the header, each line a keyword that opens to its sentence
 * (`SettingsView.logSection`). A changelog is read by someone looking for
 * whether the thing they care about moved.
 */
export function drawLog(body: HTMLElement) {
  for (const [index, release] of data.releases.entries()) {
    const counts = el('span', { class: 'rn-counts' })
    const count = (glyph: string, n: number, title: string) => {
      if (n === 0) return
      counts.append(el('span', { class: 'rn-count', title, html: icon(glyph) }, [el('span', { text: String(n) })]))
    }
    count('plus', release.added.length, L('새로 생긴 것', 'Added'))
    count('minus', release.removed.length, L('빠진 것', 'Removed'))
    count('wrench', release.fixed.length, L('고친 것', 'Fixed'))
    const section = el('section', { class: 'rn-release' })
    section.append(el('div', { class: 'rn-release-head' }, [
      el('span', { class: 'rn-version', text: release.version }),
      el('span', { class: 'rn-date', text: say(release.date) }),
      el('span', { class: 'toolbar-spacer' }),
      counts,
    ]))
    section.append(el('p', { class: 'rn-note', text: say(release.note) }))
    const list = (entries: Entry[], glyph: string) => {
      for (const entry of entries) {
        const row = el('div', { class: `rn-entry${entry.featured ? ' featured' : ''}` })
        const head = el('button', { type: 'button', class: 'rn-entry-head', 'aria-expanded': 'false', html: icon(glyph) })
        head.append(el('span', { class: 'rn-entry-title', text: say(entry.title) }))
        const chip = keyChip(entry.action)
        if (chip) head.append(chip)
        const devices = entry.devices.filter((device) => device !== 'mac')
        for (const device of devices) head.append(el('span', { class: 'rn-device', text: DEVICE_NAME[device] ?? device }))
        const detail = el('p', { class: 'rn-entry-detail', text: say(entry.detail) })
        detail.hidden = true
        on(head, 'click', () => {
          detail.hidden = !detail.hidden
          head.setAttribute('aria-expanded', String(!detail.hidden))
        })
        row.append(head, detail)
        section.append(row)
      }
    }
    list(release.added, 'plus')
    list(release.removed, 'minus')
    list(release.fixed, 'wrench')
    // The latest two open, the rest a click away.
    if (index > 1) section.classList.add('rn-older')
    body.append(section)
  }
}

// MARK: - The showcase

/**
 * The few things worth showing, one at a time — macOS's «What's New»: the
 * name above, a card with the working piece in it and its title and
 * sentence under it, dots under the card, arrows either side (←→ too).
 * Every page's words are stacked in the same place and one is shown, so the
 * card is always as tall as its longest page and nothing moves as it turns.
 */
export function showcase(): { node: HTMLElement; turn: (by: number) => void } {
  // The ones there is a working piece for: a card with nothing in it shows
  // nothing. The rest are in «All Features and Keys».
  const pages = data.highlights.filter((page) => page.demo && WEB_DEMO[page.demo])
  let at = 0
  const node = el('div', { class: 'rn-showcase' })
  const back = el('button', { type: 'button', class: 'rn-arrow', title: L('앞으로', 'Previous'), html: icon('chevron.left') })
  const next = el('button', { type: 'button', class: 'rn-arrow', title: L('다음', 'Next'), html: icon('chevron.right') })
  const card = el('div', { class: 'rn-card' })
  const stage = el('div', { class: 'rn-stage' })
  const words = el('div', { class: 'rn-words' })
  const dots = el('div', { class: 'rn-dots' })
  card.append(stage, words)
  node.append(el('div', { class: 'rn-row' }, [back, card, next]), dots)
  for (const page of pages) {
    const block = el('div', { class: `rn-page${page.tier === 'one' ? ' tier-one' : ''}` }, [
      el('h3', { class: 'rn-page-title', text: say(page.title) }),
      el('p', { class: 'rn-page-detail', text: say(page.detail) }),
    ])
    words.append(block)
  }
  const draw = () => {
    clear(stage)
    const frame = demoFrame(pages[at].demo)
    if (frame) stage.append(frame)
    ;[...words.children].forEach((child, index) => child.classList.toggle('shown', index === at))
    clear(dots)
    pages.forEach((_, index) => {
      const dot = el('button', { type: 'button', class: 'rn-dot', 'aria-current': String(index === at), title: `${index + 1}/${pages.length}` })
      on(dot, 'click', () => turnTo(index))
      dots.append(dot)
    })
    back.disabled = at === 0
    next.disabled = at === pages.length - 1
  }
  const turnTo = (index: number) => {
    at = Math.max(0, Math.min(pages.length - 1, index))
    draw()
  }
  on(back, 'click', () => turnTo(at - 1))
  on(next, 'click', () => turnTo(at + 1))
  draw()
  return { node, turn: (by: number) => turnTo(at + by) }
}

// MARK: - Sheets

function sheet(className: string, title: string, fill: (body: HTMLElement, close: () => void) => HTMLElement | null) {
  const backdrop = el('div', { class: 'sheet-backdrop' })
  const box = el('div', { class: `fb-sheet ${className}`, role: 'dialog', 'aria-modal': 'true' })
  backdrop.append(box)
  const body = el('div', { class: 'rn-sheet-body' })
  const close = () => {
    backdrop.remove()
    document.removeEventListener('keydown', onKey)
  }
  let turn: ((by: number) => void) | null = null
  const onKey = (event: KeyboardEvent) => {
    if (event.key === 'Escape') close()
    else if (turn && event.key === 'ArrowLeft') turn(-1)
    else if (turn && event.key === 'ArrowRight') turn(1)
  }
  const foot = fill(body, close)
  box.append(el('h2', { class: 'fb-title', text: title }), body)
  if (foot) box.append(foot)
  document.body.append(backdrop)
  document.addEventListener('keydown', onKey)
  return { close, setTurn: (fn: (by: number) => void) => { turn = fn } }
}

/**
 * What's New, once per version, after the library is up (`WhatsNewView`):
 * the showcase, and «Start Reading». `onDone` writes the version as seen —
 * a probe passes none, and nothing is written.
 */
export function showWhatsNew(version: string, onDone?: () => void) {
  let turnFn: ((by: number) => void) | null = null
  const opened = sheet('rn-whats-new', L(`Paper Time ${version}의 새로운 기능`, `What's New in Paper Time ${version}`), (body, close) => {
    const shown = showcase()
    turnFn = shown.turn
    body.append(shown.node)
    const start = el('button', { class: 'filled-button', text: L('읽기 시작', 'Start Reading') })
    on(start, 'click', () => {
      onDone?.()
      close()
    })
    queueMicrotask(() => start.focus())
    return el('div', { class: 'set-foot' }, [el('span', { class: 'fb-spacer' }), start])
  })
  if (turnFn) opened.setTurn(turnFn)
}

/** Every feature by the part of the app it belongs to, with its key (`FeatureLogView`). */
export function showAllFeatures() {
  sheet('rn-features', L('모든 기능과 키', 'All Features and Keys'), (body, close) => {
    for (const group of data.groups) {
      body.append(el('div', { class: 'set-subsection rn-group', html: icon(group.symbol) }, [el('span', { text: say(group.title) })]))
      for (const feature of group.features) {
        const row = el('div', { class: 'rn-feature' }, [
          el('div', { class: 'rn-feature-head' }, [el('span', { class: 'rn-entry-title', text: say(feature.title) }), ...(keyChip(feature.action) ? [keyChip(feature.action)!] : [])]),
          el('p', { class: 'rn-entry-detail', text: say(feature.detail) }),
        ])
        body.append(row)
      }
    }
    const done = el('button', { class: 'filled-button', text: L('완료', 'Done') })
    on(done, 'click', close)
    queueMicrotask(() => done.focus())
    return el('div', { class: 'set-foot' }, [el('span', { class: 'fb-spacer' }), done])
  })
}

/** The people who told us something and left a name, first sender first (`Contributors.all`). */
export function contributors(): { name: string; reports: number }[] {
  return data.contributors
}

/** Reports sent without a name (`Contributors.unnamedReports`) — reports, not people. */
export function unnamedReports(): number {
  return data.unnamedReports ?? 0
}
