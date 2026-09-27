/**
 * What the drawing panel, the rack and the keys ask of the editor
 * (`renderer/ui/sketch/commands.ts`), against a stand-in reader and page —
 * no window, no pointer: group, ungroup, frame, duplicate, delete, nudge,
 * align, front and back, select all, copy and paste, the tool keys, and
 * that each is one step to undo (`WR6`).
 */
import assert from 'node:assert/strict'
import { SketchElement, point } from '../shared/sketch.js'
import { InkStroke } from '../shared/ink.js'
import { SketchColor } from '../shared/sketch.js'
import { SketchTree } from '../shared/sketchTree.js'
import { store } from '../renderer/state.js'
import { makeEditing, type SketchInputEditing } from '../renderer/ui/sketch/commands.js'
import { session, undoStack } from '../renderer/ui/sketch/session.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface FakePage {
  index: number
  elements: SketchElement[]
  strokes: InkStroke[]
  shape: { view: number[]; rotate: number; userUnit: number }
  viewport: { scale: number }
  redraw: () => void
  redrawOverlay: () => void
}

function rig() {
  const page: FakePage = {
    index: 0, elements: [], strokes: [],
    shape: { view: [0, 0, 612, 792], rotate: 0, userUnit: 1 },
    viewport: { scale: 1 },
    redraw: () => undefined,
    redrawOverlay: () => undefined,
  }
  const saves: number[] = []
  const reader = {
    pages: [page],
    state: { currentPage: 0, drawing: true, pageCount: 1, zoom: 1 },
    setDrawing: (on: boolean) => { reader.state.drawing = on },
    update: () => undefined,
    redrawOverlays: () => undefined,
    redrawAll: () => undefined,
  }
  const host = { changed: () => undefined, save: (target: FakePage) => { saves.push(target.index) } }
  undoStack.clear()
  session.entered = null
  session.clipboard = null
  store.sketch.selection = null
  store.sketch.tool = 'select'
  const editor = makeEditing(reader as never, host as never) as SketchInputEditing
  return { page, reader, editor, saves }
}

const rect = (x: number, y: number, w = 20, h = 20) =>
  new SketchElement({ kind: 'rectangle', points: [point(x, y), point(x + w, y + h)] })

const select = (ids: string[], strokeIDs: number[] = []) => { store.sketch.selection = { pageIndex: 0, ids, strokeIDs } }

const key = (key: string, extra: Partial<KeyboardEvent> = {}) =>
  ({ key, code: '', shiftKey: false, altKey: false, metaKey: false, ctrlKey: false, target: null, ...extra }) as KeyboardEvent

