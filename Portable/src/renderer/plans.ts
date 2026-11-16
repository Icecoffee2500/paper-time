/**
 * Reading plans in the window: which view a shelf shows, the plans and
 * their edits, the days papers are read on, and what is kept beside them.
 *
 * Every change goes to the main process, which makes it on the files as they
 * are on disk (`main/plans.ts`), and comes back to be put in place — the
 * library is not read again for a day or a link. Each change is one undo
 * step (Ctrl+Z / ⌘Z while the board is showing) and says what it did with a
 * «되돌리기» beside it.
 */
import { call } from './bridge.js'
import {
  changed, paper, patchPlanSidecars, planByID, planPapers, sameShelf, setShelf, shelfPapers, store,
  type Paper, type Shelf,
} from './state.js'
import { solo } from './shell.js'
import { toast } from './ui/toolbar.js'
import { askForName, askToConfirm } from './ui/ask.js'
import { saveSettings } from './settingsController.js'
import { layoutPanes, revealPane } from './layout.js'
import { reconcileReaders } from './pageArea.js'
import { keepPaper, showPaper } from './actions/openPapers.js'
import { LEGACY } from '../shared/legacy.js'
import { setStatus } from './actions/paper.js'
import { addPaperByAddress, importDestination } from './library.js'
import { L } from '../shared/lang.js'
import { addDays, spreadDays, todayDay, type PaperLink, type PlanEntry, type PlanSection } from '../shared/readingPlan.js'
import type { PlanEdit } from '../shared/planEdit.js'
import type { PlanDTO } from '../shared/api.js'
import {
  DEFAULT_COLUMNS, boardPlace, fullDay, holdsAddress, isBehind, kindName, nextStatus, readAddRow, readColumns, spreadOrder, spreadStart, viewFor, withRo,
  type BoardContext, type BoardPaper, type ColumnID, type Status,
} from '../shared/planBoard.js'
import { addressText } from '../shared/paperAddress.js'
import { openAddPapersSheet, openPlanSheet } from './ui/planSheets.js'
import { materialAddress, materialKindOfAddress } from '../shared/readingPlan.js'

// MARK: - What the board remembers

export type View = 'list' | 'table' | 'calendar'
export type { BoardContext, ColumnID } from '../shared/planBoard.js'
export { ALL_COLUMNS, DEFAULT_COLUMNS } from '../shared/planBoard.js'
export type Grouping = 'section' | 'week' | 'status'
export type SortKey = 'title' | 'authors' | 'year' | 'date' | 'venue' | 'added' | 'opened' | 'rating' | 'progress'

export interface BoardPrefs {
  views: Record<string, View>
  columns: Record<BoardContext, ColumnID[]>
  sort: { key: SortKey | null; ascending: boolean }
  group: Grouping
  spread: { days: number[]; per: number; from: 'today' | 'next' }
  /** Whether a shelf's table shows «Read On» and «Plan» — off until asked
   *  for (the Mac's `boardShowsPlanColumns`). */
  planColumns: boolean
}

function defaults(): BoardPrefs {
  return {
    views: {},
    columns: { plan: [...DEFAULT_COLUMNS.plan], week: [...DEFAULT_COLUMNS.week], other: [...DEFAULT_COLUMNS.other] },
    sort: { key: null, ascending: true },
    group: 'section',
    spread: { days: [0, 2, 4], per: 1, from: 'today' },
    planColumns: false,
  }
}

let parsed: { from: string | null; prefs: BoardPrefs } | null = null

