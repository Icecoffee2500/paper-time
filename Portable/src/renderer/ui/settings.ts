/**
 * The settings, which this build has never had a way into.
 *
 * The menu has carried «설정…» with `Ctrl+,` on it since the beginning, and
 * behind it was nothing: the window had no case for the command and no
 * surface to show. On the Mac that went unnoticed, because the Mac is a
 * different app with a real settings window; on Windows and Linux it meant
 * the language could not be changed at all. A person whose desktop is in
 * English had no way to ask for Korean.
 *
 * A sheet rather than a second window. Two windows means a second set of
 * chrome to keep looking the same on both desktops, which is the one thing
 * this build exists to do — and the report sheet already established the
 * shape, so this is the same frame with different rows in it.
 *
 * What is here is what this build can actually change. The reading settings
 * are also in the ⋯ menu, where a hand reaching for them mid-paper will find
 * them sooner; having them in both places is what the Mac does, and a setting
 * worth changing while reading is worth two ways in. Nothing is drawn for a
 * setting that does not exist yet: a switch that does nothing is worse than
 * no switch.
 */
import { clear, el, on } from '../dom.js'
import { L } from '../../shared/lang.js'
import { store } from '../state.js'
import { call, platform } from '../bridge.js'
import { SHORTCUTS, groupTitle, keyFor, type ShortcutGroup } from '../../shared/shortcuts.js'
import { SUBTITLE_FIELDS, encodeSubtitle, parseSubtitle, subtitleName, toggledSubtitle } from '../../shared/subtitle.js'

export interface SettingsActions {
  /** Writes the patch and makes the window follow it. */
  set: (patch: Record<string, unknown>) => void
  chooseLibrary: () => void
  /** The report sheet, from the About section. */
  feedback: () => void
}

/** Where the sheet opens: at the top, or at one of its sections. */
export type SettingsSection = 'about' | 'shortcuts'

const PAGE_URL = 'https://icecoffee2500.github.io/paper-time/'
const TOGETHER_URL = 'https://icecoffee2500.github.io/paper-time/#together'

let open = false

/** One row: a name on the left, and the choices on the right. */
function choices<T extends string>(
  label: string,
  options: readonly (readonly [T, string])[],
  current: T,
  pick: (value: T) => void,
): HTMLElement {
  const row = el('div', { class: 'set-row' })
  row.append(el('span', { class: 'set-label', text: label }))
  const group = el('div', { class: 'segmented set-seg', role: 'group' })
  for (const [value, name] of options) {
    // `aria-selected` rather than `aria-pressed`: that is the attribute the
    // window's segmented control is drawn from, and the one the inspector's
    // own rows already use.
    const button = el('button', {
      type: 'button',
      text: name,
      'aria-selected': String(value === current),
    })
    on(button, 'click', () => pick(value))
    group.append(button)
  }
  row.append(group)
  return row
}

/** One row with a box to tick on the right: a setting that is on or off. */
function toggle(label: string, isOn: boolean, flip: (value: boolean) => void): HTMLElement {
  const row = el('label', { class: 'set-row' })
  const box = el('input', { type: 'checkbox', class: 'set-check' }) as HTMLInputElement
  box.checked = isOn
  on(box, 'change', () => flip(box.checked))
  row.append(el('span', { class: 'set-label', text: label }), box)
  return row
}

/** A note under a row, with its `…` spans set as code: what is typed, told apart from the words around it. */
function note(text: string): HTMLElement {
  const line = el('p', { class: 'set-note' })
  text.split('`').forEach((part, k) => line.append(k % 2 === 1 ? el('code', { text: part }) : part))
  return line
}

