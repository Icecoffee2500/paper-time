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
import { pageTintFrom, tintColorFrom } from '../shared/pageTint.js'
import { DEFAULTS, fromFile, type Settings } from '../shared/appSettings.js'

export type { Settings } from '../shared/appSettings.js'

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

/**
 * Reads the file once. A file that is there but will not parse — a write torn
 * by a power cut, a sync client's half copy — is moved aside rather than
 * treated as "no settings": the next change would otherwise write the
 * defaults over it and forget the library with everything else. The broken
 * copy stays beside it as `settings.json.broken-<when>`, and until something
 * changes, nothing is written.
 */
export function settings(): Settings {
  if (cached) return cached
  let text: string | null = null
  try {
    text = fs.readFileSync(file(), 'utf8')
  } catch {
    // No file yet: a first launch.
  }
  if (text === null) {
    cached = { ...DEFAULTS }
    return cached
  }
  try {
    cached = fromFile(JSON.parse(text) as Partial<Settings>)
  } catch (error) {
    console.error('settings - settings.json would not be read; it is kept beside as a broken copy:', error)
    if (!heldInMemory) {
      try {
        fs.renameSync(file(), `${file()}.broken-${new Date().toISOString().replace(/[:.]/g, '-')}`)
      } catch {
        // Moving it aside is a courtesy; the defaults are used either way.
      }
    }
    cached = { ...DEFAULTS }
  }
  return cached
}

let writeTimer: NodeJS.Timeout | null = null

/**
 * Changes the settings. `soon` holds the write back 300 ms, for what arrives
 * in a stream — a window being dragged sends a move for every frame, and each
 * one used to rewrite the file on the main process's thread.
 */
export function update(patch: Partial<Settings>, { soon = false }: { soon?: boolean } = {}): Settings {
  const current = settings()
  const next = { ...current, ...patch }
  // A group — the window's frame, the panes, the columns, the sort — is
  // merged key by key: a patch naming one of its keys used to replace the
  // whole group, and the rest went back to nothing.
  for (const key of ['window', 'panes', 'columns', 'sort'] as const) {
    if (patch[key]) (next as Record<string, unknown>)[key] = { ...current[key], ...patch[key] }
  }
  // What the window sends is kept to what the reader can draw.
  if ('pageTint' in patch) next.pageTint = pageTintFrom(patch.pageTint)
  if ('pageTintColor' in patch) next.pageTintColor = tintColorFrom(patch.pageTintColor)
  cached = next
  if (heldInMemory) return next
  if (writeTimer) clearTimeout(writeTimer)
  writeTimer = null
  if (soon) writeTimer = setTimeout(flushSettings, 300)
  else flushSettings()
  return next
}

/**
 * Writes what is held, now — also at quit, for a move still waiting.
 * Beside the file and renamed over it, so a torn write leaves the old file
 * whole rather than half of a new one.
 */
export function flushSettings() {
  if (writeTimer) clearTimeout(writeTimer)
  writeTimer = null
  if (heldInMemory || !cached) return
  const target = file()
  const temporary = `${target}.${process.pid}.tmp`
  try {
    fs.mkdirSync(path.dirname(target), { recursive: true })
    fs.writeFileSync(temporary, JSON.stringify(cached, null, 2), 'utf8')
    fs.renameSync(temporary, target)
  } catch (error) {
    // A preference that cannot be written is not worth failing a launch over.
    console.error('settings - could not be written:', error)
    try {
      fs.rmSync(temporary, { force: true })
    } catch {
      // Nothing more to do.
    }
  }
}

export function rememberLibrary(root: string) {
  const recent = [root, ...settings().recentLibraries.filter((entry) => entry !== root)].slice(0, 8)
  update({ libraryRoot: root, recentLibraries: recent })
}
