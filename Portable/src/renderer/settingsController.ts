/**
 * The settings the window keeps, and the one way they are written.
 *
 * Every change goes through `saveSettings` — nine places used to call
 * `settings:set` each in its own way, and one of them handed over the very
 * object it went on changing. What is sent is a copy.
 */
import { call } from './bridge.js'
import { on } from './dom.js'
import { changed, store, type InspectorTab, type Settings } from './state.js'
import { shell, solo } from './shell.js'
import { SketchStyle } from '../shared/sketch.js'
import { inkPresetsFrom } from '../shared/inkPresets.js'
import { parseShortcutOverrides, setShortcutOverrides } from '../shared/shortcuts.js'
import { readers } from './pageArea.js'
import { showSettings, type SettingsSection } from './ui/settings.js'
import { showFeedback } from './ui/feedback.js'
import { toast } from './ui/toolbar.js'
import { couldNot } from './notices.js'
import { reload, chooseLibrary } from './library.js'
import { setFocusMode } from './layout.js'
import { L } from '../shared/lang.js'

/** What is waiting to be written while a colour is being dragged. */
let pending: Partial<Settings> = {}
let pendingTimer = 0

/**
 * Writes settings the window has already put in the store. `soon` holds the
 * write back until the hand rests — a colour well being dragged, a divider.
 */
export function saveSettings(patch: Partial<Settings>, options: { soon?: boolean } = {}) {
  // A window for one paper has no library columns and is not the window the
  // app reopens: what it shows is its own, not the settings'.
  if (solo) {
    const { selectedPaperID: _paper, panes: _panes, columns: _columns, inspectorTab: _tab, ...rest } = patch
    patch = rest
    if (Object.keys(patch).length === 0) return
  }
  Object.assign(pending, structuredClone(patch))
  clearTimeout(pendingTimer)
  if (options.soon) pendingTimer = window.setTimeout(flushSettings, 300)
  else flushSettings()
}

export function flushSettings() {
  clearTimeout(pendingTimer)
  const patch = pending
  pending = {}
  if (Object.keys(patch).length > 0) void call('settings:set', patch as Record<string, unknown>)
}

/**
 * Changes settings from the sheet, the ⋯ menu or a probe, and makes the
 * window follow at once — a sheet that saves and shows nothing is a form.
 *
 * `live` is for a value still moving under the hand, the ground colour while
 * its well is dragged: the page follows every step, the file is written once
 * the hand rests, and the sheet is not drawn again — drawing it again would
 * take the colour well away from under the pointer, and the picker with it.
 */
export function setSettings(patch: Partial<Settings>, options: { live?: boolean } = {}) {
  Object.assign(store.settings, structuredClone(patch))
  saveSettings(patch, { soon: options.live })
  if ('appearance' in patch) applyTheme()
  else if ('pageTint' in patch || 'pageTintColor' in patch) {
    for (const reader of readers.values()) reader.applyTint()
  }
  if ('pageLayout' in patch) setLayout(store.settings.pageLayout)
  if ('listSubtitle' in patch) shell.paperList.update()
  // A key changed: every tooltip and list reads the new one from now on.
  if ('shortcuts' in patch) {
    setShortcutOverrides(parseShortcutOverrides(store.settings.shortcuts))
    shell.toolbar.update()
  }
  if (options.live) return
  changed('settings')
  openSheet?.redraw()
}

/** What another window chose, followed here without writing it again. The
 *  columns, the paper showing and the tab are each window's own. */
const SHARED = new Set<string>(['appearance', 'language', 'pageTint', 'pageTintColor', 'pageLayout', 'latexShortcuts', 'semanticSearch', 'listSubtitle', 'bibtexProtectCase', 'bibtexPreprintStyle', 'bibtexIncludeUnverified', 'sort', 'sketchStyle', 'inkPresets', 'shortcuts'])

export function adoptSettings(patch: Record<string, unknown>) {
  const taken: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(patch)) if (SHARED.has(key)) taken[key] = value
  if (Object.keys(taken).length === 0) return
  const layoutBefore = store.settings.pageLayout
  Object.assign(store.settings, structuredClone(taken))
  if ('appearance' in taken) applyTheme()
  else if ('pageTint' in taken || 'pageTintColor' in taken) for (const reader of readers.values()) reader.applyTint()
  if ('pageLayout' in taken && store.settings.pageLayout !== layoutBefore) {
    for (const reader of readers.values()) reader.setLayout(store.settings.pageLayout)
  }
  if ('sketchStyle' in taken && typeof taken.sketchStyle === 'string') {
    try {
      store.sketch.style = SketchStyle.from(JSON.parse(taken.sketchStyle))
    } catch {
      // Kept as it was.
    }
  }
  if ('inkPresets' in taken) store.sketch.presets = inkPresetsFrom(taken.inkPresets)
  if ('shortcuts' in taken) setShortcutOverrides(parseShortcutOverrides(taken.shortcuts))
  changed('settings', 'papers')
  openSheet?.redraw()
}

