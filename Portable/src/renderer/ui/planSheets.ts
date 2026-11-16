/**
 * The two sheets a plan is made and filled with, so that nobody has to read
 * a manual to know how: «새 계획» asks a name, the papers and — if wanted now
 * — the days, in three numbered parts; «논문 더하기» is the same picker for a
 * plan that has some already. The papers chosen when a sheet opens are
 * listed first and stay where they are while boxes are ticked
 * (`pickerOrder`); the search reads titles and authors (`pickerShown`).
 */
import { clear, el, on } from '../dom.js'
import { iconNode } from '../icons.js'
import { planByID, store, type Paper } from '../state.js'
import { L, prefersKorean } from '../../shared/lang.js'
import { spreadDays } from '../../shared/readingPlan.js'
import {
  authorsText, pickerOrder, pickerShown, spreadOrder, spreadPreview, spreadStart, weekdayName, type PickerPaper,
} from '../../shared/planBoard.js'
import { addToPlan, boardPaper, createPlanFromSheet, prefs, savePrefs, type BoardPrefs } from '../plans.js'

/** What a row says under its title: «Kumar 외 · 2020». */
function whoLine(entry: Paper): string {
  const year = entry.meta.year
  return [authorsText(entry.meta.csl.author), year ? String(year) : ''].filter(Boolean).join(' · ')
}

function pickerPapers(): PickerPaper[] {
  return store.papers
    .filter((entry) => !entry.meta.parentID)
    .map((entry) => ({
      id: entry.id,
      title: entry.meta.displayTitle,
      search: [entry.meta.displayTitle, ...(entry.meta.csl.author ?? []).map((one) => [one.given, one.family, one.literal].filter(Boolean).join(' '))].join(' '),
    }))
}

interface Frame {
  backdrop: HTMLElement
  sheet: HTMLElement
  close: () => void
}

/** The sheet's frame — the settings sheet's, so the window has one shape of sheet. */
function frame(className: string, label: string): Frame {
  const backdrop = el('div', { class: 'sheet-backdrop' })
  const sheet = el('div', { class: `fb-sheet set-sheet plan-sheet ${className}`, role: 'dialog', 'aria-modal': 'true', 'aria-label': label })
  backdrop.append(sheet)
  document.body.append(backdrop)
  const close = () => backdrop.remove()
  on(backdrop, 'mousedown', (event: MouseEvent) => {
    if (event.target === backdrop) close()
  })
  on(sheet, 'keydown', (event: KeyboardEvent) => {
    // The window's own keys — a letter picks a drawing tool — must not hear what is typed here.
    event.stopPropagation()
    if (event.key === 'Escape') {
      event.preventDefault()
      close()
    }
  })
  return { backdrop, sheet, close }
}

function part(number: string, label: string, extra: Node[] = []): HTMLElement {
  return el('div', { class: 'ps-part-head' }, [el('span', { class: 'ps-num', text: number }), el('span', { class: 'ps-label', text: label }), ...extra])
}

/** The list of papers to tick, with its search and «Chosen only». */
function picker(options: { chosen: string[]; locked: Set<string>; onChange: () => void }) {
  const papers = pickerPapers()
  const byID = new Map(store.papers.map((entry) => [entry.id, entry]))
  const order = pickerOrder(papers, options.chosen, options.locked)
  let chosenOnly = false
  const search = el('input', {
    class: 'ask-field ps-search',
    type: 'search',
    placeholder: L('제목·저자로 찾기', 'Search by title or author'),
    spellcheck: 'false',
    autocomplete: 'off',
  }) as HTMLInputElement
  const only = el('button', { class: 'ps-chip', 'aria-pressed': 'false', text: L('고른 것만', 'Chosen only') })
  const list = el('div', { class: 'ps-list', role: 'listbox', 'aria-multiselectable': 'true' })
  const count = el('span', { class: 'ps-count' })

  const sayCount = () => {
    const n = options.chosen.length
    count.textContent = L(`${n}편 골랐어요`, `${n} chosen`)
  }

  const draw = () => {
    const kept = list.scrollTop
    clear(list)
    const shown = pickerShown(order, papers, search.value, chosenOnly, [...options.chosen, ...options.locked])
    for (const id of shown) {
      const entry = byID.get(id)
      if (!entry) continue
      const locked = options.locked.has(id)
      const picked = locked || options.chosen.includes(id)
      const check = el('span', { class: 'ps-check' })
      if (picked) {
        const tick = iconNode('checkmark')
        if (tick) check.append(tick)
      }
      const row = el('button', {
        class: `ps-row${picked ? ' on' : ''}${locked ? ' locked' : ''}`,
        role: 'option',
        'aria-selected': String(picked),
        'data-id': id,
        title: entry.meta.displayTitle,
      }, [
        check,
        el('span', { class: 'ps-text' }, [
          el('span', { class: 'ps-title', text: entry.meta.displayTitle }),
          el('span', { class: 'ps-who', text: locked ? L('이미 있어요', 'Already in') : whoLine(entry) }),
        ]),
      ]) as HTMLButtonElement
      if (locked) row.disabled = true
      on(row, 'click', () => {
        const at = options.chosen.indexOf(id)
        if (at >= 0) options.chosen.splice(at, 1)
        else options.chosen.push(id)
        sayCount()
        draw()
        options.onChange()
      })
      list.append(row)
    }
    if (shown.length === 0) {
      list.append(el('div', { class: 'ps-none', text: chosenOnly && options.chosen.length === 0 ? L('아직 고른 논문이 없어요', 'Nothing chosen yet') : L('맞는 논문이 없어요', 'No paper matches') }))
    }
    list.scrollTop = kept
  }

  on(search, 'input', draw)
  on(only, 'click', () => {
    chosenOnly = !chosenOnly
    only.setAttribute('aria-pressed', String(chosenOnly))
    draw()
  })
  sayCount()
  draw()
  return { search, only, list, count }
}

