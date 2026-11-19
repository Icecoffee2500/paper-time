/**
 * What the reading plan's board says and in what order (`shared/planBoard.ts`),
 * and the plan edits the window sends (`shared/planEdit.ts`).
 */
import assert from 'node:assert/strict'
import { setKorean } from '../shared/lang.js'
import {
  ALL_COLUMNS, BOARD_ROW_CHROME, DEFAULT_COLUMNS, TITLE_KEEP, authorsText, boardGeometry, boardPlace, clampSlide, slideStep, wheelSlide, calendarDays, calendarHome, calendarLabel, dateLabel, dayHeading, detectionLine,
  groupByStatus, groupByWeek, holdsAddress, isBehind, nextStatus, pickerFold, pickerOrder, pickerShown, planGuidance, planStats,
  progress, readAddRow, readColumns, spanText, spreadOrder, spreadPreview, spreadStart, viewFor, weekCount, weekName, weekShelf,
  withPlanColumns, withRo, type BoardPaper, type ColumnID,
  compareText, nextSort, sortKeyOf, sortRows, type BoardSortKey,
} from '../shared/planBoard.js'
import { acceptedEdit, applyPlanEdit } from '../shared/planEdit.js'
import { newPlan, planOrder } from '../shared/readingPlan.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const TODAY = '2026-11-16' // a Monday
const p = (id: string, date: string | null, status: BoardPaper['status'] = 'unread'): BoardPaper => ({ id, date, status })

