/**
 * A project — a piece of work planned backwards from when it is due: a paper
 * to submit, an exam to sit — with the steps to get there and what it draws
 * on (1.1, the slip-box's 프로젝트). The Mac's `Project.swift`, rule for rule.
 *
 *   <library>/.papertime/projects/<id>.json
 *
 * One file each, beside the reading plans, so it travels with the papers it
 * uses and both builds read the same file. The file is written the way the
 * Mac's `JSONEncoder` writes it (`encodeSwiftJSON`): every key, sorted, days
 * as `YYYY-MM-DD` like the plans' `PlanDay`, `createdAt` as the records'
 * ISO-8601, and an optional left out when it is nil. A file this build
 * cannot read whole — a key missing, a status a later build added — is left
 * alone rather than half read and written back over.
 */
import { L } from './lang.js'
import { encodeSwiftJSON, isoTimestamp, makeUUID } from './coding.js'
import { addDays, dayOrdinal, isDay, readDay, todayDay } from './readingPlan.js'

export type ProjectStatus = 'active' | 'paused' | 'done'
export type TodoState = 'todo' | 'doing' | 'done'

export const PROJECT_STATUSES: readonly ProjectStatus[] = ['active', 'paused', 'done']
export const TODO_STATES: readonly TodoState[] = ['todo', 'doing', 'done']

/** A point on the way, on a day. */
export interface Milestone {
  id: string
  title: string
  day: string
  done: boolean
  [key: string]: unknown
}

/** One step: to do, under way, or done — and what it needs. */
export interface Todo {
  id: string
  title: string
  state: TodoState
  /** When it starts and when it is due, for the timeline. Absent is none. */
  start?: string
  due?: string
  papers: string[]
  notes: string[]
  memo: string
  [key: string]: unknown
}

export interface Project {
  id: string
  name: string
  /** One line on what it is for. */
  goal: string
  /** When it is due — a submission deadline, an exam. Absent is none. */
  deadline?: string
  status: ProjectStatus
  milestones: Milestone[]
  todos: Todo[]
  /** The papers it draws on. */
  papers: string[]
  /** The notes it draws on, by identifier. */
  notes: string[]
  /** The reading plans it reads through. */
  plans: string[]
  /** As the file says it — kept as written, so it is written back to the byte. */
  createdAt: string
  [key: string]: unknown
}

// MARK: - Reading and writing

const isString = (value: unknown): value is string => typeof value === 'string'
const strings = (value: unknown): value is string[] => Array.isArray(value) && value.every(isString)
const optionalDay = (value: unknown): boolean => value === undefined || isDay(value)

function readMilestone(value: unknown): Milestone | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  const raw = value as Record<string, unknown>
  if (!isString(raw.id) || !isString(raw.title) || !isDay(raw.day) || typeof raw.done !== 'boolean') return null
  return { ...raw } as Milestone
}

function readTodo(value: unknown): Todo | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  const raw = value as Record<string, unknown>
  if (!isString(raw.id) || !isString(raw.title) || !(TODO_STATES as readonly unknown[]).includes(raw.state)) return null
  if (!strings(raw.papers) || !strings(raw.notes) || !isString(raw.memo)) return null
  if (!optionalDay(raw.start) || !optionalDay(raw.due)) return null
  return { ...raw, papers: [...raw.papers], notes: [...raw.notes] } as Todo
}

/**
 * A project read from a file, or null when it is not one the Mac would read
 * — the Mac's decoding takes every key or none, and so does this, so that a
 * file it would refuse is never rewritten here with pieces missing.
 */
