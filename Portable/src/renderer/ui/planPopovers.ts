/**
 * The two small surfaces the plan opens over the board: a paper's day —
 * typed («금요일», «12/3», «+1주»), picked from four, or pressed on a month —
 * and «Spread Evenly», which asks the weekdays and how many a day and shows
 * what it would do before it does it.
 */
import { clear, el, on } from '../dom.js'
import { paper, planPapers, store } from '../state.js'
import { L, prefersKorean } from '../../shared/lang.js'
import { addDays, dayParts, mondayOf, readDay, spreadDays, weekdayOf } from '../../shared/readingPlan.js'
import { fullDay, monthDay, spreadOrder, spreadPreview, spreadStart, weekdayName } from '../../shared/planBoard.js'
import { boardPaper, prefs, savePrefs, setDay, spread } from '../plans.js'

let open: { node: HTMLElement; anchor: Element; kind: 'date' | 'spread'; id: string; away: (event: MouseEvent) => void } | null = null

export function isPlanPopOpen(): boolean {
  return open !== null
}

export function closePlanPop() {
  if (!open) return
  open.node.remove()
  document.removeEventListener('mousedown', open.away, true)
  open = null
}

/** The same popover asked for again from the same place: it goes away instead. */
function toggleAt(anchor: Element, kind: 'date' | 'spread', id: string): boolean {
  if (open && open.anchor === anchor && open.kind === kind && open.id === id) {
    closePlanPop()
    return false
  }
  closePlanPop()
  return true
}

function place(node: HTMLElement, anchor: Element) {
  document.body.append(node)
  const box = anchor.getBoundingClientRect()
  const size = node.getBoundingClientRect()
  const left = Math.max(8, Math.min(box.left, window.innerWidth - size.width - 8))
  let top = box.bottom + 6
  if (top + size.height > window.innerHeight - 8) top = Math.max(8, box.top - size.height - 6)
  node.style.left = `${left}px`
  node.style.top = `${top}px`
}

function show(node: HTMLElement, anchor: Element, kind: 'date' | 'spread', id: string) {
  const away = (event: MouseEvent) => {
    if (node.contains(event.target as Node) || anchor.contains(event.target as Node)) return
    closePlanPop()
  }
  document.addEventListener('mousedown', away, true)
  open = { node, anchor, kind, id, away }
  place(node, anchor)
}

// Escape puts the popover away before anything else hears it.
window.addEventListener('keydown', (event: KeyboardEvent) => {
  if (open && event.key === 'Escape') {
    event.preventDefault()
    event.stopPropagation()
    closePlanPop()
  }
}, true)
window.addEventListener('resize', () => closePlanPop())

// MARK: - A paper's day

export function openDatePop(anchor: Element, paperID: string) {
  if (!toggleAt(anchor, 'date', paperID)) return
  const entry = paper(paperID)
  if (!entry) return
  const today = store.today
  const node = el('div', { class: 'plan-pop', role: 'dialog', 'aria-label': L('읽을 날', 'Read On') })
  const field = el('input', {
    class: 'pp-field',
    type: 'text',
    placeholder: L('금요일, 12/3, +1주처럼 적어요', 'Friday, 12/3, +1w…'),
    autocomplete: 'off',
    spellcheck: 'false',
  }) as HTMLInputElement
  const preview = el('div', { class: 'pp-preview' })
  const pick = (date: string | null) => {
    closePlanPop()
    void setDay(paperID, date)
  }
  on(field, 'input', () => {
    const typed = field.value.trim()
    const day = readDay(typed, today)
    preview.textContent = day ? L(`→ ${fullDay(day)} · Enter`, `→ ${fullDay(day)} · Return`) : typed ? L('아직 못 읽었어요', "Can't read that yet") : ''
  })
  on(field, 'keydown', (event: KeyboardEvent) => {
    if (event.key !== 'Enter') return
    event.preventDefault()
    const day = readDay(field.value, today)
    if (day) pick(day)
  })

  let friday = today
  for (let i = 0; i < 7; i += 1) if (weekdayOf(addDays(today, i)) === 4) { friday = addDays(today, i); break }
  const quick = el('div', { class: 'pp-quick' })
  // The weekday beside the date only where the label does not already say it.
  for (const [label, day, named] of [
    [L('오늘', 'Today'), today, false],
    [L('내일', 'Tomorrow'), addDays(today, 1), false],
    [L('이번 금요일', 'This Friday'), friday, true],
    [L('다음 주 월요일', 'Next Monday'), addDays(mondayOf(today), 7), true],
  ] as const) {
    const button = el('button', { class: 'pp-quick-button', title: fullDay(day) }, [
      el('span', { text: label }),
      el('small', { text: named ? monthDay(day) : `${weekdayName(weekdayOf(day))} ${monthDay(day)}` }),
    ])
    on(button, 'click', () => pick(day))
    quick.append(button)
  }

  const names = el('div', { class: 'pp-week' }, Array.from({ length: 7 }, (_, at) => el('span', { text: weekdayName(at) })))
  const grid = el('div', { class: 'pp-month' })
  const start = mondayOf(today)
  for (let i = 0; i < 35; i += 1) {
    const day = addDays(start, i)
    const classes = ['pp-day']
    if (day === today) classes.push('today')
    if (day === entry.schedule) classes.push('chosen')
    const cell = el('button', { class: classes.join(' '), text: String(dayParts(day)[2]), title: fullDay(day) })
    on(cell, 'click', () => pick(day))
    grid.append(cell)
  }
  node.append(field, preview, quick, names, grid)
  if (entry.schedule) {
    const clearDay = el('button', { class: 'pp-clear', text: L('날짜 지우기', 'Clear Date') })
    on(clearDay, 'click', () => pick(null))
    node.append(clearDay)
  }
  show(node, anchor, 'date', paperID)
  field.focus({ preventScroll: true })
}

