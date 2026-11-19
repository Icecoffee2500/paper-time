/**
 * The slip-box's projects (1.1, the Mac's `ProjectViews.swift`): the list of
 * them, and one project's page — planned backwards from its deadline. The
 * head (how far, how long left), the milestones on a track, the steps as a
 * board or along a timeline, and what it draws on.
 *
 * The list stands in the list's column; the page in the page area. With no
 * project chosen and no list beside it, the page is the list, larger.
 */
import { clear, el, on } from '../dom.js'
import { icon, iconNode, type IconName } from '../icons.js'
import { L, prefersKorean } from '../../shared/lang.js'
import { noteByID, paper, planByID, projectByID, store, type Paper } from '../state.js'
import { carriesNote, carriesPapers, draggedNote, draggedPapers } from '../../shared/split.js'
import { addDays, dayOrdinal, dayParts, mondayOf, readDay, weekdayOf } from '../../shared/readingPlan.js'
import { fullDay, longDay, monthDay, progress as readingProgress, weekdayName, type Status } from '../../shared/planBoard.js'
import { areaTitle } from '../../shared/noteAreas.js'
import { zettelDisplayTitle } from '../../shared/zettel.js'
import {
  TODO_STATES, daysLeft, ddayText, newMilestone, newTodo, projectProgress, projectSpan, projectStatusLabel, spanDay, spanShift,
  spanX, splitDay, todoBar, todoStateLabel, todosIn, type Project, type ProjectStatus, type Todo, type TodoState,
} from '../../shared/project.js'
import { saveSettings } from '../settingsController.js'
import {
  addNotesToProject, addToProject, askNewProject, deleteProject, editProject, renameProject, showProject, statusEntries,
} from '../projects.js'
import { showMenu, showMenuAt, type MenuEntry } from './toolbar.js'
import { shelfHeader } from './shelfHeader.js'
import { ring } from './planBoard.js'
import { backToNotes } from './slipBox.js'

export interface ProjectActions {
  /** A paper opened from the project: where papers open. */
  openPaper: (id: string) => void
  /** A note the project draws on, opened beside it. */
  openNote: (id: string) => void
  /** A reading plan the project reads through, shown. */
  openPlan: (id: string) => void
  /** A pane of papers opened beside the project, to drag from (1.1). */
  showPapers: () => void
  /** Whether a pane of papers stands in the row already. */
  papersShown: () => boolean
  /** Whether the list's column is showing (the page is the list when it is not). */
  listShown: () => boolean
}

/** The kind of thing a drag on the board carries: a step going to another column. */
const TODO_TYPE = 'application/x-papertime-todo'

const glyph = (name: IconName): Node => iconNode(name) ?? document.createTextNode('')

/** The project's progress, as the ring the papers wear — with the percentage when it is big. */
export function projectRing(fraction: number, size: number, done = false): string {
  const stroke = size > 30 ? 5 : 3
  const r = (size - stroke) / 2
  const c = 2 * Math.PI * r
  const tint = done ? 'var(--shelf-read)' : 'var(--accent)'
  const text = size > 30
    ? `<text x="50%" y="50%" text-anchor="middle" dominant-baseline="central" font-size="${(size * 0.24).toFixed(1)}" font-weight="700" fill="var(--text)">${Math.round(fraction * 100)}%</text>`
    : ''
  return `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" aria-hidden="true">`
    + `<circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="var(--separator)" stroke-width="${stroke}"/>`
    + `<circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${tint}" stroke-width="${stroke}" stroke-linecap="round" `
    + `stroke-dasharray="${(c * Math.max(0.001, fraction)).toFixed(2)} ${c.toFixed(2)}" transform="rotate(-90 ${size / 2} ${size / 2})"/>`
    + `${text}</svg>`
}

/** How a deadline's D-day is tinted: past it orange, within two weeks the accent. */
function ddayTone(days: number): 'late' | 'near' | 'far' {
  return days < 0 ? 'late' : days <= 14 ? 'near' : 'far'
}

/** «Chen et al. · 2026». */
function byline(entry: Paper): string {
  return [entry.meta.displayAuthors, entry.meta.year ? String(entry.meta.year) : ''].filter(Boolean).join(' · ')
}

/** A paper's reading ring, as the lists draw it. */
export function paperRing(entry: Paper, size = 15): string {
  const status = entry.state.readingStatus as Status
  return ring(status, readingProgress(entry.meta.file.pageCount, entry.state.lastPageIndex, status).fraction, size)
}

// MARK: - Popovers

interface Pop {
  node: HTMLElement
  anchor: Element | null
  close: () => void
}

/** The popovers open now, the last one on top — a day picker over a step's editor. */
const pops: Pop[] = []

function closePopsFrom(index: number) {
  for (const pop of pops.splice(index)) pop.close()
}

export function closeProjectPops() {
  closePopsFrom(0)
}

/**
 * A small surface over the page, beside what opened it — the Mac's
 * `.popover`. A press outside it puts it (and anything opened from it)
 * away; Escape puts away the top one.
 */
function openPop(anchor: Element | { x: number; y: number }, content: HTMLElement, options: { side?: 'below' | 'right'; onClose?: () => void } = {}): Pop {
  const node = el('div', { class: 'plan-pop pj-pop', role: 'dialog' }, [content])
  document.body.append(node)
  const size = node.getBoundingClientRect()
  let left: number
  let top: number
  if ('x' in anchor) {
    left = anchor.x
    top = anchor.y
  } else {
    const box = anchor.getBoundingClientRect()
    if (options.side === 'right') {
      left = box.right + 8
      top = box.top
      if (left + size.width > window.innerWidth - 8) left = box.left - size.width - 8
    } else {
      left = box.left
      top = box.bottom + 6
      if (top + size.height > window.innerHeight - 8) top = box.top - size.height - 6
    }
  }
  node.style.left = `${Math.max(8, Math.min(left, window.innerWidth - size.width - 8))}px`
  node.style.top = `${Math.max(8, Math.min(top, window.innerHeight - size.height - 8))}px`
  let closed = false
  const pop: Pop = {
    node,
    anchor: 'x' in anchor ? null : anchor,
    close: () => {
      if (closed) return
      closed = true
      node.remove()
      options.onClose?.()
    },
  }
  pops.push(pop)
  return pop
}

// A press outside every popover from this one up puts them away.
window.addEventListener('mousedown', (event: MouseEvent) => {
  if (pops.length === 0) return
  const target = event.target as Node
  const inside = pops.findIndex((pop) => pop.node.contains(target))
  const through = pops.findIndex((pop) => pop.anchor?.contains(target))
  if (inside >= 0) closePopsFrom(inside + 1)
  else if (through >= 0) closePopsFrom(through)
  else closePopsFrom(0)
}, true)
window.addEventListener('keydown', (event: KeyboardEvent) => {
  if (pops.length === 0 || event.key !== 'Escape') return
  event.preventDefault()
  event.stopPropagation()
  closePopsFrom(pops.length - 1)
}, true)
window.addEventListener('resize', () => closeProjectPops())

