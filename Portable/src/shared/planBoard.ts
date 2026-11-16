/**
 * What the reading plan's board says and in what order — the labels on a
 * day, the groups of a week, the order of «This Week», what the add row
 * reads. Pure, so it is tested without a window (`src/test/planBoard.ts`).
 * The rules themselves (days, plans, materials) are `readingPlan.ts`, held
 * to the Mac's answers.
 */
import { L, prefersKorean } from './lang.js'
import { addDays, dayParts, daysBetween, mondayOf, weekdayOf, type MaterialKind } from './readingPlan.js'
import { readPaperAddress, type PaperAddress } from './paperAddress.js'

export type Status = 'unread' | 'reading' | 'read'

const KO_WEEKDAYS = ['월', '화', '수', '목', '금', '토', '일']
const EN_WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
const EN_WEEKDAYS_LONG = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']
const EN_MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

/** A weekday's short name; 0 is Monday. */
export const weekdayName = (weekday: number): string => (prefersKorean() ? KO_WEEKDAYS : EN_WEEKDAYS)[weekday] ?? ''

/** `11.20` / `Nov 20` — as the Mac and the demo write it. */
export function monthDay(day: string): string {
  const [, month, date] = dayParts(day)
  return prefersKorean() ? `${month}.${date}` : `${EN_MONTHS[month - 1]} ${date}`
}

/** `11월 20일` / `Nov 20`. */
export function longDay(day: string): string {
  const [, month, date] = dayParts(day)
  return prefersKorean() ? `${month}월 ${date}일` : `${EN_MONTHS[month - 1]} ${date}`
}

/** `11월 20일 금요일` / `Friday, Nov 20`. */
export function fullDay(day: string): string {
  const [, month, date] = dayParts(day)
  const weekday = weekdayOf(day)
  return prefersKorean()
    ? `${month}월 ${date}일 ${KO_WEEKDAYS[weekday]}요일`
    : `${EN_WEEKDAYS_LONG[weekday]}, ${EN_MONTHS[month - 1]} ${date}`
}

/** A day that has gone by while the paper stayed unread: behind, never «overdue» in red. */
export function isBehind(date: string | null | undefined, status: Status, today: string): boolean {
  return Boolean(date) && date! < today && status !== 'read'
}

export type DateTone = 'none' | 'today' | 'behind' | 'plain'

/** What a paper's date chip says. */
export function dateLabel(date: string | null | undefined, status: Status, today: string): { text: string; tone: DateTone } {
  if (!date) return { text: L('정하기', 'Set Date'), tone: 'none' }
  if (isBehind(date, status, today)) return { text: L(`${monthDay(date)} · 밀림`, `${monthDay(date)} · Overdue`), tone: 'behind' }
  const away = daysBetween(date, today)
  if (away === 0) return { text: L('오늘', 'Today'), tone: 'today' }
  if (away === 1) return { text: L('내일', 'Tomorrow'), tone: 'plain' }
  return { text: `${weekdayName(weekdayOf(date))} ${monthDay(date)}`, tone: 'plain' }
}

/** The same day in full, for the inspector. */
export function dateLong(date: string | null | undefined, status: Status, today: string): { text: string; tone: DateTone } {
  const short = dateLabel(date, status, today)
  if (!date) return short
  const full = fullDay(date)
  return { text: short.tone === 'behind' ? L(`${full} · 밀림`, `${full} · Overdue`) : full, tone: short.tone }
}

/** A week's heading: `이번 주 · 11.16–11.22`. */
export function weekName(monday: string, today: string): string {
  const away = daysBetween(monday, mondayOf(today)) / 7
  const range = `${monthDay(monday)}–${monthDay(addDays(monday, 6))}`
  if (away === 0) return L(`이번 주 · ${range}`, `This week · ${range}`)
  if (away === 1) return L(`다음 주 · ${range}`, `Next week · ${range}`)
  if (away === -1) return L(`지난주 · ${range}`, `Last week · ${range}`)
  return range
}

/** A day's heading on «This Week»: `오늘 · 11월 16일 월요일`, `수요일 · 11월 18일`. */
export function dayHeading(day: string, today: string): string {
  if (day === today) return L(`오늘 · ${fullDay(day)}`, `Today · ${fullDay(day)}`)
  if (day === addDays(today, 1)) return L(`내일 · ${fullDay(day)}`, `Tomorrow · ${fullDay(day)}`)
  const weekday = weekdayOf(day)
  return prefersKorean() ? `${KO_WEEKDAYS[weekday]}요일 · ${longDay(day)}` : `${EN_WEEKDAYS_LONG[weekday]} · ${longDay(day)}`
}