/** The board's remembered choices, read from the settings. */
export function prefs(): BoardPrefs {
  const raw = store.settings.planBoard ?? null
  if (parsed && parsed.from === raw) return parsed.prefs
  const made = defaults()
  try {
    const read = raw ? JSON.parse(raw) as Partial<BoardPrefs> : {}
    if (read.views && typeof read.views === 'object') {
      for (const [key, value] of Object.entries(read.views)) if (value === 'list' || value === 'table' || value === 'calendar') made.views[key] = value
    }
    if (read.columns && typeof read.columns === 'object') {
      for (const context of ['plan', 'week', 'other'] as BoardContext[]) {
        const list = readColumns((read.columns as Record<string, unknown>)[context])
        if (list) made.columns[context] = list
      }
    }
    if (read.sort && typeof read.sort === 'object') {
      const key = (read.sort.key ?? null) as string | null
      made.sort = { key: key === 'who' ? 'authors' : (key as SortKey | null), ascending: read.sort.ascending !== false }
    }
    if (read.group === 'section' || read.group === 'week' || read.group === 'status') made.group = read.group
    if (read.planColumns === true) made.planColumns = true
    if (read.spread && typeof read.spread === 'object') {
      const days = Array.isArray(read.spread.days) ? read.spread.days.filter((one) => Number.isInteger(one) && one >= 0 && one <= 6) : made.spread.days
      made.spread = {
        days,
        per: Math.max(1, Math.min(3, Number(read.spread.per) || 1)),
        from: read.spread.from === 'next' ? 'next' : 'today',
      }
    }
  } catch {
    // A choice that does not read is the default again.
  }
  parsed = { from: raw, prefs: made }
  return made
}

export function savePrefs(change: (prefs: BoardPrefs) => void) {
  const next = structuredClone(prefs())
  change(next)
  const text = JSON.stringify(next)
  store.settings.planBoard = text
  parsed = { from: text, prefs: next }
  saveSettings({ planBoard: text }, { soon: true })
}

/** The key a shelf's view is remembered under; null for the slip-box, which has none. */
export function shelfKey(shelf: Shelf): string | null {
  switch (shelf.kind) {
    case 'notes': return null
    case 'kind': return `kind:${shelf.of}`
    case 'folder': return `folder:${shelf.root}`
    case 'status': return `status:${shelf.status}`
    case 'collection': return `collection:${shelf.id}`
    case 'tag': return `tag:${shelf.id}`
    case 'author': return `author:${shelf.key}`
    case 'plan': return 'plan'
    default: return shelf.kind
  }
}

/**
 * What a shelf shows. Every shelf is its table — a plan its table or its
 * calendar; with the old list back (`LEGACY.paperList`), the list and the
 * page or the board, as the List | Table switch chose.
 */
export function viewOf(shelf: Shelf = store.shelf): View {
  const key = shelfKey(shelf)
  if (key === null) return 'list'
  const kept = prefs().views[shelf.kind === 'plan' ? `plan:${shelf.id}` : key]
  return viewFor(shelf.kind, kept, LEGACY.paperList)
}

export function boardContext(shelf: Shelf = store.shelf): BoardContext {
  return shelf.kind === 'plan' ? 'plan' : shelf.kind === 'week' ? 'week' : 'other'
}

/**
 * Where the board stands now: `wide`, where the list and the page were (a
 * plan's calendar); `list`, in the list's column with the page beside it
 * (every other shelf's table); `none`, the old list (search results, a
 * library with no papers yet, the slip-box).
 */
export function boardPlaceNow(): 'wide' | 'list' | 'none' {
  if (solo || !store.root || store.unavailable) return 'none'
  return boardPlace(store.shelf.kind, viewOf(), store.papers.length > 0, LEGACY.paperList)
}

/** Whether the board stands where the list and the page were. */
export function boardShowing(): boolean {
  return boardPlaceNow() === 'wide'
}

/** Whether the list column holds the board's table, with the page beside it. */
export function boardInListColumn(): boolean {
  return boardPlaceNow() === 'list'
}

/** Whether the board stands anywhere — wide or in the list column. */
export function boardVisible(): boolean {
  return boardPlaceNow() !== 'none'
}

/** Another view for the shelf showing. */
export function setView(view: View) {
  const shelf = store.shelf
  const key = shelfKey(shelf)
  if (key === null) return
  savePrefs((prefs) => {
    prefs.views[shelf.kind === 'plan' ? `plan:${shelf.id}` : key] = view
  })
  layoutPanes()
  if (view !== 'calendar') reconcileReaders()
  changed('shelf')
}

// MARK: - Undo

interface Step {
  name: string
  undo: () => Promise<void>
  redo: () => Promise<void>
}

const done: Step[] = []
const undone: Step[] = []

function record(step: Step) {
  done.push(step)
  if (done.length > 100) done.shift()
  undone.length = 0
}