export async function planBoardSuite(test: Test, suite: (name: string) => void) {
  suite('The reading plan’s board')

  await test('a date chip says today, tomorrow, the weekday — and behind, not overdue', () => {
    setKorean(true)
    try {
      assert.deepEqual(dateLabel(null, 'unread', TODAY), { text: '정하기', tone: 'none' })
      assert.deepEqual(dateLabel('2026-11-16', 'unread', TODAY), { text: '오늘', tone: 'today' })
      assert.deepEqual(dateLabel('2026-11-17', 'unread', TODAY), { text: '내일', tone: 'plain' })
      assert.deepEqual(dateLabel('2026-11-20', 'unread', TODAY), { text: '금 11.20', tone: 'plain' })
      assert.deepEqual(dateLabel('2026-11-12', 'unread', TODAY), { text: '11.12 · 밀림', tone: 'behind' })
      // A paper read on a day that has gone is not behind.
      assert.deepEqual(dateLabel('2026-11-12', 'read', TODAY), { text: '목 11.12', tone: 'plain' })
    } finally {
      setKorean(false)
    }
    assert.equal(dateLabel('2026-11-12', 'reading', TODAY).text, 'Nov 12 · Overdue')
    assert.equal(dateLabel('2026-11-20', 'unread', TODAY).text, 'Fri Nov 20')
  })

  await test('weeks and days are named as the demo names them', () => {
    setKorean(true)
    try {
      assert.equal(weekName('2026-11-16', TODAY), '이번 주 · 11.16–11.22')
      assert.equal(weekName('2026-11-23', TODAY), '다음 주 · 11.23–11.29')
      assert.equal(weekName('2026-11-09', TODAY), '지난주 · 11.9–11.15')
      assert.equal(weekName('2026-11-30', TODAY), '11.30–12.6')
      assert.equal(dayHeading('2026-11-16', TODAY), '오늘 · 11월 16일 월요일')
      assert.equal(dayHeading('2026-11-17', TODAY), '내일 · 11월 17일 화요일')
      assert.equal(dayHeading('2026-11-18', TODAY), '수요일 · 11월 18일')
      assert.equal(spanText(['2026-11-27', '2026-11-09', '']), '11월 9일 – 11월 27일')
      assert.equal(spanText([]), '날짜를 아직 안 정했어요')
    } finally {
      setKorean(false)
    }
    assert.equal(dayHeading('2026-11-18', TODAY), 'Wednesday · Nov 18')
    // The English the shared demo and the Mac use.
    assert.equal(weekName('2026-11-16', TODAY), 'This week · Nov 16–Nov 22')
    assert.equal(spanText([]), 'No dates yet')
    assert.equal(dayHeading('2026-11-16', TODAY), 'Today · Monday, Nov 16')
  })

  await test('grouped by week: weeks in order, the undated last, days in order inside', () => {
    const groups = groupByWeek([p('a', '2026-11-25'), p('b', null), p('c', '2026-11-18'), p('d', '2026-11-16'), p('e', '2026-11-12')], TODAY)
    assert.deepEqual(groups.map((group) => group.key), ['2026-11-09', '2026-11-16', '2026-11-23', 'none'])
    assert.deepEqual(groups[1].ids, ['d', 'c'])
    assert.deepEqual(groupByStatus([p('a', null, 'read'), p('b', null), p('c', null, 'reading')]).map((group) => group.ids), [['c'], ['b'], ['a']])
  })

  await test('«This Week»: behind first, oldest first; then each day with anything, read ones too', () => {
    const papers = [
      p('late2', '2026-11-13'), p('late1', '2026-11-12', 'reading'), p('done', '2026-11-12', 'read'),
      p('mon', '2026-11-16'), p('wed', '2026-11-18'), p('wedRead', '2026-11-18', 'read'), p('next', '2026-11-23'), p('none', null),
    ]
    const shelf = weekShelf(papers, TODAY)
    assert.deepEqual(shelf.behind, ['late1', 'late2'])
    assert.deepEqual(shelf.days, [{ day: '2026-11-16', ids: ['mon'] }, { day: '2026-11-18', ids: ['wed', 'wedRead'] }])
    // Still to read this week, and what is behind.
    assert.equal(weekCount(papers, TODAY), 4)
    // Midweek: Monday's unread paper is behind now, and leaves its day.
    const wednesday = weekShelf(papers, '2026-11-18')
    assert.deepEqual(wednesday.behind, ['late1', 'late2', 'mon'])
    assert.deepEqual(wednesday.days.map((day) => day.day), ['2026-11-18'])
  })

  await test('a plan’s numbers, its spread order, and the rings', () => {
    const papers = [p('a', '2026-11-12'), p('b', '2026-11-18', 'reading'), p('c', null, 'read'), p('d', null), p('e', '2026-11-20')]
    assert.deepEqual(planStats(papers, TODAY), { thisWeek: 2, behind: 1, undated: 2, read: 1 })
    assert.deepEqual(spreadOrder(papers), ['b', 'a', 'd', 'e'])
    assert.equal(isBehind('2026-11-15', 'unread', TODAY), true)
    assert.equal(isBehind('2026-11-16', 'unread', TODAY), false)
    assert.equal(nextStatus('unread'), 'reading')
    assert.equal(nextStatus('reading'), 'read')
    assert.equal(nextStatus('read'), 'unread')
    assert.equal(spreadStart('today', TODAY), TODAY)
    assert.equal(spreadStart('next', '2026-11-19'), '2026-11-23')
  })

  await test('progress: pages for unread and read, page of pages while reading', () => {
    assert.deepEqual(progress(17, 8, 'reading'), { fraction: 9 / 17, text: '9/17', done: false })
    assert.deepEqual(progress(31, 0, 'read'), { fraction: 1, text: '31 pp.', done: true })
    assert.deepEqual(progress(14, 3, 'unread'), { fraction: 0, text: '14 pp.', done: false })
    assert.deepEqual(progress(0, 0, 'unread'), { fraction: 0, text: '—', done: false })
    assert.equal(progress(10, 99, 'reading').text, '10/10')
  })

  await test('the add row reads arXiv addresses and DOIs, several at once, and says what it could not', () => {
    const read = readAddRow('arxiv.org/abs/2106.06926\nhttps://arxiv.org/abs/2106.06926v2, 10.1038/nature14236  hello https://example.org')
    assert.deepEqual(read.addresses, [{ kind: 'arxiv', id: '2106.06926' }, { kind: 'doi', doi: '10.1038/nature14236' }])
    assert.deepEqual(read.unread, ['hello', 'https://example.org'])
    assert.equal(holdsAddress({ arxiv: '2106.06926v1' }, { kind: 'arxiv', id: '2106.06926' }), true)
    assert.equal(holdsAddress({ doi: '10.1038/NATURE14236' }, { kind: 'doi', doi: '10.1038/nature14236' }), true)
    assert.equal(holdsAddress({}, { kind: 'arxiv', id: '2106.06926' }), false)
  })

  await test('the calendar opens on last week and names a month where it turns', () => {
    assert.equal(calendarHome(TODAY), '2026-11-09')
    const days = calendarDays('2026-11-09')
    assert.equal(days.length, 35)
    assert.equal(days[34], '2026-12-13')
    setKorean(true)
    try {
      assert.equal(calendarLabel('2026-11-09', true), '11월 9일')
      assert.equal(calendarLabel('2026-11-10', false), '10')
      assert.equal(calendarLabel('2026-12-01', false), '12월 1일')
      assert.equal(withRo('코드'), '코드로')
      assert.equal(withRo('노트북'), '노트북으로')
      assert.equal(withRo('글'), '글로')
      assert.equal(withRo('영상'), '영상으로')
      assert.equal(detectionLine('code'), '코드로 알아챘어요 · Enter로 붙여요')
      assert.equal(spreadPreview(['2026-11-16', '2026-11-27'], 3), '2편 · 11월 16일 – 11월 27일')
      assert.equal(spreadPreview([], 0), '요일을 하나 이상 골라주세요.')
    } finally {
      setKorean(false)
    }
  })

  await test('a plan edit from the window is checked, then made', () => {
    assert.equal(acceptedEdit({ op: 'rename', name: '   ' }), null)
    assert.equal(acceptedEdit({ op: 'drop tables' }), null)
    assert.equal(acceptedEdit({ op: 'add', papers: [1, 2] }), null)
    assert.deepEqual(acceptedEdit({ op: 'moveSection', id: 'S', by: 1.7 }), { op: 'moveSection', id: 'S', by: 1 })
    const plan = newPlan('Offline RL', new Date('2026-11-16T00:00:00Z'))
    for (const edit of [
      { op: 'add', papers: ['A', 'B', 'C'] },
      { op: 'addSection', name: '바탕', id: 'S1' },
      { op: 'moveToEnd', papers: ['B'], section: 'S1' },
      { op: 'moveBefore', papers: ['C'], target: 'A' },
    ]) applyPlanEdit(plan, acceptedEdit(edit)!)
    assert.deepEqual(planOrder(plan), ['C', 'A', 'B'])
    const before = { op: 'restore', name: plan.name, sections: plan.sections, entries: plan.entries }
    applyPlanEdit(plan, acceptedEdit({ op: 'remove', papers: ['A'] })!)
    assert.deepEqual(planOrder(plan), ['C', 'B'])
    applyPlanEdit(plan, acceptedEdit(JSON.parse(JSON.stringify(before)))!)
    assert.deepEqual(planOrder(plan), ['C', 'A', 'B'])
  })

  await test('a plan says what it needs next: papers, then days, then nothing', () => {
    assert.equal(planGuidance([]), 'empty')
    assert.equal(planGuidance([p('A', null), p('B', null, 'read')]), 'noDays')
    assert.equal(planGuidance([p('A', null), p('B', '2026-11-20')]), null)
    assert.equal(planGuidance([p('A', '2026-11-20')]), null)
  })

  await test('authors and year are columns of their own, and the venue is one too', () => {
    assert.deepEqual(DEFAULT_COLUMNS.plan, ['authors', 'year', 'venue', 'date', 'progress', 'materials'])
    assert.deepEqual(DEFAULT_COLUMNS.other, ['authors', 'year', 'venue', 'date', 'plan', 'materials'])
    assert.deepEqual(DEFAULT_COLUMNS.week, ['plan', 'date', 'materials'])
    // A list remembered before the split: «저자 · 해» is the two columns now.
    assert.deepEqual(readColumns(['who', 'date', 'plan', 'materials']), ['authors', 'year', 'date', 'plan', 'materials'])
    assert.deepEqual(readColumns(['venue', 'who', 'year', 'hologram']), ['venue', 'authors', 'year'])
    assert.equal(readColumns('who'), null)
    for (const list of Object.values(DEFAULT_COLUMNS)) for (const id of list) assert.ok(ALL_COLUMNS.includes(id), id)
    setKorean(true)
    try {
      assert.equal(authorsText([{ family: 'Kumar' }, { family: 'Zhou' }]), 'Kumar 외')
      assert.equal(authorsText([{ family: 'Kumar' }]), 'Kumar')
    } finally {
      setKorean(false)
    }
    assert.equal(authorsText([{ literal: 'DeepMind' }, { family: 'Mnih' }]), 'DeepMind et al.')
    assert.equal(authorsText([]), '')
    assert.equal(authorsText(undefined), '')
  })

  await test('the paper picker keeps its order while boxes are ticked, and finds by title or author', () => {
    const papers = [
      { id: 'cql', title: 'Conservative Q-Learning', search: 'Conservative Q-Learning Aviral Kumar' },
      { id: 'bcq', title: 'Off-Policy Deep RL without Exploration', search: 'Off-Policy Deep RL without Exploration Scott Fujimoto' },
      { id: 'iql', title: 'Implicit Q-Learning', search: 'Implicit Q-Learning Ilya Kostrikov' },
      { id: 'dt', title: 'Decision Transformer', search: 'Decision Transformer Lili Chen' },
      { id: 'mopo', title: 'MOPO', search: 'MOPO Tianhe Yu' },
    ]
    // Chosen first, in the order given; then the rest by title; a plan's own papers last.
    assert.deepEqual(pickerOrder(papers, ['iql', 'cql', 'iql', 'gone']), ['iql', 'cql', 'dt', 'mopo', 'bcq'])
    assert.deepEqual(pickerOrder(papers, [], ['cql']), ['dt', 'iql', 'mopo', 'bcq', 'cql'])
    const order = pickerOrder(papers, ['iql'])
    // Words in any order, accents and case ignored, authors read as well as titles.
    assert.deepEqual(pickerShown(order, papers, 'q-learning', false, []), ['iql', 'cql'])
    assert.deepEqual(pickerShown(order, papers, 'KUMAR conservative', false, []), ['cql'])
    assert.deepEqual(pickerShown(order, papers, '  ', false, []), order)
    assert.deepEqual(pickerShown(order, papers, '', true, ['mopo', 'iql']), ['iql', 'mopo'])
    assert.deepEqual(pickerShown(order, papers, 'fujimoto', true, ['mopo']), [])
    assert.equal(pickerFold('  Almudévar   ÉCOLE '), 'almudevar ecole')
  })

  await test('every column stands at its width; past the title’s room they slide behind a pinned title', () => {
    // The Mac's widths: authors 116, year 44, venue 92, date 100, progress 88, materials 34.
    const plan = [116, 44, 92, 100, 88, 34]
    const content = 116 + 44 + 92 + 100 + 88 + 34 + 10 * 5
    assert.equal(content, 524)
    assert.equal(BOARD_ROW_CHROME, 82)
    assert.equal(TITLE_KEEP, 150)
    // Wide: the title takes what the columns leave, nothing slides.
    assert.deepEqual(boardGeometry(1000, plan), { slides: false, title: 1000 - 82 - 524, content, viewport: content, limit: 0 })
    // Exactly a title's room left still stands still.
    assert.equal(boardGeometry(82 + 524 + 150, plan).slides, false)
    // One point less and the title is pinned: 45% of the room, 150 to 220.
    const tight = boardGeometry(82 + 524 + 149, plan)
    assert.equal(tight.slides, true)
    assert.equal(tight.title, 220)
    // The table beside an open inspector (490): 408 of room, a title of
    // 183.6 and the rest of the columns slide.
    const beside = boardGeometry(490, plan)
    assert.equal(beside.slides, true)
    assert.ok(Math.abs(beside.title - 408 * 0.45) < 1e-9)
    assert.ok(Math.abs(beside.viewport - (408 - 408 * 0.45)) < 1e-9)
    assert.ok(Math.abs(beside.limit - (content - beside.viewport)) < 1e-9)
    // The table's floor, 300: the title never goes under 150.
    const narrow = boardGeometry(300, plan)
    assert.equal(narrow.title, 150)
    assert.equal(narrow.viewport, 300 - 82 - 150)
    assert.equal(narrow.limit, content - (300 - 82 - 150))
    // No columns: the title has the row.
    assert.deepEqual(boardGeometry(400, []), { slides: false, title: 318, content: 0, viewport: 0, limit: 0 })
    // One column, its own width, no gap.
    assert.equal(boardGeometry(1000, [34]).content, 34)
    // Narrower than its chrome: no negative room.
    assert.equal(boardGeometry(40, plan).viewport, 0)
  })

  await test('the columns slide within their limit, by chevron or by a sideways wheel', () => {
    assert.equal(clampSlide(-20, 300), 0)
    assert.equal(clampSlide(120, 300), 120)
    assert.equal(clampSlide(400, 300), 300)
    assert.equal(clampSlide(50, 0), 0)
    // A chevron goes most of a viewport over, and stops at the ends.
    const geometry = { viewport: 200, limit: 300 }
    assert.equal(slideStep(0, geometry, 1), 160)
    assert.equal(slideStep(160, geometry, 1), 300)
    assert.equal(slideStep(300, geometry, -1), 140)
    assert.equal(slideStep(100, geometry, -1), 0)
    // A swipe more across than down slides; one more down than across
    // scrolls the rows; the wheel with Shift held slides by its turn.
    assert.equal(wheelSlide({ deltaX: 12, deltaY: 3, deltaMode: 0, shiftKey: false }), 12)
    assert.equal(wheelSlide({ deltaX: -8, deltaY: 2, deltaMode: 0, shiftKey: false }), -8)
    assert.equal(wheelSlide({ deltaX: 2, deltaY: 30, deltaMode: 0, shiftKey: false }), 0)
    assert.equal(wheelSlide({ deltaX: 0, deltaY: 30, deltaMode: 0, shiftKey: true }), 30)
    assert.equal(wheelSlide({ deltaX: 0, deltaY: 3, deltaMode: 1, shiftKey: true }), 48)
    assert.equal(wheelSlide({ deltaX: 0, deltaY: 1, deltaMode: 2, shiftKey: true }, 250), 250)
    assert.equal(wheelSlide({ deltaX: 0, deltaY: 0, deltaMode: 0, shiftKey: true }), 0)
  })

  await test('every column sorts but the two with no order', () => {
    assert.equal(sortKeyOf('materials'), null)
    assert.equal(sortKeyOf('tags'), null)
    for (const id of ALL_COLUMNS.filter((one) => one !== 'materials' && one !== 'tags')) assert.equal(sortKeyOf(id), id)
  })

  await test('a header cycles: ascending, descending, then the board’s own order', () => {
    const up = nextSort(null, 'year')
    assert.deepEqual(up, { key: 'year', ascending: true })
    const down = nextSort(up, 'year')
    assert.deepEqual(down, { key: 'year', ascending: false })
    assert.equal(nextSort(down, 'year'), null)
    // Another key starts over, ascending, whatever the first one was doing.
    assert.deepEqual(nextSort(down, 'authors'), { key: 'authors', ascending: true })
    assert.deepEqual(nextSort(up, 'title'), { key: 'title', ascending: true })
  })

  await test('sorting puts papers without a value last, either way, and keeps ties in order', () => {
    interface P { id: string; year: number | null; who: string | null }
    const papers: P[] = [
      { id: 'a', year: 2019, who: 'Kumar' },
      { id: 'b', year: null, who: null },
      { id: 'c', year: 2017, who: 'fujimoto' },
      { id: 'd', year: 2019, who: 'Kumar' },
      { id: 'e', year: null, who: 'Agarwal' },
      { id: 'f', year: 2021, who: 'Kostrikov' },
    ]
    const value = (one: P, key: BoardSortKey) => (key === 'year' ? one.year : key === 'authors' ? one.who : one.id)
    const ids = (list: P[]) => list.map((one) => one.id).join('')
    // No sort: the board's own order.
    assert.equal(ids(sortRows(papers, null, value)), 'abcdef')
    // Ascending: values up, ties (a and d) as they came, no-year last in their order.
    assert.equal(ids(sortRows(papers, { key: 'year', ascending: true }, value)), 'cadfbe')
    // Descending: only the papers with values turn round; ties still as they came; no-year still last.
    assert.equal(ids(sortRows(papers, { key: 'year', ascending: false }, value)), 'fadcbe')
    // Text the way Finder compares it: case aside.
    assert.equal(ids(sortRows(papers, { key: 'authors', ascending: true }, value)), 'ecfadb')
    assert.equal(ids(sortRows(papers, { key: 'authors', ascending: false }, value)), 'adfceb')
    // Numbers by value, accents and case aside.
    assert.ok(compareText('Week 2', 'Week 10') < 0)
    assert.equal(compareText('almudévar', 'Almudevar'), 0)
    // An empty text is no value.
    assert.equal(ids(sortRows([{ id: 'x', year: null, who: '' }, { id: 'y', year: null, who: 'Zhang' }], { key: 'authors', ascending: true }, value)), 'yx')
    // A plan sorts within each group, never across them: each group is sorted on its own.
    const groups: P[][] = [[papers[0], papers[1], papers[2]], [papers[3], papers[4], papers[5]]]
    assert.deepEqual(groups.map((group) => ids(sortRows(group, { key: 'year', ascending: true }, value))), ['cab', 'dfe'])
  })

  await test('a shelf’s table shows Read On and Plan only when asked; plans and the week always', () => {
    assert.deepEqual(withPlanColumns(DEFAULT_COLUMNS.other, 'other', false), ['authors', 'year', 'venue', 'materials'])
    assert.deepEqual(withPlanColumns(DEFAULT_COLUMNS.other, 'other', true), DEFAULT_COLUMNS.other)
    assert.deepEqual(withPlanColumns(DEFAULT_COLUMNS.plan, 'plan', false), DEFAULT_COLUMNS.plan)
    assert.deepEqual(withPlanColumns(DEFAULT_COLUMNS.week, 'week', false), DEFAULT_COLUMNS.week)
  })

  await test('which column holds the table: every shelf beside the page, a plan’s calendar wide', () => {
    // The old list set aside: every shelf is its table, a plan its table or calendar.
    assert.equal(viewFor('all', undefined, false), 'table')
    assert.equal(viewFor('all', 'list', false), 'table')
    assert.equal(viewFor('week', 'list', false), 'table')
    assert.equal(viewFor('plan', 'list', false), 'table')
    assert.equal(viewFor('plan', 'calendar', false), 'calendar')
    assert.equal(viewFor('notes', 'table', false), 'list')
    // In the list's column, with the page beside it.
    assert.equal(boardPlace('all', 'table', true, false), 'list')
    assert.equal(boardPlace('collection', 'table', true, false), 'list')
    assert.equal(boardPlace('week', 'table', true, false), 'list')
    assert.equal(boardPlace('plan', 'table', true, false), 'list')
    // A plan's calendar takes the list's room and the page's.
    assert.equal(boardPlace('plan', 'calendar', true, false), 'wide')
    assert.equal(boardPlace('plan', 'calendar', false, false), 'wide')
    // Search results keep their passages, an empty library its setup, the slip-box its notes.
    assert.equal(boardPlace('search', 'table', true, false), 'none')
    assert.equal(boardPlace('all', 'table', false, false), 'none')
    assert.equal(boardPlace('notes', 'list', true, false), 'none')
    // The old list back (`LEGACY.paperList`): the switch's choices, every board wide.
    assert.equal(viewFor('all', undefined, true), 'list')
    assert.equal(viewFor('all', 'table', true), 'table')
    assert.equal(viewFor('week', undefined, true), 'table')
    assert.equal(boardPlace('all', 'list', true, true), 'none')
    assert.equal(boardPlace('all', 'table', true, true), 'wide')
  })
}
