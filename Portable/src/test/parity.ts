/**
 * What the Windows and Linux window does the way the Mac does it — the pure
 * halves of the parity work: smart collections (`SmartRuleEvaluator`),
 * a passage quoted into a note (`NoteAnchor`, `NoteMarkdown.quotationSource`,
 * `NoteEditor.insert`), the line under a title (`SubtitleField`), and the
 * keys as each desktop writes them (`Shortcut.display`).
 */
import assert from 'node:assert/strict'
import { PaperMeta, PaperState, type Collection, type Tag } from '../shared/model.js'
import { displayName, inCollection, matchesRule } from '../shared/smartRule.js'
import {
  anchorLabel, anchorURL, parseAnchorURL, passageText, quotationInsertion, quotationSource,
} from '../shared/noteQuote.js'
import { encodeSubtitle, parseSubtitle, subtitleLine, toggledSubtitle } from '../shared/subtitle.js'
import { SHORTCUTS, acceleratorFor, displayAccelerator, keyFor, withKey } from '../shared/shortcuts.js'
import { setKorean } from '../shared/lang.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

function paper(fields: Record<string, unknown> = {}, state: Record<string, unknown> = {}) {
  const meta = new PaperMeta({
    id: 'A0000000-0000-0000-0000-000000000001',
    csl: { id: '', type: 'article-journal', title: 'Attention Is All You Need', author: [{ family: 'Vaswani', given: 'Ashish' }], issued: { 'date-parts': [[2017]] }, 'container-title': 'NeurIPS' },
    bibKey: 'vaswani2017',
    confidence: 'verified',
    file: { relativePath: 'attention.pdf', originalName: 'attention.pdf', pageCount: 15, byteSize: 1, importDigest: '' },
    tagIDs: [],
    collectionIDs: [],
    addedAt: '2026-09-01T10:00:00Z',
    ...fields,
  })
  return { meta, state: new PaperState({ readingStatus: 'reading', ...state }) }
}