/** One step of the plans back, or forward again. False when there is none. */
export async function undoPlan(redo: boolean): Promise<boolean> {
  const step = redo ? undone.pop() : done.pop()
  if (!step) return false
  await (redo ? step.redo() : step.undo())
  ;(redo ? done : undone).push(step)
  // The demo's words: what came back is the thing to say, not the command's name.
  toast(redo ? L('다시 했어요.', 'Redone.') : L('되돌렸어요.', 'Undone.'))
  return true
}

/** The toast after a change, with the way back beside it. */
function said(message: string) {
  toast(message, { label: L('되돌리기', 'Undo'), press: () => void undoPlan(false) })
}

// MARK: - Days

export const boardPaper = (entry: Paper): BoardPaper => ({ id: entry.id, date: entry.schedule ?? null, status: entry.state.readingStatus as Status })

async function writeDays(changes: { id: string; date: string | null }[]) {
  if (changes.length === 0) return
  const written = await call('schedule:set', { changes })
  for (const one of written) patchPlanSidecars(one.id, { schedule: one.date })
  changed('papers')
}

/** Days set or cleared, as one step. */
export async function setDays(changes: { id: string; date: string | null }[], message: string, name: string) {
  const real = changes.filter((one) => (paper(one.id)?.schedule ?? null) !== one.date)
  if (real.length === 0) return
  const before = real.map((one) => ({ id: one.id, date: paper(one.id)?.schedule ?? null }))
  await writeDays(real)
  record({ name, undo: () => writeDays(before), redo: () => writeDays(real) })
  said(message)
}

/** One paper's day, from the date popover or a drag. */
export function setDay(id: string, date: string | null, how: 'picked' | 'moved' = 'picked') {
  const message = date
    ? L(`${fullDay(date)}로 옮겼어요.`, `Moved to ${fullDay(date)}.`)
    : L('날짜를 지웠어요.', 'Cleared the date.')
  return setDays([{ id, date }], message, how === 'moved' ? L('옮기기', 'Move') : L('읽을 날', 'Read Date'))
}

/** «Spread Evenly»: the papers not read get days, in order, on the chosen weekdays. */
export async function spread(planID: string, options: BoardPrefs['spread']) {
  const papers = planPapers(planID).map(boardPaper)
  const order = spreadOrder(papers)
  const days = spreadDays(order.length, options.days, options.per, spreadStart(options.from, store.today))
  if (days.length === 0) return
  const changes = order.map((id, at) => ({ id, date: days[at] }))
  await setDays(changes, L(`${changes.length}편에 날짜를 정했어요.`, `Gave ${changes.length} paper${changes.length === 1 ? '' : 's'} a date.`), L('고르게 나누기', 'Spread Out'))
}

/** «Push a Week»: every paper not read that has a day, a week later. */
export async function pushWeek(planID: string) {
  const changes = planPapers(planID)
    .filter((entry) => entry.state.readingStatus !== 'read' && entry.schedule)
    .map((entry) => ({ id: entry.id, date: addDays(entry.schedule!, 7) }))
  if (changes.length === 0) {
    toast(L('미룰 논문이 없어요.', 'Nothing to push.'))
    return
  }
  await setDays(changes, L(`남은 ${changes.length}편을 한 주 뒤로 옮겼어요.`, `Pushed ${changes.length} paper${changes.length === 1 ? '' : 's'} back a week.`), L('한 주 미루기', 'Push a Week'))
}

/** «Move to Today»: everything behind, today. */
export async function pullBehind() {
  const changes = store.papers
    .filter((entry) => isBehind(entry.schedule, entry.state.readingStatus as Status, store.today))
    .map((entry) => ({ id: entry.id, date: store.today }))
  if (changes.length === 0) return
  await setDays(changes, L(`${changes.length}편을 오늘로 옮겼어요.`, `Moved ${changes.length} paper${changes.length === 1 ? '' : 's'} to today.`), L('오늘로 옮기기', 'Move to Today'))
}

/** The ring pressed: unread, reading, read, and round again. */
export function cycleStatus(id: string) {
  const entry = paper(id)
  if (!entry) return
  void setStatus(id, nextStatus(entry.state.readingStatus as Status))
}

/** Today moves on at midnight, and when the window comes back after a night asleep. */
export function watchTheDay() {
  const look = () => {
    const now = todayDay()
    if (now === store.today) return
    store.today = now
    changed('papers')
  }
  window.setInterval(look, 60_000)
  window.addEventListener('focus', look)
}

// MARK: - Plans