export function readProject(value: unknown): Project | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  const raw = value as Record<string, unknown>
  if (!isString(raw.id) || !isString(raw.name) || !isString(raw.goal) || !isString(raw.createdAt)) return null
  if (Number.isNaN(new Date(raw.createdAt).getTime())) return null
  if (!(PROJECT_STATUSES as readonly unknown[]).includes(raw.status)) return null
  if (!optionalDay(raw.deadline)) return null
  if (!Array.isArray(raw.milestones) || !Array.isArray(raw.todos)) return null
  if (!strings(raw.papers) || !strings(raw.notes) || !strings(raw.plans)) return null
  const milestones = raw.milestones.map(readMilestone)
  const todos = raw.todos.map(readTodo)
  if (milestones.some((one) => one === null) || todos.some((one) => one === null)) return null
  return {
    ...raw,
    milestones: milestones as Milestone[],
    todos: todos as Todo[],
    papers: [...raw.papers],
    notes: [...raw.notes],
    plans: [...raw.plans],
  } as Project
}

/** A new project, named, with nothing in it yet. */
export function newProject(name: string, now: Date = new Date()): Project {
  return {
    id: makeUUID(),
    name,
    goal: '',
    status: 'active',
    milestones: [],
    todos: [],
    papers: [],
    notes: [],
    plans: [],
    createdAt: isoTimestamp(now),
  }
}

export function newTodo(title: string, fields: Partial<Omit<Todo, 'id' | 'title'>> = {}): Todo {
  const todo: Todo = { id: makeUUID(), title, state: 'todo', papers: [], notes: [], memo: '', ...fields }
  if (todo.start === undefined) delete todo.start
  if (todo.due === undefined) delete todo.due
  return todo
}

export function newMilestone(title: string, day: string, done = false): Milestone {
  return { id: makeUUID(), title, day, done }
}

/** A copy that shares nothing with the original — an edit tried on the window's copy first. */
export function copyProject(project: Project): Project {
  return structuredClone(project)
}

// MARK: - Reading a project

/** How far through: the steps done of all of them — 0 with none, 1 when it is done with none. */
export function projectProgress(project: Project): number {
  if (project.todos.length === 0) return project.status === 'done' ? 1 : 0
  return project.todos.filter((todo) => todo.state === 'done').length / project.todos.length
}

/** The days left to the deadline: 0 on the day, below 0 past it; null with no deadline. */
export function daysLeft(project: Project, today: string): number | null {
  return project.deadline ? dayOrdinal(project.deadline) - dayOrdinal(today) : null
}

/** The steps in one state, in the order kept. */
export function todosIn(project: Project, state: TodoState): Todo[] {
  return project.todos.filter((todo) => todo.state === state)
}

/** The milestones in the order of their days. */
export function milestonesByDay(project: Project): Milestone[] {
  return [...project.milestones].sort((a, b) => (a.day < b.day ? -1 : a.day > b.day ? 1 : 0))
}

/** «D-72», «D-day», «D+3» — the way a deadline is counted here (`ProjectText.dday`). */
export function ddayText(days: number): string {
  if (days === 0) return L('D-day', 'Due today')
  if (days > 0) return L(`D-${days}`, `${days}d left`)
  return L(`D+${-days}`, `${-days}d over`)
}

export function projectStatusLabel(status: ProjectStatus): string {
  switch (status) {
    case 'active': return L('진행 중', 'Active')
    case 'paused': return L('멈춤', 'Paused')
    case 'done': return L('끝남', 'Done')
  }
}

export function todoStateLabel(state: TodoState): string {
  switch (state) {
    case 'todo': return L('할 일', 'To Do')
    case 'doing': return L('하는 중', 'Doing')
    case 'done': return L('끝', 'Done')
  }
}

/** The projects still being worked on, for the sidebar. */
export function activeProjects<T extends { project: Project }>(all: T[]): T[] {
  return all.filter((one) => one.project.status !== 'done')
}

/**
 * The step's title and the day at its end, when the end reads as one — the
 * quick-add field reads «초고 금요일», «figures 12/3», «draft +1주»
 * (`ProjectPage.splitDay`): the last two words first, then the last one.
 */
export function splitDay(text: string, today: string): { title: string; day: string | null } {
  const words = text.split(' ').filter((word) => word.length > 0)
  for (const take of [2, 1]) {
    if (words.length <= take) continue
    const day = readDay(words.slice(-take).join(' '), today)
    if (day) return { title: words.slice(0, -take).join(' '), day }
  }
  return { title: text, day: null }
}

