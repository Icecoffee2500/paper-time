/**
 * The window's columns and focus mode by the Mac's rules
 * (`shared/paneModel.ts`, `WR8`): something is always left to look at, focus
 * gives back what it hid, and what is saved is the window out of focus —
 * so a restart never comes back with every column shut.
 */
import assert from 'node:assert/strict'
import {
  PAGE_FLOOR, READING_FLOOR, TABLE_LEAST, enterFocus, leaveFocus, restingPanes, showPane, tableAndPageRoom, tableShownWidth, tableWidest,
  togglePaneState, unfocused, type Panes,
} from '../shared/paneModel.js'

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
}
