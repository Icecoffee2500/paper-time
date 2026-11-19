/**
 * The boxes the notes are kept in, and which one each note goes back to —
 * `main/slipBox.ts`, the port of the Mac's `SlipBox`/`LooseNotes`/`NotesModel`.
 *
 * Real folders, made and thrown away: a note is a file, and what these test
 * is where the file ends up and what bytes are in it.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { AreaRefused, NotesStore, SlipBoxFolder, cleanArea, inATrash } from '../main/slipBox.js'
import { slipBoxDir } from '../main/layout.js'
import { zettelText, type Zettel } from '../shared/zettel.js'
import type { NoteDTO } from '../shared/api.js'
import {
  areaAfterRename, areaDepth, areaName, areaNameProblem, areaParent, areaTitle, isAreaName, knowledgeIn, literatureNotes,
  noteOrderFrom, renamedArea, rewrittenAsKnowledge, sortAreas, sortNotes,
} from '../shared/noteAreas.js'
import { prefersKorean, setKorean } from '../shared/lang.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const P1 = '4F3A1C08-0000-4000-8000-000000000001'
const P2 = '4F3A1C08-0000-4000-8000-000000000002'
const P3 = '4F3A1C08-0000-4000-8000-000000000003'

function note(id: string, body: string, paperID: string | null = null, at = 1_757_000_000, area = ''): Zettel {
  return { id, kind: 'note', title: '', body, paperID, created: new Date(at * 1000), modified: new Date(at * 1000), area }
}

/** Writes a note the way the Mac would have, into a box. */
function plant(directory: string, one: Zettel, mtime?: Date) {
  fs.mkdirSync(directory, { recursive: true })
  const file = path.join(directory, `${one.id}.md`)
  fs.writeFileSync(file, zettelText(one), 'utf8')
  if (mtime) fs.utimesSync(file, mtime, mtime)
}

const files = (directory: string) => (fs.existsSync(directory) ? fs.readdirSync(directory).filter((name) => name.endsWith('.md')).sort() : [])

function dto(one: Zettel, box = ''): NoteDTO {
  return { ...one, created: one.created.getTime(), modified: one.modified.getTime(), box }
}

