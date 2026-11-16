/**
 * The board: every shelf's table, in the list's column with the page beside
 * it — or a plan's calendar, where the list and the page were (with the old
 * list back, `LEGACY.paperList`, every board took that room).
 *
 * Three faces. A plan: its name, how far along, the path of papers by
 * section, «Spread Evenly» and «Push a Week», and the table grouped by
 * section, week or status — or the calendar, where a paper is dragged from
 * day to day. «This Week»: every plan's papers for the week, what is behind
 * on top. Any other shelf: its papers as a table, sorted by any column.
 * The rows are the library's papers, so most of the columns fill
 * themselves; the day, the materials and the order are the reader's.
 */
import { clear, el, on } from '../dom.js'
import { iconNode, type IconName } from '../icons.js'
import {
  attachmentsOf, notesForPaper, paper, planByID, planPapers, plansOf, shelfPapers, store, tagByID, type Paper,
} from '../state.js'
import { L, prefersKorean } from '../../shared/lang.js'
import { addDays, materialHost, materialTitle as materialTitleOf, mondayOf, planGroups, venueName, type PaperLink } from '../../shared/readingPlan.js'
import {
  authorsText, boardGeometry, calendarDays, calendarHome, calendarLabel, clampSlide, dateLabel, dayHeading, groupByStatus, groupByWeek, isBehind, kindName,
  kindTone, longDay, nextSort, planGuidance, planStats, progress, slideStep, sortKeyOf, sortRows, spanText, weekShelf, wheelSlide, withPlanColumns,
  type BoardGeometry, type BoardSort, type BoardSortKey, type Status,
} from '../../shared/planBoard.js'
import { sortingSurname } from '../../shared/authorKey.js'
import { carriesPapers, draggedPapers, writeDraggedPapers } from '../../shared/split.js'
import { showMenu, showMenuAt, type MenuEntry } from './menu.js'
import { emptyShelf, folderNoticeRows, papersText, shelfTitle, tagColor, type PaperListActions } from './paperList.js'
import { shelfHeader, shelfSymbol, shelfTone } from './shelfHeader.js'
import { paperMenuEntries } from '../actions/paper.js'
import { LEGACY } from '../../shared/legacy.js'
import {
  ALL_COLUMNS, addFromAddresses, addPapersTo, addSectionTo, addToPlan, boardContext, boardPaper, cycleStatus, editPlan, openFromBoard,
  ownAddress, prefs, pullBehind, pushWeek, removeFromPlan, renameSectionOf, savePrefs, selectInBoard, setDay, setDays, setView,
  togglePlanColumns, viewOf, type ColumnID,
} from '../plans.js'

/** The plans whose «When will you read them?» strip was put away, this session. */
const quietGuides = new Set<string>()
import { closePlanPop, openDatePop, openSpreadPop } from './planPopovers.js'

/** The kind of row a drag on the board carries: plan rows being put in order, or a pill going to another day. */
const ROWS_TYPE = 'application/x-papertime-plan-rows'
const PILL_TYPE = 'application/x-papertime-plan-pill'

// MARK: - Small pictures

/** The reading status as a ring: empty, filling as the pages go, a green tick. */
export function ring(status: Status, fraction: number, size = 16): string {
  const c = 2 * Math.PI * 6
  const open = `<svg width="${size}" height="${size}" viewBox="0 0 16 16" aria-hidden="true">`
  if (status === 'read') {
    return `${open}<circle cx="8" cy="8" r="7" fill="var(--shelf-read)"/><path d="M5 8.3l2 2 4-4.4" fill="none" stroke="var(--panel)" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>`
  }
  if (status === 'reading') {
    const f = Math.max(0.12, Math.min(0.92, fraction))
    return `${open}<circle cx="8" cy="8" r="6" fill="none" stroke="var(--reading-track)" stroke-width="2"/><circle cx="8" cy="8" r="6" fill="none" stroke="var(--shelf-reading)" stroke-width="2" stroke-linecap="round" stroke-dasharray="${(c * f).toFixed(1)} ${c.toFixed(1)}" transform="rotate(-90 8 8)"/></svg>`
  }
  return `${open}<circle cx="8" cy="8" r="6" fill="none" stroke="var(--ring-empty)" stroke-width="1.5"/></svg>`
}

/** How much of a plan is read, as a small ring for the sidebar. */
export function donut(fraction: number): string {
  const c = 2 * Math.PI * 5
  return `<svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><circle cx="7" cy="7" r="5" fill="none" stroke="var(--separator-strong)" stroke-width="2"/><circle cx="7" cy="7" r="5" fill="none" stroke="var(--shelf-read)" stroke-width="2" stroke-linecap="round" stroke-dasharray="${(c * fraction).toFixed(1)} ${c.toFixed(1)}" transform="rotate(-90 7 7)"/></svg>`
}

export const KIND_ICON: Record<string, IconName> = {
  paper: 'text.document', slides: 'display', code: 'chevron.left.forwardslash.chevron.right', notebook: 'book.closed',
  video: 'play.rectangle', data: 'cylinder', post: 'text.alignleft', file: 'doc', supplement: 'paperclip',
}

function glyph(name: IconName): Node {
  return iconNode(name) ?? document.createTextNode('')
}

const statusOf = (entry: Paper): Status => entry.state.readingStatus as Status

function progressOf(entry: Paper) {
  return progress(entry.meta.file.pageCount, entry.state.lastPageIndex, statusOf(entry))
}

/** One thing kept beside a paper, as the materials list shows it. `supplement` is the id of a
 *  supplement PDF under the paper. */
export interface Material { kind: PaperLink['kind']; title: string; detail: string; link: PaperLink | null; url: string | null; supplement?: string }

/** What is kept beside a paper, its own address first, then its supplements, then the rest. */
export function materialsOf(entry: Paper): Material[] {
  const out: Material[] = []
  const own = ownAddress(entry)
  if (own) {
    const ids = (entry.meta.raw.identifiers ?? {}) as { arxiv?: string; doi?: string }
    out.push({
      kind: 'paper',
      title: ids.arxiv ? `arXiv:${ids.arxiv}` : `doi.org/${ids.doi}`,
      detail: L('논문 · 서지에서 저절로', 'Paper · From the record'),
      link: null,
      url: own,
    })
  }
  // The paper's supplements are its materials too: the PDFs a conference
  // hands out beside the paper, kept in the library under it rather than in
  // the list beside it.
  for (const supplement of attachmentsOf(entry.id)) {
    out.push({
      kind: 'supplement', title: supplement.meta.file.originalName, detail: L('보충 자료 · PDF', 'Supplement · PDF'),
      link: null, url: null, supplement: supplement.id,
    })
  }
  for (const link of entry.links ?? []) {
    const title = link.title || (link.url ? materialTitleOf(link.url) : (link.file ?? '').split('/').pop() ?? '')
    const detail = link.url
      ? `${kindName(link.kind)} · ${materialHost(link.url)}`
      : L(`${kindName(link.kind)} · PDF 옆에 있어요`, `${kindName(link.kind)} · Beside the PDF`)
    out.push({ kind: link.kind, title, detail, link, url: link.url ?? null })
  }
  return out
}

// MARK: - Columns

interface Column {
  id: ColumnID
  label: () => string
  width: number
  cell: (entry: Paper) => Node
}

