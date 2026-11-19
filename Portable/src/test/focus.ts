/**
 * The window's columns and focus mode by the Mac's rules
 * (`shared/paneModel.ts`, `WR8`): something is always left to look at, focus
 * gives back what it hid, and what is saved is the window out of focus —
 * so a restart never comes back with every column shut.
 */
import assert from 'node:assert/strict'
import {
  CLOSED_KEPT, INSPECTOR_PLACE, MAX_PANES, PAGE_FLOOR, READING_FLOOR, TABLE_LEAST, chooseInspector, closePane, cycleInspector, defaultRow, enterFocus,
  ensureList, ensurePage, paperDropOn, paperZoneMode, showsPlusColumn,
  fitWidths, flexiblePane, focusedPanes, insertPane, leaveFocus, migrateLegacyPanes, movePane, paneOf, paneShelfKey, placeFloat, readPanes, reopenPane,
  restingPanes, rowOf, setContent, showPane, tableAndPageRoom, tableShownWidth, tableWidest, togglePaneKind, togglePaneState, unfocused, writePanes,
  zoneAcross, type ContentPane, type PaneRow, type Panes,
} from '../shared/paneModel.js'
import { fromFile } from '../shared/appSettings.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const all: Panes = { sidebar: true, paperList: true, reader: true, inspector: true }