/** The span a plan's dates cover, or the sentence for none. */
export function spanText(dates: string[]): string {
  const known = dates.filter(Boolean).sort()
  if (known.length === 0) return L('날짜를 아직 안 정했어요', 'No dates yet')
  return `${longDay(known[0])} – ${longDay(known[known.length - 1])}`
}

export interface BoardPaper {
  id: string
  date: string | null
  status: Status
}

export interface Group {
  key: string
  name: string
  ids: string[]
}

/** Grouped by week, the weeks in order and the papers without a day last; within a week, by day. */
export function groupByWeek(papers: BoardPaper[], today: string): Group[] {
  const weeks = new Map<string, BoardPaper[]>()
  for (const paper of papers) {
    const key = paper.date ? mondayOf(paper.date) : 'none'
    weeks.set(key, [...(weeks.get(key) ?? []), paper])
  }
  return [...weeks.keys()]
    .sort((a, b) => (a === 'none' ? 1 : b === 'none' ? -1 : a < b ? -1 : a > b ? 1 : 0))
    .map((key) => ({
      key,
      name: key === 'none' ? L('날짜 없음', 'No Date') : weekName(key, today),
      // Stable: two papers on one day keep the plan's order.
      ids: weeks.get(key)!
        .map((paper, at) => ({ paper, at }))
        .sort((a, b) => ((a.paper.date ?? '') < (b.paper.date ?? '') ? -1 : (a.paper.date ?? '') > (b.paper.date ?? '') ? 1 : a.at - b.at))
        .map(({ paper }) => paper.id),
    }))
}

/** Reading, then unread, then read — empty groups left out. */
export function groupByStatus(papers: BoardPaper[]): Group[] {
  const order: [Status, string][] = [['reading', L('읽는 중', 'Reading')], ['unread', L('안 읽음', 'Unread')], ['read', L('읽음', 'Read')]]
  return order
    .map(([status, name]) => ({ key: status, name, ids: papers.filter((paper) => paper.status === status).map((paper) => paper.id) }))
    .filter((group) => group.ids.length > 0)
}

/**
 * «This Week»: what is behind first — oldest day first — then each day of
 * this week that has anything, read papers included, in the order given.
 */
export function weekShelf(papers: BoardPaper[], today: string): { behind: string[]; days: { day: string; ids: string[] }[] } {
  const behind = papers
    .map((paper, at) => ({ paper, at }))
    .filter(({ paper }) => isBehind(paper.date, paper.status, today))
    .sort((a, b) => (a.paper.date! < b.paper.date! ? -1 : a.paper.date! > b.paper.date! ? 1 : a.at - b.at))
    .map(({ paper }) => paper.id)
  const late = new Set(behind)
  const monday = mondayOf(today)
  const days: { day: string; ids: string[] }[] = []
  for (let i = 0; i < 7; i += 1) {
    const day = addDays(monday, i)
    const ids = papers.filter((paper) => paper.date === day && !late.has(paper.id)).map((paper) => paper.id)
    if (ids.length) days.push({ day, ids })
  }
  return { behind, days }
}

/** The number by «This Week» in the sidebar: what is still to read this week, and what is behind. */
export function weekCount(papers: BoardPaper[], today: string): number {
  const monday = mondayOf(today)
  return papers.filter((paper) => paper.status !== 'read' && paper.date
    && (isBehind(paper.date, paper.status, today) || mondayOf(paper.date) === monday)).length
}

/** What «Spread Evenly» gives days to: the papers not read, the ones being read first, then the plan's order. */
export function spreadOrder(papers: BoardPaper[]): string[] {
  const left = papers.filter((paper) => paper.status !== 'read')
  return [...left.filter((paper) => paper.status === 'reading'), ...left.filter((paper) => paper.status !== 'reading')].map((paper) => paper.id)
}

/** The papers a plan has on this week's days, behind ones too. */
export function planStats(papers: BoardPaper[], today: string): { thisWeek: number; behind: number; undated: number; read: number } {
  const monday = mondayOf(today)
  return {
    thisWeek: papers.filter((paper) => paper.date && mondayOf(paper.date) === monday).length,
    behind: papers.filter((paper) => isBehind(paper.date, paper.status, today)).length,
    undated: papers.filter((paper) => !paper.date).length,
    read: papers.filter((paper) => paper.status === 'read').length,
  }
}

