/**
 * The pen's own presets, the highlighter fitted to words, the page's keys
 * as each desktop writes them, and the font names the desktop lists
 * (`WR19`) — the Mac's `InkPresets`, `StrokeSnapper` and `NSFontManager`.
 */
import assert from 'node:assert/strict'
import { defaultInkPresets, highlighterWidth, inkPresetsFrom, penColor, penWidth } from '../shared/inkPresets.js'
import { snapStroke, type Box, type TextRun } from '../shared/strokeSnap.js'
import { shortcutText } from '../shared/shortcuts.js'
import { familiesFromFontconfig, familyFromRegistryName } from '../main/fonts.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

export async function drawingToolsSuite(test: Test, suite: (name: string) => void) {
  suite('Drawing tools as the Mac has them')

  await test("the pen and the highlighter keep their own colours and widths, the Mac's defaults", () => {
    const presets = defaultInkPresets()
    assert.deepEqual(presets.penWidths, [1.5, 3, 5])
    assert.deepEqual(presets.highlighterWidths, [12, 18, 26])
    assert.equal(penWidth(presets), 3)
    assert.equal(highlighterWidth(presets), 18)
    assert.deepEqual([penColor(presets).red, penColor(presets).green, penColor(presets).blue], [0.1, 0.1, 0.12])
    assert.equal(presets.fitsToText, true)
    assert.equal(presets.eraserErasesMarks, true)
    // Read back from the settings, field by field: what is wrong is the default.
    const read = inkPresetsFrom(JSON.stringify({ ...presets, penColorIndex: 2, penWidths: [1, 2], fitsToText: false, highlighterColors: ['yellow', 'teal', 'pink'] }))
    assert.equal(read.penColorIndex, 2)
    assert.deepEqual(read.penWidths, [1.5, 3, 5])
    assert.equal(read.fitsToText, false)
    assert.deepEqual(read.highlighterColors, ['yellow', 'green', 'pink'])
    assert.deepEqual(inkPresetsFrom('not json'), defaultInkPresets())
    assert.deepEqual(inkPresetsFrom(null), defaultInkPresets())
  })

  // A page with two lines of words, eleven points tall, fourteen apart (y up).
  const line1: Box = { x: 72, y: 700, width: 468, height: 11 }
  const line2: Box = { x: 72, y: 686, width: 468, height: 11 }
  const runs: TextRun[] = [
    { box: { x: 72, y: 700, width: 234, height: 11 }, text: 'Entropy maximisation on the forget set' },
    { box: { x: 306, y: 700, width: 234, height: 11 }, text: 'drives the model toward uncertainty' },
    { box: { x: 72, y: 686, width: 468, height: 11 }, text: 'while the retain set keeps its accuracy intact' },
  ]
  const lines = [line1, line2]

  await test('a highlighter along a line of words becomes a highlight as wide as the stroke', () => {
    const snapped = snapStroke({ x: 100, y: 697, width: 150, height: 18 }, lines, runs)
    assert.equal(snapped?.kind, 'highlight')
    assert.equal(snapped?.boxes.length, 1)
    assert.deepEqual(snapped?.boxes[0], { x: 100, y: 700, width: 150, height: 11 })
    assert.ok(snapped?.text && snapped.text.length > 5)
  })

  await test('a thin stroke run just under the words is an underline', () => {
    const snapped = snapStroke({ x: 80, y: 697, width: 200, height: 4 }, lines, runs)
    assert.equal(snapped?.kind, 'underline')
    assert.equal(snapped?.boxes[0].y, 700)
  })

  await test('a stroke over two lines marks both; one in the margin, or far taller than its lines, stays ink', () => {
    const both = snapStroke({ x: 90, y: 684, width: 120, height: 30 }, lines, runs)
    assert.equal(both?.kind, 'highlight')
    assert.equal(both?.boxes.length, 2)
    assert.equal(snapStroke({ x: 10, y: 690, width: 40, height: 18 }, lines, runs), null, 'the margin has no words')
    assert.equal(snapStroke({ x: 90, y: 600, width: 120, height: 130 }, lines, runs), null, 'a scribble down the page')
    assert.equal(snapStroke({ x: 100, y: 697, width: 150, height: 18 }, [], []), null, 'a page without words')
  })

  await test('the page’s own keys are written the way each desktop writes them', () => {
    assert.equal(shortcutText('⇧⌘G', 'darwin'), '⇧⌘G')
    assert.equal(shortcutText('⇧⌘G', 'win32'), 'Ctrl+Shift+G')
    assert.equal(shortcutText('⌥⌘G', 'linux'), 'Ctrl+Alt+G')
    assert.equal(shortcutText('⇧A', 'win32'), 'Shift+A')
    assert.equal(shortcutText('⌘D', 'linux'), 'Ctrl+D')
    assert.equal(shortcutText('⇧⌘]', 'win32'), 'Ctrl+Shift+]')
    assert.equal(shortcutText('⌫', 'win32'), 'Delete')
  })

  await test('font families are read out of what the desktop lists', () => {
    assert.deepEqual(familiesFromFontconfig('DejaVu Sans,DejaVu Sans Condensed\nNoto Sans CJK KR,Noto Sans CJK KR Regular\nUbuntu\n'),
      ['DejaVu Sans', 'Noto Sans CJK KR', 'Ubuntu'])
    assert.equal(familyFromRegistryName('Arial Bold (TrueType)'), 'Arial')
    assert.equal(familyFromRegistryName('Malgun Gothic Semilight (TrueType)'), 'Malgun Gothic')
    assert.equal(familyFromRegistryName('Cambria & Cambria Math (TrueType)'), 'Cambria')
    assert.equal(familyFromRegistryName('Segoe UI Variable (TrueType)'), 'Segoe UI Variable')
  })
}
