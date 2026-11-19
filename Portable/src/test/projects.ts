/**
 * The slip-box's projects (1.1): the file the Mac writes, read and written
 * back to the byte (`src/test/fixtures/mac-project.json` is one the Mac's
 * `LibraryStore.saveProject` wrote); the rules of `Project.swift`; and the
 * edits made on the file as it is on disk (`ProjectStoreTests`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { encodeSwiftJSON } from '../shared/coding.js'
import { setKorean } from '../shared/lang.js'
import {
  acceptedProjectEdit, applyProjectEdit, daysLeft, ddayText, milestonesByDay, moveTodo, newMilestone, newProject, newTodo,
  projectProgress, projectSpan, readProject, spanDay, spanShift, spanX, splitDay, todoBar, todosIn, type Project,
} from '../shared/project.js'
import { ProjectFiles, readAllProjects } from '../main/projects.js'
import type { Library } from '../main/library.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const fixture = path.join(__dirname, '../../src/test/fixtures/mac-project.json')

function scratch(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-projects-'))
}

const library = (root: string) => ({ root }) as unknown as Library

export async function projectsSuite(test: Test, suite: (name: string) => void) {
  suite('Projects, as the Mac writes them')
  const text = fs.readFileSync(fixture, 'utf8')

  await test('the Mac’s project file is read and written back to the byte', () => {
    const project = readProject(JSON.parse(text))
    assert.ok(project, 'read')
    assert.equal(project!.name, 'ICML 투고 — 지속 언러닝')
    assert.equal(project!.deadline, '2027-01-29')
    assert.equal(project!.todos.length, 6)
    assert.equal(encodeSwiftJSON(project), text)
  })

  await test('a project made here is written as the Mac writes one, and read back the same', () => {
    const project = newProject('ICML 투고', new Date(Date.UTC(2027, 0, 15, 9, 30, 12, 345)))
    assert.equal(project.createdAt, '2027-01-15T09:30:12Z', 'whole seconds, Z')
    assert.equal('deadline' in project, false, 'no deadline is no key')
    project.todos.push(newTodo('기준선'), newTodo('초고', { due: '2027-01-29' }))
    project.milestones.push(newMilestone('실험 끝', '2026-12-20'))
    const written = encodeSwiftJSON(project)
    assert.match(written, /"plans" : \[\n\n  \]/, 'an empty array as Swift writes it')
    assert.doesNotMatch(written, /"start"/, 'a step with no start has no start key')
    assert.ok(written.indexOf('"createdAt"') < written.indexOf('"goal"') && written.indexOf('"goal"') < written.indexOf('"id"'), 'keys sorted')
    assert.ok(!written.endsWith('\n'), 'no newline at the end')
    const again = readProject(JSON.parse(written))
    assert.ok(again)
    assert.equal(encodeSwiftJSON(again), written)
  })

  await test('a file the Mac would refuse is not read — and so never written back', () => {
    const raw = JSON.parse(text) as Record<string, unknown>
    assert.equal(readProject({ ...raw, status: 'archived' }), null, 'a status a later build added')
    assert.equal(readProject({ ...raw, goal: undefined }), null, 'a key missing')
    assert.equal(readProject({ ...raw, deadline: '2027-02-30' }), null, 'a day that does not exist')
    const todos = (raw.todos as Record<string, unknown>[]).map((one) => ({ ...one }))
    todos[0].state = 'blocked'
    assert.equal(readProject({ ...raw, todos }), null, 'a step in no state')
    assert.ok(readProject({ ...raw, later: { kept: true } })?.later, 'an unknown key is carried')
  })

  await test('progress, the days left, and the D-day as it is said', () => {
    const project = readProject(JSON.parse(text))!
    assert.ok(Math.abs(projectProgress(project) - 2 / 6) < 1e-9)
    assert.equal(daysLeft(project, '2026-11-18'), 72)
    assert.equal(daysLeft(project, '2027-01-29'), 0)
    assert.equal(daysLeft(project, '2027-02-01'), -3)
    const none = newProject('P')
    assert.equal(daysLeft(none, '2026-11-18'), null)
    assert.equal(projectProgress(none), 0)
    assert.equal(projectProgress({ ...none, status: 'done' }), 1, 'done with no steps is all the way')
    setKorean(true)
    assert.deepEqual([ddayText(72), ddayText(0), ddayText(-3)], ['D-72', 'D-day', 'D+3'])
    setKorean(false)
    assert.deepEqual([ddayText(72), ddayText(0), ddayText(-3)], ['72d left', 'Due today', '3d over'])
  })

  await test('a step moves between states, before another or to the end (`Project.move`)', () => {
    const project = newProject('P')
    project.todos = [newTodo('a'), newTodo('b'), newTodo('c', { state: 'doing' })]
    const [a, , c] = project.todos.map((one) => one.id)
    moveTodo(project, a, 'doing')
    assert.deepEqual(todosIn(project, 'doing').map((one) => one.title), ['c', 'a'])
    moveTodo(project, a, 'doing', c)
    assert.deepEqual(todosIn(project, 'doing').map((one) => one.title), ['a', 'c'])
    moveTodo(project, c, 'todo')
    assert.deepEqual(project.todos.map((one) => one.title), ['b', 'c', 'a'], 'after the last step of its state')
  })

  await test('papers and notes are drawn on once; a paper dropped on a step is the step’s too', () => {
    const project = newProject('P')
    const step = newTodo('s')
    applyProjectEdit(project, { op: 'addTodo', todo: step })
    applyProjectEdit(project, { op: 'addPapers', papers: ['X', 'Y'] })
    applyProjectEdit(project, { op: 'addPapers', papers: ['X', 'Z'], todo: step.id })
    assert.deepEqual(project.papers, ['X', 'Y', 'Z'])
    assert.deepEqual(project.todos[0].papers, ['X', 'Z'])
    applyProjectEdit(project, { op: 'removeTodoPaper', todo: step.id, paper: 'X' })
    assert.deepEqual(project.todos[0].papers, ['Z'])
    applyProjectEdit(project, { op: 'addNotes', notes: ['261101_0007', '261101_0007'] })
    assert.deepEqual(project.notes, ['261101_0007'])
  })

  await test('a day cleared is a key taken away, as a nil Optional is', () => {
    const project = newProject('P')
    applyProjectEdit(project, { op: 'set', deadline: '2027-01-29' })
    assert.equal(project.deadline, '2027-01-29')
    applyProjectEdit(project, { op: 'set', deadline: null })
    assert.equal('deadline' in project, false)
    const step = newTodo('s', { start: '2026-11-01', due: '2026-11-08' })
    applyProjectEdit(project, { op: 'addTodo', todo: step })
    applyProjectEdit(project, { op: 'editTodo', id: step.id, start: null, memo: '메모' })
    assert.equal('start' in project.todos[0], false)
    assert.equal(project.todos[0].due, '2026-11-08')
    assert.equal(project.todos[0].memo, '메모')
  })

  await test('only edits that are edits are taken from the window', () => {
    assert.equal(acceptedProjectEdit({ op: 'set', deadline: '2027-13-01' }), null)
    assert.equal(acceptedProjectEdit({ op: 'set', name: '   ' }), null)
    assert.equal(acceptedProjectEdit({ op: 'moveTodo', id: 'a', state: 'blocked' }), null)
    assert.equal(acceptedProjectEdit({ op: 'addTodo', todo: { id: 'a', title: 'x' } }), null, 'a step without its fields')
    assert.equal(acceptedProjectEdit({ op: 'batch', edits: [{ op: 'batch', edits: [] }] }), null, 'no batch in a batch')
    assert.equal(acceptedProjectEdit({ op: 'rm -rf' }), null)
    assert.deepEqual(acceptedProjectEdit({ op: 'set', name: ' ICML ', deadline: null }), { op: 'set', name: 'ICML', deadline: null })
  })

  await test('the quick-add field reads a day off the end of the line', () => {
    const today = '2026-11-18' // a Wednesday
    assert.deepEqual(splitDay('초고 쓰기 금요일', today), { title: '초고 쓰기', day: '2026-11-20' })
    assert.deepEqual(splitDay('figures 12/3', today), { title: 'figures', day: '2026-12-03' })
    assert.deepEqual(splitDay('draft +1주', today), { title: 'draft', day: '2026-11-25' })
    assert.deepEqual(splitDay('review next fri', today), { title: 'review', day: '2026-11-27' })
    assert.deepEqual(splitDay('금요일', today), { title: '금요일', day: null }, 'a day alone is a title')
    assert.deepEqual(splitDay('read the related work', today), { title: 'read the related work', day: null })
  })

  await test('the span on screen: from when it began to its deadline, at least two weeks, holding everything', () => {
    const project = readProject(JSON.parse(text))!
    const span = projectSpan(project, '2026-11-18')
    assert.equal(span.start, '2026-10-31', 'the first step’s start')
    assert.equal(span.end, '2027-01-29', 'the deadline')
    assert.equal(span.days, 90)
    assert.equal(spanX(span, '2026-10-31', 900), 0)
    assert.equal(spanX(span, '2027-01-29', 900), 900)
    assert.equal(spanDay(span, 450, 900), '2026-12-15')
    assert.equal(spanDay(span, -50, 900), '2026-10-31', 'held inside')
    assert.equal(spanShift(span, 70, 900), 7)
    const fresh = newProject('P', new Date(2026, 10, 18, 12))
    const short = projectSpan(fresh, '2026-11-18')
    assert.equal(short.end, '2027-01-13', 'eight weeks on with no deadline')
    assert.deepEqual(todoBar(newTodo('x', { due: '2026-12-01' }), '2026-11-18'), { start: '2026-11-24', due: '2026-12-01' })
    assert.deepEqual(milestonesByDay(project).map((one) => one.title), ['관련 연구 정리', '실험 끝', '초고'])
  })

  suite('Projects on disk')

  await test('a project made, edited against the file, and taken away — another device’s step kept', async () => {
    const root = scratch()
    try {
      const files = new ProjectFiles(() => [library(root)])
      const made = await files.create('ICML 투고')
      assert.ok(!('error' in made))
      const id = (made as { project: Project }).project.id
      const file = path.join(root, '.papertime', 'projects', `${id}.json`)
      assert.ok(fs.existsSync(file))
      // Another device adds a step to the file meanwhile.
      const other = readProject(JSON.parse(fs.readFileSync(file, 'utf8')))!
      other.todos.push(newTodo('그림'))
      fs.writeFileSync(file, encodeSwiftJSON(other))
      const step = newTodo('기준선')
      const edited = await files.edit(id, { op: 'addTodo', todo: step })
      assert.ok(!('error' in edited))
      assert.deepEqual((edited as { project: Project }).project.todos.map((one) => one.title), ['그림', '기준선'])
      const onDisk = fs.readFileSync(file, 'utf8')
      assert.equal(onDisk, encodeSwiftJSON(readProject(JSON.parse(onDisk))))
      // An edit that changes nothing writes nothing.
      const before = fs.statSync(file).mtimeMs
      await new Promise((done) => setTimeout(done, 15))
      await files.edit(id, { op: 'addTodo', todo: step })
      assert.equal(fs.statSync(file).mtimeMs, before)
      // A probe's project goes outright; this run is no probe, so it is the Trash — not tested here.
      assert.equal((await files.edit(id, { op: 'nonsense' })).hasOwnProperty('error'), true)
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('every folder’s projects, the first folder winning, oldest first; a broken file left alone', async () => {
    const first = scratch()
    const second = scratch()
    try {
      const dir = (root: string) => {
        const at = path.join(root, '.papertime', 'projects')
        fs.mkdirSync(at, { recursive: true })
        return at
      }
      fs.writeFileSync(path.join(dir(first), 'BB3620E9-38BE-418D-B6A2-1D595A57F093.json'), text)
      const copy = JSON.parse(text)
      copy.name = 'second copy'
      fs.writeFileSync(path.join(dir(second), 'BB3620E9-38BE-418D-B6A2-1D595A57F093.json'), encodeSwiftJSON(copy))
      const older = newProject('older', new Date(Date.UTC(2026, 0, 1)))
      fs.writeFileSync(path.join(dir(second), `${older.id}.json`), encodeSwiftJSON(older))
      fs.writeFileSync(path.join(dir(second), 'broken.json'), '{ "id": ')
      fs.writeFileSync(path.join(dir(second), '.hidden.json'), encodeSwiftJSON(newProject('hidden')))
      const all = await readAllProjects([library(first), library(second)])
      assert.deepEqual(all.map((one) => one.project.name), ['older', 'ICML 투고 — 지속 언러닝'])
      assert.equal(fs.readFileSync(path.join(dir(second), 'broken.json'), 'utf8'), '{ "id": ', 'untouched')
    } finally {
      fs.rmSync(first, { recursive: true, force: true })
      fs.rmSync(second, { recursive: true, force: true })
    }
  })

  await test('the Mac’s file edited here stays the Mac’s file, but for the change', async () => {
    const root = scratch()
    try {
      const dir = path.join(root, '.papertime', 'projects')
      fs.mkdirSync(dir, { recursive: true })
      const file = path.join(dir, 'BB3620E9-38BE-418D-B6A2-1D595A57F093.json')
      fs.writeFileSync(file, text)
      const files = new ProjectFiles(() => [library(root)])
      await files.edit('BB3620E9-38BE-418D-B6A2-1D595A57F093', { op: 'moveTodo', id: '9A0882F4-FF31-4499-A353-8C5D0051B026', state: 'done' })
      const after = fs.readFileSync(file, 'utf8')
      const expected = readProject(JSON.parse(text))!
      moveTodo(expected, '9A0882F4-FF31-4499-A353-8C5D0051B026', 'done')
      assert.equal(after, encodeSwiftJSON(expected))
      // Moved back, the order differs (it went to the end of its state) — but the
      // bytes are still the Mac's shape: a Mac reading this file reads every key.
      assert.ok(readProject(JSON.parse(after)))
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })
}