// MARK: - Spread Evenly

export function openSpreadPop(anchor: Element, planID: string) {
  if (!toggleAt(anchor, 'spread', planID)) return
  const node = el('div', { class: 'plan-pop', role: 'dialog', 'aria-label': L('고르게 나누기', 'Spread Out') })
  const draw = () => {
    const choice = prefs().spread
    clear(node)
    const order = spreadOrder(planPapers(planID).map(boardPaper))
    const days = spreadDays(order.length, choice.days, choice.per, spreadStart(choice.from, store.today))
    const weekdays = el('span', { class: 'pp-weekdays' })
    for (const day of [0, 1, 2, 3, 4, 5, 6]) {
      // Two letters in English — «Sun» does not fit a 25-point circle; the full name is the title.
      const button = el('button', { text: prefersKorean() ? weekdayName(day) : weekdayName(day).slice(0, 2), title: weekdayName(day), 'aria-pressed': String(choice.days.includes(day)) })
      on(button, 'click', () => {
        savePrefs((prefs) => {
          prefs.spread.days = prefs.spread.days.includes(day) ? prefs.spread.days.filter((one) => one !== day) : [...prefs.spread.days, day].sort()
        })
        draw()
      })
      weekdays.append(button)
    }
    const step = (by: number) => {
      const button = el('button', { text: by < 0 ? '−' : '+', 'aria-label': by < 0 ? L('줄이기', 'Fewer') : L('늘리기', 'More') })
      on(button, 'click', () => {
        savePrefs((prefs) => { prefs.spread.per = Math.max(1, Math.min(3, prefs.spread.per + by)) })
        draw()
      })
      return button
    }
    const from = el('span', { class: 'pb-seg' })
    for (const [value, label] of [['today', L('오늘부터', 'Today')], ['next', L('다음 주부터', 'Next Week')]] as const) {
      const button = el('button', { text: label, 'aria-pressed': String(choice.from === value) })
      on(button, 'click', () => {
        savePrefs((prefs) => { prefs.spread.from = value })
        draw()
      })
      from.append(button)
    }
    const apply = el('button', { class: 'pb-cap strong', text: L('날짜 정하기', 'Set Days') }) as HTMLButtonElement
    apply.disabled = days.length === 0
    on(apply, 'click', () => {
      closePlanPop()
      void spread(planID, prefs().spread)
    })
    node.append(
      el('h4', { text: L('고르게 나누기', 'Spread Out') }),
      el('p', { class: 'pp-sub', text: L('아직 안 읽은 논문에 차례대로 날짜를 정해요.', 'Gives each unread paper a day, in order.') }),
      el('div', { class: 'pp-row' }, [el('span', { text: L('요일', 'Days') }), weekdays]),
      el('div', { class: 'pp-row' }, [
        el('span', { text: L('하루에', 'Per day') }),
        el('span', { class: 'pp-stepper' }, [step(-1), el('b', { text: L(`${choice.per}편`, `${choice.per}`) }), step(1)]),
      ]),
      el('div', { class: 'pp-row' }, [el('span', { text: L('시작', 'Start') }), from]),
      el('div', { class: 'pp-spread-preview', text: spreadPreview(days, choice.days.length) }),
      el('div', { class: 'pp-foot' }, [apply]),
    )
  }
  draw()
  show(node, anchor, 'spread', planID)
}