/**
 * The days a project spans on screen: from when it began (or today) to its
 * deadline (or eight weeks on), widened to hold every milestone and every
 * step's days — at least two weeks (`ProjectSpan`).
 */
export interface ProjectSpan {
  start: string
  end: string
  /** Whole days from start to end, at least one. */
  days: number
}

export function projectSpan(project: Project, today: string): ProjectSpan {
  const began = todayDay(new Date(project.createdAt))
  let first = began < today ? began : today
  let last = project.deadline ?? addDays(today, 56)
  for (const milestone of project.milestones) {
    if (milestone.day < first) first = milestone.day
    if (milestone.day > last) last = milestone.day
  }
  for (const todo of project.todos) {
    if (todo.start && todo.start < first) first = todo.start
    if (todo.due && todo.due > last) last = todo.due
  }
  if (dayOrdinal(last) - dayOrdinal(first) < 14) last = addDays(first, 14)
  return { start: first, end: last, days: Math.max(1, dayOrdinal(last) - dayOrdinal(first)) }
}

/** Where a day stands along `width` points of the span. */
export function spanX(span: ProjectSpan, day: string, width: number): number {
  return ((dayOrdinal(day) - dayOrdinal(span.start)) / span.days) * width
}

/** The day at `x` points along the span, held inside it. */
export function spanDay(span: ProjectSpan, x: number, width: number): string {
  const offset = Math.round((x / Math.max(1, width)) * span.days)
  return addDays(span.start, Math.min(Math.max(offset, 0), span.days))
}

/** Whole days a drag of `dx` points covers along the span. */
export function spanShift(span: ProjectSpan, dx: number, width: number): number {
  return Math.round((dx / Math.max(1, width)) * span.days)
}

/** A step's bar on the timeline: its days, or a week either side of what it has. */
export function todoBar(todo: Todo, today: string): { start: string; due: string } {
  const due = todo.due ?? (todo.start ? addDays(todo.start, 7) : addDays(today, 7))
  const start = todo.start ?? addDays(due, -7)
  return { start, due }
}

// MARK: - Changing a project

/**
 * One change to a project, as the window asks for it and the main process
 * makes it — on the file as it is on disk at that moment, so another
 * device's change since the last reading is kept (`updateProject`). The
 * same function makes it on the window's copy first, so the page answers at
 * once.
 */
export type ProjectEdit =
  | { op: 'set'; name?: string; goal?: string; deadline?: string | null; status?: ProjectStatus }
  | { op: 'addTodo'; todo: Todo }
  | { op: 'editTodo'; id: string; title?: string; memo?: string; start?: string | null; due?: string | null }
  | { op: 'moveTodo'; id: string; state: TodoState; before?: string | null }
  | { op: 'removeTodo'; id: string }
  | { op: 'addMilestone'; milestone: Milestone }
  | { op: 'editMilestone'; id: string; title?: string; day?: string; done?: boolean }
  | { op: 'removeMilestone'; id: string }
  /** Papers dropped on the project, or on one of its steps. */
  | { op: 'addPapers'; papers: string[]; todo?: string | null }
  | { op: 'removePaper'; paper: string }
  | { op: 'removeTodoPaper'; todo: string; paper: string }
  | { op: 'addNotes'; notes: string[] }
  | { op: 'removeNote'; note: string }
  | { op: 'addPlan'; plan: string }
  | { op: 'removePlan'; plan: string }
  /** Several at once, as one write. */
  | { op: 'batch'; edits: ProjectEdit[] }

const isState = (value: unknown): value is TodoState => (TODO_STATES as readonly unknown[]).includes(value)
const isStatus = (value: unknown): value is ProjectStatus => (PROJECT_STATUSES as readonly unknown[]).includes(value)
const dayOrNull = (value: unknown): boolean => value === undefined || value === null || isDay(value)