/** «Kumar 외», for the authors column. */
const authorsOf = (entry: Paper): string => authorsText(entry.meta.csl.author)

/** «NeurIPS», for the venue column — the record's short name, a known one, or the title. */
const venueOf = (entry: Paper): string =>
  venueName(entry.meta.csl['container-title'], entry.meta.csl['container-title-short'] as string | undefined) ?? ''

function dateChip(entry: Paper): HTMLElement {
  const label = dateLabel(entry.schedule, statusOf(entry), store.today)
  return el('button', { class: `pb-date ${label.tone}`, 'data-act': 'date', 'data-id': entry.id, title: L('읽을 날 정하기', 'Set the Day to Read') }, [label.text])
}

function progressCell(entry: Paper): HTMLElement {
  const made = progressOf(entry)
  const bar = el('span', { class: made.done ? 'pb-bar done' : 'pb-bar' }, [el('i', { style: `width:${Math.round(made.fraction * 100)}%` })])
  return el('div', { class: 'pb-prog' }, [bar, made.text])
}

/**
 * One tile, the width of the column; more than one, and a count in its
 * corner, the kinds in its tooltip (2026-11-16: the column only as wide as
 * the button — the Mac's `MaterialChips`).
 */
function materialsCell(entry: Paper): HTMLElement {
  const list = materialsOf(entry)
  const cell = el('div', { class: 'pb-links' })
  const first = list[0]
  if (!first) return cell
  const tile = el('span', {
    class: 'pb-kchip',
    'data-tone': kindTone(first.kind),
    title: list.length > 1 ? list.map((one) => kindName(one.kind)).join(' · ') : `${kindName(first.kind)} · ${first.title}`,
  }, [glyph(KIND_ICON[first.kind])])
  if (list.length > 1) tile.append(el('span', { class: 'pb-kcount', text: String(list.length) }))
  cell.append(tile)
  return cell
}

function tagsCell(entry: Paper): HTMLElement {
  const cell = el('div', { class: 'pb-tags' })
  for (const id of entry.meta.tagIDs.slice(0, 2)) {
    const tag = tagByID(id)
    if (tag) cell.append(el('span', { class: 'pb-tag', style: `--k:${tagColor(tag.color)}`, text: tag.name }))
  }
  return cell
}

function planCell(entry: Paper): HTMLElement {
  const cell = el('div', { class: 'pb-tags' })
  const plans = plansOf(entry.id)
  if (plans.length === 0) cell.append(el('span', { class: 'pb-dim', text: '—' }))
  for (const one of plans.slice(0, 2)) cell.append(el('span', { class: 'pb-tag', style: '--k:var(--tag-indigo)', text: one.plan.name }))
  return cell
}

const text = (value: string, extra = '') => el('div', { class: `pb-text ${extra}`.trim(), text: value || '—', title: value })

const COLUMNS: Record<ColumnID, Column> = {
  authors: { id: 'authors', label: () => L('저자', 'Authors'), width: 116, cell: (entry) => text(authorsOf(entry), 'secondary') },
  year: { id: 'year', label: () => L('해', 'Year'), width: 44, cell: (entry) => text(entry.meta.year ? String(entry.meta.year) : '', 'secondary') },
  venue: { id: 'venue', label: () => L('학회', 'Venue'), width: 92, cell: (entry) => text(venueOf(entry), 'secondary') },
  date: { id: 'date', label: () => L('읽을 날', 'Read On'), width: 100, cell: dateChip },
  plan: { id: 'plan', label: () => L('계획', 'Plan'), width: 132, cell: planCell },
  progress: { id: 'progress', label: () => L('진행', 'Progress'), width: 88, cell: progressCell },
  materials: { id: 'materials', label: () => L('자료', 'Materials'), width: 34, cell: materialsCell },
  tags: { id: 'tags', label: () => L('태그', 'Tags'), width: 110, cell: tagsCell },
  rating: { id: 'rating', label: () => L('별점', 'Rating'), width: 72, cell: (entry) => text(entry.state.rating ? '★'.repeat(Math.round(entry.state.rating)) : '', 'stars') },
  notes: { id: 'notes', label: () => L('노트', 'Notes'), width: 56, cell: (entry) => text(String(notesForPaper(entry.id).length || ''), 'secondary') },
  added: { id: 'added', label: () => L('더한 날', 'Added'), width: 88, cell: (entry) => text(longDay(isoDay(entry.meta.addedAt)), 'secondary') },
  opened: { id: 'opened', label: () => L('마지막으로 읽은 날', 'Last Read'), width: 120, cell: (entry) => text(entry.state.lastOpenedAt ? longDay(isoDay(entry.state.lastOpenedAt)) : '', 'secondary') },
}

/** A moment as the reader's own day. */
function isoDay(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
}

/** The columns asked for, in their order: a shelf's Read On and Plan only when turned on. */
function wantedColumns(): ColumnID[] {
  const context = boardContext()
  return withPlanColumns(prefs().columns[context], context, prefs().planColumns)
}

/**
 * Every column asked for stands, at its own width: when they do not all fit
 * beside the title, the title is pinned and they slide (`boardGeometry`).
 */
function columnsFor(): Column[] {
  return wantedColumns().map((id) => COLUMNS[id]).filter(Boolean)
}

/**
 * The columns' part of a row or of the header: a viewport that clips, and in
 * it a track at the columns' own width that slides by the board's offset
 * (`--pb-x`). Only the track's grid is the columns'; where the title ends and
 * the viewport begins is the board's (`--pb-title-col`, `--pb-cols-col`), so
 * a resize moves no row's markup.
 */
function columnsCell(columns: Column[], cells: Node[]): HTMLElement {
  const widths = columns.map((one) => one.width)
  const content = widths.reduce((sum, one) => sum + one, 0) + 10 * Math.max(0, widths.length - 1)
  const track = el('div', {
    class: 'pb-track',
    style: `grid-template-columns:${widths.map((one) => `${one}px`).join(' ')};width:${content}px`,
  }, cells)
  return el('div', { class: 'pb-cols' }, [track])
}

/** The table that holds the header and the rows; no wider than the board — the columns slide inside it. */
function tableNode(columns: Column[], head: (columns: Column[]) => HTMLElement): HTMLElement {
  return el('div', { class: 'pb-table' }, [head(columns)])
}

/**
 * A paper's value for a key, or null when it has none — no year, no
 * authors, never opened — which sorts last whichever way the rest face (the
 * Mac's comparator). Text compares the way Finder does (`compareText`).
 */
function sortValue(entry: Paper, key: BoardSortKey): string | number | null {
  switch (key) {
    case 'title': return entry.meta.displayTitle
    case 'authors': {
      const first = entry.meta.csl.author?.[0]
      return first ? sortingSurname(first) : null
    }
    case 'year': return entry.meta.year ?? null
    case 'venue': return venueOf(entry) || null
    case 'plan': return plansOf(entry.id)[0]?.plan.name ?? null
    case 'date': return entry.schedule ?? null
    case 'progress': return progressOf(entry).fraction
    case 'rating': return entry.state.rating ?? null
    case 'notes': return notesForPaper(entry.id).length
    case 'added': return entry.meta.addedAt.getTime()
    case 'opened': return entry.state.lastOpenedAt?.getTime() ?? null
  }
}

