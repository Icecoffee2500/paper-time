/**
 * Fenced code in a note, as the Mac finds it — `note-code.json` is the Mac's
 * own `NoteCode` (`Scripts/note-code-fixture.swift`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { CODE_SURFACE, codeBlocks, codeLanguageName, codeOf, codeRowAt, openingFence } from '../shared/noteCode.js'
import { codeIndentEdit, codeReturnEdit, fenceTypingEdit, pairEdit, returnEdit, wrapEdit, type LineEdit } from '../shared/noteBlocks.js'
import { codeBlockHTML, noteBodyHTML } from '../renderer/ui/note/noteHTML.js'
import { CODE_PALETTE, type CodeRole } from '../shared/codeHighlight.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Fixture {
  notes: { text: string; blocks: { range: number[]; open: number[]; close: number[] | null; lines: number[][]; language: string; code: string }[] }[]
  fences: { line: string; fence: { character: string; length: number; language: string } | null }[]
  names: { language: string; name: string }[]
}

export async function noteCodeSuite(test: Test, suite: (name: string) => void) {
  suite('Fenced code in a note, found as the Mac finds it')
  const file = path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures', 'note-code.json')
  const fixture = JSON.parse(fs.readFileSync(file, 'utf8')) as Fixture
  const span = (range: { from: number; to: number }) => [range.from, range.to]

  await test(`${fixture.notes.length} notes: the same blocks, lines and languages`, () => {
    for (const note of fixture.notes) {
      const blocks = codeBlocks(note.text)
      assert.equal(blocks.length, note.blocks.length, JSON.stringify(note.text))
      blocks.forEach((block, index) => {
        const expected = note.blocks[index]
        assert.deepEqual(span(block.range), expected.range, note.text)
        assert.deepEqual(span(block.open), expected.open, note.text)
        assert.deepEqual(block.close ? span(block.close) : null, expected.close, note.text)
        assert.deepEqual(block.lines.map(span), expected.lines, note.text)
        assert.equal(block.language, expected.language, note.text)
        assert.equal(codeOf(block, note.text), expected.code, note.text)
      })
    }
  })

  await test(`${fixture.fences.length} lines: the same fences; ${fixture.names.length} languages: the same names`, () => {
    for (const one of fixture.fences) assert.deepEqual(openingFence(one.line), one.fence, JSON.stringify(one.line))
    for (const one of fixture.names) assert.equal(codeLanguageName(one.language), one.name, one.language)
  })

  suite('Fenced code, written as a code editor writes it')
  /** The text with the edit made, and `|` where the caret is left. */
  const made = (text: string, edit: LineEdit | null) => {
    if (!edit) return null
    const after = text.slice(0, edit.from) + edit.insert + text.slice(edit.to)
    return after.slice(0, edit.caret) + '|' + after.slice(edit.caret)
  }
  /** `|` in the text is the caret. */
  const at = (marked: string): [string, number] => [marked.replace('|', ''), marked.indexOf('|')]

  await test('every line of a block knows what it is in it', () => {
    const text = 'a\n```py\nx = 1\n\n```\nb\n~~~\nopen'
    const row = (caret: number) => {
      const one = codeRowAt(text, caret)
      return one ? `${one.role} ${one.number}${one.isLast ? ' last' : ''}` : null
    }
    assert.equal(row(0), null)
    assert.equal(row(text.indexOf('```py') + 2), 'header 0')
    assert.equal(row(text.indexOf('x = 1')), 'line 1')
    assert.equal(row(text.indexOf('\n\n```') + 1), 'line 2')
    assert.equal(row(text.indexOf('```\nb') + 1), 'close 0 last')
    assert.equal(row(text.indexOf('b\n~~~')), null)
    assert.equal(row(text.indexOf('~~~')), 'header 0')
    assert.equal(row(text.length), 'line 1 last')
  })

  await test('Return on a fence just typed closes it, and the caret waits inside', () => {
    assert.equal(made(...((t, c) => [t, codeReturnEdit(t, c)] as const)(...at('x\n```python|'))), 'x\n```python\n|\n```')
    assert.equal(made(...((t, c) => [t, codeReturnEdit(t, c)] as const)(...at('  ~~~~|\nnext'))), '  ~~~~\n|\n  ~~~~\nnext')
    // Closed already: the plain new line.
    assert.equal(codeReturnEdit(...at('```py|\nx\n```')), null)
    // Typed above another block, whose closing fence it would take: closed.
    assert.equal(made(...((t, c) => [t, codeReturnEdit(t, c)] as const)(...at('```|\n\n```js\nx\n```'))), '```\n|\n```\n\n```js\nx\n```')
    // In the middle of the fence: the plain new line.
    assert.equal(codeReturnEdit(...at('```py|thon')), null)
  })

  await test('Return in code keeps the indent, and adds one after a colon or a bracket', () => {
    const edit = (marked: string) => made(...((t, c) => [t, codeReturnEdit(t, c)] as const)(...at(marked)))
    assert.equal(edit('```\n    x = 1|\n```'), '```\n    x = 1\n    |\n```')
    assert.equal(edit('```\ndef f(x):|\n```'), '```\ndef f(x):\n    |\n```')
    assert.equal(edit('```\n  call(| \n```'), '```\n  call(\n      | \n```')
    assert.equal(codeReturnEdit(...at('```\nx\n```|')), null)
    // A list's Return is not code's: `- x` in code is no bullet.
    assert.equal(returnEdit(...at('```\n- x|\n```')), null)
    assert.equal(made(...((t, c) => [t, returnEdit(t, c)] as const)(...at('- x|'))), '- x\n- |')
  })

  await test('Tab and Shift-Tab in code: four spaces, or the selected lines in and out', () => {
    const text = '```\na\n  b\n```'
    const a = text.indexOf('a')
    assert.deepEqual(codeIndentEdit(text, a, a, 1), { from: a, to: a, insert: '    ', selectFrom: a + 4, selectTo: a + 4 })
    const lines = codeIndentEdit(text, a, text.indexOf('b') + 1, 1)
    assert.equal(lines?.insert, '    a\n      b')
    assert.equal(codeIndentEdit(text, text.indexOf('b'), text.indexOf('b'), -1)?.insert, 'b')
    assert.equal(codeIndentEdit(text, 0, 0, 1), null, 'not on a fence')
    assert.equal(codeIndentEdit('plain', 0, 0, 1), null, 'not outside code')
  })

  await test('the third backtick of a fence is a fence, not a fourth mark', () => {
    const typed = (marked: string, key: string) => {
      const [text, caret] = at(marked)
      return made(text, fenceTypingEdit(text, caret, key) ?? pairEdit(text, caret, key) ?? { from: caret, to: caret, insert: key, caret: caret + 1 })
    }
    assert.equal(typed('|', '`'), '`|`')
    assert.equal(typed('`|`', '`'), '``|')
    assert.equal(typed('``|', '`'), '```|')
    assert.equal(typed('~~|~~', '~'), '~~~|')
    assert.equal(typed('   ``|', '`'), '   ```|')
    // Not a fence: words before it, or four spaces.
    assert.equal(fenceTypingEdit(...at('a ``|'), '`'), null)
    assert.equal(fenceTypingEdit(...at('    ``|'), '`'), null)
  })

  await test('pairs in code are a code editor\'s: brackets and quotes, never Markdown\'s marks', () => {
    const pair = (marked: string, key: string) => made(...((t, c) => [t, pairEdit(t, c, key)] as const)(...at(marked)))
    assert.equal(pair('```\na |\n```', '*'), null)
    assert.equal(pair('```\na |\n```', '$'), null)
    assert.equal(pair('```\na |\n```', '_'), null)
    assert.equal(pair('```\ng|\n```', '('), '```\ng(|)\n```')
    assert.equal(pair('```\ns = |\n```', '"'), '```\ns = "|"\n```')
    assert.equal(pair("```\ns = |\n```", "'"), "```\ns = '|'\n```")
    assert.equal(pair('```\nit|\n```', "'"), null, 'an apostrophe after a word')
    assert.equal(pair('```\nf(x|)\n```', ')'), '```\nf(x)|\n```')
    // In prose, as before: a star between non-words brings its pair.
    assert.equal(pair('a |', '*'), 'a *|*')
    // Over a selection in code, a star replaces it; a bracket wraps it.
    const text = '```\nabc\n```'
    const from = text.indexOf('abc')
    assert.equal(wrapEdit(text, from, from + 3, '*'), null)
    assert.equal(wrapEdit(text, from, from + 3, '(')?.insert, '(abc)')
  })

  suite('Fenced code, printed')
  await test('a block prints once, whole: its language, its numbers, its colours', () => {
    const source = 'before\n```python\ndef f():\n    return 1 < 2\n```\nafter'
    const block = codeBlocks(source)[0]
    const html = codeBlockHTML(block, source)
    assert.ok(html.includes('<div class="nm-codeblock-head"><span class="nm-codeblock-lang">Python</span></div>'), html)
    assert.ok(html.includes('<span class="nm-codeblock-n">1</span>') && html.includes('<span class="nm-codeblock-n">2</span>'), html)
    assert.ok(html.includes('<span class="nm-tok-keyword">def</span>'), html)
    assert.ok(html.includes('1 &lt; 2') || html.includes('&lt;'), html)
    const body = noteBodyHTML(source, { set: () => null })
    assert.equal(body.split('nm-codeblock"').length - 1, 1, body)
    assert.ok(!body.includes('```'), body)
    assert.ok(body.includes('before') && body.includes('after'), body)
  })

  await test('a block with no language prints no chip', () => {
    const source = '```\nplain\n```'
    const html = codeBlockHTML(codeBlocks(source)[0], source)
    assert.ok(html.includes('<div class="nm-codeblock-head"></div>'), html)
  })

  await test('the box is the Mac\'s box: its wash and its copy pill, light and dark', () => {
    const css = fs.readFileSync(path.join(process.cwd(), 'src/renderer/style.css'), 'utf8')
    const light = /:root \{([\s\S]*?)\n\}/.exec(css)?.[1] ?? ''
    const dark = /:root\[data-theme='dark'\] \{([\s\S]*?)\n\}/.exec(css)?.[1] ?? ''
    const token = (block: string, name: string) => new RegExp(`--codeblock-${name}:\\s*([^;]+);`).exec(block)?.[1].trim()
    for (const [name, key] of [['fill', 'fill'], ['pill', 'pill'], ['pill-edge', 'pillEdge']] as const) {
      assert.equal(token(light, name), CODE_SURFACE[key].light, `--codeblock-${name} light`)
      assert.equal(token(dark, name), CODE_SURFACE[key].dark, `--codeblock-${name} dark`)
    }
    // The Mac's, read from its source: `dark ? <colour> : <light colour>`.
    const swift = fs.readFileSync(path.join(process.cwd(), '..', 'App/Views/Notes/NoteTypography.swift'), 'utf8')
    const rgba = (r: string, g: string, b: string, a: string) => `rgba(${r}, ${g}, ${b}, ${a})`
    const srgb = String.raw`NSColor\(srgbRed: (\d+) / 255, green: (\d+) / 255, blue: (\d+) / 255, alpha: ([\d.]+)\)`
    const fill = new RegExp(String.raw`static var fill: NSColor \{[^}]*?\? ${srgb}\s*: ${srgb}`).exec(swift)
    assert.ok(fill, 'NoteCodeStyle.Block.fill')
    assert.equal(rgba(fill[1], fill[2], fill[3], fill[4]), CODE_SURFACE.fill.dark)
    assert.equal(rgba(fill[5], fill[6], fill[7], fill[8]), CODE_SURFACE.fill.light)
    const white = (w: string, a: string) => (w === '1' ? `rgba(255, 255, 255, ${a})` : `rgba(0, 0, 0, ${a})`)
    const pill = /static var pillFill: NSColor \{[^}]*?\? NSColor\(white: (\d), alpha: ([\d.]+)\)\s*: NSColor\(white: (\d), alpha: ([\d.]+)\)/.exec(swift)
    assert.ok(pill, 'NoteCodeStyle.Block.pillFill')
    assert.equal(white(pill[1], pill[2]), CODE_SURFACE.pill.dark)
    assert.equal(white(pill[3], pill[4]), CODE_SURFACE.pill.light)
    const edge = /static var pillEdge: NSColor \{[^}]*?\? \.clear\s*: NSColor\(white: (\d), alpha: ([\d.]+)\)/.exec(swift)
    assert.ok(edge, 'NoteCodeStyle.Block.pillEdge')
    assert.equal(CODE_SURFACE.pillEdge.dark, 'transparent')
    assert.equal(white(edge[1], edge[2]), CODE_SURFACE.pillEdge.light)
  })

  await test('the window paints with the palette the Mac paints with', () => {
    const css = fs.readFileSync(path.join(process.cwd(), 'src/renderer/style.css'), 'utf8')
    const light = /:root \{([\s\S]*?)\n\}/.exec(css)?.[1] ?? ''
    const dark = /:root\[data-theme='dark'\] \{([\s\S]*?)\n\}/.exec(css)?.[1] ?? ''
    const value = (block: string, role: string) => new RegExp(`--code-tok-${role}:\\s*(#[0-9a-f]{6})`).exec(block)?.[1]
    for (const [role, colours] of Object.entries(CODE_PALETTE) as [CodeRole, { light: string; dark: string }][]) {
      assert.equal(value(light, role), colours.light, `${role} light`)
      assert.equal(value(dark, role), colours.dark, `${role} dark`)
    }
  })
}