/** An edit from the window, checked; null when it is not one. */
export function acceptedProjectEdit(value: unknown, nested = false): ProjectEdit | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  const edit = value as Record<string, unknown>
  switch (edit.op) {
    case 'set': {
      if (edit.name !== undefined && !(isString(edit.name) && edit.name.trim())) return null
      if (edit.goal !== undefined && !isString(edit.goal)) return null
      if (!dayOrNull(edit.deadline)) return null
      if (edit.status !== undefined && !isStatus(edit.status)) return null
      const out: ProjectEdit = { op: 'set' }
      if (isString(edit.name)) out.name = edit.name.trim()
      if (isString(edit.goal)) out.goal = edit.goal.trim()
      if (edit.deadline !== undefined) out.deadline = (edit.deadline as string | null)
      if (isStatus(edit.status)) out.status = edit.status
      return out
    }
    case 'addTodo': {
      const todo = readTodo(edit.todo)
      return todo && todo.title.trim() ? { op: 'addTodo', todo } : null
    }
    case 'editTodo': {
      if (!isString(edit.id)) return null
      if (edit.title !== undefined && !(isString(edit.title) && edit.title.trim())) return null
      if (edit.memo !== undefined && !isString(edit.memo)) return null
      if (!dayOrNull(edit.start) || !dayOrNull(edit.due)) return null
      const out: ProjectEdit = { op: 'editTodo', id: edit.id }
      if (isString(edit.title)) out.title = edit.title.trim()
      if (isString(edit.memo)) out.memo = edit.memo
      if (edit.start !== undefined) out.start = edit.start as string | null
      if (edit.due !== undefined) out.due = edit.due as string | null
      return out
    }
    case 'moveTodo':
      return isString(edit.id) && isState(edit.state) && (edit.before == null || isString(edit.before))
        ? { op: 'moveTodo', id: edit.id, state: edit.state, before: (edit.before as string | null | undefined) ?? null } : null
    case 'removeTodo': return isString(edit.id) ? { op: 'removeTodo', id: edit.id } : null
    case 'addMilestone': {
      const milestone = readMilestone(edit.milestone)
      return milestone && milestone.title.trim() ? { op: 'addMilestone', milestone } : null
    }
    case 'editMilestone': {
      if (!isString(edit.id)) return null
      if (edit.title !== undefined && !(isString(edit.title) && edit.title.trim())) return null
      if (edit.day !== undefined && !isDay(edit.day)) return null
      if (edit.done !== undefined && typeof edit.done !== 'boolean') return null
      const out: ProjectEdit = { op: 'editMilestone', id: edit.id }
      if (isString(edit.title)) out.title = edit.title.trim()
      if (isString(edit.day)) out.day = edit.day
      if (typeof edit.done === 'boolean') out.done = edit.done
      return out
    }
    case 'removeMilestone': return isString(edit.id) ? { op: 'removeMilestone', id: edit.id } : null
    case 'addPapers':
      return strings(edit.papers) && (edit.todo == null || isString(edit.todo))
        ? { op: 'addPapers', papers: [...edit.papers], todo: (edit.todo as string | null | undefined) ?? null } : null
    case 'removePaper': return isString(edit.paper) ? { op: 'removePaper', paper: edit.paper } : null
    case 'removeTodoPaper': return isString(edit.todo) && isString(edit.paper) ? { op: 'removeTodoPaper', todo: edit.todo, paper: edit.paper } : null
    case 'addNotes': return strings(edit.notes) ? { op: 'addNotes', notes: [...edit.notes] } : null
    case 'removeNote': return isString(edit.note) ? { op: 'removeNote', note: edit.note } : null
    case 'addPlan': return isString(edit.plan) ? { op: 'addPlan', plan: edit.plan } : null
    case 'removePlan': return isString(edit.plan) ? { op: 'removePlan', plan: edit.plan } : null
    case 'batch': {
      if (nested || !Array.isArray(edit.edits)) return null
      const edits = edit.edits.map((one) => acceptedProjectEdit(one, true))
      return edits.every((one) => one !== null) ? { op: 'batch', edits: edits as ProjectEdit[] } : null
    }
    default: return null
  }
}