function putPlan(dto: PlanDTO) {
  const at = store.plans.findIndex((one) => one.plan.id === dto.plan.id)
  store.plans = at < 0 ? [...store.plans, dto] : [...store.plans.slice(0, at), dto, ...store.plans.slice(at + 1)]
  changed('papers')
}

/** Every plan read again — another window or machine changed one. */
export async function reloadPlans() {
  store.plans = await call('plans:load')
  if (store.shelf.kind === 'plan' && !planByID(store.shelf.id)) setShelf({ kind: 'all' })
  changed('papers', 'shelf')
}

function restoring(dto: PlanDTO): PlanEdit {
  return {
    op: 'restore',
    name: dto.plan.name,
    sections: dto.plan.sections.map((one): PlanSection => ({ ...one })),
    entries: dto.plan.entries.map((one): PlanEntry => ({ ...one })),
  }
}

async function sendEdit(id: string, edit: PlanEdit): Promise<boolean> {
  const answer = await call('plans:edit', { id, edit })
  if ('error' in answer) {
    toast(L('계획을 고치지 못했어요.', "Paper Time couldn't change the plan."))
    return false
  }
  putPlan(answer)
  return true
}

/** One change to a plan, as one undo step. */
export async function editPlan(id: string, edit: PlanEdit, name: string, message?: string) {
  const found = planByID(id)
  if (!found) return
  const before = restoring(found)
  if (!(await sendEdit(id, edit))) return
  const after = restoring(planByID(id)!)
  record({ name, undo: async () => void (await sendEdit(id, before)), redo: async () => void (await sendEdit(id, after)) })
  if (message) said(message)
}

/** A new plan, holding these papers, shown on its table. */
export async function createPlan(name: string, papers: string[] = []) {
  const made = await call('plans:create', { name, root: importDestination(), papers })
  if ('error' in made) {
    toast(L('계획을 만들지 못했어요.', "Paper Time couldn't make the plan."))
    return null
  }
  putPlan(made)
  setShelf({ kind: 'plan', id: made.plan.id })
  layoutPanes()
  changed('shelf')
  return made
}

/**
 * «새 계획…»: the New Plan sheet — a name, the papers, and the days if they
 * are wanted now — with `papers` already chosen.
 */
export function newPlan(papers: string[] = [], name = '') {
  openPlanSheet({ name, preselected: papers })
}

/** A shelf — a collection, a tag, a folder — made a plan: the sheet, with its name and its papers, in the list's order. */
export function makePlanFrom(shelf: Shelf, name: string) {
  const showing = store.shelf
  store.shelf = shelf
  const ids = shelfPapers().map((entry) => entry.id)
  store.shelf = showing
  openPlanSheet({ name, preselected: ids })
}

/**
 * What the New Plan sheet does when its button is pressed: the plan made of
 * the chosen papers, in the order chosen, and — when asked — their days,
 * spread as «Spread Out» spreads them (one undo step for the days).
 */
export async function createPlanFromSheet(name: string, papers: string[], days: BoardPrefs['spread'] | null) {
  const made = await createPlan(name, papers)
  if (!made) return
  if (days && papers.length) {
    const order = spreadOrder(papers.map((id) => paper(id)).filter((entry): entry is Paper => entry !== null).map(boardPaper))
    const dates = spreadDays(order.length, days.days, days.per, spreadStart(days.from, store.today))
    if (dates.length) {
      const changes = order.map((id, at) => ({ id, date: dates[at] }))
      await setDays(changes, L(`${changes.length}편에 날짜를 정했어요.`, `Gave ${changes.length} paper${changes.length === 1 ? '' : 's'} a day.`), L('고르게 나누기', 'Spread Out'))
      return
    }
  }
  if (papers.length) toast(L(`논문 ${papers.length}편으로 계획을 만들었어요.`, `Made a plan of ${papers.length} paper${papers.length === 1 ? '' : 's'}.`))
}

/** «논문 더하기…»: the picker, for papers not in the plan yet. */
export function addPapersTo(planID: string) {
  if (planByID(planID)) openAddPapersSheet(planID)
}