/** A paper's progress: how far through, and what the cell says. */
export function progress(pages: number, lastPageIndex: number | undefined, status: Status): { fraction: number; text: string; done: boolean } {
  const count = Math.max(0, Math.round(pages || 0))
  const pagesText = count > 0 ? L(`${count}쪽`, `${count} pp.`) : '—'
  if (status === 'read') return { fraction: 1, text: pagesText, done: true }
  if (status === 'reading' && count > 0) {
    const page = Math.min(count, Math.max(1, (lastPageIndex ?? 0) + 1))
    return { fraction: page / count, text: `${page}/${count}`, done: false }
  }
  return { fraction: 0, text: pagesText, done: false }
}

/** The next status a paper's ring goes to. */
export const nextStatus = (status: Status): Status => (status === 'unread' ? 'reading' : status === 'reading' ? 'read' : 'unread')

/**
 * What the plan's add row was given: the addresses in it, one per line or
 * separated by spaces and commas, and what was not one.
 */
export function readAddRow(text: string): { addresses: PaperAddress[]; unread: string[] } {
  const addresses: PaperAddress[] = []
  const unread: string[] = []
  const seen = new Set<string>()
  for (const piece of text.split(/[\s,]+/).map((one) => one.trim()).filter(Boolean)) {
    const address = readPaperAddress(piece)
    if (!address || address.kind === 'web') {
      unread.push(piece)
      continue
    }
    const key = address.kind === 'arxiv' ? `arxiv:${address.id.toLowerCase()}` : `doi:${address.doi.toLowerCase()}`
    if (seen.has(key)) continue
    seen.add(key)
    addresses.push(address)
  }
  return { addresses, unread }
}

/** Whether a paper's identifiers are this address. */
export function holdsAddress(identifiers: { arxiv?: string; doi?: string }, address: PaperAddress): boolean {
  if (address.kind === 'arxiv') {
    const base = (id: string) => id.toLowerCase().replace(/v\d+$/, '')
    return Boolean(identifiers.arxiv) && base(identifiers.arxiv!) === base(address.id)
  }
  if (address.kind === 'doi') return Boolean(identifiers.doi) && identifiers.doi!.toLowerCase() === address.doi.toLowerCase()
  return false
}

/** A material's kind, said. */
export function kindName(kind: MaterialKind): string {
  switch (kind) {
    case 'paper': return L('논문', 'Paper')
    case 'slides': return L('슬라이드', 'Slides')
    case 'code': return L('코드', 'Code')
    case 'notebook': return L('노트북', 'Notebook')
    case 'video': return L('영상', 'Video')
    case 'data': return L('데이터', 'Data')
    case 'post': return L('글', 'Article')
    case 'file': return L('파일', 'File')
    case 'supplement': return L('보충 자료', 'Supplement')
  }
}

/** The colour token a kind wears (the demo's). */
export function kindTone(kind: MaterialKind): string {
  switch (kind) {
    case 'paper': return 'blue'
    case 'slides': return 'orange'
    case 'code': return 'gray'
    case 'notebook': return 'yellow'
    case 'video': return 'pink'
    case 'data': return 'teal'
    case 'post': return 'green'
    case 'file': return 'indigo'
    case 'supplement': return 'purple'
  }
}

/** A Korean noun with its «(으)로»: 코드로, 노트북으로, 글로. */
export function withRo(word: string): string {
  const last = word.charCodeAt(word.length - 1)
  if (last < 0xac00 || last > 0xd7a3) return `${word}(으)로`
  const final = (last - 0xac00) % 28
  return final === 0 || final === 8 ? `${word}로` : `${word}으로`
}

/** The line under the paste field: what the address was taken for. */
export function detectionLine(kind: MaterialKind): string {
  const name = kindName(kind)
  return L(`${withRo(name)} 알아챘어요 · Enter로 붙여요`, `${name} — press Return to add`)
}

/** The number of days a «Spread Evenly» covers, said: `5편 · 11월 16일 – 11월 27일`. */
export function spreadPreview(days: string[], weekdayCount: number): string {
  if (weekdayCount === 0) return L('요일을 하나 이상 골라주세요.', 'Choose at least one day.')
  if (days.length === 0) return L('안 읽은 논문이 없어요.', 'Every paper here is read.')
  const range = `${longDay(days[0])} – ${longDay(days[days.length - 1])}`
  return L(`${days.length}편 · ${range}`, `${days.length} paper${days.length === 1 ? '' : 's'} · ${range}`)
}