/** The weekdays, how many a day and from when — the controls «Spread Out» has. */
function dayControls(choice: BoardPrefs['spread'], papers: () => string[], onChange: () => void): HTMLElement {
  const box = el('div', { class: 'ps-days' })
  const draw = () => {
    clear(box)
    const weekdays = el('span', { class: 'pp-weekdays' })
    for (const day of [0, 1, 2, 3, 4, 5, 6]) {
      const button = el('button', { text: prefersKorean() ? weekdayName(day) : weekdayName(day).slice(0, 2), title: weekdayName(day), 'aria-pressed': String(choice.days.includes(day)) })
      on(button, 'click', () => {
        choice.days = choice.days.includes(day) ? choice.days.filter((one) => one !== day) : [...choice.days, day].sort()
        draw()
        onChange()
      })
      weekdays.append(button)
    }
    const step = (by: number) => {
      const button = el('button', { text: by < 0 ? '−' : '+', 'aria-label': by < 0 ? L('줄이기', 'Fewer') : L('늘리기', 'More') })
      on(button, 'click', () => {
        choice.per = Math.max(1, Math.min(3, choice.per + by))
        draw()
        onChange()
      })
      return button
    }
    const from = el('span', { class: 'pb-seg' })
    for (const [value, label] of [['today', L('오늘부터', 'Today')], ['next', L('다음 주부터', 'Next Week')]] as const) {
      const button = el('button', { text: label, 'aria-pressed': String(choice.from === value) })
      on(button, 'click', () => {
        choice.from = value
        draw()
        onChange()
      })
      from.append(button)
    }
    const ids = papers()
    const order = spreadOrder(ids.map((id) => store.papers.find((entry) => entry.id === id)).filter((entry): entry is Paper => Boolean(entry)).map(boardPaper))
    const days = spreadDays(order.length, choice.days, choice.per, spreadStart(choice.from, store.today))
    box.append(
      el('div', { class: 'pp-row' }, [el('span', { text: L('요일', 'Days') }), weekdays]),
      el('div', { class: 'pp-row' }, [
        el('span', { text: L('하루에', 'Per day') }),
        el('span', { class: 'pp-stepper' }, [step(-1), el('b', { text: L(`${choice.per}편`, `${choice.per}`) }), step(1)]),
      ]),
      el('div', { class: 'pp-row' }, [el('span', { text: L('시작', 'Start') }), from]),
      el('div', { class: 'pp-spread-preview', text: ids.length === 0 ? L('고른 논문이 생기면 여기서 날짜를 보여줘요.', 'The days show here once papers are chosen.') : spreadPreview(days, choice.days.length) }),
    )
  }
  draw()
  return box
}

// MARK: - New Plan

export interface PlanSheetOptions {
  name?: string
  preselected?: string[]
}