export function setLayout(layout: Settings['pageLayout']) {
  const was = store.settings.pageLayout
  store.settings.pageLayout = layout
  for (const reader of readers.values()) reader.setLayout(layout)
  saveSettings({ pageLayout: layout })
  // A spread wants the whole window: choosing Book is the clearest thing a
  // reader can say about being here to read, so the columns step aside — and
  // come back when Book is left (`RootView`, `setFocusMode(layout == .book)`).
  if (layout !== was && (layout === 'book' || was === 'book')) setFocusMode(layout === 'book')
}

export function setSort(field: Settings['sort']['field'], ascending: boolean) {
  store.settings.sort = { field, ascending }
  saveSettings({ sort: store.settings.sort })
  changed('papers')
}

export function setInspectorTab(tab: InspectorTab) {
  if (store.settings.inspectorTab === tab) return
  store.settings.inspectorTab = tab
  saveSettings({ inspectorTab: tab })
  changed('inspector')
}

// ------------------------------------------------------------------ theme

export function applyTheme() {
  const choice = store.settings.appearance
  const theme = choice === 'system'
    ? (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
    : choice
  document.documentElement.setAttribute('data-theme', theme)
  // Glass is the panel's colour, and so goes with the appearance: multiplied
  // onto a light panel, turned to night on a dark one.
  for (const reader of readers.values()) reader.applyTint()
}

/**
 * The desktop's accent, as the Mac's window takes the system's: the fill of a
 * chosen row, a pressed button, a focus ring. Linux has no one accent to ask
 * for, and keeps the blue.
 */
export async function applyAccent() {
  const accent = await call('theme:accent').catch(() => null)
  const root = document.documentElement.style
  if (!accent) {
    root.removeProperty('--accent')
    root.removeProperty('--accent-soft')
    root.removeProperty('--accent-text')
    return
  }
  root.setProperty('--accent', accent)
  root.setProperty('--accent-soft', `color-mix(in srgb, ${accent} 16%, transparent)`)
  root.setProperty('--accent-text', accent)
}

export function installTheme() {
  void applyAccent()
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (store.settings.appearance === 'system') applyTheme()
  })
  // A colour still resting when the window goes is written as it goes.
  on(window, 'beforeunload', flushSettings)
}

// ------------------------------------------------------------------ sheet

let openSheet: { redraw: () => void; close: () => void } | undefined

/**
 * The settings sheet — from the ⚙ in the bar, from the menu, and from
 * `Ctrl+,`, which until now went nowhere at all.
 */
export function openSettings(section?: SettingsSection) {
  // A folder that came back while the app was open is caught up the moment
  // somebody looks (`NotesModel.comeBack`, asked when the settings show).
  void call('notes:comeBack').then((result) => {
    if (!result) return
    lastNotesMove = { moved: result.moved, kept: result.kept, keptIn: result.notesFolder.leftBehind[0] ?? null }
    store.notesFolder = result.notesFolder
    openSheet?.redraw()
  }).catch(() => undefined)
  const sheet = showSettings({
    set: (patch, options) => setSettings(patch as Partial<Settings>, options),
    // The same errand as the ⋯ menu's. `library:choose` only asks which
    // folder; this called it and then read the old library again, so the
    // sheet's «Choose…» let somebody pick a folder and changed nothing.
    chooseLibrary: () => void chooseLibrary(),
    chooseNotesFolder: () => void moveLooseNotes('notes:chooseFolder'),
    useAppNotesFolder: () => void moveLooseNotes('notes:useAppFolder'),
    reconnectNotesFolder: () => void moveLooseNotes('notes:reconnect'),
    revealNotesFolder: () => void call('notes:reveal'),
    lastNotesMove: () => lastNotesMove ?? (store.notesFolder?.lastMove ? { ...store.notesFolder.lastMove, keptIn: store.notesFolder.leftBehind[0] ?? null } : null),
    feedback: () => void showFeedback(),
  }, section)
  if (sheet) openSheet = sheet
}

/**
 * A folder for the notes about no paper, and the notes carried into it —
 * the settings' «Loose Notes». What could not go — a note of the same name
 * already there — stays where it was, and the toast says how many.
 */
/** The last move of the loose notes, said under their row until the next —
 *  not a toast that is gone before it is read (`AppModel.lastNotesMove`). */
let lastNotesMove: { moved: number; kept: number; keptIn: string | null } | null = null

async function moveLooseNotes(request: 'notes:chooseFolder' | 'notes:useAppFolder' | 'notes:reconnect') {
  const result = await call(request)
  if (!result) {
    if (request === 'notes:reconnect') toast(L('아직 폴더에 닿을 수 없어요.', "The folder still isn't there."))
    return
  }
  if ('error' in result) return couldNot('moveNotes', result.error)
  const { moved, kept } = result
  lastNotesMove = { moved, kept, keptIn: result.notesFolder.leftBehind[0] ?? null }
  toast(kept > 0
    ? L(`노트 ${moved}개를 옮겼어요. ${kept}개는 이름이 겹쳐 그대로 뒀어요.`, `Moved ${moved} note${moved === 1 ? '' : 's'}. ${kept} stayed: a note of the same name was already there.`)
    : L(`노트 ${moved}개를 옮겼어요.`, `Moved ${moved} note${moved === 1 ? '' : 's'}.`))
  await reload()
  openSheet?.redraw()
}
