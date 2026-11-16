/**
 * One change to a plan, as the window asks for it and the main process does
 * it — on the file as it is on disk at that moment, not on the window's copy
 * (`plans.ts`). Two machines editing one plan through a cloud folder each
 * apply their own change to the other's file, instead of the last one to
 * save putting its whole copy over the first.
 */
import {
  addSection, addToPlan, moveBefore, moveSection, moveToEnd, removeFromPlan, removeSection, renameSection,
  type PlanEntry, type PlanSection, type ReadingPlan,
} from './readingPlan.js'

export type PlanEdit =
  | { op: 'rename'; name: string }
  | { op: 'add'; papers: string[]; section?: string | null }
  | { op: 'remove'; papers: string[] }
  | { op: 'moveBefore'; papers: string[]; target: string }
  | { op: 'moveToEnd'; papers: string[]; section: string | null }
  | { op: 'addSection'; name: string; id: string }
  | { op: 'renameSection'; id: string; name: string }
  | { op: 'removeSection'; id: string }
  | { op: 'moveSection'; id: string; by: number }
  /** An undo: the sections and the order put back as they were. */
  | { op: 'restore'; name: string; sections: PlanSection[]; entries: PlanEntry[] }

const isString = (value: unknown): value is string => typeof value === 'string'
const strings = (value: unknown): value is string[] => Array.isArray(value) && value.every(isString)

/** An edit from the window, checked; null when it is not one. */
export function acceptedEdit(value: unknown): PlanEdit | null {
  if (!value || typeof value !== 'object') return null
  const edit = value as Record<string, unknown>
  switch (edit.op) {
    case 'rename': return isString(edit.name) && edit.name.trim() ? { op: 'rename', name: edit.name.trim() } : null
    case 'add': return strings(edit.papers) && (edit.section == null || isString(edit.section))
      ? { op: 'add', papers: edit.papers, section: (edit.section as string | null | undefined) ?? null } : null
    case 'remove': return strings(edit.papers) ? { op: 'remove', papers: edit.papers } : null
    case 'moveBefore': return strings(edit.papers) && isString(edit.target) ? { op: 'moveBefore', papers: edit.papers, target: edit.target } : null
    case 'moveToEnd': return strings(edit.papers) && (edit.section === null || isString(edit.section))
      ? { op: 'moveToEnd', papers: edit.papers, section: edit.section as string | null } : null
    case 'addSection': return isString(edit.name) && edit.name.trim() && isString(edit.id) ? { op: 'addSection', name: edit.name.trim(), id: edit.id } : null
    case 'renameSection': return isString(edit.id) && isString(edit.name) && edit.name.trim() ? { op: 'renameSection', id: edit.id, name: edit.name.trim() } : null
    case 'removeSection': return isString(edit.id) ? { op: 'removeSection', id: edit.id } : null
    case 'moveSection': return isString(edit.id) && typeof edit.by === 'number' && Number.isFinite(edit.by) ? { op: 'moveSection', id: edit.id, by: Math.trunc(edit.by) } : null
    case 'restore': {
      if (!isString(edit.name) || !Array.isArray(edit.sections) || !Array.isArray(edit.entries)) return null
      const sections = edit.sections.filter((s): s is PlanSection => !!s && typeof s === 'object' && isString((s as PlanSection).id) && isString((s as PlanSection).name))
      const entries = edit.entries.filter((e): e is PlanEntry => !!e && typeof e === 'object' && isString((e as PlanEntry).paper)
        && ((e as PlanEntry).section === undefined || isString((e as PlanEntry).section)))
      return { op: 'restore', name: edit.name, sections, entries }
    }
    default: return null
  }
}

/** Does the edit to the plan, in place. */
export function applyPlanEdit(plan: ReadingPlan, edit: PlanEdit): void {
  switch (edit.op) {
    case 'rename': plan.name = edit.name; break
    case 'add': addToPlan(plan, edit.papers, edit.section ?? null); break
    case 'remove': removeFromPlan(plan, edit.papers); break
    case 'moveBefore': moveBefore(plan, edit.papers, edit.target); break
    case 'moveToEnd': moveToEnd(plan, edit.papers, edit.section); break
    case 'addSection': addSection(plan, edit.name, edit.id); break
    case 'renameSection': renameSection(plan, edit.id, edit.name); break
    case 'removeSection': removeSection(plan, edit.id); break
    case 'moveSection': moveSection(plan, edit.id, edit.by); break
    case 'restore':
      plan.name = edit.name
      plan.sections = edit.sections.map((s) => ({ ...s }))
      plan.entries = edit.entries.map((e) => ({ ...e }))
      break
  }
}