/**
 * A day, picked: typed («금요일», «12/3», «+1주»), one of four, or pressed
 * on a month that can be turned — the Mac's `DayPicker`.
 */
function openDayPicker(anchor: Element, current: string | null, pick: (day: string | null) => void) {
  const today = store.today
  const box = el('div', { class: 'pj-daypick' })
  let pop: Pop | null = null
  const choose = (day: string | null) => {
    pop?.close()
    const at = pops.indexOf(pop!)
    if (at >= 0) pops.splice(at, 1)
    pick(day)
  }
  const field = el('input', {
    class: 'pp-field', type: 'text', autocomplete: 'off', spellcheck: 'false',
    placeholder: L('금요일, 12/3, +1주처럼 적어요', 'Friday, 12/3, +1w…'),
  }) as HTMLInputElement
  const preview = el('div', { class: 'pp-preview' })
  on(field, 'input', () => {
    const typed = field.value.trim()
    const day = readDay(typed, today)
    preview.textContent = day ? L(`→ ${fullDay(day)} · Enter`, `→ ${fullDay(day)} · Return`) : typed ? L('아직 못 읽었어요', "Can't read that yet") : ''
  })
  on(field, 'keydown', (event: KeyboardEvent) => {
    event.stopPropagation()
    if (event.key === 'Escape') {
      choose(current)
      return
    }
    if (event.key !== 'Enter') return
    event.preventDefault()
    const day = readDay(field.value, today)
    if (day) choose(day)
  })
  let friday = today
  for (let i = 0; i < 7; i += 1) if (weekdayOf(addDays(today, i)) === 4) { friday = addDays(today, i); break }
  const quick = el('div', { class: 'pp-quick' })
  for (const [label, day] of [
    [L('오늘', 'Today'), today],
    [L('내일', 'Tomorrow'), addDays(today, 1)],
    [L('이번 금요일', 'This Friday'), friday],
    [L('다음 주 월요일', 'Next Monday'), addDays(mondayOf(today), 7)],
  ] as const) {
    const button = el('button', { class: 'pp-quick-button', title: fullDay(day) }, [el('span', { text: label }), el('small', { text: monthDay(day) })])
    on(button, 'click', () => choose(day))
    quick.append(button)
  }
  // A month, turned with the arrows: a deadline is often further than five weeks.
  let shown = (current ?? today).slice(0, 7)
  const monthHead = el('div', { class: 'pj-month-head' })
  const grid = el('div', { class: 'pp-month' })
  const names = el('div', { class: 'pp-week' }, Array.from({ length: 7 }, (_, at) => el('span', { text: weekdayName(at) })))
  const drawMonth = () => {
    clear(monthHead)
    clear(grid)
    const [year, month] = shown.split('-').map(Number)
    const back = el('button', { class: 'icon-button', title: L('이전 달', 'Previous Month'), html: icon('chevron.left') })
    const ahead = el('button', { class: 'icon-button', title: L('다음 달', 'Next Month'), html: icon('chevron.right') })
    const turn = (by: number) => {
      const index = year * 12 + (month - 1) + by
      shown = `${String(Math.floor(index / 12)).padStart(4, '0')}-${String((index % 12) + 1).padStart(2, '0')}`
      drawMonth()
    }
    on(back, 'click', () => turn(-1))
    on(ahead, 'click', () => turn(1))
    const title = prefersKorean() ? `${year}년 ${month}월` : `${longDay(`${shown}-01`).split(' ')[0]} ${year}`
    monthHead.append(back, el('span', { class: 'pj-month-title', text: title }), ahead)
    const first = `${shown}-01`
    const start = mondayOf(first)
    for (let i = 0; i < 42; i += 1) {
      const day = addDays(start, i)
      const classes = ['pp-day']
      if (day.slice(0, 7) !== shown) classes.push('pj-other-month')
      if (day === today) classes.push('today')
      if (day === current) classes.push('chosen')
      const cell = el('button', { class: classes.join(' '), text: String(dayParts(day)[2]), title: fullDay(day) })
      on(cell, 'click', () => choose(day))
      grid.append(cell)
    }
  }
  drawMonth()
  box.append(field, preview, quick, monthHead, names, grid)
  if (current) {
    const clearDay = el('button', { class: 'pp-clear', text: L('날짜 지우기', 'Clear Date') })
    on(clearDay, 'click', () => choose(null))
    box.append(clearDay)
  }
  pop = openPop(anchor, box)
  field.focus({ preventScroll: true })
}

// MARK: - The list of projects

/** One project as a row: ring, name, goal, how long left (`ProjectRow`). */
function projectRow(project: Project, options: { selected: boolean; large: boolean }): HTMLElement {
  const done = project.status === 'done'
  const row = el('div', {
    class: options.large ? 'pj-row pj-row-large' : 'pj-row',
    role: 'option',
    'aria-selected': String(options.selected),
    'data-project': project.id,
    tabindex: '-1',
  })
  row.append(el('span', { class: 'pj-row-ring', html: projectRing(projectProgress(project), options.large ? 26 : 20, done) }))
  const lines = el('div', { class: 'pj-row-lines' }, [el('span', { class: 'pj-row-name', text: project.name })])
  if (project.goal) lines.append(el('span', { class: 'pj-row-goal', text: project.goal }))
  row.append(lines)
  const days = daysLeft(project, store.today)
  if (days !== null && !done) row.append(el('span', { class: 'pj-dday', 'data-tone': ddayTone(days), text: ddayText(days) }))
  on(row, 'click', () => showProject(project.id))
  on(row, 'contextmenu', (event: MouseEvent) => {
    event.preventDefault()
    showMenuAt({ x: event.clientX, y: event.clientY }, projectMenu(project.id))
  })
  return row
}

/** What a right-click on a project offers: its name, its status, and the way out. */
export function projectMenu(id: string): MenuEntry[] {
  return [
    { label: L('이름 바꾸기…', 'Rename…'), icon: 'square.and.pencil', action: () => void renameProject(id) },
    { label: L('상태', 'Status'), icon: 'flag', children: statusEntries(id) },
    { separator: true },
    { label: L('프로젝트 지우기…', 'Delete Project…'), icon: 'trash', danger: true, action: () => void deleteProject(id) },
  ]
}

