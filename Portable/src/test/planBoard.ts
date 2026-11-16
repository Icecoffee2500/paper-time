/**
 * What the reading plan's board says and in what order (`shared/planBoard.ts`),
 * and the plan edits the window sends (`shared/planEdit.ts`).
 */
import assert from 'node:assert/strict'
import { setKorean } from '../shared/lang.js'
import {
  ALL_COLUMNS, DEFAULT_COLUMNS, authorsText, calendarDays, calendarHome, calendarLabel, dateLabel, dayHeading, detectionLine,
  groupByStatus, groupByWeek, holdsAddress, isBehind, nextStatus, pickerFold, pickerOrder, pickerShown, planGuidance, planStats,
  progress, readAddRow, readColumns, spanText, spreadOrder, spreadPreview, spreadStart, weekCount, weekName, weekShelf, withRo,
  type BoardPaper,
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
    assert.equal(dateLabel('2026-11-12', 'reading', TODAY).text, '11/12 · Overdue')
    assert.equal(dateLabel('2026-11-20', 'unread', TODAY).text, 'Fri 11/20')
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
    assert.equal(weekName('2026-11-16', TODAY), 'This week · 11/16–11/22')
    assert.equal(spanText([]), 'No dates yet')
    assert.equal(dayHeading('2026-11-16', TODAY), 'Today · Monday, November 16')
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
}