export async function sketchCommandsSuite(test: Test, suite: (name: string) => void) {
  suite('Drawing: what the panel and the keys ask of the editor')

  await test('grouping takes the selection in, one step; ungrouping lets it out', () => {
    const { page, editor, saves } = rig()
    const a = rect(0, 0)
    const b = rect(50, 50)
    page.elements = [a, b]
    select([a.id, b.id])
    editor.groupSelection()
    const group = page.elements.find((one) => one.kind === 'group')!
    assert.ok(group)
    assert.deepEqual(page.elements.filter((one) => one.parent === group.id).map((one) => one.id).sort(), [a.id, b.id].sort())
    assert.deepEqual(store.sketch.selection?.ids, [group.id])
    assert.equal(saves.length, 1, 'written once')
    editor.ungroupSelection()
    assert.equal(page.elements.some((one) => one.kind === 'group'), false)
    assert.ok(page.elements.every((one) => one.parent === null))
    assert.ok(undoStack.canUndo)
    undoStack.undo()
    const back = undoStack.undo()!
    assert.equal(back.elements.length, 2, 'two steps back is the two boxes, loose')
  })

  await test('a frame round the selection takes it in, inset by eight points, and has a name', () => {
    const { page, editor } = rig()
    const a = rect(100, 100)
    page.elements = [a]
    select([a.id])
    editor.frameSelection()
    const frame = page.elements.find((one) => one.kind === 'frame')!
    assert.deepEqual(frame.rect, { x: 92, y: 92, width: 36, height: 36 })
    assert.ok(frame.name)
    assert.equal(page.elements.find((one) => one.id === a.id)!.parent, frame.id)
  })

  await test('duplicate, delete, nudge — and the tree stays whole', () => {
    const { page, editor } = rig()
    const a = rect(10, 10)
    page.elements = [a]
    select([a.id])
    editor.duplicateSelection()
    assert.equal(page.elements.length, 2)
    const copy = page.elements.find((one) => one.id !== a.id)!
    assert.deepEqual(copy.rect, { x: 22, y: -2, width: 20, height: 20 })
    assert.deepEqual(store.sketch.selection?.ids, [copy.id])
    editor.nudge(1, 0, true)
    assert.equal(page.elements.find((one) => one.id === copy.id)!.rect.x, 32)
    editor.deleteSelection()
    assert.deepEqual(page.elements.map((one) => one.id), [a.id])
    assert.equal(store.sketch.selection, null)
  })

  await test('aligning two boxes lines them up with each other', () => {
    const { page, editor } = rig()
    const a = rect(10, 10)
    const b = rect(100, 60)
    page.elements = [a, b]
    select([a.id, b.id])
    editor.align('left')
    assert.ok(page.elements.every((one) => one.rect.x === 10))
    editor.align('top')
    assert.ok(page.elements.every((one) => one.rect.y + one.rect.height === 80), 'top is the largest y')
  })

  await test('to the front and to the back move among siblings', () => {
    const { page, editor } = rig()
    const a = rect(0, 0)
    const b = rect(5, 5)
    const c = rect(9, 9)
    page.elements = [a, b, c]
    select([a.id])
    editor.bringSelectionToFront()
    assert.deepEqual(page.elements.map((one) => one.id), [b.id, c.id, a.id])
    editor.sendSelectionToBack()
    assert.deepEqual(page.elements.map((one) => one.id), [a.id, b.id, c.id])
  })

  await test('select all takes every root and every stroke; copy then paste lands beside, chosen', () => {
    const { page, editor } = rig()
    const a = rect(0, 0)
    page.elements = [a]
    page.strokes = [new InkStroke([{ x: 1, y: 1, w: 2 }, { x: 5, y: 5, w: 2 }], SketchColor.ink, 'pen')]
    editor.selectAllOnPage()
    assert.deepEqual(store.sketch.selection, { pageIndex: 0, ids: [a.id], strokeIDs: [0] })
    assert.ok(editor.copySelection())
    editor.pasteSketch()
    assert.equal(page.elements.length, 2)
    assert.equal(page.strokes.length, 2)
    const pasted = page.elements.find((one) => one.id !== a.id)!
    assert.deepEqual(pasted.rect, { x: 12, y: -12, width: 20, height: 20 }, 'nudged off the original on its own page')
    assert.deepEqual(store.sketch.selection?.strokeIDs, [1])
    const step = undoStack.undo()!
    assert.equal(step.elements.length, 1, 'the paste is one step, shapes and strokes together')
    assert.equal(step.strokes.length, 1)
  })

  await test("the tool keys pick through the rack's groups, and Escape steps back out", () => {
    const { page, editor, reader } = rig()
    const a = rect(0, 0)
    page.elements = [a]
    assert.ok(editor.handleKey(key('o')))
    assert.equal(store.sketch.tool, 'ellipse')
    assert.equal(store.sketch.lastShape, 'ellipse', 'the shapes button shows the one last reached for')
    assert.ok(editor.handleKey(key('h')))
    assert.equal(store.sketch.lastInk, 'highlighter')
    select([a.id])
    assert.ok(editor.handleKey(key('Escape')))
    assert.equal(store.sketch.selection, null, 'first the selection')
    assert.ok(editor.handleKey(key('Escape')))
    assert.equal(store.sketch.tool, 'select', 'then the tool')
    assert.ok(editor.handleKey(key('Escape')))
    assert.equal(reader.state.drawing, false, 'then the pen')
  })

  await test("the command key is the desktop's own — Ctrl off the Mac, never the Windows key", () => {
    const { page, editor } = rig()
    page.elements = [rect(0, 0)]
    const mac = process.platform === 'darwin'
    const primary = mac ? { metaKey: true } : { ctrlKey: true }
    const other = mac ? { ctrlKey: true } : { metaKey: true }
    assert.ok(editor.handleKey(key('a', primary)))
    assert.equal(store.sketch.selection?.ids.length, 1)
    store.sketch.selection = null
    assert.equal(editor.handleKey(key('a', other)), false)
  })

  await test('entering a group chooses its first child, and Escape comes back out to the group', () => {
    const { page, editor } = rig()
    const a = rect(0, 0)
    const b = rect(30, 30)
    page.elements = [a, b]
    select([a.id, b.id])
    editor.groupSelection()
    const group = store.sketch.selection!.ids[0]
    editor.enterSelectedGroup()
    assert.equal(session.entered, group)
    assert.ok(new SketchTree(page.elements).isDescendant(store.sketch.selection!.ids[0], group))
    editor.escape()
    assert.deepEqual(store.sketch.selection?.ids, [group])
    assert.equal(session.entered, null)
  })
}
