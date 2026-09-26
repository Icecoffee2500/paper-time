/**
 * What the app remembers between launches.
 *
 * A single JSON file in the platform's own per-user config directory —
 * `%APPDATA%` on Windows, `~/.config` on Linux, `~/Library/Application
 * Support` on a Mac — because this is the app's own preference, not the
 * library's. The library folder holds only what belongs to the papers, so the
 * same folder opened on two machines does not carry one machine's window size
 * to the other.
 */
import { app } from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import { DEFAULT_TINT_COLOR, pageTintFrom, tintColorFrom, type PageTint } from '../shared/pageTint.js'

export interface Settings {
  libraryRoot: string | null
  /** Folders opened beside the first one, in the order they were added. */
  extraRoots: string[]
  recentLibraries: string[]
  window: { width: number; height: number; x?: number; y?: number; maximized?: boolean }
  panes: { sidebar: boolean; paperList: boolean; reader: boolean; inspector: boolean }
  columns: { sidebar: number; paperList: number; inspector: number }
  inspectorTab: 'details' | 'marks' | 'note'
  sort: { field: 'title' | 'author' | 'year' | 'added' | 'opened'; ascending: boolean }
  /** 'system' follows the desktop; the other two are the reader's choice. */
  appearance: 'system' | 'light' | 'dark'
  /** Same shape as `appearance`: the desktop's locale, or the reader's word. */
  language: 'system' | 'ko' | 'en'
  /** A ground for the page and how the paper is drawn on it — the Mac's
   *  model (`shared/pageTint.ts`). */
  pageTint: PageTint
  /** The custom tint's ground, `#rrggbb`. */
  pageTintColor: string
  pageLayout: 'single' | 'continuous'
  selectedPaperID: string | null
  /** Latex Suite's shortcuts in the note and on the cards. On unless turned off. */
  latexShortcuts: boolean
  /** Search by meaning in the palette, and the index it needs. On unless turned off. */
  semanticSearch: boolean
}

const DEFAULTS: Settings = {
  libraryRoot: null,
  extraRoots: [],
  recentLibraries: [],
  window: { width: 1440, height: 900 },
  panes: { sidebar: true, paperList: true, reader: true, inspector: true },
  columns: { sidebar: 240, paperList: 320, inspector: 320 },
  inspectorTab: 'details',
  sort: { field: 'added', ascending: false },
  appearance: 'system',
  language: 'system',
  pageTint: 'none',
  pageTintColor: DEFAULT_TINT_COLOR,
  pageLayout: 'continuous',
  selectedPaperID: null,
  latexShortcuts: true,
  semanticSearch: true,
}

let cached: Settings | null = null

/**
 * Set for a probe run: what the page changes is kept for this run and never
 * written. The file belongs to whoever uses this copy of the app — a probe
 * that opens a paper would otherwise write that paper's id, and the tab it
 * looked at, into their settings.
 */
let heldInMemory = false

export function holdInMemory() {
  heldInMemory = true
}

function file(): string {
  return path.join(app.getPath('userData'), 'settings.json')
}

export function settings(): Settings {
  if (cached) return cached
  try {
    const raw = JSON.parse(fs.readFileSync(file(), 'utf8')) as Partial<Settings>
    cached = {
      ...DEFAULTS,
      ...raw,
      window: { ...DEFAULTS.window, ...raw.window },
      panes: { ...DEFAULTS.panes, ...raw.panes },
      columns: { ...DEFAULTS.columns, ...raw.columns },
      sort: { ...DEFAULTS.sort, ...raw.sort },
      // The old four washes under their new names: «grey» was a paler white
      // and is Paper White now, «night» a blue-grey multiplied over black
      // words and is Dimmed. Read that way rather than rewritten, so the file
      // changes only when somebody next changes a setting.
      pageTint: pageTintFrom(raw.pageTint),
      pageTintColor: tintColorFrom(raw.pageTintColor),
    }
  } catch {
    cached = { ...DEFAULTS }
  }
  return cached
}

export function update(patch: Partial<Settings>): Settings {
  const next = { ...settings(), ...patch }
  // What the window sends is kept to what the reader can draw.
  if ('pageTint' in patch) next.pageTint = pageTintFrom(patch.pageTint)
  if ('pageTintColor' in patch) next.pageTintColor = tintColorFrom(patch.pageTintColor)
  cached = next
  if (heldInMemory) return next
  try {
    fs.mkdirSync(path.dirname(file()), { recursive: true })
    fs.writeFileSync(file(), JSON.stringify(next, null, 2), 'utf8')
  } catch {
    // A preference that cannot be written is not worth failing a launch over.
  }
  return next
}

export function rememberLibrary(root: string) {
  const recent = [root, ...settings().recentLibraries.filter((entry) => entry !== root)].slice(0, 8)
  update({ libraryRoot: root, recentLibraries: recent })
}
