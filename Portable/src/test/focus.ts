/**
 * The window's columns and focus mode by the Mac's rules
 * (`shared/paneModel.ts`, `WR8`): something is always left to look at, focus
 * gives back what it hid, and what is saved is the window out of focus —
 * so a restart never comes back with every column shut.
 */
import assert from 'node:assert/strict'
import {
  enterFocus, leaveFocus, restingPanes, showPane, togglePaneState, unfocused, type Panes,
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
}