/** The first day of a «Spread Evenly»: today, or next Monday. */
export const spreadStart = (from: 'today' | 'next', today: string): string => (from === 'today' ? today : addDays(mondayOf(today), 7))

/** The 35 days of the plan's calendar, starting on the given Monday. */
export function calendarDays(start: string): string[] {
  return Array.from({ length: 35 }, (_, at) => addDays(start, at))
}

/** Where the calendar opens: last week's Monday, so a behind paper is in sight. */
export const calendarHome = (today: string): string => addDays(mondayOf(today), -7)

/** A calendar cell's label: the month's name on the first cell and on the 1st. */
export function calendarLabel(day: string, first: boolean): string {
  const [, , date] = dayParts(day)
  return first || date === 1 ? longDay(day) : String(date)
}

// MARK: - What the plan asks for next

/**
 * What a plan's board says it needs, so nobody has to read a manual to know
 * the next step: an empty plan asks for papers, a plan of papers with no day
 * at all asks when they will be read. Anything else asks for nothing.
 */
export type Guidance = 'empty' | 'noDays' | null

export function planGuidance(papers: BoardPaper[]): Guidance {
  if (papers.length === 0) return 'empty'
  if (papers.every((paper) => !paper.date)) return 'noDays'
  return null
}

// MARK: - The columns

export type ColumnID = 'authors' | 'year' | 'venue' | 'date' | 'plan' | 'progress' | 'materials' | 'tags' | 'rating' | 'notes' | 'added' | 'opened'
export type BoardContext = 'plan' | 'week' | 'other'

/** Every column, in the order the column menu lists them. */
export const ALL_COLUMNS: ColumnID[] = ['authors', 'year', 'venue', 'date', 'plan', 'progress', 'materials', 'tags', 'rating', 'notes', 'added', 'opened']

export const DEFAULT_COLUMNS: Record<BoardContext, ColumnID[]> = {
  plan: ['authors', 'year', 'venue', 'date', 'progress', 'materials'],
  week: ['plan', 'date', 'materials'],
  other: ['authors', 'year', 'venue', 'date', 'plan', 'materials'],
}

/**
 * Where a board's row puts its parts, for a board of a given width (the
 * Mac's `BoardGeometry`). The row is the ring (22), a gap (10), the title, a
 * gap (10) and the columns, each at its own width with 10 between them,
 * inside 20 of padding each side — so `room` (title and columns) is the
 * width less 82.
 *
 * Every column stands, at its own width, aligned down the table. When they
 * all fit beside a title of at least 150 the title takes the rest. When they
 * do not, the title is pinned on the left (45% of the room, 150 to 220) and
 * the columns slide sideways in what is left — the viewport — by up to
 * `limit` (2026-11-16: the authors, year and venue folded under the title
 * read as clutter, «열로 정렬이 되어있는게 아니다보니까 조금 번잡스럽네»;
 * the user chose a pinned title and columns that slide, as Notion and
 * Numbers do).
 */
export interface BoardGeometry {
  /** Whether the columns slide behind a pinned title. */
  slides: boolean
  title: number
  /** The columns' own width, gaps included. */
  content: number
  /** How much of the columns shows at once. */
  viewport: number
  /** How far they slide: 0 when they all show. */
  limit: number
}

/** The ring, the two gaps beside the title and the padding either side. */
export const BOARD_ROW_CHROME = 82
/** The title is never narrower than this; past it, the columns slide. */
export const TITLE_KEEP = 150
export const PINNED_TITLE = { least: 150, most: 220, share: 0.45 }

export function boardGeometry(width: number, columnWidths: readonly number[]): BoardGeometry {
  const room = Math.max(0, width - BOARD_ROW_CHROME)
  const count = columnWidths.length
  const content = count === 0 ? 0 : columnWidths.reduce((sum, one) => sum + one, 0) + 10 * (count - 1)
  if (count === 0 || room - content >= TITLE_KEEP) {
    return { slides: false, title: room - content, content, viewport: content, limit: 0 }
  }
  const title = Math.min(PINNED_TITLE.most, Math.max(PINNED_TITLE.least, room * PINNED_TITLE.share))
  const viewport = Math.max(0, room - title)
  return { slides: true, title, content, viewport, limit: Math.max(0, content - viewport) }
}

