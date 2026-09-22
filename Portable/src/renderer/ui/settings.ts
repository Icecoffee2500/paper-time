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

export interface SettingsActions {
  /** Writes the patch and makes the window follow it. */
  set: (patch: Record<string, unknown>) => void
  chooseLibrary: () => void
  showReleaseNotes?: () => void
}

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

export function showSettings(actions: SettingsActions) {
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
      [['continuous', L('이어서', 'Continuous')], ['single', L('한 쪽씩', 'Single')]] as const,
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

  return { redraw: draw, close }
}
