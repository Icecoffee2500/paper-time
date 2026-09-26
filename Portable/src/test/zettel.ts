/**
 * The slip-box's files, as the Mac writes and reads them.
 *
 * `zettel-files.json` is what the Mac's own `ZettelFile` and `Zettel` said
 * (`Scripts/zettel-fixtures.swift`), read from where the Swift tests read it.
 * A note is one file both builds open in the same folder, so the port has to
 * write the same bytes and read the same note — down to the header's
 * trimming and the way a title is made from a body that has none.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import {
  makeZettelID, parseISO8601, zettelDisplayTitle, zettelFromText, zettelIsEmpty, zettelLinkMarkdown,
  zettelLinks, zettelOutline, zettelPreview, zettelPreviewBody, zettelTags, zettelText, type Zettel,
} from '../shared/zettel.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Fields {
  id: string
  kind: string
  title: string
  body: string
  paperID?: string
  created: number
}

interface Fixture {
  write: { name: string; note: Fields; text: string }[]
  read: { name: string; text: string; fallbackID: string; modified: number; note: Fields }[]
  derived: {
    name: string; title: string; body: string; tags: string[]; links: string[]
    preview: string; previewBody: string; displayTitle: string; isEmpty: boolean; linkMarkdown: string
  }[]
}

function fixture(): Fixture {
  const file = path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures', 'zettel-files.json')
  return JSON.parse(fs.readFileSync(file, 'utf8')) as Fixture
}

function note(fields: Fields): Zettel {
  return {
    id: fields.id,
    kind: fields.kind === 'map' || fields.kind === 'draft' ? fields.kind : 'note',
    title: fields.title,
    body: fields.body,
    paperID: fields.paperID ?? null,
    created: new Date(fields.created * 1000),
    modified: new Date(fields.created * 1000),
  }
}

export async function zettelSuite(test: Test, suite: (name: string) => void) {
  suite("The slip-box's files are the Mac's, byte for byte")
  const cases = fixture()

  await test(`a note is written as the Mac writes it (${cases.write.length} notes)`, () => {
    for (const one of cases.write) {
      assert.equal(zettelText(note(one.note)), one.text, one.name)
    }
  })

  await test(`a file is read as the Mac reads it (${cases.read.length} files)`, () => {
    for (const one of cases.read) {
      const read = zettelFromText(one.text, one.fallbackID, new Date(one.modified * 1000))
      assert.equal(read.id, one.note.id, `${one.name}: id`)
      assert.equal(read.kind, one.note.kind, `${one.name}: kind`)
      assert.equal(read.title, one.note.title, `${one.name}: title`)
      assert.equal(read.body, one.note.body, `${one.name}: body`)
      assert.equal(read.paperID, one.note.paperID ?? null, `${one.name}: paper`)
      // The Mac keeps a fraction of a second where a file carries one; a
      // Date here keeps milliseconds.
      assert.ok(Math.abs(read.created.getTime() / 1000 - one.note.created) < 0.0011, `${one.name}: created ${read.created.getTime() / 1000} vs ${one.note.created}`)
    }
  })

  await test(`a row and a link say what the Mac's say (${cases.derived.length} bodies)`, () => {
    for (const one of cases.derived) {
      const fields = { id: '202609081530', title: one.title, body: one.body }
      assert.deepEqual(zettelTags(one.body), one.tags, `${one.name}: tags`)
      assert.deepEqual(zettelLinks(one.body), one.links, `${one.name}: links`)
      assert.equal(zettelPreview(one.body), one.preview, `${one.name}: preview`)
      assert.equal(zettelPreviewBody(fields), one.previewBody, `${one.name}: previewBody`)
      assert.equal(zettelDisplayTitle(fields), one.displayTitle, `${one.name}: displayTitle`)
      assert.equal(zettelIsEmpty(fields), one.isEmpty, `${one.name}: isEmpty`)
      assert.equal(zettelLinkMarkdown(fields), one.linkMarkdown, `${one.name}: linkMarkdown`)
    }
  })

  await test('a creation time reads the way Foundation reads it', () => {
    const seconds = (text: string) => {
      const date = parseISO8601(text)
      return date ? date.getTime() / 1000 : null
    }
    // Probed on the Mac, one by one.
    assert.equal(seconds('2026-09-08T15:30:00Z'), 1788881400)
    assert.equal(seconds('2026-09-08T15:30:00+0900'), 1788849000)
    assert.equal(seconds('2026-09-08T15:30:00+09'), 1788849000)
    assert.equal(seconds('2026-09-08T15:30:00+9'), 1788849000)
    assert.equal(seconds('2026-09-08T15:30:00-09:30'), 1788915600)
    assert.equal(seconds('2026-09-08T15:30:00z'), 1788881400)
    assert.equal(seconds('2026-09-08T15:30:00ZZ'), 1788881400)
    assert.equal(seconds('2026-09-08T15:30:00+09:00Z'), 1788849000)
    assert.equal(seconds('2026-09-08T24:00:00Z'), 1788912000)
    assert.equal(seconds('2026-02-30T10:00:00Z'), 1772445600)
    assert.equal(seconds('2026-09-08T15:30:60Z'), 1788881460)
    assert.equal(seconds('2026-9-8T5:30:00Z'), 1788845400)
    // A three-digit year is read (the Mac takes it too); before 1582 the two
    // calendars differ by days, and no note was written then.
    assert.equal(seconds('1999-01-01T00:00:00Z'), 915148800)
    assert.equal(seconds('1969-12-31T23:59:59.5Z'), -0.5)
    assert.equal(seconds('2026-09-08T15:30:00.9999999Z'), 1788881401)
    for (const refused of [
      '2026-09-08T15:30:00', '2026-09-08 15:30:00Z', '2026-09-08T15:30Z', '2026-09-08', '20260908T153000Z',
      ' 2026-09-08T15:30:00Z', '2026-09-08t15:30:00Z', '2026-09-08T15:30:00,5Z', '2026-09-08T15:30:00.Z',
      '2026-13-08T15:30:00Z', '2026-00-08T15:30:00Z', '2026-09-00T15:30:00Z', '2026-09-08T15:30:00+23:59',
      '2026-09-08T15:30:00 Z', '2026-09-08T15:30:00.1234567891Z', 'yesterday', '',
    ]) assert.equal(seconds(refused), null, refused)
  })

  await test('an outline is the headings and the links under them', () => {
    assert.deepEqual(zettelOutline('- [[a|A]]\n# One\ntext [[b]] and [[c|C]]\n## Two\n\n# Empty'), [
      { title: '', entries: [{ id: 'a', label: 'A' }] },
      { title: 'One', entries: [{ id: 'b', label: '' }, { id: 'c', label: 'C' }] },
      { title: 'Two', entries: [] },
      { title: 'Empty', entries: [] },
    ])
    assert.deepEqual(zettelOutline(''), [])
  })

  await test('an identifier is the minute, then the minute with a suffix', () => {
    const at = new Date(2026, 8, 8, 15, 30, 45)
    assert.equal(makeZettelID(at, new Set()), '202609081530')
    assert.equal(makeZettelID(at, new Set(['202609081530'])), '202609081530-1')
    assert.equal(makeZettelID(at, new Set(['202609081530', '202609081530-1'])), '202609081530-2')
    const all = new Set(['202609081530', ...Array.from({ length: 99 }, (_, k) => `202609081530-${k + 1}`)])
    assert.equal(makeZettelID(at, all, () => 'ABCD'), '202609081530-ABCD')
  })
}