/** An offset held inside what the columns can slide. */
export function clampSlide(x: number, limit: number): number {
  return Math.min(Math.max(x, 0), Math.max(0, limit))
}

/** Where a chevron takes the columns: most of a viewport over, either way. */
export function slideStep(x: number, geometry: Pick<BoardGeometry, 'viewport' | 'limit'>, direction: 1 | -1): number {
  return clampSlide(x + direction * geometry.viewport * 0.8, geometry.limit)
}

/**
 * How far a wheel event slides the columns, or 0 when it is not a sideways
 * one: a trackpad swipe that goes more across than down, or the wheel with
 * Shift held (the vertical turn read as horizontal). Lines and pages are
 * turned into pixels the way the browser scrolls them.
 */
export function wheelSlide(event: { deltaX: number; deltaY: number; deltaMode: number; shiftKey: boolean }, page = 400): number {
  const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? page : 1
  if (Math.abs(event.deltaX) > Math.abs(event.deltaY)) return event.deltaX * unit
  if (event.shiftKey) return event.deltaY * unit
  return 0
}

// MARK: - Sorting

/**
 * What a table sorts by: the title, and every column with one value a
 * paper either has or has not. The materials and the tags have no order.
 */
export type BoardSortKey = 'title' | 'authors' | 'year' | 'venue' | 'plan' | 'date' | 'progress' | 'rating' | 'notes' | 'added' | 'opened'

export const BOARD_SORT_KEYS: readonly BoardSortKey[] = ['title', 'authors', 'year', 'venue', 'plan', 'date', 'progress', 'rating', 'notes', 'added', 'opened']

export interface BoardSort {
  key: BoardSortKey
  ascending: boolean
}

/** The key a column sorts by, or null for a column with no order. */
export function sortKeyOf(id: ColumnID): BoardSortKey | null {
  return id === 'materials' || id === 'tags' ? null : id
}

/**
 * The sort after a header is clicked: another key starts ascending, the
 * current one turns descending, and a third click gives the board its own
 * order back — the shelf's, the plan's reading order, the week's. A plan
 * sorted by year and no way back to the order it was planned in would be a
 * trap (2026-11-16).
 */
export function nextSort(current: BoardSort | null, key: BoardSortKey): BoardSort | null {
  if (!current || current.key !== key) return { key, ascending: true }
  return current.ascending ? { key, ascending: false } : null
}

/** Text compared the way Finder does: case aside, numbers by value. */
export function compareText(a: string, b: string): number {
  return a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' })
}

/**
 * The items in the sort's order (the Mac's comparator). A value of null is
 * a paper without one — no year, no authors, never opened — and those go
 * last, in their own order, whichever way the rest face: only the papers
 * with values turn round between ↑ and ↓. Ties keep the board's own order.
 * No sort is the items as they came.
 */
export function sortRows<T>(items: readonly T[], sort: BoardSort | null, value: (item: T, key: BoardSortKey) => string | number | null): T[] {
  if (!sort) return [...items]
  const sign = sort.ascending ? 1 : -1
  const known: { item: T; at: number; v: string | number }[] = []
  const missing: T[] = []
  items.forEach((item, at) => {
    const v = value(item, sort.key)
    if (v === null || v === '') missing.push(item)
    else known.push({ item, at, v })
  })
  known.sort((a, b) => {
    const order = typeof a.v === 'number' && typeof b.v === 'number' ? a.v - b.v : compareText(String(a.v), String(b.v))
    return order !== 0 ? order * sign : a.at - b.at
  })
  return [...known.map((one) => one.item), ...missing]
}

/**
 * A shelf's table — not a plan's, not This Week's — shows «Read On» and
 * «Plan» only when asked: on a shelf that is not a plan they are two columns
 * of «Set Date» and «—» (2026-11-16, the user's ask).
 */
export function withPlanColumns(columns: ColumnID[], context: BoardContext, shown: boolean): ColumnID[] {
  if (context !== 'other' || shown) return columns
  return columns.filter((id) => id !== 'date' && id !== 'plan')
}

/**
 * How a shelf is seen. With the old list set aside (`LEGACY.paperList` off)
 * a plan is its table or its calendar and every other shelf is its table;
 * with it back, the choices are the ones the List | Table switch made.
 */