export async function renamePlan(id: string) {
  const found = planByID(id)
  if (!found) return
  const name = await askForName({ title: L('계획 이름 바꾸기', 'Rename Plan'), placeholder: L('계획 이름', 'Plan Name'), confirm: L('바꾸기', 'Rename'), initial: found.plan.name })
  if (!name || name === found.plan.name) return
  await editPlan(id, { op: 'rename', name }, L('이름 바꾸기', 'Rename'))
}

export async function deletePlan(id: string) {
  const found = planByID(id)
  if (!found) return
  const yes = await askToConfirm({
    title: L(`‘${found.plan.name}’ 계획을 지울까요?`, `Delete “${found.plan.name}”?`),
    message: L('논문은 그대로 있어요. 계획 파일만 휴지통으로 가요.', 'The papers stay in the library. Only the plan goes to the Trash.'),
    confirm: L('지우기', 'Delete'),
    danger: true,
  })
  if (!yes) return
  if (!(await call('plans:delete', { id }))) {
    toast(L('계획을 지우지 못했어요.', "Paper Time couldn't delete the plan."))
    return
  }
  store.plans = store.plans.filter((one) => one.plan.id !== id)
  if (store.shelf.kind === 'plan' && store.shelf.id === id) {
    setShelf({ kind: 'all' })
    layoutPanes()
  }
  changed('papers', 'shelf')
}

/** Papers put in a plan, at the end — or in a section. */
export async function addToPlan(id: string, papers: string[], section: string | null = null) {
  const found = planByID(id)
  if (!found) return
  const fresh = papers.filter((one) => !found.plan.entries.some((entry) => entry.paper === one))
  if (fresh.length === 0) {
    toast(L('이미 이 계획에 있어요.', 'Already in this plan.'))
    return
  }
  await editPlan(id, { op: 'add', papers: fresh, section }, L('계획에 넣기', 'Add to Plan'),
    L(`‘${found.plan.name}’에 ${fresh.length}편을 넣었어요.`, `Added ${fresh.length} paper${fresh.length === 1 ? '' : 's'} to “${found.plan.name}”.`))
}

export async function removeFromPlan(id: string, papers: string[]) {
  await editPlan(id, { op: 'remove', papers }, L('계획에서 빼기', 'Remove from Plan'),
    L(`${papers.length}편을 계획에서 뺐어요.`, `Removed ${papers.length} paper${papers.length === 1 ? '' : 's'} from the plan.`))
}

export async function addSectionTo(id: string) {
  const name = await askForName({ title: L('새 섹션', 'New Section'), placeholder: L('섹션 이름', 'Section Name'), confirm: L('만들기', 'Create') })
  if (!name) return
  await editPlan(id, { op: 'addSection', name, id: crypto.randomUUID().toUpperCase() }, L('섹션 더하기', 'Add Section'))
}

export async function renameSectionOf(id: string, section: PlanSection) {
  const name = await askForName({ title: L('섹션 이름 바꾸기', 'Rename Section'), placeholder: L('섹션 이름', 'Section Name'), confirm: L('바꾸기', 'Rename'), initial: section.name })
  if (!name || name === section.name) return
  await editPlan(id, { op: 'renameSection', id: section.id, name }, L('섹션 이름 바꾸기', 'Rename Section'))
}

/**
 * The plan's add row: addresses pasted, one or many. A paper the library
 * already has joins the plan; the rest are fetched by address first.
 */
export async function addFromAddresses(id: string, text: string): Promise<boolean> {
  const { addresses, unread } = readAddRow(text)
  if (addresses.length === 0) {
    toast(unread.length
      ? L('arXiv 주소나 DOI가 아니에요.', "That isn't an arXiv address or a DOI.")
      : L('arXiv 주소나 DOI를 붙여넣어 주세요.', 'Paste an arXiv address or a DOI.'))
    return false
  }
  const ids: string[] = []
  let failed = 0
  for (const address of addresses) {
    const known = store.papers.find((entry) => holdsAddress((entry.meta.raw.identifiers ?? {}) as { arxiv?: string; doi?: string }, address))
    if (known) {
      ids.push(known.id)
      continue
    }
    const outcome = await addPaperByAddress(addressText(address))
    if ('added' in outcome && outcome.added) ids.push(outcome.added)
    else if ('already' in outcome && outcome.already) ids.push(outcome.already)
    else failed += 1
  }
  if (ids.length) await addToPlan(id, ids)
  if (failed) toast(L(`${failed}편은 가져오지 못했어요.`, `Paper Time couldn't fetch ${failed} of them.`))
  return ids.length > 0
}