/** Each plan's sort and the week's, this session; the shelves share the one remembered in the settings. */
const sessionSorts = new Map<string, BoardSort>()

/** Which sort the board in front stands in. */
function sortSlot(): string {
  const shelf = store.shelf
  return shelf.kind === 'plan' ? `plan:${shelf.id}` : shelf.kind === 'week' ? 'week' : 'shelf'
}

/** The board's sort, or null for its own order — the shelf's, the plan's reading order, the week's. */
export function boardSortNow(): BoardSort | null {
  const slot = sortSlot()
  if (slot !== 'shelf') return sessionSorts.get(slot) ?? null
  const remembered = prefs().sort
  return remembered.key ? { key: remembered.key, ascending: remembered.ascending } : null
}

function setBoardSort(next: BoardSort | null) {
  const slot = sortSlot()
  if (slot !== 'shelf') {
    if (next) sessionSorts.set(slot, next)
    else sessionSorts.delete(slot)
    return
  }
  savePrefs((prefs) => { prefs.sort = next ? { key: next.key, ascending: next.ascending } : { key: null, ascending: true } })
}

/** Papers in the board's sort; a board's own order when it has none. */
const sortedForTable = (papers: Paper[]): Paper[] => sortRows(papers, boardSortNow(), sortValue)

// MARK: - The board

export interface PlanBoard {
  node: HTMLElement
  update: () => void
  /** Only the chosen paper moved: the highlight follows, nothing is rebuilt —
   *  a popover anchored to a row's date stays anchored. */
  mark: () => void
}

/** What the board asks of the library: the folder's notices act through these. */
export type PlanBoardActions = Pick<PaperListActions, 'refresh' | 'adoptLoose'>