export function viewFor(kind: string, kept: 'list' | 'table' | 'calendar' | undefined, legacyList: boolean): 'list' | 'table' | 'calendar' {
  if (kind === 'notes') return 'list'
  if (!legacyList) {
    if (kind === 'plan') return kept === 'calendar' ? 'calendar' : 'table'
    return 'table'
  }
  if (kind === 'week') return kept === 'list' ? 'list' : 'table'
  if (kind === 'plan') return kept ?? 'table'
  return kept === 'table' ? 'table' : 'list'
}

/**
 * Where a shelf's board stands. `wide` takes the room of the list and the
 * page (a plan's calendar; with the old list back, every board); `list`
 * holds the table in the list's column with the page beside it — every
 * shelf of papers except search results (their passages are rows) and a
 * library with nothing in it yet (its setup); `none` is the old list.
 */
export function boardPlace(kind: string, view: 'list' | 'table' | 'calendar', hasPapers: boolean, legacyList: boolean): 'wide' | 'list' | 'none' {
  if (kind === 'notes') return 'none'
  if (legacyList) return view === 'list' ? 'none' : 'wide'
  if (kind === 'plan' && view === 'calendar') return 'wide'
  if (kind === 'search' || !hasPapers) return 'none'
  return 'list'
}

/**
 * A remembered list of columns, read: the old «저자 · 해» (`who`) is the two
 * columns it became, anything this build does not know is dropped, and a
 * column is listed once.
 */
export function readColumns(list: unknown): ColumnID[] | null {
  if (!Array.isArray(list)) return null
  const out: ColumnID[] = []
  for (const one of list) {
    const ids: ColumnID[] = one === 'who' ? ['authors', 'year'] : ALL_COLUMNS.includes(one as ColumnID) ? [one as ColumnID] : []
    for (const id of ids) if (!out.includes(id)) out.push(id)
  }
  return out
}

/** «Kumar 외» / "Kumar et al.": the first author's family name, and whether there are more. */
export function authorsText(authors: { family?: string; literal?: string; given?: string }[] | undefined): string {
  const list = authors ?? []
  const first = list[0]
  const name = first ? (first.family || first.literal || first.given || '') : ''
  if (!name) return ''
  return list.length > 1 ? L(`${name} 외`, `${name} et al.`) : name
}

// MARK: - Choosing papers

/** A paper as the picker lists it. */
export interface PickerPaper {
  id: string
  title: string
  /** What the search reads: the title and the authors' names. */
  search: string
}

/** Lower-cased, accents taken off, spaces made one: what a search compares. */
export function pickerFold(text: string): string {
  return text.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/\s+/g, ' ').trim()
}

/**
 * The order the picker lists papers in, fixed when it opens: the ones chosen
 * then, in the order they were given; then the rest by title. It does not
 * change as boxes are ticked — a row that jumps away under the pointer is a
 * row ticked twice. `last` (a plan's own papers, in the add sheet) go at the
 * end, where they are shown and cannot be ticked.
 */
export function pickerOrder(papers: PickerPaper[], chosen: string[], last: Iterable<string> = []): string[] {
  const known = new Set(papers.map((paper) => paper.id))
  const first = chosen.filter((id, at) => known.has(id) && chosen.indexOf(id) === at)
  const firstSet = new Set(first)
  const lastSet = new Set(last)
  const byTitle = (a: PickerPaper, b: PickerPaper) => a.title.localeCompare(b.title, undefined, { sensitivity: 'base' })
  const rest = papers.filter((paper) => !firstSet.has(paper.id) && !lastSet.has(paper.id)).sort(byTitle).map((paper) => paper.id)
  const tail = papers.filter((paper) => lastSet.has(paper.id) && !firstSet.has(paper.id)).sort(byTitle).map((paper) => paper.id)
  return [...first, ...rest, ...tail]
}

/** The rows the picker shows: those whose title or authors hold every word typed, and only the chosen when asked. */
export function pickerShown(order: string[], papers: PickerPaper[], query: string, chosenOnly: boolean, chosen: Iterable<string>): string[] {
  const known = new Map(papers.map((paper) => [paper.id, pickerFold(paper.search)]))
  const words = pickerFold(query).split(' ').filter(Boolean)
  const picked = new Set(chosen)
  return order.filter((id) => {
    if (chosenOnly && !picked.has(id)) return false
    const text = known.get(id)
    return text !== undefined && words.every((word) => text.includes(word))
  })
}
