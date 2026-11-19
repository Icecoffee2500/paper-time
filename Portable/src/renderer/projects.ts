/**
 * The slip-box's projects in the window (1.1, the Mac's
 * `LibraryModel+Projects.swift`): read beside the plans, one file each, and
 * edited against the file as it is now.
 *
 * Every change is made on the window's copy first, so the page answers at
 * once, and then by the main process on the file as it is on disk
 * (`main/projects.ts`) — whose answer is put in place of the copy.
 */
import { call, flags } from './bridge.js'
import { ensurePagePane } from './layout.js'
import { changed, projectByID, setShelf, store } from './state.js'
import { toast } from './ui/toolbar.js'
import { askForName, askToConfirm } from './ui/ask.js'
import { L } from '../shared/lang.js'
import { addDays } from '../shared/readingPlan.js'
import { knowledgeNotes } from '../shared/noteAreas.js'
import {
  applyProjectEdit, copyProject, newMilestone, newTodo, projectStatusLabel, type ProjectEdit, type ProjectStatus,
} from '../shared/project.js'
import type { ProjectDTO } from '../shared/api.js'

function putProject(dto: ProjectDTO) {
  const at = store.projects.findIndex((one) => one.project.id === dto.project.id)
  store.projects = at < 0 ? [...store.projects, dto] : [...store.projects.slice(0, at), dto, ...store.projects.slice(at + 1)]
}

/** Every project read again — another window or machine changed one. */
export async function reloadProjects() {
  store.projects = await call('projects:load')
  // The shelf moves only when the project it showed is gone: a change from
  // another machine must not put away the step being edited here.
  if (store.shelf.kind === 'projects' && store.shelf.id && !projectByID(store.shelf.id)) {
    setShelf({ kind: 'projects', id: null })
    changed('projects', 'shelf')
    return
  }
  changed('projects')
}

/** A project shown: its page, in the projects' place. */
export function showProject(id: string | null) {
  setShelf({ kind: 'projects', id })
  // A project chosen with no page in the row: one comes, for its page (1.1).
  if (id !== null) ensurePagePane()
  changed('shelf')
}

/** A new project, in the first library folder, open. */
export async function createProject(name: string): Promise<string | null> {
  const made = await call('projects:create', { name })
  if ('error' in made) {
    toast(L('프로젝트를 만들지 못했어요.', "Paper Time couldn't make the project."))
    return null
  }
  putProject(made)
  showProject(made.project.id)
  changed('projects')
  return made.project.id
}

/** «새 프로젝트…»: the name, asked in a sheet. */
export async function askNewProject() {
  const name = await askForName({
    title: L('새 프로젝트', 'New Project'),
    placeholder: L('프로젝트 이름', 'Project Name'),
    confirm: L('만들기', 'Create'),
  })
  if (name) await createProject(name)
}

/** One change: on screen straight away, then against its file. */
export async function editProject(id: string, edit: ProjectEdit): Promise<boolean> {
  const found = projectByID(id)
  if (!found) return false
  const local = copyProject(found.project)
  applyProjectEdit(local, edit)
  putProject({ root: found.root, project: local })
  changed('projects')
  const answer = await call('projects:edit', { id, edit })
  if ('error' in answer) {
    toast(L('프로젝트를 고치지 못했어요.', "Paper Time couldn't change the project."))
    await reloadProjects()
    return false
  }
  putProject(answer)
  changed('projects')
  return true
}

export async function renameProject(id: string) {
  const found = projectByID(id)
  if (!found) return
  const name = await askForName({
    title: L('프로젝트 이름 바꾸기', 'Rename Project'),
    placeholder: L('프로젝트 이름', 'Project Name'),
    confirm: L('바꾸기', 'Rename'),
    initial: found.project.name,
  })
  if (!name || name === found.project.name) return
  await editProject(id, { op: 'set', name })
}

export function setProjectStatus(id: string, status: ProjectStatus) {
  return editProject(id, { op: 'set', status })
}

/** The file to the Trash, asked first. The papers and notes it drew on stay. */
export async function deleteProject(id: string) {
  const found = projectByID(id)
  if (!found) return
  const yes = await askToConfirm({
    title: L(`‘${found.project.name}’ 프로젝트를 지울까요?`, `Delete “${found.project.name}”?`),
    message: L('논문과 노트는 그대로 있어요. 프로젝트 파일만 휴지통으로 가요.', 'The papers and notes stay. Only the project goes to the Trash.'),
    confirm: L('지우기', 'Delete'),
    danger: true,
  })
  if (!yes) return
  if (!(await call('projects:delete', { id }))) {
    toast(L('프로젝트를 지우지 못했어요.', "Paper Time couldn't delete the project."))
    return
  }
  store.projects = store.projects.filter((one) => one.project.id !== id)
  if (store.shelf.kind === 'projects' && store.shelf.id === id) setShelf({ kind: 'projects', id: null })
  changed('projects', 'shelf')
}