/** A day set, or taken away when null — an absent key, as a nil Optional is. */
function setDay<T extends Record<string, unknown>>(target: T, key: string, day: string | null | undefined) {
  if (day === undefined) return
  if (day === null) delete target[key]
  else (target as Record<string, unknown>)[key] = day
}

/** Papers it does not draw on yet, drawn on now. */
function addOnce(list: string[], ids: string[]) {
  for (const id of ids) if (!list.includes(id)) list.push(id)
}

/**
 * Puts a step in a state, before another step there or at the end of that
 * state's steps (`Project.move(_:to:before:)`).
 */
export function moveTodo(project: Project, id: string, state: TodoState, before: string | null = null) {
  const index = project.todos.findIndex((todo) => todo.id === id)
  if (index < 0) return
  const [todo] = project.todos.splice(index, 1)
  todo.state = state
  const at = before ? project.todos.findIndex((one) => one.id === before) : -1
  if (at >= 0) {
    project.todos.splice(at, 0, todo)
    return
  }
  let last = -1
  project.todos.forEach((one, position) => { if (one.state === state) last = position })
  if (last >= 0) project.todos.splice(last + 1, 0, todo)
  else project.todos.push(todo)
}

/** Does the edit to the project, in place. */
export function applyProjectEdit(project: Project, edit: ProjectEdit): void {
  const todo = (id: string) => project.todos.find((one) => one.id === id)
  const milestone = (id: string) => project.milestones.find((one) => one.id === id)
  switch (edit.op) {
    case 'set':
      if (edit.name !== undefined) project.name = edit.name
      if (edit.goal !== undefined) project.goal = edit.goal
      setDay(project, 'deadline', edit.deadline)
      if (edit.status !== undefined) project.status = edit.status
      break
    case 'addTodo':
      if (!todo(edit.todo.id)) project.todos.push(structuredClone(edit.todo))
      break
    case 'editTodo': {
      const found = todo(edit.id)
      if (!found) break
      if (edit.title !== undefined) found.title = edit.title
      if (edit.memo !== undefined) found.memo = edit.memo
      setDay(found, 'start', edit.start)
      setDay(found, 'due', edit.due)
      break
    }
    case 'moveTodo': moveTodo(project, edit.id, edit.state, edit.before ?? null); break
    case 'removeTodo': project.todos = project.todos.filter((one) => one.id !== edit.id); break
    case 'addMilestone':
      if (!milestone(edit.milestone.id)) project.milestones.push(structuredClone(edit.milestone))
      break
    case 'editMilestone': {
      const found = milestone(edit.id)
      if (!found) break
      if (edit.title !== undefined) found.title = edit.title
      if (edit.day !== undefined) found.day = edit.day
      if (edit.done !== undefined) found.done = edit.done
      break
    }
    case 'removeMilestone': project.milestones = project.milestones.filter((one) => one.id !== edit.id); break
    case 'addPapers': {
      addOnce(project.papers, edit.papers)
      const step = edit.todo ? todo(edit.todo) : undefined
      if (step) addOnce(step.papers, edit.papers)
      break
    }
    case 'removePaper': project.papers = project.papers.filter((one) => one !== edit.paper); break
    case 'removeTodoPaper': {
      const found = todo(edit.todo)
      if (found) found.papers = found.papers.filter((one) => one !== edit.paper)
      break
    }
    case 'addNotes': addOnce(project.notes, edit.notes); break
    case 'removeNote': project.notes = project.notes.filter((one) => one !== edit.note); break
    case 'addPlan': addOnce(project.plans, [edit.plan]); break
    case 'removePlan': project.plans = project.plans.filter((one) => one !== edit.plan); break
    case 'batch': for (const one of edit.edits) applyProjectEdit(project, one); break
  }
}

/** Whether two readings of a project say the same — nothing to write when they do. */
export function sameProject(a: Project, b: Project): boolean {
  return encodeSwiftJSON(a) === encodeSwiftJSON(b)
}

/** In the order the Mac lists them: when they were made, then by identifier. */
export function compareProjects(a: Project, b: Project): number {
  const at = new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime()
  if (at !== 0) return at
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
}
