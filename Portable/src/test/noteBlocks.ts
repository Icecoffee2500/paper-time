/**
 * What Return, Tab and `[[` do in a note (`shared/noteBlocks.ts`) — the
 * Mac's `NoteMarkdown.Block(line:)`, `insertNewline`, `insertTab` and
 * `openWikiLink(in:)`, case by case.
 */
import assert from 'node:assert/strict'
import { acceptWikiLink, backspaceEdit, blockOf, continuation, homeTarget, indentEdit, openWikiLink, pairBackspaceEdit, pairEdit, returnEdit, todoShortcutEdit, toggleChildrenEnd, toggleEmphasisEdit, toggleShortcutEdit, wrapEdit, type LineEdit, type SelectionEdit } from '../shared/noteBlocks.js'

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
      // «+ » is a toggle; «+» with a tab is still the bullet it always was.
      ['+ toggle', 'toggle', '+ ', 'toggle', 0],
      ['    + nested toggle', 'toggle', '    + ', 'nested toggle', 2],
      ['+ [ ] still a task', 'task', '+ [ ] ', 'still a task', 0],
    ]
    for (const [line, kind, marker, content, indent] of cases) {
      const block = blockOf(line)
      assert.deepEqual([block.type.kind, block.marker, block.content, block.indent], [kind, marker, content, indent], line)
    }
    assert.equal(continuation(blockOf('  7. seven')), '  8. ')
    assert.equal(continuation(blockOf('- [x] done')), '- [ ] ')
    assert.equal(continuation(blockOf('## Heading')), '')
    assert.equal(continuation(blockOf('  + toggle')), '    ')
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
    assert.deepEqual(applied('+ toggle', indentEdit('+ toggle', 8, 1)), { text: '  + toggle', caret: 10 })
  })

  await test('a toggle opens its children under it, and Return twice steps back out', () => {
    const at = (text: string) => returnEdit(text, text.length)
    // Return at the end of a header: a child line, one step in, plain.
    assert.deepEqual(applied('+ Title', at('+ Title')), { text: '+ Title\n  ', caret: 10 })
    assert.deepEqual(applied('  + Title', at('  + Title')), { text: '  + Title\n    ', caret: 14 })
    // Return on an empty child line: out to the toggle's own level.
    assert.deepEqual(applied('+ Title\n  ', at('+ Title\n  ')), { text: '+ Title\n', caret: 8 })
    assert.deepEqual(applied('  + Title\n    child\n    ', at('  + Title\n    child\n    ')), { text: '  + Title\n    child\n  ', caret: 22 })
    // An empty indented line under no toggle, or one as deep as the toggle, is the editor's own Return.
    assert.equal(at('- item\n  '), null)
    assert.equal(at('+ Title\n  child\n'), null)
    assert.equal(at('plain\n  '), null)
    // Backspace at the words takes the marker off, as for any marker.
    assert.deepEqual(applied('+ Title', backspaceEdit('+ Title', 2)), { text: 'Title', caret: 0 })
    // The children: every deeper line, blank lines between them included, up to the first that is not.
    const note = '+ Title\n  one\n\n  two\n+ Next\n  other'
    assert.equal(toggleChildrenEnd(note, 0), note.indexOf('two') + 3)
    assert.equal(toggleChildrenEnd(note, note.indexOf('+ Next')), note.length)
    assert.equal(toggleChildrenEnd('+ Alone\nplain', 0), null)
    assert.equal(toggleChildrenEnd('+ Alone\n\n', 0), null)
  })

  await test('«--» and a space at the start of a line become a toggle', () => {
    assert.deepEqual(applied('--', toggleShortcutEdit('--', 2)), { text: '+ ', caret: 2 })
    assert.deepEqual(applied('a\n  --', toggleShortcutEdit('a\n  --', 6)), { text: 'a\n  + ', caret: 6 })
    assert.equal(toggleShortcutEdit('x--', 3), null)
    assert.equal(toggleShortcutEdit('-', 1), null)
    assert.equal(toggleShortcutEdit('---', 3), null)
  })

  /** Types `text` character by character through `pairEdit`, as the editor would; `trace` has the text after each key, the caret as «|». */
  const typed = (start: string, caret: number, keys: string, trace?: string[]) => {
    let text = start
    for (const key of keys) {
      const edit = pairEdit(text, caret, key)
      if (edit) {
        text = text.slice(0, edit.from) + edit.insert + text.slice(edit.to)
        caret = edit.caret
      } else {
        text = text.slice(0, caret) + key + text.slice(caret)
        caret += 1
      }
      trace?.push(`${text.slice(0, caret)}|${text.slice(caret)}`)
    }
    return { text, caret }
  }

  await test('brackets and quotes bring their closers, step over them, and go together under Backspace', () => {
    // An opener: both, the caret between.
    assert.deepEqual(typed('', 0, '('), { text: '()', caret: 1 })
    assert.deepEqual(typed('ab', 1, '['), { text: 'a[]b', caret: 2 })
    assert.deepEqual(typed('', 0, '{'), { text: '{}', caret: 1 })
    // A closer already there is stepped over, not doubled.
    assert.deepEqual(typed('', 0, '(x)'), { text: '(x)', caret: 3 })
    assert.deepEqual(typed('"|"'.replace('|', ''), 1, '"'), { text: '""', caret: 2 })
    // The symmetric ones pair only between non-words: «don't» and «5$» stay as typed.
    assert.deepEqual(typed('', 0, '$'), { text: '$$', caret: 1 })
    assert.deepEqual(typed('don', 3, "'"), { text: "don'", caret: 4 })
    assert.deepEqual(typed('don', 3, '"'), { text: 'don"', caret: 4 })
    assert.deepEqual(typed('x', 1, '$'), { text: 'x$', caret: 2 })
    assert.deepEqual(typed('5', 1, '$'), { text: '5$', caret: 2 })
    assert.deepEqual(typed('x', 0, '$'), { text: '$x', caret: 1 })
    assert.deepEqual(typed('', 0, '`'), { text: '``', caret: 1 })
    // «**bold**» typed star by star ends as «**bold**», the caret after it —
    // the second star doubles the first rather than stepping over it (the Mac's trace).
    assert.deepEqual(typed('', 0, '**bold**'), { text: '**bold**', caret: 8 })
    const stars: string[] = []
    typed('', 0, '**b**', stars)
    assert.deepEqual(stars, ['*|*', '**|**', '**b|**', '**b*|*', '**b**|'])
    const dollars: string[] = []
    typed('', 0, '$$x$$', dollars)
    assert.deepEqual(dollars, ['$|$', '$$|$$', '$$x|$$', '$$x$|$', '$$x$$|'])
    // Quotes and backticks do not double.
    const quotes: string[] = []
    typed('', 0, '""', quotes)
    assert.deepEqual(quotes, ['"|"', '""|'])
    const ticks: string[] = []
    typed('', 0, '``', ticks)
    assert.deepEqual(ticks, ['`|`', '``|'])
    // A star after a word doubles nothing: it steps over.
    assert.deepEqual(typed('**b**', 4, '*'), { text: '**b**', caret: 5 })
    assert.deepEqual(typed('say  here', 4, '*word*'), { text: 'say *word* here', caret: 10 })
    assert.deepEqual(typed('', 0, '$x^2$'), { text: '$x^2$', caret: 5 })
    assert.equal(pairEdit('', 0, 'a'), null)
    assert.equal(pairEdit('', 0, 'ab'), null)
    // Backspace between an empty pair takes both; anywhere else it is the ordinary key.
    assert.deepEqual(applied('()', pairBackspaceEdit('()', 1)), { text: '', caret: 0 })
    assert.deepEqual(applied('a$$b', pairBackspaceEdit('a$$b', 2)), { text: 'ab', caret: 1 })
    assert.deepEqual(applied('[]', pairBackspaceEdit('[]', 1)), { text: '', caret: 0 })
    assert.equal(pairBackspaceEdit('(x)', 1), null)
    assert.equal(pairBackspaceEdit('()', 0), null)
    assert.equal(pairBackspaceEdit('()', 2), null)
    assert.equal(pairBackspaceEdit("''", 1), null)
  })

  await test('Home on a marked line goes to the words, then to the very start', () => {
    assert.equal(homeTarget('- item', 6), 2)
    assert.equal(homeTarget('- item', 2), 0)
    assert.equal(homeTarget('- item', 1), 0)
    assert.equal(homeTarget('  - [ ] todo', 12), 8)
    assert.equal(homeTarget('## Heading', 10), 3)
    assert.equal(homeTarget('## Heading', 3), 0)
    assert.equal(homeTarget('> quoted', 5), 2)
    assert.equal(homeTarget('+ toggle', 8), 2)
    assert.equal(homeTarget('plain words', 5), null)
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
    // ⌘⇧M: a formula's dollars, the same way.
    assert.deepEqual(emphasised('say x here', toggleEmphasisEdit('say x here', 4, 5, '$')), { text: 'say $x$ here', selected: [5, 6] })
    assert.deepEqual(emphasised('say $x$ here', toggleEmphasisEdit('say $x$ here', 4, 7, '$')), { text: 'say x here', selected: [4, 5] })
    assert.deepEqual(emphasised('say $x$ here', toggleEmphasisEdit('say $x$ here', 5, 6, '$')), { text: 'say x here', selected: [4, 5] })
    assert.deepEqual(emphasised('ab', toggleEmphasisEdit('ab', 1, 1, '$')), { text: 'a$$b', selected: [2, 2] })
    assert.deepEqual(emphasised('a$$b', toggleEmphasisEdit('a$$b', 2, 2, '$')), { text: 'ab', selected: [1, 1] })
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