export function buildPlanBoard(actions: PlanBoardActions): PlanBoard {
  const node = el('div', { class: 'panel plan-board' })
  /** The columns drawn last, which is what the geometry is worked out for. */
  let drawnColumns: Column[] = []
  const columnsNow = (): Column[] => {
    drawnColumns = columnsFor()
    return drawnColumns
  }
  /**
   * How far the columns have slid behind the pinned title, one offset for
   * the header and every row. Back to the start when the board shows another
   * shelf or another set of columns; held inside the limit when the board
   * narrows or widens.
   */
  let slideX = 0
  let slideFor = ''
  let geometry: BoardGeometry | null = null
  /** The scroll area the rows are measured in: its width leaves out a classic scrollbar. */
  let measured: HTMLElement | null = null

  /** The board's geometry for its width now, said as variables the rows read. */
  function applyGeometry() {
    const width = measured?.isConnected ? measured.clientWidth : node.clientWidth
    if (width <= 0) return
    const next = boardGeometry(width, drawnColumns.map((one) => one.width))
    geometry = next
    slideX = clampSlide(slideX, next.limit)
    node.style.setProperty('--pb-title-col', next.slides ? `${next.title}px` : 'minmax(0, 1fr)')
    node.style.setProperty('--pb-cols-col', next.slides ? 'minmax(0, 1fr)' : `${next.content}px`)
    showSlide()
  }

  /** Where the columns stand now, and which chevrons and fades go with it. */
  function showSlide() {
    const slides = geometry?.slides ?? false
    const limit = geometry?.limit ?? 0
    node.style.setProperty('--pb-x', `${slideX}px`)
    node.classList.toggle('pb-slides', slides)
    node.classList.toggle('pb-can-left', slides && slideX > 0.5)
    node.classList.toggle('pb-can-right', slides && slideX < limit - 0.5)
  }

  /** Moves the columns, with the motion ladder when a chevron asked for it. */
  function slideTo(x: number, animated: boolean) {
    const next = clampSlide(x, geometry?.limit ?? 0)
    if (Math.abs(next - slideX) < 0.5) return false
    slideX = next
    if (animated) {
      node.classList.add('pb-sliding')
      window.setTimeout(() => node.classList.remove('pb-sliding'), 400)
    } else {
      node.classList.remove('pb-sliding')
    }
    showSlide()
    return true
  }
  /** Where the calendar starts; back to last week whenever another plan is shown. */
  let calendarStart = calendarHome(store.today)
  let calendarFor = ''
  /** Which row a drag started on, and which rows it carries. */
  let dragging: string[] = []
  /** The board's sort as of this drawing. */
  let sortNow: BoardSort | null = null
  let shownKey = ''

  function update() {
    // A field being typed into is not taken out from under the hand.
    const typing = document.activeElement
    const typingIn = typing instanceof HTMLInputElement && node.contains(typing) ? typing : null
    const scroll = node.querySelector<HTMLElement>('.pb-scroll')
    const kept = scroll ? { top: scroll.scrollTop, left: scroll.scrollLeft } : null
    const key = JSON.stringify(store.shelf)
    if (store.shelf.kind === 'plan' && calendarFor !== store.shelf.id) {
      calendarFor = store.shelf.id
      calendarStart = calendarHome(store.today)
    }
    const typedValue = typingIn?.value
    const typedClass = typingIn?.className
    sortNow = boardSortNow()
    clear(node)
    switch (store.shelf.kind) {
      case 'plan': drawPlan(store.shelf.id); break
      case 'week': drawWeek(); break
      default: drawShelf()
    }
    const after = node.querySelector<HTMLElement>('.pb-scroll')
    if (after && kept && key === shownKey) {
      after.scrollTop = kept.top
      after.scrollLeft = kept.left
    }
    shownKey = key
    // Another shelf or another set of columns starts at its first column.
    const slideKey = `${key}|${drawnColumns.map((one) => one.id).join(',')}`
    if (slideKey !== slideFor) {
      slideFor = slideKey
      slideX = 0
    }
    if (measured && measured !== after) resizes?.unobserve(measured)
    measured = after
    if (after) resizes?.observe(after)
    applyGeometry()
    fitActions()
    if (typingIn && typedClass) {
      const again = node.querySelector<HTMLInputElement>(`input.${typedClass.split(' ').join('.')}`)
      if (again) {
        again.value = typedValue ?? ''
        again.focus({ preventScroll: true })
      }
    }
  }

  // A narrower column fits fewer columns, and a plan's buttons lose their
  // words before they wrap: both follow the board's width as it changes.
  // Answered before the frame is painted, so a column that no longer fits is
  // never drawn for a frame first.
  // The columns themselves never change with the width — only where the
  // title ends and how far they can slide, which are variables on the board.
  const resizes = typeof ResizeObserver !== 'undefined'
    ? new ResizeObserver(() => {
      if (!node.isConnected || node.clientWidth === 0) return
      fitActions()
      applyGeometry()
    })
    : null
  resizes?.observe(node)

  // A sideways swipe over the header or the rows slides the columns, and so
  // does the wheel with Shift held; anything else scrolls the rows as ever.
  on(node, 'wheel', (event: WheelEvent) => {
    if (!geometry?.slides) return
    if (!(event.target as Element).closest('.pb-thead, .pb-row')) return
    const step = wheelSlide(event, geometry.viewport)
    if (step !== 0 && slideTo(slideX + step, false)) event.preventDefault()
  }, { passive: false })

  /** A plan's buttons with their words when they fit, the symbols alone when they do not. */
  function fitActions() {
    const row = node.querySelector<HTMLElement>('.pb-plan-row')
    const group = row?.querySelector<HTMLElement>('.pb-plan-actions')
    if (!row || !group) return
    group.classList.remove('compact')
    if (group.scrollWidth > row.clientWidth + 0.5) group.classList.add('compact')
  }

  // ---------------------------------------------------------------- parts

  function head(icon: IconName, title: string, sub: string, trailing: Node[] = [], tone = shelfTone(store.shelf)): HTMLElement {
    return shelfHeader({ icon, tone, title, subtitle: sub, trailing })
  }

  function viewSwitch(views: ['list' | 'table' | 'calendar', string, IconName | null][]): HTMLElement {
    const now = viewOf()
    const seg = el('span', { class: 'pb-seg', role: 'group', 'aria-label': L('보기', 'View') })
    for (const [view, label, icon] of views) {
      const button = el('button', { 'aria-pressed': String(now === view), 'data-act': 'view', 'data-v': view }, [...(icon ? [glyph(icon)] : []), label])
      seg.append(button)
    }
    return seg
  }

  function cap(label: string, act: string, icon?: IconName, id?: string, tip?: string): HTMLElement {
    return el('button', { class: 'pb-cap', 'data-act': act, ...(id ? { id } : {}), ...(tip ? { title: tip, 'aria-label': tip } : {}) },
      [...(icon ? [glyph(icon)] : []), el('span', { class: 'pb-cap-label', text: label })])
  }

  /**
   * The column titles, each a sort: once ascending, twice descending, a
   * third time the board's own order. They slide with their columns; the
   * title's stays pinned with the titles, and at the viewport's edges a
   * chevron says there is more and goes there.
   */
  function thead(columns: Column[]): HTMLElement {
    const row = el('div', { class: 'pb-thead' }, [el('span')])
    const button = (label: string, key: BoardSortKey): HTMLElement => {
      const current = sortNow?.key === key
      const arrow = current ? (sortNow!.ascending ? ' ↑' : ' ↓') : ''
      return el('button', {
        class: current ? 'pb-sort current' : 'pb-sort',
        'data-act': 'sort',
        'data-k': key,
        title: current
          ? L('한 번 더 누르면 반대로, 또 누르면 원래 순서로 돌아가요', 'Click again to reverse, once more for the original order')
          : L('누르면 이 열로 정렬해요', 'Click to sort by this column'),
      }, [label + arrow])
    }
    row.append(button(L('제목', 'Title'), 'title'))
    const labels = columns.map((one) => {
      const key = sortKeyOf(one.id)
      return key ? button(one.label(), key) : el('span', { class: 'pb-label', text: one.label() })
    })
    const more = L('다른 열 보기 — 트랙패드로 옆으로 밀어도 돼요', 'More columns — or swipe sideways on the trackpad')
    row.append(el('div', { class: 'pb-hcols' }, [
      columnsCell(columns, labels),
      el('button', { class: 'pb-slide left', 'data-act': 'slide', 'data-dir': '-1', title: more, 'aria-label': more }, [glyph('chevron.left')]),
      el('button', { class: 'pb-slide right', 'data-act': 'slide', 'data-dir': '1', title: more, 'aria-label': more }, [glyph('chevron.right')]),
    ]))
    row.dataset.menu = 'columns'
    return row
  }

  function row(entry: Paper, columns: Column[], options: { draggable?: boolean } = {}): HTMLElement {
    const status = statusOf(entry)
    const made = el('div', {
      class: `pb-row s-${status}${entry.id === store.selectedID ? ' on' : ''}`,
      'data-act': 'select',
      'data-id': entry.id,
      tabindex: '0',
      draggable: 'true',
      ...(options.draggable ? { 'data-drop-row': entry.id } : {}),
    })
    const ringButton = el('button', { class: 'pb-st', 'data-act': 'status', 'data-id': entry.id, 'aria-label': L('읽기 상태 바꾸기', 'Change Reading Status'), title: L('누르면 상태가 바뀌어요', 'Press to change the status'), html: ring(status, progressOf(entry).fraction) })
    const title = el('div', { class: 'pb-title', title: entry.meta.displayTitle, text: entry.meta.displayTitle })
    made.append(ringButton, title, columnsCell(columns, columns.map((one) => one.cell(entry))))
    return made
  }

  function groupHead(name: string, items: Paper[], extra: { section?: string | null; action?: HTMLElement } = {}): HTMLElement {
    const read = items.filter((entry) => statusOf(entry) === 'read').length
    const head = el('div', { class: 'pb-grp' }, [
      el('span', { text: name }),
      el('small', { text: L(`${read}/${items.length} 읽음`, `${read} of ${items.length} read`) }),
    ])
    if (extra.action) head.append(extra.action)
    if (extra.section !== undefined) head.dataset.dropSection = extra.section ?? ''
    return head
  }

  // ------------------------------------------------------------------ plan

  function drawPlan(id: string) {
    const found = planByID(id)
    if (!found) {
      node.append(el('div', { class: 'pb-empty', text: L('이 계획을 찾지 못했어요', "Paper Time can't find this plan") }))
      return
    }
    const papers = planPapers(id)
    const board = papers.map(boardPaper)
    const stats = planStats(board, store.today)
    const sub = `${spanText(papers.map((entry) => entry.schedule ?? '').filter(Boolean))} · ${L(`${papers.length}편 중 ${stats.read}편 읽음`, `${stats.read} of ${papers.length} read`)}`
    // The name with Table | Calendar at its end; the plan's own buttons on a
    // row of their own under it, so a column the width of a list still has
    // room for them (words when they fit, the symbols alone when not —
    // `fitActions`), the counts beside or under them, then the path.
    const pushable = papers.some((entry) => entry.state.readingStatus !== 'read' && entry.schedule)
    const buttons = el('div', { class: 'pb-plan-actions' }, [
      cap(L('논문 더하기…', 'Add Papers…'), 'add-papers', 'plus', 'pb-add-papers', L('논문 더하기', 'Add Papers')),
      ...(papers.length ? [cap(L('고르게 나누기…', 'Spread Out…'), 'spread', 'calendar', 'pb-spread', L('고르게 나누기', 'Spread Out'))] : []),
      // Only once there is a day to push.
      ...(pushable ? [cap(L('한 주 미루기', 'Push a Week'), 'push', 'arrow.right', 'pb-push', L('한 주 미루기', 'Push a Week'))] : []),
    ])
    const planRow = el('div', { class: 'pb-plan-row' }, [buttons])
    const header = el('div', { class: 'pb-head' }, [
      head('point.topleft.down.to.point.bottomright.curvepath', found.plan.name, papers.length ? sub : L('아직 논문이 없어요', 'No papers yet'), [
        viewSwitch([['table', L('표', 'Table'), 'tablecells'], ['calendar', L('달력', 'Calendar'), 'calendar']]),
      ], 'accent'),
      planRow,
    ])
    const guidance = planGuidance(board)
    if (guidance === 'empty') {
      node.append(header, emptyPlan(id))
      return
    }
    const chips = el('div', { class: 'pb-stats' }, [el('span', { class: 'pb-stat', 'data-tone': 'blue', text: L(`이번 주 ${stats.thisWeek}편`, `This week ${stats.thisWeek}`) })])
    if (stats.behind) chips.append(el('span', { class: 'pb-stat', 'data-tone': 'orange', text: L(`밀린 것 ${stats.behind}편`, `Overdue ${stats.behind}`) }))
    // The papers with no day are a place to go: the calendar, where they wait in «No Date».
    if (stats.undated) {
      chips.append(el('button', {
        class: 'pb-stat pb-stat-button', 'data-act': 'view', 'data-v': 'calendar',
        title: L('달력에서 날짜 정하기', 'Give them days on the calendar'),
        text: L(`날짜 없음 ${stats.undated}편`, `No date ${stats.undated}`),
      }))
    }
    planRow.append(chips)
    header.append(path(found.plan))
    node.append(header)
    if (viewOf() === 'calendar') {
      drawCalendar(id, papers)
      return
    }
    if (guidance === 'noDays' && !quietGuides.has(id)) node.append(noDaysStrip())
    drawPlanTable(id, papers)
  }

  /**
   * A plan with nothing in it says what goes in and how — and does it, right
   * there: the picker, an address, or a drag from the list.
   */
  function emptyPlan(id: string): HTMLElement {
    const field = el('input', {
      class: 'pb-add-input',
      type: 'text',
      placeholder: L('arXiv 주소나 DOI를 붙여넣어 논문을 더해요', 'Paste an arXiv link or a DOI to add a paper'),
      autocomplete: 'off',
      spellcheck: 'false',
    }) as HTMLInputElement
    on(field, 'keydown', (event: KeyboardEvent) => {
      if (event.key !== 'Enter' || !field.value.trim()) return
      event.preventDefault()
      const value = field.value
      field.disabled = true
      void addFromAddresses(id, value).then((added) => {
        field.disabled = false
        if (added) field.value = ''
      })
    })
    const choose = el('button', { class: 'pb-cap strong', 'data-act': 'add-papers' }, [glyph('plus'), L('논문 고르기…', 'Choose Papers…')])
    return el('div', { class: 'pb-scroll' }, [
      el('div', { class: 'pb-empty-plan', 'data-drop-plan': id }, [
        el('span', { class: 'pb-empty-icon' }, [glyph('tray.and.arrow.down')]),
        el('h3', { text: L('이 계획에 읽을 논문을 모아요', 'Gather the papers for this plan') }),
        el('p', { text: L('라이브러리에서 고르거나, arXiv 주소·DOI를 붙여넣거나, 목록에서 끌어와요.', 'Pick them from your library, paste an arXiv link or a DOI, or drag them in from the list.') }),
        choose,
        el('label', { class: 'pb-addrow pb-empty-add' }, [glyph('link'), field]),
      ]),
    ])
  }

  /** A plan of papers with no day at all asks when they will be read. */
  function noDaysStrip(): HTMLElement {
    const dismiss = el('button', { class: 'pb-icon pb-guide-x', 'data-act': 'guide-dismiss', 'aria-label': L('닫기', 'Close'), title: L('닫기', 'Close') }, [glyph('xmark')])
    return el('div', { class: 'pb-guide', role: 'note' }, [
      el('span', { class: 'pb-guide-icon' }, [glyph('calendar')]),
      el('div', { class: 'pb-guide-text' }, [
        el('strong', { text: L('언제 읽을지 정해 볼까요?', 'When will you read them?') }),
        el('span', { text: L('요일만 고르면 차례대로 날짜를 정해요.', 'Pick the weekdays and each paper gets a day, in order.') }),
      ]),
      cap(L('고르게 나누기…', 'Spread Out…'), 'spread', 'calendar'),
      cap(L('달력에서 정하기', 'Use the Calendar'), 'view-calendar'),
      dismiss,
    ])
  }

  function path(plan: NonNullable<ReturnType<typeof planByID>>['plan']): HTMLElement {
    const line = el('div', { class: 'pb-path' })
    for (const group of planGroups(plan)) {
      const entries = group.papers.map((one) => paper(one)).filter((entry): entry is Paper => entry !== null)
      if (entries.length === 0) continue
      const dots = el('div', { class: 'pb-dots' })
      for (const entry of entries) {
        dots.append(el('button', {
          class: `pb-dot${entry.id === store.selectedID ? ' on' : ''}`,
          'data-act': 'select',
          'data-id': entry.id,
          title: entry.meta.displayTitle,
          'aria-label': entry.meta.displayTitle,
          html: ring(statusOf(entry), progressOf(entry).fraction),
        }))
      }
      line.append(el('div', { class: 'pb-segment' }, [dots, el('small', { text: group.section?.name ?? '' })]))
    }
    return line
  }

  function drawPlanTable(id: string, papers: Paper[]) {
    const found = planByID(id)!
    const group = prefs().group
    const columns = columnsNow()
    const viewbar = el('div', { class: 'pb-viewbar' }, [el('span', { text: L('묶기', 'Group By') })])
    const chips = el('span', { class: 'pb-gchips', role: 'group', 'aria-label': L('묶기', 'Group By') })
    for (const [value, label] of [['section', L('섹션', 'Section')], ['week', L('주', 'Week')], ['status', L('상태', 'Status')]] as const) {
      chips.append(el('button', { 'data-act': 'group', 'data-v': value, 'aria-pressed': String(group === value), text: label }))
    }
    viewbar.append(chips)
    // A sorted plan says so where its order is chosen, with the way back to
    // the reading order: the arrow in a header is easy to miss, and the
    // plan's order is the plan (the Mac's chip beside «Group By»).
    const sorting = boardSortNow()
    if (sorting) {
      const name = sorting.key === 'title' ? L('제목', 'Title') : COLUMNS[sorting.key].label()
      const arrow = sorting.ascending ? '↑' : '↓'
      viewbar.append(el('button', {
        class: 'pb-unsort', 'data-act': 'unsort', title: L('계획 순서로 돌아가요', "Back to the plan's order"),
      }, [el('span', { text: L(`${name} 순 ${arrow}`, `By ${name} ${arrow}`) }), glyph('xmark')]))
    }
    viewbar.append(el('span', { class: 'pb-spacer' }), cap(L('섹션', 'Section'), 'add-section', 'plus', undefined, L('섹션 더하기', 'Add Section')))
    node.append(viewbar)
    const table = tableNode(columns, thead)
    const byID = new Map(papers.map((entry) => [entry.id, entry]))
    // Sorted, a plan is sorted within each group, and the rows stop being
    // dragged into another order — the order a drag would make is not the
    // one shown (the Mac's `reorders`).
    const sorted = sortNow !== null
    if (group === 'section') {
      for (const one of planGroups(found.plan)) {
        const items = sortedForTable(one.papers.map((paperID) => byID.get(paperID)).filter((entry): entry is Paper => Boolean(entry)))
        // The papers in no section stand without a heading when there are no sections at all.
        if (one.section || found.plan.sections.length > 0) {
          const head = groupHead(one.section?.name ?? L('섹션 없음', 'No Section'), items, { section: one.section?.id ?? null })
          if (one.section) head.dataset.sectionMenu = one.section.id
          table.append(head)
        }
        for (const entry of items) table.append(row(entry, columns, { draggable: !sorted }))
        if (items.length === 0 && one.section && !sorted) table.append(el('div', { class: 'pb-drop-hint', 'data-drop-section': one.section.id, text: L('여기로 끌어다 놓아요', 'Drag papers here') }))
      }
    } else {
      const groups = group === 'week' ? groupByWeek(papers.map(boardPaper), store.today) : groupByStatus(papers.map(boardPaper))
      for (const one of groups) {
        const items = sortedForTable(one.ids.map((paperID) => byID.get(paperID)!).filter(Boolean))
        table.append(groupHead(one.name, items))
        for (const entry of items) table.append(row(entry, columns))
      }
    }
    const field = el('input', {
      class: 'pb-add-input',
      type: 'text',
      placeholder: L('arXiv 주소나 DOI를 붙여넣어 논문을 더해요', 'Paste an arXiv link or a DOI to add a paper'),
      autocomplete: 'off',
      spellcheck: 'false',
    }) as HTMLInputElement
    on(field, 'keydown', (event: KeyboardEvent) => {
      if (event.key !== 'Enter' || !field.value.trim()) return
      event.preventDefault()
      const value = field.value
      field.disabled = true
      void addFromAddresses(id, value).then((added) => {
        field.disabled = false
        if (added) field.value = ''
      })
    })
    table.append(el('label', { class: 'pb-addrow', 'data-drop-plan': id }, [
      glyph('plus'), field, el('span', { class: 'pb-hint', text: L('목록에서 끌어와도 돼요', 'Or drag one in from the list') }),
    ]))
    node.append(el('div', { class: 'pb-scroll' }, [table]))
  }

  function drawCalendar(id: string, papers: Paper[]) {
    const bar = el('div', { class: 'pb-viewbar' }, [
      el('button', { class: 'pb-icon', 'data-act': 'cal-prev', 'aria-label': L('앞으로', 'Earlier'), title: L('4주 앞', 'Four Weeks Earlier') }, [glyph('chevron.left')]),
      el('button', { class: 'pb-cap', 'data-act': 'cal-home', text: L('오늘', 'Today') }),
      el('button', { class: 'pb-icon', 'data-act': 'cal-next', 'aria-label': L('뒤로', 'Later'), title: L('4주 뒤', 'Four Weeks Later') }, [glyph('chevron.right')]),
      el('span', { class: 'pb-range', text: `${longDay(calendarStart)} – ${longDay(addDays(calendarStart, 34))}` }),
    ])
    node.append(bar)
    const grid = el('div', { class: 'pb-cal' })
    for (let i = 0; i < 7; i += 1) grid.append(el('div', { class: 'pb-dh', text: weekdayShort(i) }))
    const thisWeek = mondayOf(store.today)
    const mine = new Set(papers.map((entry) => entry.id))
    calendarDays(calendarStart).forEach((day, at) => {
      const classes = ['pb-day']
      if (day < store.today) classes.push('past')
      if (day === store.today) classes.push('today')
      if (mondayOf(day) === thisWeek) classes.push('week')
      const cell = el('div', { class: classes.join(' '), 'data-drop-day': day }, [el('span', { class: 'pb-num', text: calendarLabel(day, at === 0) })])
      for (const entry of papers.filter((one) => one.schedule === day)) cell.append(pill(entry))
      // Other plans' papers that day, faint, so a crowded day shows before it is crowded.
      for (const other of store.papers) {
        if (other.schedule !== day || mine.has(other.id)) continue
        const plans = plansOf(other.id)
        if (plans.length === 0) continue
        cell.append(el('div', { class: 'pb-pill ghost', title: `${plans[0].plan.name} · ${other.meta.displayTitle}` }, [el('span', { text: other.meta.displayTitle })]))
      }
      grid.append(cell)
    })
    const undated = papers.filter((entry) => !entry.schedule)
    const tray = el('div', { class: 'pb-tray', 'data-drop-day': '' }, [
      el('h4', { text: L(`날짜 없음 · ${undated.length}`, `No Date · ${undated.length}`) }),
      el('p', { text: L('달력으로 끌면 그날로 정해요. 여기로 끌면 날짜를 지워요.', 'Drag to the calendar to give it a day. Drag here to clear the day.') }),
      ...undated.map(pill),
    ])
    node.append(el('div', { class: 'pb-scroll pb-cal-wrap' }, [el('div', { class: 'pb-cal-scroll' }, [grid]), tray]))
  }

  function pill(entry: Paper): HTMLElement {
    const status = statusOf(entry)
    const late = isBehind(entry.schedule, status, store.today)
    return el('div', {
      class: `pb-pill s-${status}${late ? ' late' : ''}${entry.id === store.selectedID ? ' on' : ''}`,
      draggable: 'true',
      'data-act': 'select',
      'data-pill': entry.id,
      'data-id': entry.id,
      tabindex: '0',
      title: entry.meta.displayTitle,
    }, [el('span', { html: ring(status, progressOf(entry).fraction, 13) }, [document.createTextNode(entry.meta.displayTitle)])])
  }

  // ------------------------------------------------------------------ week

  function drawWeek() {
    const papers = store.papers.filter((entry) => !entry.meta.parentID && entry.schedule)
    const shelf = weekShelf(papers.map(boardPaper), store.today)
    const monday = mondayOf(store.today)
    const all = [...shelf.behind, ...shelf.days.flatMap((day) => day.ids)]
    const planCount = new Set(all.flatMap((one) => plansOf(one).map((found) => found.plan.id))).size
    const sub = `${longDay(monday)} – ${longDay(addDays(monday, 6))} · ${L(`계획 ${planCount}개에서 ${all.length}편`, `${all.length} paper${all.length === 1 ? '' : 's'} from ${planCount} plan${planCount === 1 ? '' : 's'}`)}`
    const trailing = LEGACY.paperList ? [viewSwitch([['list', L('목록', 'List'), null], ['table', L('표', 'Table'), 'tablecells']])] : []
    node.append(el('div', { class: 'pb-head' }, [head('calendar', L('이번 주', 'This Week'), sub, trailing, 'accent')]))
    const columns = columnsNow()
    const table = tableNode(columns, thead)
    const byID = new Map(papers.map((entry) => [entry.id, entry]))
    // Sorted within what is behind and within each day.
    if (shelf.behind.length) {
      const items = sortedForTable(shelf.behind.map((one) => byID.get(one)!))
      const head = el('div', { class: 'pb-grp', id: 'pb-behind' }, [
        el('span', { text: L('밀린 것', 'Overdue') }),
        el('small', { text: L(`${items.length}편`, `${items.length}`) }),
        cap(L('오늘로 옮기기', 'Move to Today'), 'pull'),
      ])
      table.append(head, ...items.map((entry) => row(entry, columns)))
    }
    for (const day of shelf.days) {
      table.append(el('div', { class: 'pb-grp' }, [el('span', { text: dayHeading(day.day, store.today) })]))
      for (const entry of sortedForTable(day.ids.map((one) => byID.get(one)!))) table.append(row(entry, columns))
    }
    if (all.length === 0) table.append(el('div', { class: 'pb-empty', text: L('이번 주에 읽을 논문이 없어요', 'Nothing to read this week.') }))
    node.append(el('div', { class: 'pb-scroll' }, [table]))
  }

  // ---------------------------------------------------------- other shelves

  function drawShelf() {
    const papers = sortedForTable(shelfPapers())
    const sub = `${papersText(papers.length)} · ${L('열 머리를 누르면 정렬돼요', 'Click a column to sort')}`
    // «읽을 날·계획»: on a shelf that is not a plan the two columns are «Set
    // Date» and «—» down the page, so they wait until asked for.
    const on = prefs().planColumns
    const planColumns = el('button', {
      class: `pb-chip-toggle${on ? ' on' : ''}`,
      'data-act': 'plan-columns',
      'aria-pressed': String(on),
      title: L('읽을 날과 계획 열을 보이거나 숨겨요', 'Show or hide the Read On and Plan columns'),
    }, [glyph('calendar'), el('span', { text: L('읽을 날·계획', 'Read On · Plan') })])
    const trailing: Node[] = [planColumns]
    if (LEGACY.paperList) trailing.push(viewSwitch([['list', L('목록', 'List'), null], ['table', L('표', 'Table'), 'tablecells']]))
    node.append(el('div', { class: 'pb-head' }, [head(shelfSymbol(store.shelf), shelfTitle(), sub, trailing)]))
    // What the old list said about the folder, said over the table.
    const notices = folderNoticeRows(actions)
    if (notices.length) node.append(el('div', { class: 'pb-notices' }, notices))
    if (papers.length === 0) {
      // Each shelf is empty for its own reason, and says it (the old list's words).
      const empty = emptyShelf()
      node.append(el('div', { class: 'empty pb-empty-shelf' }, [
        el('span', { class: 'empty-icon' }, [glyph(empty.icon)]),
        el('h2', { text: empty.title }),
        el('p', { text: empty.note }),
      ]))
      return
    }
    const columns = columnsNow()
    const table = tableNode(columns, thead)
    for (const entry of papers) table.append(row(entry, columns))
    node.append(el('div', { class: 'pb-scroll' }, [table]))
  }

  // ---------------------------------------------------------------- input

  const idOf = (target: Element | null) => target?.closest<HTMLElement>('[data-id]')?.dataset.id ?? null

  on(node, 'click', (event: MouseEvent) => {
    const target = (event.target as Element).closest<HTMLElement>('[data-act]')
    if (!target || !node.contains(target)) return
    const id = target.dataset.id ?? idOf(target)
    const shelf = store.shelf
    switch (target.dataset.act) {
      case 'select':
        if (id) selectInBoard(id)
        break
      case 'status':
        event.stopPropagation()
        if (id) {
          selectInBoard(id)
          cycleStatus(id)
        }
        break
      case 'date':
        event.stopPropagation()
        if (id) {
          selectInBoard(id)
          openDatePop(target, id)
        }
        break
      case 'view':
        closePlanPop()
        setView(target.dataset.v as 'list' | 'table' | 'calendar')
        break
      case 'group':
        savePrefs((prefs) => { prefs.group = target.dataset.v as 'section' | 'week' | 'status' })
        update()
        break
      case 'plan-columns':
        togglePlanColumns()
        update()
        break
      case 'sort': {
        setBoardSort(nextSort(boardSortNow(), target.dataset.k as BoardSortKey))
        update()
        break
      }
      case 'slide':
        if (geometry) slideTo(slideStep(slideX, geometry, target.dataset.dir === '-1' ? -1 : 1), true)
        break
      case 'unsort':
        setBoardSort(null)
        update()
        break
      case 'spread':
        if (shelf.kind === 'plan') openSpreadPop(target, shelf.id)
        break
      case 'add-papers':
        if (shelf.kind === 'plan') addPapersTo(shelf.id)
        break
      case 'view-calendar':
        closePlanPop()
        setView('calendar')
        break
      case 'guide-dismiss':
        if (shelf.kind === 'plan') {
          quietGuides.add(shelf.id)
          update()
        }
        break
      case 'push':
        if (shelf.kind === 'plan') void pushWeek(shelf.id)
        break
      case 'pull':
        void pullBehind()
        break
      case 'add-section':
        if (shelf.kind === 'plan') void addSectionTo(shelf.id)
        break
      case 'cal-prev':
        calendarStart = addDays(calendarStart, -28)
        update()
        break
      case 'cal-next':
        calendarStart = addDays(calendarStart, 28)
        update()
        break
      case 'cal-home':
        calendarStart = calendarHome(store.today)
        update()
        break
    }
  })

  on(node, 'dblclick', (event: MouseEvent) => {
    const target = (event.target as Element)
    if (target.closest('button, input')) return
    const id = idOf(target.closest('.pb-row, .pb-pill'))
    if (id) void openFromBoard(id)
  })

  on(node, 'keydown', (event: KeyboardEvent) => {
    const target = event.target as HTMLElement
    if (target.tagName === 'INPUT') return
    const id = target.dataset?.id
    if (!id || !(target.classList.contains('pb-row') || target.classList.contains('pb-pill'))) return
    if (event.key === 'Enter') {
      event.preventDefault()
      void openFromBoard(id)
      return
    }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault()
      const rows = [...node.querySelectorAll<HTMLElement>('.pb-row')]
      const at = rows.indexOf(target)
      const next = rows[at + (event.key === 'ArrowDown' ? 1 : -1)]
      if (next?.dataset.id) {
        selectInBoard(next.dataset.id)
        requestAnimationFrame(() => node.querySelector<HTMLElement>(`.pb-row[data-id="${next.dataset.id}"]`)?.focus())
      }
    }
  })

  on(node, 'contextmenu', (event: MouseEvent) => {
    const target = event.target as Element
    const point = { x: event.clientX, y: event.clientY }
    if (target.closest('.pb-thead')) {
      event.preventDefault()
      showMenuAt(point, columnMenu())
      return
    }
    const section = target.closest<HTMLElement>('[data-section-menu]')
    if (section && store.shelf.kind === 'plan') {
      event.preventDefault()
      showMenuAt(point, sectionMenu(store.shelf.id, section.dataset.sectionMenu!))
      return
    }
    const id = idOf(target.closest('.pb-row, .pb-pill'))
    if (id) {
      event.preventDefault()
      selectInBoard(id)
      showMenuAt(point, rowMenu(id))
    }
  })

  // ----------------------------------------------------------------- drags

  const clearOver = () => node.querySelectorAll('.over').forEach((one) => one.classList.remove('over'))

  on(node, 'dragstart', (event: DragEvent) => {
    const target = event.target as HTMLElement
    const pillID = target.closest<HTMLElement>('[data-pill]')?.dataset.pill
    const rowID = target.closest<HTMLElement>('.pb-row')?.dataset.id
    if (!event.dataTransfer || (!pillID && !rowID)) return
    const id = (pillID ?? rowID)!
    dragging = [id]
    event.dataTransfer.effectAllowed = 'move'
    if (pillID) event.dataTransfer.setData(PILL_TYPE, id)
    else {
      event.dataTransfer.setData(ROWS_TYPE, id)
      // And as papers, so a row can go onto a plan or a collection in the sidebar.
      writeDraggedPapers(event.dataTransfer, [id])
      event.dataTransfer.effectAllowed = 'copyMove'
    }
    requestAnimationFrame(() => target.classList.add('dragging'))
  })

  on(node, 'dragend', () => {
    dragging = []
    clearOver()
    node.querySelectorAll('.dragging').forEach((one) => one.classList.remove('dragging'))
  })

  /** Where a drag over the board would land, or null. */
  function landing(event: DragEvent): { kind: 'day'; day: string | null; node: HTMLElement } | { kind: 'row'; target: string; node: HTMLElement } | { kind: 'section'; section: string | null; node: HTMLElement } | { kind: 'plan'; node: HTMLElement } | null {
    const target = event.target as Element
    const types = event.dataTransfer?.types ?? []
    if (types.includes(PILL_TYPE)) {
      const cell = target.closest<HTMLElement>('[data-drop-day]')
      return cell ? { kind: 'day', day: cell.dataset.dropDay || null, node: cell } : null
    }
    if (store.shelf.kind !== 'plan') return null
    // A sorted plan takes no drops: a row put «before» another lands in an
    // order that is not the one shown.
    if (boardSortNow() !== null) return null
    if (types.includes(ROWS_TYPE) && prefs().group === 'section') {
      const rowNode = target.closest<HTMLElement>('[data-drop-row]')
      if (rowNode) return { kind: 'row', target: rowNode.dataset.dropRow!, node: rowNode }
      const head = target.closest<HTMLElement>('[data-drop-section]')
      if (head) return { kind: 'section', section: head.dataset.dropSection || null, node: head }
      return null
    }
    if (!types.includes(ROWS_TYPE) && carriesPapers(event.dataTransfer)) {
      const spot = target.closest<HTMLElement>('.pb-table, .pb-addrow, .pb-empty-plan')
      return spot ? { kind: 'plan', node: spot as HTMLElement } : null
    }
    return null
  }

  on(node, 'dragover', (event: DragEvent) => {
    const spot = landing(event)
    if (!spot || !event.dataTransfer) return
    event.preventDefault()
    event.dataTransfer.dropEffect = spot.kind === 'plan' ? 'copy' : 'move'
    if (!spot.node.classList.contains('over')) {
      clearOver()
      spot.node.classList.add('over')
    }
  })

  on(node, 'dragleave', (event: DragEvent) => {
    if (!node.contains(event.relatedTarget as Node)) clearOver()
  })

  on(node, 'drop', (event: DragEvent) => {
    const spot = landing(event)
    clearOver()
    if (!spot || !event.dataTransfer) return
    event.preventDefault()
    event.stopPropagation()
    const shelf = store.shelf
    if (spot.kind === 'day') {
      const id = event.dataTransfer.getData(PILL_TYPE) || dragging[0]
      if (id && (paper(id)?.schedule ?? null) !== spot.day) void setDay(id, spot.day, 'moved')
      return
    }
    if (shelf.kind !== 'plan') return
    if (spot.kind === 'row') {
      const id = event.dataTransfer.getData(ROWS_TYPE) || dragging[0]
      if (id && id !== spot.target) void editPlan(shelf.id, { op: 'moveBefore', papers: [id], target: spot.target }, L('차례 바꾸기', 'Reorder'))
      return
    }
    if (spot.kind === 'section') {
      const id = event.dataTransfer.getData(ROWS_TYPE) || dragging[0]
      if (id) void editPlan(shelf.id, { op: 'moveToEnd', papers: [id], section: spot.section }, L('차례 바꾸기', 'Reorder'))
      return
    }
    const ids = draggedPapers(event.dataTransfer)
    if (ids.length) void addToPlan(shelf.id, ids)
  })

  // ----------------------------------------------------------------- menus

  function columnMenu(): MenuEntry[] {
    const context = boardContext()
    const shown = prefs().columns[context]
    return ALL_COLUMNS.map((id) => ({
      label: COLUMNS[id].label(),
      checked: shown.includes(id),
      action: () => {
        savePrefs((prefs) => {
          const list = prefs.columns[context]
          prefs.columns[context] = list.includes(id) ? list.filter((one) => one !== id) : ALL_COLUMNS.filter((one) => one === id || list.includes(one))
        })
        update()
      },
    }))
  }

  function sectionMenu(planID: string, sectionID: string): MenuEntry[] {
    const found = planByID(planID)
    const section = found?.plan.sections.find((one) => one.id === sectionID)
    if (!found || !section) return []
    return [
      { label: L('이름 바꾸기…', 'Rename…'), icon: 'square.and.pencil', action: () => void renameSectionOf(planID, section) },
      { label: L('위로', 'Move Up'), icon: 'chevron.up', action: () => void editPlan(planID, { op: 'moveSection', id: sectionID, by: -1 }, L('섹션 옮기기', 'Move Section')) },
      { label: L('아래로', 'Move Down'), icon: 'chevron.down', action: () => void editPlan(planID, { op: 'moveSection', id: sectionID, by: 1 }, L('섹션 옮기기', 'Move Section')) },
      { separator: true },
      { label: L('섹션 지우기', 'Delete Section'), icon: 'trash', danger: true, action: () => void editPlan(planID, { op: 'removeSection', id: sectionID }, L('섹션 지우기', 'Delete Section'), L('섹션을 지웠어요. 논문은 계획에 남아요.', 'Deleted the section. Its papers stay in the plan.')) },
    ]
  }

  /**
   * Everything the list's rows offered — open beside, keep open, reading
   * status, tags, a plan, the star, attach, the key, the folder, the Trash —
   * then what a board adds: the day, the section, out of the plan.
   */
  function rowMenu(id: string): MenuEntry[] {
    const entries: MenuEntry[] = [
      ...paperMenuEntries(id, { open: () => void openFromBoard(id) }),
      { separator: true },
      { label: L('읽을 날…', 'Read On…'), icon: 'calendar', action: () => {
        const anchor = node.querySelector(`[data-act="date"][data-id="${id}"]`) ?? node.querySelector(`[data-id="${id}"]`)
        if (anchor) openDatePop(anchor, id)
      } },
    ]
    if (paper(id)?.schedule) {
      entries.push({ label: L('날짜 지우기', 'Clear Date'), icon: 'xmark.circle', action: () => void setDays([{ id, date: null }], L('날짜를 지웠어요.', 'Cleared the date.'), L('읽을 날', 'Read Date')) })
    }
    const shelf = store.shelf
    if (shelf.kind === 'plan') {
      const found = planByID(shelf.id)
      if (found && found.plan.sections.length > 0) {
        entries.push({
          label: L('섹션', 'Section'),
          icon: 'list.bullet',
          children: [
            { label: L('섹션 없음', 'No Section'), action: () => void editPlan(shelf.id, { op: 'moveToEnd', papers: [id], section: null }, L('섹션 바꾸기', 'Change Section')) },
            ...found.plan.sections.map((section) => ({
              label: section.name,
              checked: found.plan.entries.find((entry) => entry.paper === id)?.section === section.id,
              action: () => void editPlan(shelf.id, { op: 'moveToEnd', papers: [id], section: section.id }, L('섹션 바꾸기', 'Change Section')),
            })),
          ],
        })
      }
      entries.push({ separator: true }, { label: L('계획에서 빼기', 'Remove from Plan'), icon: 'xmark.circle', danger: true, action: () => void removeFromPlan(shelf.id, [id]) })
    }
    return entries
  }

  function mark() {
    for (const one of node.querySelectorAll<HTMLElement>('.pb-row, .pb-pill:not(.ghost), .pb-dot')) {
      one.classList.toggle('on', one.dataset.id === store.selectedID)
    }
  }

  return { node, update, mark }
}

function weekdayShort(weekday: number): string {
  return (prefersKorean() ? ['월', '화', '수', '목', '금', '토', '일'] : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'])[weekday]
}

/** What a paper's date chip says, for a probe. */
export function dateChipText(id: string): string | null {
  const entry = paper(id)
  return entry ? dateLabel(entry.schedule, statusOf(entry), store.today).text : null
}
