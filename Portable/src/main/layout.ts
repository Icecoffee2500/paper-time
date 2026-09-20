/**
 * Where everything sits inside a library folder — `LibraryLayout.swift`.
 *
 * ```
 * <library root>/
 * ├── Attention Is All You Need.pdf     ← your PDFs, under their own names
 * └── .papertime/                        ← everything the app adds, out of sight
 *     ├── library.json
 *     ├── collections.json
 *     └── papers/
 *         └── 4F3A1C08-…/
 *             ├── meta.json
 *             ├── state.json
 *             ├── ink/p0003.drawing      ← the Mac's PencilKit original
 *             ├── ink/p0003.json         ← this port's equivalent
 *             ├── sketch/p0003.json      ← shapes, arrows, text: shared
 *             └── marks/<device>.json
 * ```
 */
import path from 'node:path'
import fs from 'node:fs'

export const SUPPORT_DIR = '.papertime'
export const MANIFEST_FILE = 'library.json'
export const COLLECTIONS_FILE = 'collections.json'
export const PAPERS_DIR = 'papers'
export const META_FILE = 'meta.json'
export const STATE_FILE = 'state.json'
export const NOTES_DIR = 'notes'
export const INK_DIR = 'ink'
export const SKETCH_DIR = 'sketch'
export const MARKS_DIR = 'marks'
export const TRASH_DIR = 'Trash'

export const supportDir = (root: string) => path.join(root, SUPPORT_DIR)
export const manifestPath = (root: string) => path.join(supportDir(root), MANIFEST_FILE)
export const collectionsPath = (root: string) => path.join(supportDir(root), COLLECTIONS_FILE)
export const papersDir = (root: string) => path.join(supportDir(root), PAPERS_DIR)
export const slipBoxDir = (root: string) => path.join(supportDir(root), NOTES_DIR)
export const trashDir = (root: string) => path.join(root, TRASH_DIR)
export const paperDir = (root: string, id: string) => path.join(papersDir(root), id)

export const metaPath = (root: string, id: string) => path.join(paperDir(root, id), META_FILE)
export const statePath = (root: string, id: string) => path.join(paperDir(root, id), STATE_FILE)
export const inkDir = (root: string, id: string) => path.join(paperDir(root, id), INK_DIR)
export const sketchDir = (root: string, id: string) => path.join(paperDir(root, id), SKETCH_DIR)
export const marksDir = (root: string, id: string) => path.join(paperDir(root, id), MARKS_DIR)
export const notesDir = (root: string, id: string) => path.join(paperDir(root, id), NOTES_DIR)

const pageStem = (pageIndex: number) => `p${String(pageIndex).padStart(4, '0')}`

/** This port's ink sidecar. The Mac's loader only looks for `.drawing`, so
 *  the two sit in the same folder without ever being mistaken for each other. */
export const inkFileName = (pageIndex: number) => `${pageStem(pageIndex)}.json`
/** The Mac's PencilKit original, which this port can see but not read. */
export const appleInkFileName = (pageIndex: number) => `${pageStem(pageIndex)}.drawing`
export const sketchFileName = (pageIndex: number) => `${pageStem(pageIndex)}.json`

export const inkPath = (root: string, id: string, pageIndex: number) =>
  path.join(inkDir(root, id), inkFileName(pageIndex))
export const appleInkPath = (root: string, id: string, pageIndex: number) =>
  path.join(inkDir(root, id), appleInkFileName(pageIndex))
export const sketchPath = (root: string, id: string, pageIndex: number) =>
  path.join(sketchDir(root, id), sketchFileName(pageIndex))
export const marksPath = (root: string, id: string, device: string) =>
  path.join(marksDir(root, id), `${device}.json`)

export function pageIndexFromFileName(name: string, extension: string): number | null {
  if (!name.startsWith('p') || !name.endsWith(extension)) return null
  const digits = name.slice(1, name.length - extension.length)
  const value = Number(digits)
  return Number.isInteger(value) ? value : null
}

/**
 * The name a newly imported PDF takes inside the library.
 *
 * The file keeps the name it arrived with; only a collision forces a change,
 * and then it gains a numeric suffix the way a file manager does, so the name
 * you recognise is still the name you see.
 */
export function availableFileName(originalName: string, root: string): string {
  const ext = path.extname(originalName)
  const stem = path.basename(originalName, ext)
  let candidate = originalName
  let counter = 2
  while (fs.existsSync(path.join(root, candidate))) {
    candidate = `${stem} ${counter}${ext}`
    counter += 1
  }
  return candidate
}
