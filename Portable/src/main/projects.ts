/**
 * The projects on disk — the Mac's files, byte for byte (`shared/project.ts`,
 * `encodeSwiftJSON`), read and written the way the plans are:
 *
 *   <library>/.papertime/projects/<id>.json
 *
 * Every project lives in one library folder and is written back there.
 * Every edit reads the file again first and makes the one change to what is
 * on disk (`LibraryStore.updateProject`), so two machines editing a project
 * through a cloud folder do not put their whole copies over each other. One
 * edit at a time per file.
 */
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import { shell } from 'electron'
import { probe } from './probeMode.js'
import { samePath } from '../shared/paths.js'
import { acceptedProjectEdit, applyProjectEdit, compareProjects, newProject, readProject, sameProject, type Project } from '../shared/project.js'
import * as L from './layout.js'
import { readJSON, writeJSON, type Library } from './library.js'
import { noteOwnWrite } from './ownWrites.js'

import type { ProjectDTO } from '../shared/api.js'

/** Every project in one library folder. A file that does not read is left alone. */
export async function readProjects(root: string): Promise<Project[]> {
  let names: string[]
  try {
    names = await fsp.readdir(L.projectsDir(root))
  } catch {
    return []
  }
  const read = await Promise.all(names
    // Dot files left out by name, as the Mac does, not by the hidden flag
    // a cloud drive sets on what it is still bringing down.
    .filter((name) => name.endsWith('.json') && !name.startsWith('.'))
    .map(async (name) => readProject(await readJSON(path.join(L.projectsDir(root), name)).catch(() => null))))
  return read.filter((project): project is Project => project !== null)
}

/** Projects from every folder, one per id — the first folder that has it wins — oldest first. */
export async function readAllProjects(libraries: Library[]): Promise<ProjectDTO[]> {
  const out: ProjectDTO[] = []
  const seen = new Set<string>()
  for (const library of libraries) {
    for (const project of await readProjects(library.root)) {
      const key = project.id.toUpperCase()
      if (seen.has(key)) continue
      seen.add(key)
      out.push({ root: library.root, project })
    }
  }
  return out.sort((a, b) => compareProjects(a.project, b.project))
}

export class ProjectFiles {
  /** Which folder each project was read from. */
  private readonly rootOf = new Map<string, string>()
  /** One write at a time per file. */
  private readonly queues = new Map<string, Promise<unknown>>()

  constructor(private readonly libraries: () => Library[]) {}

  private inLine<T>(key: string, work: () => Promise<T>): Promise<T> {
    const before = this.queues.get(key) ?? Promise.resolve()
    const next = before.then(work, work)
    this.queues.set(key, next.catch(() => undefined))
    return next
  }

  async load(): Promise<ProjectDTO[]> {
    const projects = await readAllProjects(this.libraries())
    for (const one of projects) this.rootOf.set(one.project.id, one.root)
    return projects
  }

  private async locate(id: string): Promise<string | null> {
    const known = this.rootOf.get(id)
    if (known && fs.existsSync(L.projectPath(known, id))) return known
    await this.load()
    return this.rootOf.get(id) ?? null
  }

  /** A new project in the first library folder, as the Mac makes one. */
  async create(name: string, root?: string): Promise<ProjectDTO | { error: string }> {
    const all = this.libraries()
    const library = (root ? all.find((one) => samePath(one.root, root)) : undefined) ?? all[0]
    if (!library) return { error: 'No library is open.' }
    const trimmed = name.trim()
    if (!trimmed) return { error: 'A project needs a name.' }
    const project = newProject(trimmed)
    await writeJSON(L.projectPath(library.root, project.id), project)
    this.rootOf.set(project.id, library.root)
    return { root: library.root, project }
  }

  /** One change, made to the file as it is now. Nothing is written when it changes nothing. */
  edit(id: string, raw: unknown): Promise<ProjectDTO | { error: string }> {
    const edit = acceptedProjectEdit(raw)
    if (!edit) return Promise.resolve({ error: 'Not an edit.' })
    return this.inLine(`project:${id}`, async () => {
      const root = await this.locate(id)
      if (!root) return { error: 'The project is gone.' }
      const file = L.projectPath(root, id)
      const before = readProject(await readJSON(file).catch(() => null))
      if (!before) return { error: 'The project could not be read.' }
      const project = structuredClone(before)
      applyProjectEdit(project, edit)
      if (!sameProject(before, project)) await writeJSON(file, project)
      return { root, project }
    })
  }

  /** To the trash, or gone when the desktop has none. The papers and notes it drew on stay. */
  remove(id: string): Promise<boolean> {
    return this.inLine(`project:${id}`, async () => {
      const root = await this.locate(id)
      if (!root) return false
      const file = L.projectPath(root, id)
      noteOwnWrite(file)
      noteOwnWrite(path.dirname(file))
      // A probe's projects are its own scratch: gone outright, never into
      // the Trash of the person whose machine it runs on.
      if (probe.isRun) {
        await fsp.rm(file, { force: true })
      } else {
        try {
          await shell.trashItem(file)
        } catch {
          await fsp.rm(file, { force: true })
        }
      }
      this.rootOf.delete(id)
      return true
    })
  }
}