// MARK: - The board's selection

/**
 * A row chosen on the board. In the list's column the page beside it shows
 * the paper, as the list's rows did; on the wide calendar the inspector
 * shows it, and opening it is a double-click.
 */
export function selectInBoard(id: string) {
  if (!paper(id)) return
  if (boardInListColumn()) {
    void showPaper(id)
    return
  }
  store.selection = [id]
  store.selectionAnchor = id
  store.selectionLead = id
  if (store.selectedID !== id) {
    store.selectedID = id
    saveSettings({ selectedPaperID: id })
  }
  changed('selection')
}

/**
 * A row opened (a double-click, Return): picked, on the page, kept on the
 * open shelf. From the calendar the plan turns back into its table, so the
 * page has room beside it; with the old list back, the shelf goes to its list.
 */
export async function openFromBoard(id: string) {
  if (!paper(id)) return
  if (LEGACY.paperList) setView('list')
  else if (boardShowing()) setView('table')
  await showPaper(id)
  keepPaper(id)
  revealPane('reader')
  reconcileReaders()
}

/** «읽을 날·계획»: a shelf's table shows its Read On and Plan columns, or not. */
export function togglePlanColumns() {
  savePrefs((prefs) => { prefs.planColumns = !prefs.planColumns })
}

/** Whether the shelf showing is this plan. */
export const onPlan = (id: string) => sameShelf(store.shelf, { kind: 'plan', id })

// MARK: - Materials

function putLinks(id: string, links: PaperLink[]) {
  patchPlanSidecars(id, { links })
  changed('papers')
}

/** An address kept beside a paper. */
export async function addMaterial(id: string, text: string): Promise<boolean> {
  const address = materialAddress(text)
  if (!address) {
    toast(L('주소가 아니에요.', "That isn't a web address."))
    return false
  }
  const answer = await call('links:add', { id, url: address })
  if ('error' in answer) {
    toast(L('자료를 붙이지 못했어요.', "Paper Time couldn't add that."))
    return false
  }
  putLinks(id, answer.links)
  const name = kindName(materialKindOfAddress(address))
  toast(L(`${withRo(name)} 붙였어요.`, `Added as ${name.toLowerCase()}.`))
  return true
}

/** Files copied in beside the paper's PDF. */
export async function addMaterialFiles(id: string, files: string[]) {
  if (files.length === 0) return
  const answer = await call('links:add', { id, files })
  if ('error' in answer) {
    toast(answer.error === 'pdf'
      ? L('PDF는 자료 대신 보충 자료로 붙여요. 목록에서 이 논문 위로 끌어다 놓아요.', 'A PDF goes under the paper as a supplement. Drag it onto the paper in the list.')
      : L('파일을 붙이지 못했어요.', "Paper Time couldn't add the file."))
    return
  }
  putLinks(id, answer.links)
  toast(L(`파일 ${files.length}개를 PDF 옆에 두었어요.`, `Put ${files.length} file${files.length === 1 ? '' : 's'} beside the PDF.`))
}

export async function removeMaterial(id: string, link: PaperLink) {
  putLinks(id, await call('links:edit', { id, linkID: link.id, remove: true }))
}

export async function renameMaterial(id: string, link: PaperLink, shown: string) {
  const title = await askForName({ title: L('자료 이름 바꾸기', 'Rename'), placeholder: shown, confirm: L('바꾸기', 'Rename'), initial: link.title ?? shown })
  if (title === null) return
  putLinks(id, await call('links:edit', { id, linkID: link.id, title: title || null }))
}

export async function openMaterial(id: string, link: PaperLink) {
  if (!(await call('links:open', { id, linkID: link.id }))) toast(L('열지 못했어요.', "Paper Time couldn't open it."))
}

/** The paper's own address, which every paper with an identifier has without being told. */
export function ownAddress(entry: Paper): string | null {
  const ids = (entry.meta.raw.identifiers ?? {}) as { arxiv?: string; doi?: string }
  if (ids.arxiv) return `https://arxiv.org/abs/${ids.arxiv}`
  if (ids.doi) return `https://doi.org/${ids.doi}`
  return null
}

export const papersOfShelf = (): Paper[] => shelfPapers()
