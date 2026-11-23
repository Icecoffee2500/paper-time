/**
 * The format panel's edits, as the Mac makes them — `note-format.json` is
 * the Mac's own `NoteFormat`, asked case by case
 * (`Scripts/note-format-fixture.sh`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { formatState, insertPicture, setAlignment, setList, setParagraph, setStyle, tidyLine, type FormatEdit, type ListKind, type Paragraph } from '../shared/noteFormat.js'
import { cssOf, styleFromCSS, type NoteAlignment } from '../shared/noteSpan.js'
import { inlineTokens } from '../shared/noteMarkdown.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Case {
  source: string
  from: number
  to: number
  op: string
  value?: string
  edit?: FormatEdit
  tidied?: string
  state?: { css: string; paragraph: string; list: string; alignment: string; size: number; ownSize: number }
}

export async function noteFormatSuite(test: Test, suite: (name: string) => void) {
  suite('A note’s format is edited as the Mac edits it')
  const file = path.resolve('..', 'Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/note-format.json')
  const cases = JSON.parse(fs.readFileSync(file, 'utf8')) as Case[]

  const answer = (one: Case): FormatEdit | null => {
    const value = one.value ?? ''
    const on = value === '1'
    switch (one.op) {
      case 'color': return setStyle({ color: value || null }, one.source, one.from, one.to)
      case 'size': return setStyle({ size: value ? Number(value) : null }, one.source, one.from, one.to)
      case 'family': return setStyle({ family: value || null }, one.source, one.from, one.to)
      case 'highlight': return setStyle({ highlight: value || null }, one.source, one.from, one.to)
      case 'bold': return setStyle({ bold: on }, one.source, one.from, one.to)
      case 'italic': return setStyle({ italic: on }, one.source, one.from, one.to)
      case 'underline': return setStyle({ underline: on }, one.source, one.from, one.to)
      case 'strike': return setStyle({ strike: on }, one.source, one.from, one.to)
      case 'para': return setParagraph(value as Paragraph, one.source, one.from, one.to)
      case 'list': return setList(value as ListKind, one.source, one.from, one.to)
      case 'align': return setAlignment(value as NoteAlignment, one.source, one.from, one.to)
      case 'picture': return insertPicture(value, one.source, one.to)
      default: return null
    }
  }
  const label = (one: Case) => `${one.op}${one.value !== undefined ? `=${one.value}` : ''} ${JSON.stringify(`${one.source.slice(0, one.from)}⟦${one.source.slice(one.from, one.to)}⟧${one.source.slice(one.to)}`)}`

  await test('every change of characters, paragraph, list, alignment and picture is the Mac’s edit', () => {
    let asked = 0
    for (const one of cases) {
      if (one.op === 'tidy' || one.op === 'state') continue
      asked += 1
      const edit = answer(one)
      if (!one.edit) {
        assert.equal(edit, null, label(one))
        continue
      }
      assert.ok(edit, label(one))
      assert.deepEqual(edit, one.edit, label(one))
    }
    assert.ok(asked > 3000)
  })

  await test('the panel reads the same format where the selection is', () => {
    let asked = 0
    for (const one of cases) {
      if (!one.state) continue
      asked += 1
      const state = formatState(one.source, one.from, one.to)
      assert.deepEqual(
        { css: cssOf(state.style), paragraph: state.paragraph, list: state.list, alignment: state.alignment, size: state.size, ownSize: state.ownSize },
        one.state, label(one),
      )
    }
    assert.ok(asked > 200)
  })

  await test('a line whose tags lost their pair is put in order the same way', () => {
    for (const one of cases) {
      if (one.op === 'tidy') assert.equal(tidyLine(one.source), one.tidied, JSON.stringify(one.source))
    }
  })

  await test('a style is written and read back as the same bytes', () => {
    for (const css of ['color:#d62e54', 'color:#1f70d9;background-color:#fff3b0;font-size:20px;font-family:Georgia;font-weight:bold;font-style:italic;text-decoration:underline line-through', 'font-size:17.5px']) {
      assert.equal(cssOf(styleFromCSS(css)), css)
    }
    assert.equal(styleFromCSS('background:#ffee99').highlight, 'yellow')
    assert.equal(styleFromCSS('COLOR: #F00; font-weight: 700').color, '#ff0000')
    assert.equal(styleFromCSS('COLOR: #F00; font-weight: 700').bold, true)
  })

  await test('a highlight named in the middle of a word is read, and a bare one is not', () => {
    const kinds = (text: string) => inlineTokens(text).map((token) => token.kind)
    assert.deepEqual(kinds('c=={green}ontinuous ac==tion'), ['highlight'])
    assert.deepEqual(kinds('a==b && c==d'), [])
    assert.deepEqual(kinds('x <span style="color:#d62e54">y</span> ![](.assets/a.png) <p align="center">'), ['styled', 'image', 'hidden'])
  })
}