/** The projects by status: under way, then paused, then the finished ones folded away. */
function drawProjectGroups(body: HTMLElement, options: { large: boolean; showsDone: boolean; toggleDone: () => void; chosen: string | null }) {
  const chosen = options.chosen
  const all = store.projects.map((one) => one.project)
  for (const status of ['active', 'paused'] as ProjectStatus[]) {
    const rows = all.filter((one) => one.status === status)
    if (rows.length === 0) continue
    body.append(el('div', { class: 'pj-group', text: projectStatusLabel(status) }))
    for (const project of rows) body.append(projectRow(project, { selected: project.id === chosen, large: options.large }))
  }
  const done = all.filter((one) => one.status === 'done')
  if (done.length > 0) {
    const head = el('button', { class: `pj-group pj-group-fold${options.showsDone ? ' open' : ''}`, 'aria-expanded': String(options.showsDone) }, [
      el('span', { class: 'fold-chevron' }, [glyph('chevron.right')]),
      el('span', { text: L(`끝남 ${done.length}개`, `Done (${done.length})`) }),
    ])
    on(head, 'click', options.toggleDone)
    body.append(head)
    if (options.showsDone) for (const project of done) body.append(projectRow(project, { selected: project.id === chosen, large: options.large }))
  }
}

function emptyProjects(): HTMLElement {
  const make = el('button', { class: 'filled-button', text: L('새 프로젝트…', 'New Project…') })
  on(make, 'click', () => void askNewProject())
  return el('div', { class: 'empty pj-empty' }, [
    el('span', { html: icon('flag') }),
    el('h2', { text: L('아직 프로젝트가 없어요', 'No Projects Yet') }),
    el('p', { text: L('마감을 정하고, 이정표를 놓고, 할 일을 옮기며 끝까지 가요.', 'Set a deadline, place the milestones, and move the steps along to the end.') }),
    make,
  ])
}

// MARK: - Building

/**
 * The projects' list and page. `pinned` is a pane's own project (1.1): the
 * list and the page of that project whatever the sidebar shows; without it,
 * the sidebar's.
 */