export async function focusSuite(test: Test, suite: (name: string) => void) {
  suite('The columns and focus mode')

  await test('focus is the paper alone, and leaving it gives back the list and the inspector', () => {
    const start = unfocused({ ...all, inspector: false })
    const focused = enterFocus(start)
    assert.deepEqual(focused.panes, { sidebar: false, paperList: false, reader: true, inspector: false })
    assert.equal(focused.focus.on, true)
    const back = leaveFocus(focused)
    assert.deepEqual(back.panes, { sidebar: true, paperList: true, reader: true, inspector: false })
    assert.equal(back.focus.on, false)
  })

  await test('what is saved in focus is the window focus would give back', () => {
    const focused = enterFocus(unfocused(all))
    assert.deepEqual(restingPanes(focused), all, 'a restart does not strand the window')
    // Saved, read back as a fresh window, it has its columns.
    const relaunched = unfocused(JSON.parse(JSON.stringify(restingPanes(focused))))
    assert.deepEqual(relaunched.panes, all)
    assert.equal(relaunched.focus.on, false)
  })

  await test('asking for the paper in focus leaves focus', () => {
    const focused = enterFocus(unfocused(all))
    const next = togglePaneState(focused, 'reader')
    assert.equal(next.focus.on, false)
    assert.equal(next.panes.reader, true)
  })

  await test('something is always left to look at', () => {
    const onlyList = unfocused({ sidebar: false, paperList: true, reader: false, inspector: false })
    assert.equal(togglePaneState(onlyList, 'paperList').panes.reader, true, 'the list closed: the paper opens')
    const onlyPaper = unfocused({ sidebar: false, paperList: false, reader: true, inspector: true })
    assert.equal(togglePaneState(onlyPaper, 'reader').panes.paperList, true, 'the paper closed: the list opens')
    const onlySidebar = unfocused({ sidebar: true, paperList: false, reader: false, inspector: false })
    assert.equal(togglePaneState(onlySidebar, 'sidebar').panes.reader, true)
  })

  await test('the pen shows the inspector in focus too, and focus stays on', () => {
    const focused = enterFocus(unfocused(all))
    const shown = showPane(focused, 'inspector')
    assert.equal(shown.panes.inspector, true)
    assert.equal(shown.focus.on, true)
    assert.equal(showPane(shown, 'inspector'), shown, 'already showing: nothing changes')
  })

  await test('the table gives way to the page, and the inspector takes its room from the table', () => {
    // The Mac's numbers (`Pane`): a page you can read is 520, the table
    // yields down to 300, and the page is never left under 300.
    assert.deepEqual([READING_FLOOR, TABLE_LEAST, PAGE_FLOOR], [520, 300, 300])
    // A 1728-point screen: the panes have 1712 inside their margins; the
    // sidebar is 232 and the inspector 360, and each column has a gap of 10.
    const shut = tableAndPageRoom({ window: 1712, sidebar: 232, inspector: null, gap: 10 })
    const open = tableAndPageRoom({ window: 1712, sidebar: 232, inspector: 360, gap: 10 })
    assert.equal(shut, 1712 - 10 - 242)
    assert.equal(open, shut - 370)
    // Shut, the table has the width it was given and the page more than a reading width.
    assert.equal(tableShownWidth(620, shut), 620)
    assert.ok(shut - tableShownWidth(620, shut) >= READING_FLOOR)
    // Open, the table gives way and the page keeps its reading width
    // (2026-11-16: the table kept its 620 and the paper was left 270).
    assert.equal(tableShownWidth(620, open), open - READING_FLOOR)
    assert.equal(open - tableShownWidth(620, open), READING_FLOOR)
    // Shut again, the width it was given comes back — nothing was written.
    assert.equal(tableShownWidth(620, shut), 620)
    // A narrow window: the table holds at a title's room, the page takes
    // what is left above its floor…
    const narrow = tableAndPageRoom({ window: 1222, sidebar: 232, inspector: 360, gap: 10 })
    assert.equal(tableShownWidth(620, narrow), TABLE_LEAST)
    assert.ok(narrow - TABLE_LEAST >= PAGE_FLOOR)
    // …and narrower still, the page keeps its floor before the table its own.
    const tight = tableAndPageRoom({ window: 1000, sidebar: 232, inspector: 360, gap: 10 })
    assert.equal(tableShownWidth(620, tight), Math.max(tight - PAGE_FLOOR, 200))
    assert.equal(tableShownWidth(620, 100), 200, 'never under 200, whatever the window')
    // A table given less than it may have keeps what it was given.
    assert.equal(tableShownWidth(360, shut), 360)
    // The divider stops where the page would go under a reading width, and
    // never under the table's own floor.
    assert.equal(tableWidest(shut), shut - READING_FLOOR)
    assert.equal(tableWidest(600), TABLE_LEAST)
    // The sidebar shut gives its room to the table too.
    assert.equal(tableAndPageRoom({ window: 1712, sidebar: null, inspector: null, gap: 10 }), 1702)
  })

  await test('the other panes take their room from the table too', () => {
    const without = tableAndPageRoom({ window: 1712, sidebar: 232, inspector: null, gap: 10 })
    assert.equal(tableAndPageRoom({ window: 1712, sidebar: 232, inspector: null, others: [340], gap: 10 }), without - 350)
    assert.equal(tableAndPageRoom({ window: 1712, sidebar: 232, inspector: null, others: [340, 22], gap: 10 }), without - 350 - 32)
    assert.equal(tableAndPageRoom({ window: 1712, sidebar: 232, inspector: null, others: [], gap: 10 }), without)
  })

  suite('The row of panes (1.1)')

  const kinds = (row: PaneRow) => row.panes.map((pane) => pane.content.kind === 'shelf' ? `shelf:${JSON.parse(pane.content.shelf).kind}` : pane.content.kind)
  const ids = (row: PaneRow) => row.panes.map((pane) => pane.id)
  const shelf = (value: unknown): ContentPane['content'] => ({ kind: 'shelf', shelf: paneShelfKey(value) })
  const plan = shelf({ kind: 'plan', id: 'P' })
  const papers = shelf({ kind: 'kind', of: 'paper' })

  await test('the window starts as it always was: the list and the page', () => {
    const row = defaultRow()
    assert.deepEqual(kinds(row), ['list', 'page'])
    assert.deepEqual(row.closed, [])
    assert.equal(flexiblePane(row.panes), 'page', 'the page takes the room left')
    assert.equal(flexiblePane(rowOf([{ id: 'a', content: { kind: 'list' }, width: null }, { id: 'b', content: plan, width: null }]).panes), 'a', 'no page: the list does')
    assert.equal(flexiblePane(rowOf([{ id: 'a', content: plan, width: null }, { id: 'b', content: papers, width: null }]).panes), 'b', 'neither: the last one does')
  })

  await test('a pane goes in beside another, and four is the most', () => {
    let row = defaultRow()
    row = insertPane(row, { id: 'p', content: plan }, 2).row
    assert.deepEqual(ids(row), ['list', 'page', 'p'])
    row = insertPane(row, { id: 'q', content: papers }, 0).row
    assert.deepEqual(ids(row), ['q', 'list', 'page', 'p'])
    assert.equal(row.panes.length, MAX_PANES)
    const fifth = insertPane(row, { id: 'r', content: { kind: 'note', note: null } }, 1)
    assert.equal(fifth.refused, 'full')
    assert.equal(fifth.row, row, 'refused: nothing changes')
  })

  await test('one list and one page: a second is refused, and asking a pane to be the page trades with the page', () => {
    const row = insertPane(defaultRow(), { id: 'p', content: plan }, 2).row
    assert.equal(insertPane(row, { id: 'x', content: { kind: 'list' } }, 0).refused, 'taken')
    assert.equal(insertPane(row, { id: 'x', content: { kind: 'page' } }, 0).refused, 'taken')
    const traded = setContent(row, 'p', { kind: 'page' }).row
    assert.deepEqual(kinds(traded), ['list', 'shelf:plan', 'page'])
    assert.equal(traded.panes.find((pane) => pane.id === 'p')?.content.kind, 'page')
    assert.equal(traded.panes.find((pane) => pane.id === 'page')?.content.kind, 'shelf', 'the old page shows what the other pane showed')
    assert.equal(traded.panes.filter((pane) => pane.content.kind === 'page').length, 1)
  })

  await test('a shelf dropped in the page’s middle replaces it, and the next paper opens to its right', () => {
    let row = setContent(defaultRow(), 'page', plan).row
    assert.deepEqual(kinds(row), ['list', 'shelf:plan'])
    assert.equal(paneOf(row, 'page'), null)
    row = ensurePage(row, 'page', 'new').row
    assert.deepEqual(kinds(row), ['list', 'shelf:plan', 'page'])
    assert.equal(row.panes[2].id, 'new')
    // Shown already: nothing more.
    assert.equal(ensurePage(row, 'list', 'again').row, row)
  })

  await test('a paper chosen with no page: the page comes to the right of where it was chosen, or at the end', () => {
    const row = rowOf([{ id: 'l', content: { kind: 'list' }, width: null }, { id: 'p', content: plan, width: null }])
    assert.deepEqual(ids(ensurePage(row, 'l', 'g').row), ['l', 'g', 'p'], 'chosen in the list: beside the list')
    assert.deepEqual(ids(ensurePage(row, 'p', 'g').row), ['l', 'p', 'g'], 'chosen in the plan: beside the plan')
    assert.deepEqual(ids(ensurePage(row, null, 'g').row), ['l', 'p', 'g'], 'chosen anywhere else: at the end')
    assert.deepEqual(ids(ensurePage(row, 'gone', 'g').row), ['l', 'p', 'g'])
    // A full row gives up the pane to the right of the one chosen in — kept to reopen.
    const full = rowOf(['a', 'b', 'c', 'd'].map((id) => ({ id, content: shelf({ kind: 'plan', id }), width: null })))
    const made = ensurePage(full, 'b', 'g').row
    assert.deepEqual(ids(made), ['a', 'b', 'g', 'd'])
    assert.equal(made.closed.at(-1)?.pane.id, 'c')
    assert.deepEqual(ids(ensurePage(full, 'd', 'g').row), ['a', 'b', 'g', 'd'], 'at the end: the one to its left')
    // Reopened, the pane given up goes back where it stood, if there is room.
    const reopened = reopenPane(closePane(made, 'd').row)
    assert.deepEqual(ids(reopened.row), ['a', 'b', 'g', 'd'], 'the last closed comes first')
  })

  await test('a sidebar row with no list pane brings one at the left', () => {
    const row = rowOf([{ id: 'p', content: { kind: 'page' }, width: null }])
    assert.deepEqual(kinds(ensureList(row, 'l').row), ['list', 'page'])
    const full = rowOf([
      { id: 'g', content: { kind: 'page' }, width: null },
      ...['a', 'b', 'c'].map((id) => ({ id, content: shelf({ kind: 'plan', id }), width: null })),
    ])
    const made = ensureList(full, 'l').row
    assert.deepEqual(ids(made), ['g', 'l', 'b', 'c'], 'the leftmost that is not the page gives way')
    assert.equal(made.closed.at(-1)?.pane.id, 'a')
  })

  await test('panes move beside each other, or trade places', () => {
    const row = rowOf(['a', 'b', 'c', 'd'].map((id) => ({ id, content: shelf({ kind: 'plan', id }), width: null })))
    assert.deepEqual(ids(movePane(row, 'a', 'c', 'right').row), ['b', 'c', 'a', 'd'])
    assert.deepEqual(ids(movePane(row, 'd', 'a', 'left').row), ['d', 'a', 'b', 'c'])
    assert.deepEqual(ids(movePane(row, 'a', 'd', 'swap').row), ['d', 'b', 'c', 'a'])
    assert.equal(movePane(row, 'a', 'a', 'left').row, row)
    assert.equal(movePane(row, 'a', 'zz', 'left').refused, 'missing')
  })

  await test('the last pane cannot close; a closed one comes back where it stood', () => {
    const one = rowOf([{ id: 'p', content: { kind: 'page' }, width: null }])
    assert.equal(closePane(one, 'p').refused, 'last')
    let row = insertPane(defaultRow(), { id: 'p', content: plan, width: 300 }, 1).row
    assert.deepEqual(ids(row), ['list', 'p', 'page'])
    row = closePane(row, 'p').row
    assert.deepEqual(ids(row), ['list', 'page'])
    assert.deepEqual({ left: row.closed[0].left, right: row.closed[0].right, index: row.closed[0].index }, { left: 'list', right: 'page', index: 1 })
    // Its neighbour on the left moved: it follows that one.
    row = movePane(row, 'list', 'page', 'right').row
    const back = reopenPane(row)
    assert.deepEqual(ids(back.row), ['page', 'list', 'p'])
    assert.equal(back.row.panes[2].width, 300, 'with the width it had')
    assert.deepEqual(back.row.closed, [])
    // Its left neighbour gone too: before the one on its right; both gone: its old place.
    const lone = reopenPane({ panes: [{ id: 'page', content: { kind: 'page' }, width: null }], closed: [{ pane: { id: 'p', content: plan, width: null }, left: 'gone', right: 'page', index: 3 }] })
    assert.deepEqual(ids(lone.row), ['p', 'page'])
    const nowhere = reopenPane({ panes: [{ id: 'page', content: { kind: 'page' }, width: null }], closed: [{ pane: { id: 'p', content: plan, width: null }, left: null, right: null, index: 5 }] })
    assert.deepEqual(ids(nowhere.row), ['page', 'p'])
  })

  await test('eight closed panes are kept, the last closed reopens first, and a full row says so', () => {
    let row: PaneRow = rowOf([{ id: 'page', content: { kind: 'page' }, width: null }])
    for (let at = 0; at < 10; at += 1) {
      row = insertPane(row, { id: `s${at}`, content: shelf({ kind: 'plan', id: String(at) }) }, 1).row
      row = closePane(row, `s${at}`).row
    }
    assert.equal(row.closed.length, CLOSED_KEPT)
    assert.equal(row.closed[0].pane.id, 's2', 'the oldest go first')
    assert.equal(reopenPane(row).pane, 's9')
    const full = { ...rowOf(['a', 'b', 'c', 'd'].map((id) => ({ id, content: shelf({ kind: 'plan', id }), width: null }))), closed: row.closed }
    const refused = reopenPane(full)
    assert.equal(refused.refused, 'full')
    assert.equal(refused.row.closed.length, CLOSED_KEPT, 'kept for when there is room')
    // A list or a page open again already is no pane to reopen.
    const listBack = closePane(defaultRow(), 'list').row
    const again = ensureList(listBack, 'l2').row
    const taken = reopenPane(again)
    assert.equal(taken.refused, 'taken')
    assert.deepEqual(taken.row.closed, [], 'and it leaves the stack')
  })

  await test('the toolbar’s switches close the list and the page onto the stack, and bring them back where they were', () => {
    let row = insertPane(defaultRow(), { id: 'p', content: plan }, 2).row
    row = togglePaneKind(row, 'list', 'x').row
    assert.deepEqual(kinds(row), ['page', 'shelf:plan'])
    row = togglePaneKind(row, 'list', 'x').row
    assert.deepEqual(ids(row), ['list', 'page', 'p'], 'back at the left, as itself')
    row = togglePaneKind(row, 'page', 'x').row
    assert.deepEqual(ids(row), ['list', 'p'])
    row = togglePaneKind(row, 'page', 'x').row
    assert.deepEqual(ids(row), ['list', 'page', 'p'], 'back between the two')
    // The last pane is not closed but turned into the other: something is always left to look at.
    const only = rowOf([{ id: 'l', content: { kind: 'list' }, width: null }])
    assert.deepEqual(kinds(togglePaneKind(only, 'list', 'x').row), ['page'])
    // Never opened before: the list at the left, the page at the end.
    const pinned = rowOf([{ id: 'a', content: plan, width: null }])
    assert.deepEqual(kinds(togglePaneKind(pinned, 'list', 'l').row), ['list', 'shelf:plan'])
    assert.deepEqual(kinds(togglePaneKind(pinned, 'page', 'g').row), ['shelf:plan', 'page'])
  })

  await test('a crowded row gives way toward each pane’s floor, never past the window', () => {
    assert.deepEqual(fitWidths([{ wanted: 300, least: 200 }, { wanted: 420, least: 260 }], 800), [300, 420], 'room enough: as wanted')
    // 120 too many: the list can give 100, the pinned pane 160 — in that proportion.
    assert.deepEqual(fitWidths([{ wanted: 300, least: 200 }, { wanted: 420, least: 260 }], 600), [254, 346])
    // Not even the floors fit: the floors share what there is.
    const tight = fitWidths([{ wanted: 300, least: 200 }, { wanted: 420, least: 260 }, { wanted: 420, least: 260 }], 540)
    assert.deepEqual(tight, [150, 195, 195])
    assert.ok(tight.reduce((sum, one) => sum + one, 0) <= 540)
  })

  await test('focus mode is the page alone, whatever else the row holds', () => {
    const row = insertPane(defaultRow(), { id: 'p', content: plan }, 0).row
    assert.deepEqual(focusedPanes(row).map((pane) => pane.id), ['page'])
    assert.deepEqual(focusedPanes(rowOf([{ id: 'a', content: plan, width: null }])).map((pane) => pane.id), ['a'], 'no page: the first pane')
  })

  await test('a drop’s zone: a quarter at each side, the middle between', () => {
    assert.equal(zoneAcross(0), 'left')
    assert.equal(zoneAcross(0.25), 'left')
    assert.equal(zoneAcross(0.27), 'middle')
    assert.equal(zoneAcross(0.5), 'middle')
    assert.equal(zoneAcross(0.73), 'middle')
    assert.equal(zoneAcross(0.75), 'right')
    assert.equal(zoneAcross(1), 'right')
  })

  await test('a shelf is the same string however its keys were written', () => {
    assert.equal(paneShelfKey({ kind: 'plan', id: 'P' }), paneShelfKey({ id: 'P', kind: 'plan' }))
    assert.equal(paneShelfKey({ kind: 'knowledge', area: null }), '{"area":null,"kind":"knowledge"}')
  })

  await test('the settings keep one arrangement; what does not read is left out', () => {
    const row = insertPane(defaultRow(), { id: 'p', content: plan, width: 412 }, 2).row
    const floating = { floating: true, x: 40, y: 30, width: 340, height: 560 }
    const read = readPanes(writePanes({ ...row, closed: closePane(row, 'list').row.closed }, floating))
    assert.deepEqual(read?.panes, row.panes, 'the closed stack is this session’s, not the file’s')
    assert.deepEqual(read?.inspector, floating)
    assert.equal(readPanes(null), null)
    assert.equal(readPanes('nonsense'), null)
    assert.equal(readPanes('{"panes":[]}'), null, 'no panes is no row')
    const messy = readPanes(JSON.stringify({ panes: [
      { id: 'a', content: { kind: 'list' } }, { id: 'b', content: { kind: 'list' } }, { id: 'a', content: { kind: 'page' } },
      { id: 'c', content: { kind: 'shelf', shelf: '' } }, { id: 'd', content: { kind: 'note', note: 'N' }, width: -4 },
      { id: 'e', content: { kind: 'page' } }, { id: 'f', content: plan }, { id: 'g', content: papers },
    ] }))
    assert.deepEqual(messy?.panes.map((pane) => pane.id), ['a', 'd', 'e', 'f'], 'one list, one page, unique ids, four at most')
    assert.equal(messy?.panes[1].width, null)
    assert.deepEqual(messy?.inspector, INSPECTOR_PLACE)
  })

  await test('the old places and the companion are carried into the row once, and their keys left behind', () => {
    const arrangements = JSON.stringify({
      library: { list: true, page: true, inspector: true, companion: { kind: 'papers' } },
      projects: { list: false, page: true, inspector: false, companion: { kind: 'note' } },
    })
    const carried = readPanes(migrateLegacyPanes({ workspaceArrangements: arrangements, columns: { companion: 300 } }))
    assert.deepEqual(carried?.panes.map((pane) => pane.content), [{ kind: 'list' }, { kind: 'page' }, papers])
    assert.equal(carried?.panes[2].width, 300)
    // A plan beside a page with the list closed.
    const planned = readPanes(migrateLegacyPanes({ workspaceArrangements: JSON.stringify({ library: { list: false, page: true, inspector: true, companion: { kind: 'plan', id: 'P' } } }) }))
    assert.deepEqual(planned?.panes.map((pane) => pane.content), [{ kind: 'page' }, plan])
    // A companion in another place only: the window's two switches and that pane.
    const elsewhere = readPanes(migrateLegacyPanes({ workspaceArrangements: JSON.stringify({ knowledge: { list: true, page: true, inspector: false, companion: { kind: 'note' } } }), panes: { paperList: false, reader: true } }))
    assert.deepEqual(elsewhere?.panes.map((pane) => pane.content), [{ kind: 'page' }, { kind: 'note', note: null }])
    // Nothing to carry: none, and the switches say the rest.
    assert.equal(migrateLegacyPanes({}), null)
    assert.equal(migrateLegacyPanes({ workspaceArrangements: 'not json' }), null)
    // Read from the file: the row made, the old keys gone, so the next write leaves them out.
    const file = fromFile({ workspaceArrangements: arrangements, columns: { sidebar: 250, companion: 300 } } as never) as unknown as Record<string, unknown>
    assert.equal('workspaceArrangements' in file, false)
    assert.equal('companion' in (file.columns as Record<string, unknown>), false)
    assert.equal((file.columns as Record<string, unknown>).sidebar, 250)
    assert.deepEqual(readPanes(file.paneRow as string)?.panes.map((pane) => pane.content.kind), ['list', 'page', 'shelf'])
    // A row already written wins over what is left of the old keys.
    const kept = writePanes(rowOf([{ id: 'x', content: { kind: 'page' }, width: null }]), INSPECTOR_PLACE)
    assert.equal((fromFile({ paneRow: kept, workspaceArrangements: arrangements } as never) as unknown as Record<string, unknown>).paneRow, kept)
    assert.equal((fromFile({} as never) as unknown as Record<string, unknown>).paneRow, null)
  })

  await test('a paper over a pane opens beside the page’s paper, on the side facing that pane', () => {
    const shelf = { kind: 'shelf' as const, shelf: '{"kind":"week"}' }
    const row = rowOf([
      { id: 'list', content: { kind: 'list' }, width: null },
      { id: 'page', content: { kind: 'page' }, width: null },
      { id: 'week', content: shelf, width: null },
    ])
    assert.equal(paperZoneMode(row), 'one', 'a page to stand beside: the whole pane is one zone')
    assert.deepEqual(paperDropOn(row, 'list', 'middle'), { kind: 'beside', side: 'left' })
    assert.deepEqual(paperDropOn(row, 'list', 'right'), { kind: 'beside', side: 'left' }, 'the side is the pane’s, not the pointer’s')
    assert.deepEqual(paperDropOn(row, 'week', 'left'), { kind: 'beside', side: 'right' })
    assert.deepEqual(paperDropOn(row, null, 'right'), { kind: 'beside', side: 'right' }, 'the «+» column: beside, on the right')
    assert.equal(paperDropOn(row, 'gone', 'middle'), null)
  })

  await test('a paper over a pane with no page open: a page comes where it was put', () => {
    const row = rowOf([
      { id: 'list', content: { kind: 'list' }, width: null },
      { id: 'week', content: { kind: 'shelf', shelf: '{"kind":"week"}' }, width: null },
    ])
    assert.equal(paperZoneMode(row), 'three')
    assert.deepEqual(paperDropOn(row, 'week', 'left'), { kind: 'page', at: 1 })
    assert.deepEqual(paperDropOn(row, 'week', 'right'), { kind: 'page', at: 2 })
    assert.deepEqual(paperDropOn(row, 'list', 'middle'), { kind: 'page', at: 1 }, 'the middle: to its right, as the Mac has it')
    assert.deepEqual(paperDropOn(row, null, 'right'), { kind: 'page', at: 2 }, 'the «+» column: a page at the end')
  })

  await test('no «+» column with four panes open, nor in focus', () => {
    const plan = { kind: 'shelf' as const, shelf: '{"kind":"week"}' }
    let row = defaultRow()
    assert.equal(showsPlusColumn(row, false), true)
    assert.equal(showsPlusColumn(row, true), false, 'focus is the page alone')
    row = insertPane(row, { id: 'a', content: plan }, 2).row
    assert.equal(showsPlusColumn(row, false), true, 'three: room for one more')
    row = insertPane(row, { id: 'b', content: { kind: 'note', note: null } }, 3).row
    assert.equal(row.panes.length, MAX_PANES)
    assert.equal(showsPlusColumn(row, false), false, 'four: it could only say «칸은 네 개까지예요»')
    assert.equal(showsPlusColumn(closePane(row, 'b').row, false), true, 'one closed: it is back')
  })

  await test('⌘] turns the inspector: floating, docked, gone — and floating again', () => {
    let now = { shown: false, floating: false }
    now = cycleInspector(now)
    assert.deepEqual(now, { shown: true, floating: true })
    now = cycleInspector(now)
    assert.deepEqual(now, { shown: true, floating: false })
    now = cycleInspector(now)
    assert.deepEqual(now, { shown: false, floating: false })
    assert.deepEqual(cycleInspector(now), { shown: true, floating: true })
    assert.deepEqual(cycleInspector({ shown: false, floating: true }), { shown: true, floating: true }, 'hidden while floating: floating again')
  })

  await test('the menus’ two ways of showing it: the one chosen, or — chosen again — put away', () => {
    assert.deepEqual(chooseInspector({ shown: false, floating: false }, true), { shown: true, floating: true })
    assert.deepEqual(chooseInspector({ shown: true, floating: false }, true), { shown: true, floating: true }, 'docked to floating')
    assert.deepEqual(chooseInspector({ shown: true, floating: true }, true), { shown: false, floating: true }, 'the one showing: put away')
    assert.deepEqual(chooseInspector({ shown: true, floating: false }, false), { shown: false, floating: false })
    assert.deepEqual(chooseInspector({ shown: false, floating: true }, false), { shown: true, floating: false })
  })

  await test('the floating inspector stays inside the window, at a size it can be read at', () => {
    const area = { width: 1400, height: 820 }
    const first = placeFloat(INSPECTOR_PLACE, area)
    assert.deepEqual({ x: first.x, y: first.y, width: first.width, height: first.height }, { x: 1400 - 340 - 16, y: 72, width: 340, height: 560 }, 'not placed yet: at the right, under the heads')
    const off = placeFloat({ floating: true, x: 5000, y: -300, width: 340, height: 560 }, area)
    assert.deepEqual({ x: off.x, y: off.y }, { x: 1400 - 340 - 8, y: 8 }, 'dragged out: back in reach')
    const tiny = placeFloat({ floating: true, x: 20, y: 20, width: 10, height: 10 }, area)
    assert.deepEqual({ width: tiny.width, height: tiny.height }, { width: 280, height: 240 })
    const huge = placeFloat({ floating: true, x: 20, y: 20, width: 9000, height: 9000 }, { width: 600, height: 500 })
    assert.deepEqual({ x: huge.x, y: huge.y, width: huge.width, height: huge.height }, { x: 8, y: 8, width: 584, height: 484 }, 'a small window: as large as it allows')
  })
}