export function showSettings(actions: SettingsActions, section?: SettingsSection) {
  if (open) return
  open = true

  const backdrop = el('div', { class: 'sheet-backdrop' })
  const sheet = el('div', { class: 'fb-sheet set-sheet', role: 'dialog', 'aria-modal': 'true' })
  backdrop.append(sheet)
  document.body.append(backdrop)

  const close = () => {
    backdrop.remove()
    open = false
    document.removeEventListener('keydown', onKey)
  }
  function onKey(event: KeyboardEvent) {
    if (event.key === 'Escape') close()
  }

  const body = el('div', { class: 'set-body' })

  /** Redrawn after every change, because a choice that does not light up
   *  reads as a press that did not land. */
  const draw = () => {
    clear(body)

    body.append(el('div', { class: 'set-section', text: L('라이브러리', 'Library') }))
    const folder = el('div', { class: 'set-row' })
    folder.append(el('span', { class: 'set-label', text: L('폴더', 'Folder') }))
    const name = store.root?.replace(/[\\/]+$/, '').split(/[\\/]/).pop()
    const path = el('span', { class: 'set-path', text: name ?? L('아직 고르지 않았어요', 'Not chosen yet') })
    if (store.root) path.title = store.root
    const pick = el('button', { class: 'plain-button', text: L('고르기…', 'Choose…') })
    on(pick, 'click', () => {
      close()
      actions.chooseLibrary()
    })
    folder.append(path, pick)
    body.append(folder)
    body.append(el('p', {
      class: 'set-note',
      text: L(
        '폴더를 더 여는 것은 사이드바의 «라이브러리 더하기…»에 있어요.',
        'Opening another folder beside it is Add Library… in the sidebar.',
      ),
    }))

    body.append(el('div', { class: 'set-section', text: L('읽기', 'Reading') }))
    body.append(choices(
      L('쪽 배치', 'Page Layout'),
      [['continuous', L('이어서', 'Continuous')], ['single', L('한 쪽씩', 'Single')], ['book', L('책처럼', 'Book')]] as const,
      store.settings.pageLayout,
      (value) => actions.set({ pageLayout: value }),
    ))
    body.append(choices(
      L('쪽 색조', 'Page Tint'),
      [
        ['none', L('없음', 'None')], ['sepia', L('세피아', 'Sepia')],
        ['grey', L('회색', 'Grey')], ['night', L('밤', 'Night')],
      ] as const,
      store.settings.pageTint,
      (value) => actions.set({ pageTint: value }),
    ))

    // Where the Mac keeps it, under Reading: the switch for the palette's
    // section of passages that mean what was typed, and for the index it
    // builds in the background to answer with.
    body.append(toggle(
      L('뜻으로 찾기', 'Search by Meaning'),
      store.settings.semanticSearch !== false,
      (value) => actions.set({ semanticSearch: value }),
    ))
    body.append(note(L(
      '찾을 때 뜻이 비슷한 구절도 같이 보여줘요. 논문은 이 기기에서만 읽어요.',
      'Finds passages that mean what you typed, beside the exact matches. Everything stays on this device.',
    )))

    // What stands under a title in the list, and in what order — the Mac's
    // «Under the Title». The order is the order they were switched on in.
    const fields = parseSubtitle(store.settings.listSubtitle)
    const under = el('div', { class: 'set-row set-wrap' })
    under.append(el('span', { class: 'set-label', text: L('제목 아래에', 'Under the Title') }))
    const chips = el('div', { class: 'set-chips' })
    for (const field of SUBTITLE_FIELDS) {
      const chip = el('button', {
        type: 'button',
        class: 'set-chip',
        text: subtitleName(field),
        'aria-pressed': String(fields.includes(field)),
      })
      on(chip, 'click', () => actions.set({ listSubtitle: encodeSubtitle(toggledSubtitle(fields, field)) }))
      chips.append(chip)
    }
    under.append(chips)
    body.append(under)
    body.append(el('p', { class: 'set-note', text: fields.map(subtitleName).join(' · ') }))

    body.append(el('div', { class: 'set-section', text: L('쓰기', 'Writing') }))
    body.append(toggle(
      L('LaTeX 단축 입력', 'LaTeX Shortcuts'),
      store.settings.latexShortcuts !== false,
      (value) => actions.set({ latexShortcuts: value }),
    ))
    body.append(note(L(
      '`//`를 치면 분수가 되는 것처럼, 짧게 친 말을 LaTeX로 바꿔요.',
      'Expands short triggers into LaTeX as you type, like // into a fraction.',
    )))

    body.append(el('div', { class: 'set-section', text: L('모양', 'Appearance') }))
    body.append(choices(
      L('화면 모드', 'Theme'),
      [
        ['system', L('시스템에 따라', 'System')],
        ['light', L('밝게', 'Light')], ['dark', L('어둡게', 'Dark')],
      ] as const,
      store.settings.appearance,
      (value) => actions.set({ appearance: value }),
    ))
    // The one thing that had no way in at all. Changing it takes a restart —
    // the window's words are read once, at build time of every string — and
    // saying so beside the choice is better than a window that half changes.
    body.append(choices(
      L('말', 'Language'),
      [
        ['system', L('시스템에 따라', 'System')],
        ['ko', '한국어'], ['en', 'English'],
      ] as const,
      store.settings.language,
      (value) => actions.set({ language: value }),
    ))
    body.append(el('p', {
      class: 'set-note',
      text: L('말을 바꾸면 앱을 다시 열어야 해요.', 'Changing the language takes effect when you reopen the app.'),
    }))

    body.append(el('div', { class: 'set-section', text: 'BibTeX' }))
    body.append(toggle(
      L('제목 대소문자 지키기', 'Protect Case in Titles'),
      store.settings.bibtexProtectCase !== false,
      (value) => actions.set({ bibtexProtectCase: value }),
    ))
    body.append(note(L(
      '제목의 대문자를 `{}`로 감싸서, 인용 양식이 «BERT»를 «bert»로 바꾸지 못하게 해요.',
      'Wraps capitals in a title in `{}`, so a citation style cannot turn BERT into bert.',
    )))

    // Every key, to read: on Windows and Linux the window has no menu bar to
    // read them off, so this list and the tooltips are where they are found.
    const keys = el('div', { class: 'set-section', text: L('단축키', 'Shortcuts') })
    keys.dataset.section = 'shortcuts'
    body.append(keys)
    const groups: ShortcutGroup[] = ['library', 'reading', 'marking', 'panes', 'moving', 'app']
    for (const group of groups) {
      body.append(el('div', { class: 'set-subsection', text: groupTitle(group) }))
      for (const entry of SHORTCUTS.filter((one) => one.group === group)) {
        const row = el('div', { class: 'set-row set-key-row' })
        row.append(
          el('span', { class: 'set-label', text: entry.title() }),
          el('span', { class: 'set-key', text: keyFor(entry.command, platform) }),
        )
        body.append(row)
      }
    }

    // About, as the Mac has it at the end of its settings: which version this
    // is, what changed, and the two ways to say something back.
    const about = el('div', { class: 'set-section', text: L('정보', 'About') })
    about.dataset.section = 'about'
    body.append(about)
    const version = el('span', { class: 'set-path', text: '' })
    body.append(el('div', { class: 'set-row' }, [
      el('span', { class: 'set-label', text: 'Paper Time' }),
      version,
    ]))
    void call<{ version: string }>('app:about').then((answer) => {
      version.textContent = L(`버전 ${answer.version}`, `Version ${answer.version}`)
    }).catch(() => undefined)
    const links = el('div', { class: 'set-row set-links' })
    const link = (label: string, press: () => void) => {
      const button = el('button', { type: 'button', class: 'plain-button', text: label })
      on(button, 'click', press)
      return button
    }
    links.append(
      link(L('새로운 기능', "What's New"), () => void call('shell:openExternal', { url: PAGE_URL })),
      link(L('함께 만드는 중', 'Built together'), () => void call('shell:openExternal', { url: TOGETHER_URL })),
      link(L('한마디 보내기…', 'Send Feedback…'), () => {
        close()
        actions.feedback()
      }),
    )
    body.append(links)
  }

  draw()

  const title = el('h2', { class: 'fb-title', text: L('설정', 'Settings') })
  const foot = el('div', { class: 'set-foot' })
  const done = el('button', { class: 'filled-button', text: L('완료', 'Done') })
  on(done, 'click', close)
  foot.append(el('span', { class: 'fb-spacer' }), done)

  sheet.append(title, body, foot)
  on(backdrop, 'click', (event: MouseEvent) => {
    if (event.target === backdrop) close()
  })
  document.addEventListener('keydown', onKey)
  done.focus()
  if (section) {
    // Opened for one part of itself — «About Paper Time» from the ⋯ menu.
    body.querySelector(`[data-section="${section}"]`)?.scrollIntoView({ block: 'start' })
  }

  /** Redrawn in place: a choice that does not light up reads as a press
   *  that did not land — but the page stays where it was scrolled to. */
  const redraw = () => {
    const top = body.scrollTop
    draw()
    body.scrollTop = top
  }
  return { redraw, close }
}