/** «새 계획»: a name, the papers, and the days if they are wanted now. */
export function openPlanSheet(options: PlanSheetOptions = {}) {
  const { sheet, close } = frame('plan-sheet-new', L('새 계획', 'New Plan'))
  const chosen = [...new Set(options.preselected ?? [])]
  const days: BoardPrefs['spread'] = structuredClone(prefs().spread)
  let giveDays = false

  const name = el('input', {
    class: 'ask-field ps-name',
    type: 'text',
    placeholder: L('예: Offline RL 정주행', 'e.g. Offline RL, in Order'),
    spellcheck: 'false',
    autocomplete: 'off',
    'aria-label': L('이름', 'Name'),
  }) as HTMLInputElement
  name.value = options.name ?? ''

  const create = el('button', { class: 'filled-button', text: L('계획 만들기', 'Create Plan') }) as HTMLButtonElement
  const refresh = () => {
    create.disabled = name.value.trim().length === 0
  }
  const daysSlot = el('div', { class: 'ps-days-slot' })
  const redrawDays = () => {
    clear(daysSlot)
    if (giveDays) daysSlot.append(dayControls(days, () => chosen, () => {}))
  }
  const pick = picker({ chosen, locked: new Set(), onChange: redrawDays })

  const toggle = el('input', { type: 'checkbox', class: 'set-check', 'aria-label': L('날짜도 지금 정하기', 'Give them days now') }) as HTMLInputElement
  on(toggle, 'change', () => {
    giveDays = toggle.checked
    redrawDays()
  })

  const submit = () => {
    const title = name.value.trim()
    if (!title) {
      name.focus()
      return
    }
    close()
    if (giveDays) savePrefs((stored) => { stored.spread = { ...days } })
    void createPlanFromSheet(title, [...chosen], giveDays ? days : null)
  }
  on(name, 'input', refresh)
  on(name, 'keydown', (event: KeyboardEvent) => {
    if (event.key === 'Enter') {
      event.preventDefault()
      submit()
    }
  })
  on(create, 'click', submit)
  const cancel = el('button', { class: 'plain-button', text: L('취소', 'Cancel') })
  on(cancel, 'click', close)

  sheet.append(
    el('h2', { class: 'fb-title', text: L('새 계획', 'New Plan') }),
    el('p', { class: 'ps-sub', text: L('읽을 논문을 모으고, 원하면 날짜까지 한 번에 정해요.', 'Gather the papers to read and, if you like, give them days in one go.') }),
    el('div', { class: 'set-body ps-body' }, [
      el('section', { class: 'ps-part' }, [part('1', L('이름', 'Name')), name]),
      el('section', { class: 'ps-part' }, [
        part('2', L('논문', 'Papers'), [el('span', { class: 'pb-spacer' }), pick.count]),
        el('div', { class: 'ps-search-row' }, [pick.search, pick.only]),
        pick.list,
      ]),
      el('section', { class: 'ps-part' }, [
        part('3', L('날짜', 'Days'), [el('span', { class: 'ps-optional', text: L('골라도 되고 안 골라도 돼요', 'Optional') })]),
        el('label', { class: 'set-row ps-toggle' }, [el('span', { class: 'set-label', text: L('날짜도 지금 정하기', 'Give them days now') }), toggle]),
        daysSlot,
      ]),
    ]),
    el('div', { class: 'set-foot' }, [el('span', { class: 'fb-spacer' }), cancel, create]),
  )
  refresh()
  name.focus()
  if (name.value) name.select()
}

// MARK: - Add Papers

/** «논문 더하기»: the picker, for a plan that has some papers already. */
export function openAddPapersSheet(planID: string) {
  const found = planByID(planID)
  if (!found) return
  const { sheet, close } = frame('plan-sheet-add', L('논문 더하기', 'Add Papers'))
  const chosen: string[] = []
  const locked = new Set(found.plan.entries.map((entry) => entry.paper))
  const add = el('button', { class: 'filled-button' }) as HTMLButtonElement
  const refresh = () => {
    add.textContent = L(`${chosen.length}편 더하기`, `Add ${chosen.length}`)
    add.disabled = chosen.length === 0
  }
  const pick = picker({ chosen, locked, onChange: refresh })
  on(add, 'click', () => {
    if (chosen.length === 0) return
    close()
    void addToPlan(planID, [...chosen])
  })
  const cancel = el('button', { class: 'plain-button', text: L('취소', 'Cancel') })
  on(cancel, 'click', close)
  sheet.append(
    el('h2', { class: 'fb-title', text: L('논문 더하기', 'Add Papers') }),
    el('p', { class: 'ps-sub', text: L(`‘${found.plan.name}’에 넣을 논문을 골라요.`, `Choose the papers to put in “${found.plan.name}”.`) }),
    el('div', { class: 'set-body ps-body' }, [
      el('section', { class: 'ps-part' }, [
        el('div', { class: 'ps-part-head' }, [el('span', { class: 'ps-label', text: L('논문', 'Papers') }), el('span', { class: 'pb-spacer' }), pick.count]),
        el('div', { class: 'ps-search-row' }, [pick.search, pick.only]),
        pick.list,
      ]),
    ]),
    el('div', { class: 'set-foot' }, [el('span', { class: 'fb-spacer' }), cancel, add]),
  )
  refresh()
  pick.search.focus()
}
