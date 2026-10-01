/**
 * What Return, Tab and `[[` do in a note (`shared/noteBlocks.ts`) — the
 * Mac's `NoteMarkdown.Block(line:)`, `insertNewline`, `insertTab` and
 * `openWikiLink(in:)`, case by case.
 */
import assert from 'node:assert/strict'
import { acceptWikiLink, backspaceEdit, blockOf, continuation, indentEdit, openWikiLink, returnEdit, todoShortcutEdit, toggleEmphasisEdit, wrapEdit, type LineEdit, type SelectionEdit } from '../shared/noteBlocks.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const applied = (text: string, edit: LineEdit | null) =>
  edit ? { text: text.slice(0, edit.from) + edit.insert + text.slice(edit.to), caret: edit.caret } : null

export async function noteBlocksSuite(test: Test, suite: (name: string) => void) {
  suite('Lists and links in a note, as the Mac types them')

  await test('a line is read for its marker the way the Mac reads it', () => {
    const cases: [string, string, string, string, number][] = [
      ['plain words', 'plain', '', 'plain words', 0],
      ['- item', 'bullet', '- ', 'item', 0],
      ['  * nested', 'bullet', '  * ', 'nested', 1],
      ['+\titem', 'bullet', '+\t', 'item', 0],
      ['3. third', 'ordered', '3. ', 'third', 0],
      ['12) twelfth', 'ordered', '12) ', 'twelfth', 0],
      ['1234. not a list', 'plain', '', '1234. not a list', 0],
      ['- [ ] to do', 'task', '- [ ] ', 'to do', 0],
      ['- [x] done', 'task', '- [x] ', 'done', 0],
      ['## Heading', 'heading', '## ', 'Heading', 0],
      ['#tag is no heading', 'plain', '', '#tag is no heading', 0],
      ['> quoted', 'quote', '> ', 'quoted', 0],
      ['>### Section', 'quote', '>### ', 'Section', 0],
      ['-no space', 'plain', '', '-no space', 0],
    ]
    for (const [line, kind, marker, content, indent] of cases) {
      const block = blockOf(line)
      assert.deepEqual([block.type.kind, block.marker, block.content, block.indent], [kind, marker, content, indent], line)
    }
    assert.equal(continuation(blockOf('  7. seven')), '  8. ')
    assert.equal(continuation(blockOf('- [x] done')), '- [ ] ')
    assert.equal(continuation(blockOf('## Heading')), '')
  })

  await test('Return continues a list, and an empty item ends it', () => {
    const at = (text: string) => returnEdit(text, text.length)
    assert.deepEqual(applied('- one', at('- one')), { text: '- one\n- ', caret: 8 })
    assert.deepEqual(applied('1. one', at('1. one')), { text: '1. one\n2. ', caret: 10 })
    assert.deepEqual(applied('  - [x] done', at('  - [x] done')), { text: '  - [x] done\n  - [ ] ', caret: 21 })
    assert.deepEqual(applied('> quoted', at('> quoted')), { text: '> quoted\n> ', caret: 11 })
    // An empty item: the marker goes, and the line breaks.
    assert.deepEqual(applied('- one\n- ', at('- one\n- ')), { text: '- one\n\n', caret: 7 })
    // An empty nested item steps out a level first (Notion).
    assert.deepEqual(applied('- one\n  - ', at('- one\n  - ')), { text: '- one\n- ', caret: 8 })
    assert.deepEqual(applied('1. a\n    3. ', at('1. a\n    3. ')), { text: '1. a\n  3. ', caret: 10 })
    assert.equal(at('plain'), null)
    assert.equal(at('## Heading'), null)
    // In the middle of an item, the rest of it goes onto the new line.
    const text = '- one two'
    assert.deepEqual(applied(text, returnEdit(text, 5)), { text: '- one\n-  two', caret: 8 })
  })

  await test('Tab indents a list item and Shift-Tab takes it back', () => {
    const text = 'intro\n- item'
    assert.deepEqual(applied(text, indentEdit(text, text.length, 1)), { text: 'intro\n  - item', caret: text.length + 2 })
    const indented = 'intro\n  - item'
    assert.deepEqual(applied(indented, indentEdit(indented, indented.length, -1)), { text: 'intro\n- item', caret: indented.length - 2 })
    // At the left already: the key is taken, nothing moves.
    assert.deepEqual(applied(text, indentEdit(text, text.length, -1)), { text, caret: text.length })
    assert.equal(indentEdit('plain words', 3, 1), null)
    assert.equal(indentEdit('> quote', 3, 1), null)
  })

  await test('a [[ open on the caret line is read up to the caret, and a link goes in with its title', () => {
    assert.deepEqual(openWikiLink('see [[entro', 11), { from: 4, query: 'entro' })
    assert.equal(openWikiLink('see [[done]] after', 18), null)
    assert.equal(openWikiLink('[[open\nnext line', 16), null)
    assert.deepEqual(openWikiLink('a [[x]] b [[', 12), { from: 10, query: '' })
    const text = 'see [[ent]] more'
    assert.deepEqual(applied(text, acceptWikiLink(text, 9, '202609281200', 'Entropy')), { text: 'see [[202609281200|Entropy]] more', caret: 28 })
    const bare = 'see [[ent'
    assert.deepEqual(applied(bare, acceptWikiLink(bare, 9, '202609281200', 'Entropy')), { text: 'see [[202609281200|Entropy]]', caret: 28 })
  })

  await test('Backspace right after a marker steps a nested item out, and takes the marker off one at the left', () => {
    const nested = 'intro\n  - item'
    assert.deepEqual(applied(nested, backspaceEdit(nested, 10)), { text: 'intro\n- item', caret: 8 })
    assert.deepEqual(applied('- item', backspaceEdit('- item', 2)), { text: 'item', caret: 0 })
    assert.deepEqual(applied('- [ ] todo', backspaceEdit('- [ ] todo', 6)), { text: 'todo', caret: 0 })
    assert.deepEqual(applied('3. third', backspaceEdit('3. third', 3)), { text: 'third', caret: 0 })
    assert.deepEqual(applied('> quoted', backspaceEdit('> quoted', 2)), { text: 'quoted', caret: 0 })
    assert.deepEqual(applied('## Head', backspaceEdit('## Head', 3)), { text: 'Head', caret: 0 })
    // Anywhere else, the ordinary Backspace.
    assert.equal(backspaceEdit('- item', 3), null)
    assert.equal(backspaceEdit('- item', 1), null)
    assert.equal(backspaceEdit('plain', 3), null)
    assert.equal(backspaceEdit('  - item', 2), null)
  })

  const emphasised = (text: string, edit: SelectionEdit) => ({
    text: text.slice(0, edit.from) + edit.insert + text.slice(edit.to),
    selected: [edit.selectFrom, edit.selectTo] as [number, number],
  })

  await test('⌘B, ⌘I and ⌘E put a mark around the selection and take it off again', () => {
    assert.deepEqual(emphasised('say word here', toggleEmphasisEdit('say word here', 4, 8, '**')), { text: 'say **word** here', selected: [6, 10] })
    // The marks taken in by the selection, or standing just outside it: both come off.
    assert.deepEqual(emphasised('say **word** here', toggleEmphasisEdit('say **word** here', 4, 12, '**')), { text: 'say word here', selected: [4, 8] })
    assert.deepEqual(emphasised('say **word** here', toggleEmphasisEdit('say **word** here', 6, 10, '**')), { text: 'say word here', selected: [4, 8] })
    assert.deepEqual(emphasised('a *b* c', toggleEmphasisEdit('a *b* c', 3, 4, '*')), { text: 'a b c', selected: [2, 3] })
    assert.deepEqual(emphasised('a `b` c', toggleEmphasisEdit('a `b` c', 2, 5, '`')), { text: 'a b c', selected: [2, 3] })
    // A selection given backwards is the same selection.
    assert.deepEqual(emphasised('say word', toggleEmphasisEdit('say word', 8, 4, '*')), { text: 'say *word*', selected: [5, 9] })
    // «**bold**» is not in italics: ⌘I adds the third star rather than taking one away.
    assert.deepEqual(emphasised('**bold**', toggleEmphasisEdit('**bold**', 0, 8, '*')), { text: '***bold***', selected: [1, 9] })
    assert.deepEqual(emphasised('***both***', toggleEmphasisEdit('***both***', 0, 10, '*')), { text: '**both**', selected: [0, 8] })
    assert.deepEqual(emphasised('***both***', toggleEmphasisEdit('***both***', 0, 10, '**')), { text: '*both*', selected: [0, 6] })
    // Nothing selected: an empty pair with the caret between, and the pair gone again.
    assert.deepEqual(emphasised('ab', toggleEmphasisEdit('ab', 1, 1, '**')), { text: 'a****b', selected: [3, 3] })
    assert.deepEqual(emphasised('a****b', toggleEmphasisEdit('a****b', 3, 3, '**')), { text: 'ab', selected: [1, 1] })
    assert.deepEqual(emphasised('a``b', toggleEmphasisEdit('a``b', 2, 2, '`')), { text: 'ab', selected: [1, 1] })
  })

  await test('an opening character typed over a selection wraps it, and the words stay selected', () => {
    const pairs: [string, string][] = [['(', ')'], ['[', ']'], ['{', '}'], ['"', '"'], ["'", "'"], ['`', '`'], ['*', '*'], ['_', '_'], ['$', '$'], ['~', '~']]
    for (const [open, close] of pairs) {
      assert.deepEqual(emphasised('say word here', wrapEdit('say word here', 4, 8, open)!), { text: `say ${open}word${close} here`, selected: [5, 9] }, open)
    }
    assert.deepEqual(emphasised('say word', wrapEdit('say word', 8, 4, '(')!), { text: 'say (word)', selected: [5, 9] })
    assert.equal(wrapEdit('say word', 4, 8, 'x'), null)
    assert.equal(wrapEdit('say word', 4, 8, ')'), null)
    assert.equal(wrapEdit('say word', 4, 4, '('), null)
  })

  await test('«[]» and a space at the start of a line become a checkbox', () => {
    assert.deepEqual(applied('[]', todoShortcutEdit('[]', 2)), { text: '- [ ] ', caret: 6 })
    assert.deepEqual(applied('a\n  []', todoShortcutEdit('a\n  []', 6)), { text: 'a\n  - [ ] ', caret: 10 })
    assert.deepEqual(applied('[]tail', todoShortcutEdit('[]tail', 2)), { text: '- [ ] tail', caret: 6 })
    assert.equal(todoShortcutEdit('x[]', 3), null)
    assert.equal(todoShortcutEdit('[] ', 3), null)
    assert.equal(todoShortcutEdit('[', 1), null)
  })
}