export function buildProjects(actions: ProjectActions, pinned?: () => string | null) {
  /** The project shown: the pane's own, or the sidebar's. */
  const chosen = (): string | null => (pinned ? pinned() : store.shelf.kind === 'projects' ? store.shelf.id : null)
  // ---- the list's column
  const listNode = el('div', { class: 'panel pj-list-column' })
  const listHead = el('div', { class: 'shelf-head-wrap' })
  const listBody = el('div', { class: 'panel-body pj-list-body', role: 'listbox', 'aria-label': L('프로젝트', 'Projects') })
  listNode.append(listHead, listBody)
  let showsDone = false

  function drawList() {
    const active = store.projects.filter((one) => one.project.status === 'active').length
    const add = el('button', { class: 'icon-button', title: L('새 프로젝트', 'New Project'), 'aria-label': L('새 프로젝트', 'New Project'), html: icon('plus') })
    on(add, 'click', () => void askNewProject())
    clear(listHead)
    listHead.append(shelfHeader({
      icon: 'flag', title: L('프로젝트', 'Projects'),
      subtitle: L(`진행 중 ${active}개`, `${active} active`),
      trailing: [add], closes: true,
    }))
    const scrolled = listBody.scrollTop
    clear(listBody)
    if (store.projects.length === 0) listBody.append(emptyProjects())
    else drawProjectGroups(listBody, { large: false, showsDone, toggleDone: () => { showsDone = !showsDone; drawList() }, chosen: chosen() })
    listBody.scrollTop = scrolled
  }

  // ---- a paper opened from the project: the paper takes the page area and
  // the project stands where the list was, cut to what it draws on and the
  // steps still open — with the way back above it.
  const sideNode = el('div', { class: 'panel slipbox-side pj-side' })
  const sideBack = el('button', { class: 'plain-button note-back', title: L('프로젝트로 (Esc)', 'Back to the Project (Esc)') }, [glyph('chevron.left'), el('span', { text: L('프로젝트', 'Project') })])
  on(sideBack, 'click', () => backToNotes())
  const sideTitle = el('span', { class: 'slipbox-side-title' })
  const sideBody = el('div', { class: 'panel-body pj-side-body' })
  sideNode.append(el('div', { class: 'panel-header slipbox-side-head' }, [sideBack, sideTitle]), sideBody)

  function drawSide() {
    const found = projectByID(chosen())
    clear(sideBody)
    if (!found) {
      sideTitle.textContent = L('프로젝트', 'Projects')
      return
    }
    const project = found.project
    sideTitle.textContent = project.name
    const open = project.todos.filter((todo) => todo.state !== 'done')
    if (open.length > 0) {
      sideBody.append(el('div', { class: 'pj-group', text: L('남은 할 일', 'Steps Left') }))
      for (const todo of open) {
        const late = todo.due !== undefined && todo.due < store.today
        sideBody.append(el('div', { class: 'pj-side-step' }, [
          el('span', { class: 'pj-dot', 'data-state': todo.state }),
          el('span', { class: 'pj-side-step-title', text: todo.title }),
          ...(todo.due ? [el('span', { class: 'pj-chip', 'data-tone': late ? 'late' : 'secondary', text: monthDay(todo.due) })] : []),
        ]))
      }
    }
    sideBody.append(el('div', { class: 'pj-group', text: L('자료', 'Materials') }))
    const shownPaper = store.slipBox.paperID
    for (const id of project.papers) {
      const entry = paper(id)
      if (!entry) continue
      const row = materialRow(entry.meta.shelfKind === 'book' ? 'book' : entry.meta.shelfKind === 'document' ? 'doc' : 'text.document', entry.meta.shelfKind,
        entry.meta.displayTitle, byline(entry), () => actions.openPaper(id), () => void editProject(project.id, { op: 'removePaper', paper: id }))
      row.setAttribute('aria-selected', String(id === shownPaper))
      on(row, 'click', () => actions.openPaper(id))
      sideBody.append(row)
    }
    for (const id of project.notes) {
      const note = noteByID(id)
      if (!note) continue
      sideBody.append(materialRow('note', 'note', zettelDisplayTitle(note), note.paperID ? L('문헌 노트', 'Literature note') : areaTitle(note.area),
        () => actions.openNote(id), () => void editProject(project.id, { op: 'removeNote', note: id })))
    }
  }

  // ---- the page
  const pageNode = el('div', { class: 'panel pj-page' })
  const scroller = el('div', { class: 'pj-scroll' })
  pageNode.append(scroller)
  let quickAdd = ''
  let showsDoneOnPage = false

  /** Which field had the keyboard, and what was in it, so a redraw does not take it away. */
  function holdFocus(): () => void {
    const active = document.activeElement as HTMLInputElement | HTMLTextAreaElement | null
    const key = active && scroller.contains(active) ? active.dataset.keep : undefined
    if (!key) return () => {}
    const value = active!.value
    const start = active!.selectionStart
    const end = active!.selectionEnd
    return () => {
      const again = scroller.querySelector<HTMLInputElement>(`[data-keep="${key}"]`)
      if (!again) return
      again.value = value
      again.focus({ preventScroll: true })
      if (start !== null && end !== null) again.setSelectionRange(start, end)
    }
  }

  function drawPage() {
    const top = scroller.scrollTop
    const restore = holdFocus()
    clear(scroller)
    const found = projectByID(chosen())
    if (!found) {
      if (store.projects.length === 0) {
        scroller.append(emptyProjects())
      } else if (actions.listShown()) {
        // The list is beside it: the page asks for a choice.
        const make = el('button', { class: 'filled-button', text: L('새 프로젝트…', 'New Project…') })
        on(make, 'click', () => void askNewProject())
        scroller.append(el('div', { class: 'empty pj-empty' }, [
          el('span', { html: icon('flag') }),
          el('h2', { text: L('프로젝트를 고르거나 새로 만들어요', 'Choose a project, or make one') }),
          make,
        ]))
      } else {
        // No list beside it: the page is the list, larger.
        const add = el('button', { class: 'icon-button', title: L('새 프로젝트', 'New Project'), 'aria-label': L('새 프로젝트', 'New Project'), html: icon('plus') })
        on(add, 'click', () => void askNewProject())
        const active = store.projects.filter((one) => one.project.status === 'active').length
        const wrap = el('div', { class: 'pj-overview' })
        wrap.append(shelfHeader({ icon: 'flag', title: L('프로젝트', 'Projects'), subtitle: L(`진행 중 ${active}개`, `${active} active`), trailing: [add] }))
        const body = el('div', { class: 'pj-overview-body', role: 'listbox' })
        drawProjectGroups(body, { large: true, showsDone: showsDoneOnPage, toggleDone: () => { showsDoneOnPage = !showsDoneOnPage; drawPage() }, chosen: chosen() })
        wrap.append(body)
        scroller.append(wrap)
      }
      scroller.scrollTop = top
      restore()
      return
    }
    const project = found.project
    const page = el('div', { class: 'pj-content' }, [
      head(project),
      milestoneTrack(project),
      controls(project),
      store.settings.projectView === 'timeline' ? timeline(project) : board(project),
      materials(project),
    ])
    scroller.append(page)
    scroller.scrollTop = top
    restore()
  }

  // ---- the head

  function head(project: Project): HTMLElement {
    const done = project.status === 'done'
    const name = el('input', { class: 'pj-name', type: 'text', spellcheck: 'false', placeholder: L('프로젝트 이름', 'Project name'), 'data-keep': 'name' }) as HTMLInputElement
    const goal = el('input', { class: 'pj-goal', type: 'text', spellcheck: 'false', placeholder: L('목표 한 줄 — 무엇을 끝내면 끝인가요?', 'The goal in a line — what does done look like?'), 'data-keep': 'goal' }) as HTMLInputElement
    name.value = project.name
    goal.value = project.goal
    // Saved on Return and on leaving the field, the way a note keeps what was typed.
    const commit = () => {
      const newName = name.value.trim()
      const newGoal = goal.value.trim()
      if (!newName) {
        name.value = project.name
        return
      }
      if (newName === project.name && newGoal === project.goal) return
      void editProject(project.id, { op: 'set', name: newName, goal: newGoal })
    }
    for (const field of [name, goal]) {
      on(field, 'keydown', (event: KeyboardEvent) => {
        event.stopPropagation()
        if (event.key === 'Enter') {
          event.preventDefault()
          field.blur()
        } else if (event.key === 'Escape') {
          name.value = project.name
          goal.value = project.goal
          field.blur()
        }
      })
      on(field, 'blur', commit)
    }
    const days = daysLeft(project, store.today)
    const ddayButton = el('button', { class: 'pj-head-dday', title: L('마감 정하기', 'Set Deadline') })
    if (days !== null) {
      ddayButton.append(el('span', { class: 'pj-head-dday-text', 'data-late': String(days < 0), text: ddayText(days) }))
    } else {
      ddayButton.append(el('span', { class: 'pj-head-dday-set', text: L('마감 정하기', 'Set Deadline') }))
    }
    on(ddayButton, 'click', () => openDayPicker(ddayButton, project.deadline ?? null, (day) => {
      void editProject(project.id, { op: 'set', deadline: day })
    }))
    const status = el('button', { class: 'pj-status', 'data-status': project.status, text: projectStatusLabel(project.status) })
    on(status, 'click', () => showMenu(status, statusEntries(project.id), 'right'))
    const meta = el('div', { class: 'pj-head-meta' })
    if (project.deadline) meta.append(el('span', { class: 'pj-due', text: L(`마감 ${longDay(project.deadline)}`, `Due ${longDay(project.deadline)}`) }))
    meta.append(status)
    return el('div', { class: 'pj-head' }, [
      el('span', { class: 'pj-head-ring', html: projectRing(projectProgress(project), 50, done) }),
      el('div', { class: 'pj-head-titles' }, [name, goal]),
      el('div', { class: 'pj-head-side' }, [ddayButton, meta]),
    ])
  }

  // ---- the milestones

  function milestoneTrack(project: Project): HTMLElement {
    const span = projectSpan(project, store.today)
    const add = el('button', { class: 'pj-link' }, [glyph('plus'), el('span', { text: L('이정표', 'Milestone') })])
    on(add, 'click', () => {
      const day = addDays(store.today, Math.max(1, Math.trunc((dayOrdinal(span.end) - dayOrdinal(store.today)) / 2)))
      const milestone = newMilestone(L('새 이정표', 'New milestone'), day)
      void editProject(project.id, { op: 'addMilestone', milestone }).then(() => {
        const diamond = scroller.querySelector(`[data-milestone="${milestone.id}"]`)
        if (diamond) openMilestoneEditor(project.id, milestone.id, diamond)
      })
    })
    const track = el('div', { class: 'pj-track' })
    /** A day's place along the track, as a fraction of the room between its insets. */
    const at = (day: string) => Math.min(1, Math.max(0, spanX(span, day, 1)))
    const left = (f: number) => `calc(14px + (100% - 28px) * ${f.toFixed(5)})`
    const todayF = at(store.today)
    track.append(
      el('span', { class: 'pj-track-line' }),
      el('span', { class: 'pj-track-fill', style: `width: calc((100% - 28px) * ${todayF.toFixed(5)})` }),
      el('span', { class: 'pj-track-today', style: `left: ${left(todayF)}` }),
      el('span', { class: 'pj-track-today-label', style: `left: ${left(todayF)}`, text: L('오늘', 'Today') }),
    )
    if (project.deadline) {
      const f = at(project.deadline)
      track.append(
        el('span', { class: 'pj-diamond pj-diamond-due', style: `left: ${left(f)}` }),
        el('span', { class: 'pj-track-label pj-track-due', style: `left: ${left(f)}`, text: L('마감', 'Due') }),
      )
    }
    for (const milestone of project.milestones) {
      const f = at(milestone.day)
      const mark = el('div', {
        class: 'pj-milestone', style: `left: ${left(f)}`, 'data-milestone': milestone.id,
        title: L(`${milestone.title} · ${longDay(milestone.day)} — 끌어서 날짜를 바꿔요`, `${milestone.title} · ${longDay(milestone.day)} — drag to change its day`),
      }, [
        el('span', { class: `pj-diamond${milestone.done ? ' done' : ''}` }),
        el('span', { class: 'pj-track-label', text: milestone.title }),
      ])
      // Dragged along the track to another day; pressed, it is edited.
      on(mark, 'pointerdown', (event: PointerEvent) => {
        if (event.button !== 0) return
        event.preventDefault()
        mark.setPointerCapture(event.pointerId)
        const box = track.getBoundingClientRect()
        const width = Math.max(1, box.width - 28)
        const startX = event.clientX
        let day = milestone.day
        let moved = false
        const move = (next: PointerEvent) => {
          if (!moved && Math.abs(next.clientX - startX) < 2) return
          moved = true
          mark.classList.add('dragging')
          // From where the diamond stood, by how far the hand went — not to
          // the pointer: a milestone taken by its label does not jump.
          day = spanDay(span, at(milestone.day) * width + (next.clientX - startX), width)
          mark.style.left = left(at(day))
          mark.title = longDay(day)
        }
        const up = () => {
          mark.removeEventListener('pointermove', move)
          mark.removeEventListener('pointerup', up)
          mark.removeEventListener('pointercancel', up)
          mark.classList.remove('dragging')
          if (!moved) {
            openMilestoneEditor(project.id, milestone.id, mark)
            return
          }
          if (day !== milestone.day) void editProject(project.id, { op: 'editMilestone', id: milestone.id, day })
        }
        mark.addEventListener('pointermove', move)
        mark.addEventListener('pointerup', up)
        mark.addEventListener('pointercancel', up)
      })
      track.append(mark)
    }
    return el('div', { class: 'pj-section' }, [
      el('div', { class: 'pj-section-head' }, [el('span', { class: 'pj-section-title', text: L('이정표', 'Milestones') }), add]),
      track,
    ])
  }

  function openMilestoneEditor(projectID: string, id: string, anchor: Element) {
    const milestone = projectByID(projectID)?.project.milestones.find((one) => one.id === id)
    if (!milestone) return
    const box = el('div', { class: 'pj-editor' })
    const title = el('input', { class: 'pj-field', type: 'text', placeholder: L('이정표 이름', 'Milestone name'), spellcheck: 'false' }) as HTMLInputElement
    title.value = milestone.title
    const reached = el('label', { class: 'pj-check' }, [
      el('input', { type: 'checkbox' }),
      el('span', { text: L('다다랐어요', 'Reached') }),
    ])
    const box2 = reached.querySelector('input') as HTMLInputElement
    box2.checked = milestone.done
    on(box2, 'change', () => void editProject(projectID, { op: 'editMilestone', id, done: box2.checked }))
    const dayLine = el('p', { class: 'pj-caption', text: L(`날짜: ${longDay(milestone.day)} — 트랙에서 끌어 바꿔요`, `${longDay(milestone.day)} — drag it on the track to change`) })
    const remove = el('button', { class: 'plain-button danger', text: L('지우기', 'Delete') })
    const save = el('button', { class: 'filled-button', text: L('저장', 'Save') })
    let pop: Pop | null = null
    const saveTitle = () => {
      const trimmed = title.value.trim()
      if (trimmed && trimmed !== milestone.title) void editProject(projectID, { op: 'editMilestone', id, title: trimmed })
    }
    on(remove, 'click', () => {
      pop?.close()
      void editProject(projectID, { op: 'removeMilestone', id })
    })
    on(save, 'click', () => {
      saveTitle()
      pop?.close()
    })
    on(title, 'keydown', (event: KeyboardEvent) => {
      event.stopPropagation()
      if (event.key !== 'Enter') return
      event.preventDefault()
      saveTitle()
      pop?.close()
    })
    box.append(title, reached, dayLine, el('div', { class: 'pj-editor-foot' }, [remove, el('span', { class: 'fb-spacer' }), save]))
    pop = openPop(anchor, box)
    title.focus({ preventScroll: true })
    title.select()
  }

  // ---- the switch and the quick add

  function controls(project: Project): HTMLElement {
    const seg = el('span', { class: 'pb-seg pj-views', role: 'group', 'aria-label': L('보기', 'View') })
    for (const [view, label] of [['board', L('보드', 'Board')], ['timeline', L('타임라인', 'Timeline')]] as const) {
      const button = el('button', { 'aria-pressed': String(store.settings.projectView === view), text: label, 'data-view': view })
      on(button, 'click', () => {
        if (store.settings.projectView === view) return
        store.settings.projectView = view
        saveSettings({ projectView: view })
        drawPage()
      })
      seg.append(button)
    }
    const field = el('input', {
      class: 'pj-add-field', type: 'text', spellcheck: 'false', 'data-keep': 'quick-add',
      placeholder: L('할 일 더하기 — «금요일», «12/3», «+1주»처럼 날짜도 적어요', 'Add a step — a date like Fri, 12/3 or +1w at the end works'),
    }) as HTMLInputElement
    field.value = quickAdd
    on(field, 'input', () => { quickAdd = field.value })
    on(field, 'keydown', (event: KeyboardEvent) => {
      event.stopPropagation()
      if (event.key !== 'Enter') return
      event.preventDefault()
      const text = field.value.trim()
      if (!text) return
      const parsed = splitDay(text, store.today)
      quickAdd = ''
      field.value = ''
      void editProject(project.id, { op: 'addTodo', todo: newTodo(parsed.title, parsed.day ? { due: parsed.day } : {}) })
    })
    const add = el('label', { class: 'pj-add' }, [glyph('plus'), field])
    return el('div', { class: 'pj-controls' }, [seg, add])
  }

  // ---- the board

  function board(project: Project): HTMLElement {
    const node = el('div', { class: 'pj-board' })
    for (const state of TODO_STATES) node.append(column(project, state))
    return node
  }

  function column(project: Project, state: TodoState): HTMLElement {
    const todos = todosIn(project, state)
    const node = el('div', { class: 'pj-col', 'data-state': state })
    node.append(el('div', { class: 'pj-col-head' }, [
      el('span', { class: 'pj-dot', 'data-state': state }),
      el('span', { class: 'pj-col-name', text: todoStateLabel(state) }),
      el('span', { class: 'pj-col-count', text: String(todos.length) }),
    ]))
    for (const todo of todos) node.append(card(project, todo))
    if (todos.length === 0) node.append(el('div', { class: 'pj-col-empty', text: L('여기로 끌어와요', 'Drag here') }))
    // A step dragged from another column: into this state, at its end.
    let over = 0
    const carriesTodo = (event: DragEvent) => Boolean(event.dataTransfer && [...event.dataTransfer.types].includes(TODO_TYPE))
    on(node, 'dragenter', (event: DragEvent) => {
      if (!carriesTodo(event)) return
      over += 1
      node.classList.add('drop-target')
    })
    on(node, 'dragover', (event: DragEvent) => {
      if (!carriesTodo(event)) return
      event.preventDefault()
      if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
    })
    on(node, 'dragleave', () => {
      over = Math.max(0, over - 1)
      if (over === 0) node.classList.remove('drop-target')
    })
    on(node, 'drop', (event: DragEvent) => {
      over = 0
      node.classList.remove('drop-target')
      if (!carriesTodo(event)) return
      event.preventDefault()
      let carried: { project?: string; todo?: string } = {}
      try {
        carried = JSON.parse(event.dataTransfer!.getData(TODO_TYPE)) as typeof carried
      } catch {
        return
      }
      if (carried.project !== project.id || !carried.todo) return
      const moving = project.todos.find((one) => one.id === carried.todo)
      if (!moving || moving.state === state) return
      void editProject(project.id, { op: 'moveTodo', id: carried.todo, state })
    })
    return node
  }

  function chip(text: string, iconName: IconName | null, tone: 'secondary' | 'late' | 'accent' | 'note'): HTMLElement {
    const node = el('span', { class: 'pj-chip', 'data-tone': tone })
    if (iconName) node.append(glyph(iconName))
    node.append(el('span', { text }))
    return node
  }

  function card(project: Project, todo: Todo): HTMLElement {
    const node = el('div', { class: 'pj-card', draggable: 'true', 'data-todo': todo.id, 'data-state': todo.state })
    node.append(el('div', { class: 'pj-card-title', text: todo.title }))
    const chips: HTMLElement[] = []
    if (todo.due) {
      const late = todo.state !== 'done' && todo.due < store.today
      chips.push(chip(monthDay(todo.due), 'calendar', late ? 'late' : 'secondary'))
    }
    for (const id of todo.papers.slice(0, 2)) {
      const entry = paper(id)
      if (entry) chips.push(chip(entry.meta.displayAuthors || entry.meta.displayTitle, 'text.document', 'accent'))
    }
    if (todo.papers.length > 2) chips.push(chip(`+${todo.papers.length - 2}`, null, 'accent'))
    if (todo.notes.length > 0) chips.push(chip(String(todo.notes.length), 'note', 'note'))
    if (chips.length > 0) node.append(el('div', { class: 'pj-chips' }, chips))
    on(node, 'dragstart', (event: DragEvent) => {
      if (!event.dataTransfer) return
      event.dataTransfer.setData(TODO_TYPE, JSON.stringify({ project: project.id, todo: todo.id }))
      event.dataTransfer.effectAllowed = 'move'
      node.classList.add('dragging')
    })
    on(node, 'dragend', () => node.classList.remove('dragging'))
    // A paper dropped on the card is that step's.
    let over = 0
    on(node, 'dragenter', (event: DragEvent) => {
      if (!carriesPapers(event.dataTransfer)) return
      over += 1
      node.classList.add('drop-target')
    })
    on(node, 'dragover', (event: DragEvent) => {
      if (!carriesPapers(event.dataTransfer)) return
      event.preventDefault()
      event.stopPropagation()
      if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
    })
    on(node, 'dragleave', () => {
      over = Math.max(0, over - 1)
      if (over === 0) node.classList.remove('drop-target')
    })
    on(node, 'drop', (event: DragEvent) => {
      over = 0
      node.classList.remove('drop-target')
      if (!carriesPapers(event.dataTransfer)) return
      event.preventDefault()
      event.stopPropagation()
      const ids = draggedPapers(event.dataTransfer)
      if (ids.length > 0) void addToProject(project.id, ids, todo.id)
    })
    on(node, 'click', () => openTodoEditor(project.id, todo.id, node))
    on(node, 'contextmenu', (event: MouseEvent) => {
      event.preventDefault()
      const entries: MenuEntry[] = TODO_STATES.map((state) => ({
        label: todoStateLabel(state),
        disabled: todo.state === state,
        action: () => void editProject(project.id, { op: 'moveTodo', id: todo.id, state }),
      }))
      entries.push({ separator: true }, { label: L('지우기', 'Delete'), icon: 'trash', danger: true, action: () => void editProject(project.id, { op: 'removeTodo', id: todo.id }) })
      showMenuAt({ x: event.clientX, y: event.clientY }, entries)
    })
    return node
  }

  function openTodoEditor(projectID: string, id: string, anchor: Element) {
    const found = () => projectByID(projectID)?.project.todos.find((one) => one.id === id)
    const todo = found()
    if (!todo) return
    const box = el('div', { class: 'pj-editor pj-todo-editor' })
    const title = el('input', { class: 'pj-field pj-field-title', type: 'text', placeholder: L('할 일', 'Step'), spellcheck: 'false' }) as HTMLInputElement
    title.value = todo.title
    const memo = el('textarea', { class: 'pj-memo', spellcheck: 'false' }) as HTMLTextAreaElement
    memo.value = todo.memo
    const states = el('span', { class: 'pb-seg pj-states', role: 'group', 'aria-label': L('상태', 'State') })
    const drawStates = () => {
      clear(states)
      const now = found()?.state ?? todo.state
      for (const state of TODO_STATES) {
        const button = el('button', { 'aria-pressed': String(now === state), text: todoStateLabel(state) })
        on(button, 'click', () => void editProject(projectID, { op: 'moveTodo', id, state }).then(drawStates))
        states.append(button)
      }
    }
    drawStates()
    const days = el('div', { class: 'pj-days' })
    const drawDays = () => {
      clear(days)
      const now = found() ?? todo
      for (const [which, label] of [['start', L('시작', 'Start')], ['due', L('마감', 'Due')]] as const) {
        const day = now[which] ?? null
        const button = el('button', { class: 'pj-day-button' }, [
          el('span', { class: 'pj-day-label', text: label }),
          el('span', { text: day ? monthDay(day) : L('정하기', 'Set') }),
        ])
        on(button, 'click', () => openDayPicker(button, day, (picked) => {
          void editProject(projectID, which === 'start' ? { op: 'editTodo', id, start: picked } : { op: 'editTodo', id, due: picked }).then(drawDays)
        }))
        days.append(button)
      }
    }
    drawDays()
    const papers = el('div', { class: 'pj-todo-papers' })
    const drawPapers = () => {
      clear(papers)
      const now = found() ?? todo
      if (now.papers.length === 0) {
        papers.append(el('p', { class: 'pj-caption pj-quiet', text: L('논문을 카드 위로 끌어다 놓으면 이 할 일에 붙어요.', 'Drop a paper on the card to attach it to this step.') }))
        return
      }
      papers.append(el('p', { class: 'pj-caption', text: L('논문', 'Papers') }))
      for (const paperID of now.papers) {
        const entry = paper(paperID)
        if (!entry) continue
        const open = el('button', { class: 'pj-todo-paper', text: entry.meta.displayTitle, title: entry.meta.displayTitle })
        on(open, 'click', () => {
          closeProjectPops()
          actions.openPaper(paperID)
        })
        const remove = el('button', { class: 'icon-button pj-minus', title: L('이 할 일에서 빼기', 'Remove from This Step'), html: icon('minus') })
        on(remove, 'click', () => void editProject(projectID, { op: 'removeTodoPaper', todo: id, paper: paperID }).then(drawPapers))
        papers.append(el('div', { class: 'pj-todo-paper-row' }, [open, remove]))
      }
    }
    drawPapers()
    const saved = () => {
      const now = found()
      if (!now) return
      const newTitle = title.value.trim()
      const changes: { title?: string; memo?: string } = {}
      if (newTitle && newTitle !== now.title) changes.title = newTitle
      if (memo.value !== now.memo) changes.memo = memo.value
      if (Object.keys(changes).length > 0) void editProject(projectID, { op: 'editTodo', id, ...changes })
    }
    const save = el('button', { class: 'filled-button', text: L('저장', 'Save') })
    let pop: Pop | null = null
    on(save, 'click', () => pop?.close())
    on(title, 'keydown', (event: KeyboardEvent) => {
      event.stopPropagation()
      if (event.key !== 'Enter') return
      event.preventDefault()
      pop?.close()
    })
    on(memo, 'keydown', (event: KeyboardEvent) => event.stopPropagation())
    box.append(
      title, states, days,
      el('p', { class: 'pj-caption', text: L('메모', 'Memo') }), memo,
      papers,
      el('div', { class: 'pj-editor-foot' }, [el('span', { class: 'fb-spacer' }), save]),
    )
    // What was typed is kept when the popover goes, however it goes.
    pop = openPop(anchor, box, { side: 'right', onClose: saved })
    title.focus({ preventScroll: true })
  }

  // ---- the timeline

  function timeline(project: Project): HTMLElement {
    const span = projectSpan(project, store.today)
    const LABEL = 150
    const rows = project.todos
    const node = el('div', { class: 'pj-timeline', style: `height: ${Math.max(1, rows.length) * 30 + 38}px` })
    const grid = el('div', { class: 'pj-tl-grid', style: `left: ${LABEL}px` })
    node.append(grid)
    const pct = (day: string) => `${(Math.min(1, Math.max(0, spanX(span, day, 1))) * 100).toFixed(4)}%`
    for (let offset = 0; offset <= span.days; offset += 7) {
      const day = addDays(span.start, offset)
      grid.append(
        el('span', { class: 'pj-tl-week', style: `left: ${pct(day)}` }),
        el('span', { class: 'pj-tl-week-label', style: `left: ${pct(day)}`, text: monthDay(day) }),
      )
    }
    for (const milestone of project.milestones) {
      grid.append(
        el('span', { class: 'pj-tl-milestone', style: `left: ${pct(milestone.day)}` }),
        el('span', { class: `pj-tl-diamond${milestone.done ? ' done' : ''}`, style: `left: ${pct(milestone.day)}`, title: milestone.title }),
      )
    }
    if (project.deadline) grid.append(el('span', { class: 'pj-tl-deadline', style: `left: ${pct(project.deadline)}` }))
    grid.append(el('span', { class: 'pj-tl-today', style: `left: ${pct(store.today)}` }))
    const list = el('div', { class: 'pj-tl-rows' })
    for (const todo of rows) list.append(timelineRow(project, todo, span, LABEL))
    if (rows.length === 0) {
      list.append(el('div', { class: 'pj-tl-empty', style: `padding-left: ${LABEL}px`, text: L('할 일을 더하면 여기 날짜를 따라 놓여요', 'Steps you add are laid out here by their days') }))
    }
    node.append(list)
    return node
  }

  function timelineRow(project: Project, todo: Todo, span: ReturnType<typeof projectSpan>, labelWidth: number): HTMLElement {
    const { start, due } = todoBar(todo, store.today)
    const lane = el('div', { class: 'pj-tl-lane' })
    const fraction = (day: string) => Math.min(1, Math.max(0, spanX(span, day, 1)))
    const place = (from: string, to: string) => {
      const a = fraction(from)
      const b = Math.max(a, fraction(to))
      bar.style.left = `${(a * 100).toFixed(4)}%`
      bar.style.width = `max(14px, ${((b - a) * 100).toFixed(4)}%)`
      dueText.textContent = monthDay(to)
    }
    const dueText = el('span', { class: 'pj-tl-due' })
    const handle = el('span', { class: 'pj-tl-handle', title: L('끌어서 마감을 바꿔요', 'Drag to change when it is due') })
    const bar = el('div', {
      class: 'pj-tl-bar', 'data-state': todo.state, 'data-todo': todo.id,
      title: L('끌어서 날짜를 옮기고, 끝을 끌어 마감을 바꿔요', 'Drag to move its days; drag its end to change when it is due'),
    }, [dueText, handle])
    place(start, due)
    lane.append(bar)
    /** A drag along the lane: the whole bar (both days), or its end (the due day). */
    const drag = (event: PointerEvent, stretch: boolean) => {
      if (event.button !== 0) return
      event.preventDefault()
      event.stopPropagation()
      const target = event.currentTarget as HTMLElement
      target.setPointerCapture(event.pointerId)
      const width = Math.max(1, lane.getBoundingClientRect().width)
      const startX = event.clientX
      let shift = 0
      bar.classList.add('dragging')
      const move = (next: PointerEvent) => {
        shift = spanShift(span, next.clientX - startX, width)
        if (stretch) place(start, addDays(due, shift))
        else place(addDays(start, shift), addDays(due, shift))
      }
      const up = () => {
        target.removeEventListener('pointermove', move)
        target.removeEventListener('pointerup', up)
        target.removeEventListener('pointercancel', up)
        bar.classList.remove('dragging')
        if (shift === 0) return
        if (stretch) {
          const pulled = addDays(due, shift)
          void editProject(project.id, { op: 'editTodo', id: todo.id, start, due: pulled < start ? start : pulled })
        } else {
          void editProject(project.id, { op: 'editTodo', id: todo.id, start: addDays(start, shift), due: addDays(due, shift) })
        }
      }
      target.addEventListener('pointermove', move)
      target.addEventListener('pointerup', up)
      target.addEventListener('pointercancel', up)
    }
    on(bar, 'pointerdown', (event: PointerEvent) => drag(event, false))
    on(handle, 'pointerdown', (event: PointerEvent) => drag(event, true))
    return el('div', { class: 'pj-tl-row' }, [
      el('span', { class: 'pj-tl-title', style: `width: ${labelWidth - 10}px`, text: todo.title, title: todo.title }),
      lane,
    ])
  }

  // ---- what it draws on

  function materials(project: Project): HTMLElement {
    const node = el('div', { class: 'pj-materials' })
    const plansButton = el('button', { class: 'pj-link' }, [glyph('plus'), el('span', { text: L('계획 붙이기', 'Attach Plan') })])
    on(plansButton, 'click', () => {
      const entries: MenuEntry[] = store.plans.length === 0
        ? [{ label: L('계획이 없어요', 'No Plans'), disabled: true }]
        : store.plans.map((one) => ({
          label: one.plan.name,
          disabled: project.plans.includes(one.plan.id),
          action: () => void editProject(project.id, { op: 'addPlan', plan: one.plan.id }),
        }))
      showMenu(plansButton, entries, 'right')
    })
    const headTrailing: Node[] = [plansButton]
    if (!actions.papersShown()) {
      const show = el('button', { class: 'pj-link' }, [glyph('sidebar.right'), el('span', { text: L('논문 칸 열기', 'Show Papers Beside') })])
      on(show, 'click', () => actions.showPapers())
      headTrailing.push(show)
    }
    node.append(el('div', { class: 'pj-section-head' }, [
      el('span', { class: 'pj-section-title', text: L('자료', 'Materials') }),
      el('span', { class: 'pj-section-trailing' }, headTrailing),
    ]))
    if (project.papers.length === 0 && project.notes.length === 0 && project.plans.length === 0) {
      node.append(el('div', { class: 'pj-materials-hint', text: L('논문과 노트를 여기로 끌어다 놓아요. 옆에 논문 칸을 열면 거기서 끌어올 수 있어요.', 'Drop papers and notes here. Open a paper pane beside this one to drag from it.') }))
    } else {
      const rows = el('div', { class: 'pj-materials-rows' })
      for (const id of project.plans) {
        const plan = planByID(id)
        if (!plan) continue
        rows.append(materialRow('point.topleft.down.to.point.bottomright.curvepath', 'plan', plan.plan.name, L('읽기 계획', 'Reading plan'),
          () => actions.openPlan(id), () => void editProject(project.id, { op: 'removePlan', plan: id })))
      }
      for (const id of project.papers) {
        const entry = paper(id)
        if (!entry) continue
        const kind = entry.meta.shelfKind
        const row = materialRow(kind === 'book' ? 'book' : kind === 'document' ? 'doc' : 'text.document', kind, entry.meta.displayTitle, byline(entry),
          () => actions.openPaper(id), () => void editProject(project.id, { op: 'removePaper', paper: id }))
        row.dataset.paper = id
        rows.append(row)
      }
      for (const id of project.notes) {
        const note = noteByID(id)
        if (!note) continue
        rows.append(materialRow('note', 'note', zettelDisplayTitle(note), note.paperID ? L('문헌 노트', 'Literature note') : areaTitle(note.area),
          () => actions.openNote(id), () => void editProject(project.id, { op: 'removeNote', note: id })))
      }
      node.append(rows)
    }
    // Papers and notes dropped here are what it draws on.
    let over = 0
    const carries = (event: DragEvent) => carriesPapers(event.dataTransfer) || carriesNote(event.dataTransfer)
    on(node, 'dragenter', (event: DragEvent) => {
      if (!carries(event)) return
      over += 1
      node.classList.add('drop-target')
    })
    on(node, 'dragover', (event: DragEvent) => {
      if (!carries(event)) return
      event.preventDefault()
      if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
    })
    on(node, 'dragleave', () => {
      over = Math.max(0, over - 1)
      if (over === 0) node.classList.remove('drop-target')
    })
    on(node, 'drop', (event: DragEvent) => {
      over = 0
      node.classList.remove('drop-target')
      if (!carries(event)) return
      event.preventDefault()
      const ids = draggedPapers(event.dataTransfer)
      if (ids.length > 0) {
        void addToProject(project.id, ids)
        return
      }
      const note = draggedNote(event.dataTransfer)
      if (note) void addNotesToProject(project.id, [note])
    })
    return node
  }

  function materialRow(iconName: IconName, tone: string, title: string, detail: string, open: () => void, remove: () => void): HTMLElement {
    const row = el('div', { class: 'pj-material', tabindex: '-1', title: L('두 번 눌러 열어요', 'Double-click to open') }, [
      el('span', { class: 'pj-material-icon', 'data-tone': tone }, [glyph(iconName)]),
      el('div', { class: 'pj-material-lines' }, [
        el('span', { class: 'pj-material-title', text: title }),
        ...(detail ? [el('span', { class: 'pj-material-detail', text: detail })] : []),
      ]),
    ])
    on(row, 'dblclick', open)
    on(row, 'contextmenu', (event: MouseEvent) => {
      event.preventDefault()
      showMenuAt({ x: event.clientX, y: event.clientY }, [
        { label: L('열기', 'Open'), action: open },
        { label: L('프로젝트에서 빼기', 'Remove from Project'), icon: 'minus', danger: true, action: remove },
      ])
    })
    return row
  }

  function update() {
    if (pops.length > 0 && !pops.some((pop) => pop.node.isConnected)) pops.length = 0
    drawList()
    drawPage()
    drawSide()
  }

  update()
  return { listNode, pageNode, sideNode, update }
}

/** What the project page shows now, read off the page — for a probe. */
export function projectReport() {
  const page = document.querySelector('.pj-page')
  const text = (selector: string) => [...(page?.querySelectorAll<HTMLElement>(selector) ?? [])].map((one) => one.textContent ?? '')
  return {
    shelf: store.shelf,
    view: store.settings.projectView,
    head: (page?.querySelector<HTMLInputElement>('.pj-name'))?.value ?? null,
    dday: page?.querySelector('.pj-head-dday')?.textContent ?? null,
    milestones: [...(page?.querySelectorAll<HTMLElement>('.pj-milestone') ?? [])].map((one) => `${one.textContent}@${one.style.left}`),
    columns: [...(page?.querySelectorAll<HTMLElement>('.pj-col') ?? [])].map((col) => ({
      state: col.dataset.state,
      cards: [...col.querySelectorAll<HTMLElement>('.pj-card-title')].map((one) => one.textContent),
    })),
    bars: [...(page?.querySelectorAll<HTMLElement>('.pj-tl-bar') ?? [])].map((one) => `${one.dataset.todo?.slice(0, 4)} ${one.style.left} ${one.style.width}`),
    materials: text('.pj-material-title'),
    overview: text('.pj-overview .pj-row-name'),
  }
}
