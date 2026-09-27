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
import { NotesStore, SlipBoxFolder, inATrash } from '../main/slipBox.js'
import { slipBoxDir } from '../main/layout.js'
import { zettelText, type Zettel } from '../shared/zettel.js'
import type { NoteDTO } from '../shared/api.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const P1 = '4F3A1C08-0000-4000-8000-000000000001'
const P2 = '4F3A1C08-0000-4000-8000-000000000002'
const P3 = '4F3A1C08-0000-4000-8000-000000000003'

function note(id: string, body: string, paperID: string | null = null, at = 1_757_000_000): Zettel {
  return { id, kind: 'note', title: '', body, paperID, created: new Date(at * 1000), modified: new Date(at * 1000) }
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

  await test('a folder in a trash is not a box', () => {
    assert.equal(inATrash('/Users/me/.Trash/Notes'), true)
    assert.equal(inATrash('C:\\$Recycle.Bin\\S-1-5-21\\Notes'), true)
    assert.equal(inATrash('/home/me/.local/share/Trash/files/Notes'), true)
    assert.equal(inATrash('/home/me/Trash/Notes'), false)
    assert.equal(inATrash('/Users/me/Library/CloudStorage/GoogleDrive-x/My Drive/Notes'), false)
    assert.equal(new SlipBoxFolder('/nowhere/at/all', '/nowhere/at/all', true).isReachable(), false)
  })
}