/** Papers dropped on a project, or on one of its steps. */
export async function addToProject(id: string, papers: string[], todo: string | null = null) {
  const found = projectByID(id)
  if (!found || papers.length === 0) return
  const fresh = papers.filter((one) => !found.project.papers.includes(one))
  await editProject(id, { op: 'addPapers', papers, todo })
  if (todo) return
  toast(fresh.length > 0
    ? L(`‘${found.project.name}’에 논문 ${fresh.length}편을 더했어요.`, `Added ${fresh.length} paper${fresh.length === 1 ? '' : 's'} to “${found.project.name}”.`)
    : L('이미 프로젝트에 있는 논문이에요.', 'Already in the project.'))
}

export function addNotesToProject(id: string, notes: string[]) {
  return editProject(id, { op: 'addNotes', notes })
}

/** The status, as a menu's rows — a tick beside the one it has. */
export function statusEntries(id: string): { label: string; checked: boolean; action: () => void }[] {
  const found = projectByID(id)
  return (['active', 'paused', 'done'] as const).map((status) => ({
    label: projectStatusLabel(status),
    checked: found?.project.status === status,
    action: () => void setProjectStatus(id, status),
  }))
}

/**
 * `--papertime-project-sample=1`: a project with milestones, steps and
 * materials, made in a probe's library only — never one somebody reads in
 * (`LibraryModel.sampleProject`).
 */
export async function sampleProject(): Promise<string | null> {
  if (!flags.probe || store.projects.length > 0) return null
  const id = await createProject(L('ICML 투고 — 지속 언러닝', 'ICML submission — continual unlearning'))
  if (!id) return null
  const today = store.today
  const papers = store.papers.filter((entry) => !entry.meta.parentID && entry.meta.shelfKind === 'paper').slice(0, 3).map((entry) => entry.id)
  const book = store.papers.find((entry) => entry.meta.shelfKind === 'book')?.id
  const note = knowledgeNotes(store.notes)[0]?.id
  const edits: ProjectEdit[] = [
    {
      op: 'set',
      goal: L('이어지는 삭제 요청에서도 정확도를 지키는 언러닝 방법을 논문으로', 'An unlearning method that keeps accuracy across a stream of deletions, written up'),
      deadline: addDays(today, 72),
    },
    { op: 'addMilestone', milestone: newMilestone(L('관련 연구 정리', 'Related work'), addDays(today, -10), true) },
    { op: 'addMilestone', milestone: newMilestone(L('실험 끝', 'Experiments done'), addDays(today, 20)) },
    { op: 'addMilestone', milestone: newMilestone(L('초고', 'First draft'), addDays(today, 50)) },
    { op: 'addTodo', todo: newTodo(L('기준선 셋 재현', 'Reproduce three baselines'), { state: 'done', start: addDays(today, -18), due: addDays(today, -4) }) },
    { op: 'addTodo', todo: newTodo(L('평가 축 정하기', 'Settle the evaluation axes'), { state: 'done', start: addDays(today, -14), due: addDays(today, -8) }) },
    { op: 'addTodo', todo: newTodo(L('연속 삭제 실험 — CIFAR-100', 'Sequential deletion — CIFAR-100'), { state: 'doing', start: addDays(today, -3), due: addDays(today, 4), papers: papers.slice(0, 1) }) },
    { op: 'addTodo', todo: newTodo(L('이론 부분 증명 다듬기', 'Tighten the proofs'), { start: addDays(today, 8), due: addDays(today, 18), papers: book ? [book] : [] }) },
    { op: 'addTodo', todo: newTodo(L('그림 1 · 2 그리기', 'Figures 1 and 2'), { start: addDays(today, 22), due: addDays(today, 32) }) },
    { op: 'addTodo', todo: newTodo(L('초고 쓰기', 'Write the draft'), { start: addDays(today, 34), due: addDays(today, 53) }) },
    { op: 'addPapers', papers: [...papers, ...(book ? [book] : [])] },
  ]
  if (note) edits.push({ op: 'addNotes', notes: [note] })
  await editProject(id, { op: 'batch', edits })
  return id
}