export async function slipBoxSuite(test: Test, suite: (name: string) => void) {
  suite('The slip-box: which box a note is in, and which it goes back to')

  const setUp = () => {
    const base = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-slipbox-'))
    const a = path.join(base, 'Library A')
    const b = path.join(base, 'Library B')
    const app = path.join(base, 'App Notes')
    fs.mkdirSync(a)
    fs.mkdirSync(b)
    const owner = (paperID: string) => (paperID === P1 ? a : paperID === P2 ? b : null)
    return { base, a, b, app, owner }
  }

  await test('notes are read from every folder and the loose box, each with its box', async () => {
    const { base, a, b, app, owner } = setUp()
    try {
      plant(slipBoxDir(a), note('202609081530', 'about P1 #vla', P1))
      plant(slipBoxDir(b), note('202609081531', 'about P2', P2, 1_757_000_060))
      plant(app, note('202609081532', 'a thought of my own', null, 1_757_000_120))
      const store = new NotesStore(app, null)
      store.setFolders([a, b], owner)
      const notes = await store.load()
      assert.deepEqual(notes.map((one) => [one.id, one.box, one.paperID, one.body]), [
        ['202609081532', app, null, 'a thought of my own'],
        ['202609081530', a, P1, 'about P1 #vla'],
        ['202609081531', b, P2, 'about P2'],
      ])
      assert.equal(store.info().loose, app)
      assert.equal(store.info().chosen, false)
    } finally {
      fs.rmSync(base, { recursive: true, force: true })
    }
  })

  await test('a note settles into the folder of its paper, or the loose box when it has none', async () => {
    const { base, a, b, app, owner } = setUp()
    try {
      // Written into A while B was away, say; and a loose thought that a
      // one-folder library kept beside its papers.
      plant(slipBoxDir(a), note('202609081540', 'about P2, in A', P2))
      plant(slipBoxDir(a), note('202609081541', 'no paper, in A', null))
      // About a paper no open folder has: stays where it is.
      plant(slipBoxDir(a), note('202609081542', 'about P3', P3))
      const store = new NotesStore(app, null)
      store.setFolders([a, b], owner)
      const notes = await store.load()
      const box = Object.fromEntries(notes.map((one) => [one.id, one.box]))
      assert.deepEqual(box, { '202609081540': b, '202609081541': app, '202609081542': a })
      assert.deepEqual(files(slipBoxDir(a)), ['202609081542.md'])
      assert.deepEqual(files(slipBoxDir(b)), ['202609081540.md'])
      assert.deepEqual(files(app), ['202609081541.md'])
      // Moved, not rewritten: the bytes are the Mac's.
      assert.equal(fs.readFileSync(path.join(slipBoxDir(b), '202609081540.md'), 'utf8'), zettelText(note('202609081540', 'about P2, in A', P2)))
    } finally {
      fs.rmSync(base, { recursive: true, force: true })
    }
  })

  await test('a name two boxes hold is left in both, and the newer one shows', async () => {
    const { base, a, b, app, owner } = setUp()
    try {
      plant(slipBoxDir(a), note('202609081550', 'older, in A', P2), new Date(1_757_000_000_000))
      plant(slipBoxDir(b), note('202609081550', 'newer, in B', P2), new Date(1_757_000_500_000))
      const store = new NotesStore(app, null)
      store.setFolders([a, b], owner)
      const notes = await store.load()
      assert.equal(notes.length, 1)
      assert.equal(notes[0].body, 'newer, in B')
      assert.equal(notes[0].box, b)
      // Nobody's writing was thrown away to tidy an index.
      assert.deepEqual(files(slipBoxDir(a)), ['202609081550.md'])
      assert.deepEqual(files(slipBoxDir(b)), ['202609081550.md'])
    } finally {
      fs.rmSync(base, { recursive: true, force: true })
    }
  })

  await test('a save goes back to the box the note came from, byte for byte', async () => {
    const { base, a, b, app, owner } = setUp()
    try {
      plant(slipBoxDir(a), note('202609081600', 'first words', P1))
      const store = new NotesStore(app, null)
      store.setFolders([a, b], owner)
      const [loaded] = await store.load()
      const edited = { ...loaded, title: 'Now titled', body: 'first words, then more #tag' }
      const saved = await store.save(edited)
      assert.equal(saved.box, a)
      const expected = zettelText({ ...note('202609081600', 'first words, then more #tag', P1), title: 'Now titled' })
      assert.equal(fs.readFileSync(path.join(slipBoxDir(a), '202609081600.md'), 'utf8'), expected)
      // A new note about a paper goes to that paper's folder; one about no
      // paper to the loose box; an empty one takes its file away.
      assert.equal((await store.save(dto(note('202609081601', 'new, about P2', P2)))).box, b)
      assert.deepEqual(files(slipBoxDir(b)), ['202609081601.md'])
      assert.equal((await store.save(dto(note('202609081602', 'new, loose')))).box, app)
      assert.deepEqual(files(app), ['202609081602.md'])
      await store.save(dto(note('202609081602', '   '), app))
      assert.deepEqual(files(app), [])
      await store.delete('202609081601')
      assert.deepEqual(files(slipBoxDir(b)), [])
    } finally {
      fs.rmSync(base, { recursive: true, force: true })
    }
  })

  await test('the loose notes are carried into a chosen folder, and a taken name stays behind', async () => {
    const { base, a, b, app, owner } = setUp()
    const chosen = path.join(base, 'Cloud Notes')
    try {
      fs.mkdirSync(chosen)
      plant(app, note('202609081610', 'goes across'))
      plant(app, note('202609081611', 'mine, kept'))
      plant(app, note('202609081612', 'already there, the same'))
      plant(chosen, note('202609081611', 'theirs, other words'))
      plant(chosen, note('202609081612', 'already there, the same'))
      const store = new NotesStore(app, null)
      store.setFolders([a, b], owner)
      await store.load()
      assert.deepEqual(await store.relocate(chosen), { moved: 2, kept: 1 })
      assert.deepEqual(files(chosen), ['202609081610.md', '202609081611.md', '202609081612.md'])
      assert.deepEqual(files(app), ['202609081611.md'])
      assert.equal(fs.readFileSync(path.join(chosen, '202609081611.md'), 'utf8'), zettelText(note('202609081611', 'theirs, other words')))
      // Read from both. The note kept back is still the one showing — it
      // was the one read before the move, and turning the note somebody has
      // open into the other of that name is how the other gets written
      // over (the Mac's rule) — and neither is moved over the other.
      const notes = await store.load()
      const byID = Object.fromEntries(notes.map((one) => [one.id, [one.body, one.box]]))
      assert.deepEqual(byID['202609081610'], ['goes across', chosen])
      assert.deepEqual(byID['202609081611'], ['mine, kept', app])
      assert.deepEqual(files(app), ['202609081611.md'])
      const info = store.info()
      assert.equal(info.chosen, true)
      assert.equal(info.loose, chosen)
      assert.deepEqual(info.leftBehind, [app])
      // A new loose note goes to the chosen folder now.
      assert.equal((await store.save(dto(note('202609081613', 'written after')))).box, chosen)
      // And the way back: the three that live there now come across, and
      // the taken name is taken the other way round.
      assert.deepEqual(await store.relocate(null), { moved: 3, kept: 1 })
      assert.deepEqual(files(app), ['202609081610.md', '202609081611.md', '202609081612.md', '202609081613.md'])
      assert.equal(fs.readFileSync(path.join(app, '202609081611.md'), 'utf8'), zettelText(note('202609081611', 'mine, kept')))
      assert.equal(store.info().chosen, false)
    } finally {
      fs.rmSync(base, { recursive: true, force: true })
    }
  })

  await test("a chosen folder that is away keeps the app's folder as the box, and a save falls back to it", async () => {
    const { base, a, b, app, owner } = setUp()
    const chosen = path.join(base, 'Unplugged', 'Notes')
    try {
      // Not there at launch: the app's folder for this run, the choice kept.
      const away = new NotesStore(app, chosen)
      away.setFolders([a, b], owner)
      assert.equal(away.info().loose, app)
      assert.equal(away.info().chosenPath, chosen)
      assert.equal(away.info().away, true)
      // There at launch, gone while the app is open: the note is kept anyway.
      fs.mkdirSync(chosen, { recursive: true })
      const store = new NotesStore(app, chosen)
      store.setFolders([a, b], owner)
      assert.equal(store.info().loose, chosen)
      fs.rmSync(path.join(base, 'Unplugged'), { recursive: true, force: true })
      const saved = await store.save(dto(note('202609081620', 'typed while away')))
      assert.equal(saved.box, app)
      assert.deepEqual(files(app), ['202609081620.md'])
      assert.equal(store.info().away, true)
      assert.deepEqual(store.info().leftBehind, [app])
      // Never made again where it used to be.
      assert.equal(fs.existsSync(chosen), false)
      // Plugged back in while the app is open: carried across at once, not
      // at the next launch — and read from there.
      fs.mkdirSync(chosen, { recursive: true })
      assert.deepEqual(await store.comeBack(), { moved: 1, kept: 0 })
      assert.deepEqual(files(chosen), ['202609081620.md'])
      assert.deepEqual(files(app), [])
      assert.equal(store.info().away, false)
      assert.deepEqual(store.info().lastMove, { moved: 1, kept: 0 })
      assert.equal(await store.comeBack(), null, 'nothing left to carry')
      const read = await store.load()
      assert.deepEqual(read.map((one) => [one.id, one.box]), [['202609081620', chosen]])
    } finally {
      fs.rmSync(base, { recursive: true, force: true })
    }
  })

  // ---- The areas of knowledge are folders under the notes folder (1.1):
  // the filing the file manager and any other Markdown app would see. The
  // Mac's «Areas of knowledge» suite, case by case.

  const box = () => {
    const base = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-areas-'))
    return { base, folder: new SlipBoxFolder(base, base) }
  }

  await test('a note in a folder is read with that folder as its area', async () => {
    const { base, folder } = box()
    try {
      assert.equal(await folder.createArea('통계'), '통계')
      assert.equal(await folder.createArea('추정', '통계'), '통계/추정')
      await folder.createArea('빈 영역')
      await folder.saveNote(note('a', 'Top'))
      await folder.saveNote(note('b', 'Deep', null, 1_757_000_000, '통계/추정'))
      const read = await folder.loadNotes()
      assert.deepEqual(Object.fromEntries(read.map((one) => [one.id, one.area])), { a: '', b: '통계/추정' })
      assert.ok(fs.existsSync(path.join(base, '통계', '추정', 'b.md')))
      // Empty areas are areas too: they are where the next note goes.
      assert.deepEqual(await folder.areas(), ['빈 영역', '통계', '통계/추정'])
      // The file is the Mac's: no line for the area in it.
      assert.equal(fs.readFileSync(path.join(base, '통계', '추정', 'b.md'), 'utf8'), zettelText(note('b', 'Deep')))
      await assert.rejects(folder.createArea('통계'), (error: unknown) => error instanceof AreaRefused && error.why === 'exists')
      await assert.rejects(folder.createArea('a/b'), (error: unknown) => error instanceof AreaRefused && error.why === 'name')
      await assert.rejects(folder.createArea('.hidden'), (error: unknown) => error instanceof AreaRefused && error.why === 'name')
      await assert.rejects(folder.createArea('   '), (error: unknown) => error instanceof AreaRefused && error.why === 'name')
    } finally {
      fs.rmSync(base, { recursive: true, force: true })
    }
  })

  await test('filing a note elsewhere moves its file, and leaves no copy', async () => {
    const { base, folder } = box()
    try {
      await folder.createArea('언러닝')
      const one = note('n1', 'Saliency')
      await folder.saveNote(one)
      await folder.saveNote({ ...one, area: '언러닝' })
      assert.equal(fs.existsSync(path.join(base, 'n1.md')), false)
      assert.ok(fs.existsSync(path.join(base, '언러닝', 'n1.md')))
      // A box that never read the note finds it where it is to take it away.
      await new SlipBoxFolder(base, base).deleteNote('n1')
      assert.deepEqual(await folder.loadNotes(), [])
      // A hidden folder is nobody's area, and its notes are nobody's notes.
      fs.mkdirSync(path.join(base, '.trash'))
      fs.writeFileSync(path.join(base, '.trash', 'x.md'), zettelText(note('x', 'hidden')))
      assert.deepEqual(await folder.areas(), ['언러닝'])
      assert.deepEqual(await folder.noteIDs(), [])
    } finally {
      fs.rmSync(base, { recursive: true, force: true })
    }
  })

  await test('taking an area away keeps its notes, one level up; renaming carries them', async () => {
    const { base, folder } = box()
    try {
      await folder.createArea('A')
      await folder.createArea('B', 'A')
      await folder.saveNote(note('x', 'In B', null, 1_757_000_000, 'A/B'))
      assert.equal(await folder.removeArea('A/B'), 1)
      assert.equal((await folder.loadNotes())[0].area, 'A')
      assert.deepEqual(await folder.areas(), ['A'])
      assert.equal(await folder.renameArea('A', 'C'), 'C')
      assert.equal((await folder.loadNotes())[0].area, 'C')
      assert.deepEqual(await folder.areas(), ['C'])
      // Written again after the rename, it stays in the renamed folder.
      await folder.saveNote(note('x', 'In C, edited', null, 1_757_000_000, 'C'))
      assert.deepEqual(fs.readdirSync(path.join(base, 'C')), ['x.md'])
      // A name already there is not written over, and a folder with
      // somebody else's file in it stays.
      fs.writeFileSync(path.join(base, 'C', 'photo.png'), 'not a note')
      await folder.createArea('D')
      await assert.rejects(folder.renameArea('C', 'D'), (error: unknown) => error instanceof AreaRefused && error.why === 'exists')
      assert.equal(await folder.removeArea('C'), 1)
      assert.ok(fs.existsSync(path.join(base, 'C', 'photo.png')))
      assert.deepEqual((await folder.loadNotes()).map((one) => [one.id, one.area]), [['x', '']])
      // A note of the same name one level up: the one in the area keeps its folder.
      await folder.createArea('E')
      fs.writeFileSync(path.join(base, 'E', 'x.md'), zettelText(note('x', 'another x')))
      assert.equal(await folder.removeArea('E'), 0)
      assert.ok(fs.existsSync(path.join(base, 'E', 'x.md')))
    } finally {
      fs.rmSync(base, { recursive: true, force: true })
    }
  })

  await test('moving the notes folder carries the areas, empty ones too', async () => {
    const from = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-areas-from-'))
    const to = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-areas-to-'))
    try {
      const old = new SlipBoxFolder(from, from)
      await old.createArea('Empty')
      await old.saveNote(note('p', 'Filed', null, 1_757_000_000, 'Stats'))
      await old.saveNote(note('q', 'Loose'))
      assert.deepEqual(await old.move(new SlipBoxFolder(to, to, true)), { moved: 2, kept: 0 })
      const there = new SlipBoxFolder(to, to)
      assert.deepEqual(new Set((await there.loadNotes()).map((one) => `${one.id}@${one.area}`)), new Set(['p@Stats', 'q@']))
      assert.deepEqual(await there.areas(), ['Empty', 'Stats'])
      // Nothing left behind: the folders went with their notes.
      assert.deepEqual(fs.readdirSync(from), [])
    } finally {
      fs.rmSync(from, { recursive: true, force: true })
      fs.rmSync(to, { recursive: true, force: true })
    }
  })

  await test('the store files notes by area, says the areas, and a library box has none', async () => {
    const { base, a, b, app, owner } = setUp()
    try {
      // A folder inside a library's notes is not an area: that box is the
      // one folder beside the papers, as both builds always kept it.
      fs.mkdirSync(path.join(slipBoxDir(a), 'stray'), { recursive: true })
      plant(path.join(slipBoxDir(a), 'stray'), note('202609081700', 'not read', P1))
      plant(slipBoxDir(a), note('202609081701', 'about P1', P1))
      plant(path.join(app, 'Stats'), note('202609081702', 'filed'))
      const store = new NotesStore(app, null)
      store.setFolders([a, b], owner)
      const notes = await store.load()
      assert.deepEqual(notes.map((one) => [one.id, one.area]).sort(), [['202609081701', ''], ['202609081702', 'Stats']])
      assert.deepEqual(store.info().areas, ['Stats'])
      assert.equal(await store.createArea('Proofs', 'Stats'), 'Stats/Proofs')
      assert.deepEqual(store.info().areas, ['Stats', 'Stats/Proofs'])
      // Filed elsewhere through the bridge: written there, gone from here.
      const moved = await store.save(dto({ ...note('202609081702', 'filed'), area: 'Stats/Proofs' }, app))
      assert.equal(moved.area, 'Stats/Proofs')
      assert.deepEqual(files(path.join(app, 'Stats')), [])
      assert.deepEqual(files(path.join(app, 'Stats', 'Proofs')), ['202609081702.md'])
      assert.equal(await store.renameArea('Stats', 'Statistics'), 'Statistics')
      assert.deepEqual(store.info().areas, ['Statistics', 'Statistics/Proofs'])
      assert.deepEqual((await store.load()).find((one) => one.id === '202609081702')?.area, 'Statistics/Proofs')
      assert.equal(await store.removeArea('Statistics'), 1)
      assert.deepEqual(store.info().areas, [])
      assert.deepEqual(files(app), ['202609081702.md'])
      // A window's area that steps out of the box is no area.
      assert.equal(cleanArea('../../etc'), 'etc')
      assert.equal(cleanArea('A//.hidden/B'), 'A/B')
      const out = await store.save(dto({ ...note('202609081703', 'nowhere else'), area: '../outside' }, app))
      assert.equal(out.area, 'outside')
      assert.ok(fs.existsSync(path.join(app, 'outside', '202609081703.md')))
      await assert.rejects(store.removeArea(''), (error: unknown) => error instanceof AreaRefused)
    } finally {
      fs.rmSync(base, { recursive: true, force: true })
    }
  })

  await test('an area is a path of folder names, read the way the Mac reads it', () => {
    assert.equal(areaName('통계/추정'), '추정')
    assert.equal(areaDepth('통계/추정'), 2)
    assert.equal(areaParent('통계/추정'), '통계')
    assert.equal(areaParent('통계'), '')
    const korean = prefersKorean()
    assert.equal(renamedArea('통계/추정', ' 베이즈 '), '통계/베이즈')
    assert.equal(areaAfterRename('통계/추정/점', '통계', 'Stats'), 'Stats/추정/점')
    assert.equal(areaAfterRename('통계학', '통계', 'Stats'), null, 'a name that starts the same is another area')
    setKorean(true)
    assert.equal(areaTitle(null), '지식')
    assert.equal(areaTitle(''), '분류 안 함')
    assert.equal(areaTitle('통계/추정'), '추정')
    setKorean(false)
    assert.equal(areaTitle(null), 'Knowledge')
    assert.equal(areaTitle(''), 'Unfiled')
    setKorean(korean)
    // `LooseNotes.isAreaName`, and on Windows what Windows refuses a folder.
    for (const bad of ['a/b', '.hidden', '  ', '', 'a:b']) assert.equal(isAreaName(bad), false, bad)
    for (const good of ['통계', 'Week 2', 'a\\b', 'con']) assert.equal(isAreaName(good), true, good)
    for (const bad of ['a\\b', 'con', 'COM1', 'what?', 'end.']) assert.equal(isAreaName(bad, 'win32'), false, bad)
    assert.equal(areaNameProblem(''), null, 'an empty field greys the button and says nothing')
    assert.equal(areaNameProblem('통계'), null)
    assert.ok(areaNameProblem('a/b'))
    // Finder's order, a folder right before the folders inside it.
    assert.deepEqual(sortAreas(['통계/추정', 'Week 10', 'A-C', 'A/B', 'Week 2', '빈 영역', 'A', '통계']),
      ['A', 'A/B', 'A-C', 'Week 2', 'Week 10', '빈 영역', '통계', '통계/추정'])
  })

  await test('the places hold the notes they say, in the order chosen', () => {
    const at = (id: string, paperID: string | null, area: string, created: number, modified: number, title = id) =>
      ({ ...note(id, `body of ${id}`, paperID, created, area), title, modified: new Date(modified * 1000) })
    const notes = [
      at('n1', null, '', 10, 50, 'Beta'), at('n2', null, '통계', 20, 40, 'alpha'), at('n3', null, '통계/추정', 30, 30, 'Gamma 10'),
      at('n4', P1, '', 40, 20, 'Gamma 2'), at('n5', null, '통계학', 50, 10, 'delta'),
    ]
    assert.deepEqual(knowledgeIn(notes, null).map((one) => one.id), ['n1', 'n2', 'n3', 'n5'])
    assert.deepEqual(knowledgeIn(notes, '').map((one) => one.id), ['n1'])
    assert.deepEqual(knowledgeIn(notes, '통계').map((one) => one.id), ['n2', 'n3'])
    assert.deepEqual(literatureNotes(notes).map((one) => one.id), ['n4'])
    assert.deepEqual(sortNotes(notes, 'edited').map((one) => one.id), ['n1', 'n2', 'n3', 'n4', 'n5'])
    assert.deepEqual(sortNotes(notes, 'created').map((one) => one.id), ['n5', 'n4', 'n3', 'n2', 'n1'])
    assert.deepEqual(sortNotes(notes, 'title').map((one) => one.title), ['alpha', 'Beta', 'delta', 'Gamma 2', 'Gamma 10'])
    assert.equal(noteOrderFrom('title'), 'title')
    assert.equal(noteOrderFrom('nonsense'), 'edited')
    const korean = prefersKorean()
    setKorean(true)
    assert.equal(rewrittenAsKnowledge({ id: '202611181200', title: 'A [draft] | notes', body: '' }), '출처: [[202611181200|A [draft   notes]]\n\n')
    setKorean(false)
    assert.equal(rewrittenAsKnowledge({ id: '202611181200', title: 'Saliency', body: '' }), 'From: [[202611181200|Saliency]]\n\n')
    setKorean(korean)
  })

  await test('a folder in a trash is not a box', () => {
    assert.equal(inATrash('/Users/me/.Trash/Notes'), true)
    assert.equal(inATrash('C:\\$Recycle.Bin\\S-1-5-21\\Notes'), true)
    assert.equal(inATrash('/home/me/.local/share/Trash/files/Notes'), true)
    assert.equal(inATrash('/home/me/Trash/Notes'), false)
    assert.equal(inATrash('/Users/me/Library/CloudStorage/GoogleDrive-x/My Drive/Notes'), false)
    assert.equal(new SlipBoxFolder('/nowhere/at/all', '/nowhere/at/all', true).isReachable(), false)
  })
}