export async function paritySuite(test: Test, suite: (name: string) => void) {
  suite('A smart collection holds whoever its rule matches, as on the Mac')

  const tags: Tag[] = [{ id: 'T1', name: 'transformers', color: 'blue' }]

  await test('a name reads the way CSLName.displayName writes it', () => {
    assert.equal(displayName({ family: 'Vaswani', given: 'Ashish' }), 'Ashish Vaswani')
    assert.equal(displayName({ family: 'Beethoven', 'non-dropping-particle': 'van', given: 'Ludwig' }), 'Ludwig van Beethoven')
    assert.equal(displayName({ family: 'King', given: 'Martin Luther', suffix: 'Jr.' }), 'Martin Luther King, Jr.')
    assert.equal(displayName({ literal: 'OpenAI' }), 'OpenAI')
  })

  await test('each field and comparison answers as SmartRuleEvaluator does', () => {
    const { meta, state } = paper({ tagIDs: ['T1'] })
    const rule = (field: string, comparison: string, value: string) =>
      matchesRule({ matchAll: true, conditions: [{ field, comparison, value } as never] }, meta, state, tags)
    assert.equal(rule('title', 'contains', 'attention'), true)
    assert.equal(rule('title', 'contains', ''), false, 'nothing contains nothing')
    assert.equal(rule('author', 'contains', 'vaswani'), true)
    assert.equal(rule('year', 'greaterThan', '2016'), true)
    assert.equal(rule('year', 'lessThan', '2017'), false)
    assert.equal(rule('venue', 'equals', 'neurips'), true)
    assert.equal(rule('tag', 'contains', 'transformer'), true)
    assert.equal(rule('readingStatus', 'equals', 'reading'), true)
    assert.equal(rule('confidence', 'notEquals', 'verified'), false)
    assert.equal(rule('dateAdded', 'equals', '2026-09-01'), true)
    assert.equal(rule('year', 'greaterThan', 'twenty'), true, 'a word reads as nought, as Double() fails to it')
  })

  await test('all or any, and no conditions at all takes everything', () => {
    const { meta, state } = paper()
    const yes = { field: 'title', comparison: 'contains', value: 'Attention' } as const
    const no = { field: 'title', comparison: 'contains', value: 'Diffusion' } as const
    assert.equal(matchesRule({ matchAll: true, conditions: [yes, no] }, meta, state, tags), false)
    assert.equal(matchesRule({ matchAll: false, conditions: [yes, no] }, meta, state, tags), true)
    assert.equal(matchesRule({ matchAll: true, conditions: [] }, meta, state, tags), true)
  })

  await test('a smart collection ignores membership; a plain one is only membership', () => {
    const { meta, state } = paper({ collectionIDs: ['C1'] })
    const smart: Collection = { id: 'C2', name: 'Recent', symbolName: 'folder', sortIndex: 0, rule: { matchAll: true, conditions: [{ field: 'year', comparison: 'greaterThan', value: '2020' }] } }
    const plain: Collection = { id: 'C1', name: 'Reading group', symbolName: 'folder', sortIndex: 1 }
    assert.equal(inCollection(smart, meta, state, tags), false)
    assert.equal(inCollection(plain, meta, state, tags), true)
  })

  suite('A passage goes into a note as the Mac writes it')

  const anchor = { pageIndex: 3, rect: { x: 145, y: 95.004, width: 366.5, height: 12 }, quotedText: 'the encoder is trained' }

  await test('the link is papertime://anchor with two decimals', () => {
    assert.equal(anchorURL(anchor), 'papertime://anchor?p=3&x=145.00&y=95.00&w=366.50&h=12.00')
    assert.equal(anchorURL({ ...anchor, paperID: 'abc' }), 'papertime://anchor?p=3&x=145.00&y=95.00&w=366.50&h=12.00&paper=ABC')
    assert.deepEqual(parseAnchorURL('papertime://anchor?p=3&x=145.00&y=95.00&w=366.50&h=12.00'),
      { pageIndex: 3, rect: { x: 145, y: 95, width: 366.5, height: 12 } })
    assert.equal(parseAnchorURL('papertime://note?id=1'), null)
  })

  await test('a quotation is > lines with the page after the last word', () => {
    const english = (page: number) => `p. ${page}`
    assert.equal(quotationSource(anchor, english),
      '> the encoder is trained [p. 4](papertime://anchor?p=3&x=145.00&y=95.00&w=366.50&h=12.00)\n')
    const korean = quotationSource(anchor, (page) => `${page}쪽`)
    assert.ok(korean.startsWith('> the encoder is trained [4쪽](papertime://anchor?p=3'))
  })

  await test('a displayed formula takes a line of its own, and the page goes under it', () => {
    const source = quotationSource({ ...anchor, quotedText: 'we minimise $$L = \\sum_i x_i$$' }, (page) => `p. ${page}`)
    assert.equal(source, '> we minimise\n> $$L = \\sum_i x_i$$\n> [p. 4](papertime://anchor?p=3&x=145.00&y=95.00&w=366.50&h=12.00)\n')
  })

  await test('no words: the first seven, or the page', () => {
    assert.equal(anchorLabel({ ...anchor, quotedText: 'one two three four five six seven eight' }), 'one two three four five six seven…')
    assert.equal(anchorLabel({ ...anchor, quotedText: '' }), 'p. 4')
  })

  await test('the block starts a line and leaves one after it', () => {
    const block = '> quoted\n'
    assert.deepEqual(quotationInsertion('', 0, block), { insert: '> quoted\n\n', caret: 10 })
    assert.deepEqual(quotationInsertion('Thoughts', 8, block), { insert: '\n> quoted\n\n', caret: 19 })
    assert.deepEqual(quotationInsertion('A\n\nB', 2, block), { insert: '> quoted\n', caret: 11 })
  })

  await test('the printed lines of a selection become one passage, hyphens rejoined', () => {
    assert.equal(passageText('the encoder is\ntrained with a mas-\nked objective'), 'the encoder is trained with a masked objective')
    assert.equal(passageText('  state-of-\nthe-art  '), 'state-of-the-art')
    assert.equal(passageText('a 1-\nbased index'), 'a 1-based index')
  })

  suite('The line under a title is the one the reader chose')

  await test('the stored words parse in order, unknown ones dropped, nothing meaning the Mac\'s three', () => {
    assert.deepEqual(parseSubtitle('year,authors,bogus'), ['year', 'authors'])
    assert.deepEqual(parseSubtitle(''), ['authors', 'year', 'venue'])
    assert.equal(encodeSubtitle(toggledSubtitle(['authors', 'year'], 'venue')), 'authors,year,venue')
    assert.equal(encodeSubtitle(toggledSubtitle(['authors', 'year', 'venue'], 'year')), 'authors,venue')
  })

  await test('fields join with a middle dot; a document with none says where it came from', () => {
    setKorean(false)
    const { meta } = paper()
    assert.equal(subtitleLine(meta, ['authors', 'year', 'venue']), 'Vaswani · 2017 · NeurIPS')
    assert.equal(subtitleLine(meta, ['citationKey', 'pageCount']), 'vaswani2017 · 15 pages')
    const manual = paper({ kind: 'document', csl: { id: '', type: 'other', publisher: 'ACME', issued: { 'date-parts': [[2024]] } } }).meta
    assert.equal(subtitleLine(manual, ['authors', 'venue']), 'ACME · 2024 · 15 pages')
    const bare = paper({ csl: { id: '', type: 'other' } }).meta
    assert.equal(subtitleLine(bare, ['authors', 'venue']), '', 'a paper with nothing says nothing')
  })

  suite('The keys, as each desktop writes them')

  await test('⌘ on a Mac in ⌃⌥⇧⌘ order, Ctrl+ elsewhere', () => {
    assert.equal(displayAccelerator('CmdOrCtrl+Shift+E', 'darwin'), '⇧⌘E')
    assert.equal(displayAccelerator('CmdOrCtrl+Shift+E', 'win32'), 'Ctrl+Shift+E')
    assert.equal(displayAccelerator('CmdOrCtrl+Alt+/', 'darwin'), '⌥⌘/')
    assert.equal(displayAccelerator('CmdOrCtrl+Alt+/', 'linux'), 'Ctrl+Alt+/')
    assert.equal(displayAccelerator('CmdOrCtrl+Plus', 'win32'), 'Ctrl++')
    assert.equal(displayAccelerator('CmdOrCtrl+Down', 'darwin'), '⌘↓')
    assert.equal(displayAccelerator('Alt+Left', 'win32'), 'Alt+←')
  })

  await test('back and forward keep the desktop\'s own keys; the rest are the Mac\'s letters', () => {
    const back = SHORTCUTS.find((entry) => entry.command === 'back')!
    assert.equal(acceleratorFor(back, 'darwin'), 'CmdOrCtrl+Alt+[')
    assert.equal(acceleratorFor(back, 'win32'), 'Alt+Left')
    assert.equal(keyFor('searchEverything', 'win32'), 'Ctrl+K')
    assert.equal(keyFor('searchEverything', 'darwin'), '⌘K')
    assert.equal(withKey('Sidebar', 'sidebar', 'win32'), 'Sidebar (Ctrl+[)')
    assert.equal(withKey('Nothing', 'no-such-command', 'win32'), 'Nothing')
  })

  await test('no two commands share a key', () => {
    for (const platform of ['darwin', 'win32']) {
      const keys = SHORTCUTS.map((entry) => acceleratorFor(entry, platform).toLowerCase())
      assert.equal(new Set(keys).size, keys.length, `a key given twice on ${platform}`)
    }
  })
}
