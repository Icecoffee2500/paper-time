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
import { shell } from './shell.js'
import { readers } from './pageArea.js'
import { showSettings, type SettingsSection } from './ui/settings.js'
import { showFeedback } from './ui/feedback.js'
import { toast } from './ui/toolbar.js'
import { couldNot } from './notices.js'
import { reload, chooseLibrary } from './library.js'
import { L } from '../shared/lang.js'

/** What is waiting to be written while a colour is being dragged. */
let pending: Partial<Settings> = {}
let pendingTimer = 0

/**
 * Writes settings the window has already put in the store. `soon` holds the
 * write back until the hand rests — a colour well being dragged, a divider.
 */
export function saveSettings(patch: Partial<Settings>, options: { soon?: boolean } = {}) {
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
  if (options.live) return
  changed('settings')
  openSheet?.redraw()
}

export function setLayout(layout: Settings['pageLayout']) {
  store.settings.pageLayout = layout
  for (const reader of readers.values()) reader.setLayout(layout)
  saveSettings({ pageLayout: layout })
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

export function installTheme() {
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
  const sheet = showSettings({
    set: (patch, options) => setSettings(patch as Partial<Settings>, options),
    // The same errand as the ⋯ menu's. `library:choose` only asks which
    // folder; this called it and then read the old library again, so the
    // sheet's «Choose…» let somebody pick a folder and changed nothing.
    chooseLibrary: () => void chooseLibrary(),
    chooseNotesFolder: () => void moveLooseNotes('notes:chooseFolder'),
    useAppNotesFolder: () => void moveLooseNotes('notes:useAppFolder'),
    feedback: () => void showFeedback(),
  }, section)
  if (sheet) openSheet = sheet
}

/**
 * A folder for the notes about no paper, and the notes carried into it —
 * the settings' «Loose Notes». What could not go — a note of the same name
 * already there — stays where it was, and the toast says how many.
 */
async function moveLooseNotes(request: 'notes:chooseFolder' | 'notes:useAppFolder') {
  const result = await call(request)
  if (!result) return
  if ('error' in result) return couldNot('moveNotes', result.error)
  const { moved, kept } = result
  toast(kept > 0
    ? L(`노트 ${moved}개를 옮겼어요. ${kept}개는 이름이 겹쳐 그대로 뒀어요.`, `Moved ${moved} note${moved === 1 ? '' : 's'}. ${kept} stayed: a note of the same name was already there.`)
    : L(`노트 ${moved}개를 옮겼어요.`, `Moved ${moved} note${moved === 1 ? '' : 's'}.`))
  await reload()
  openSheet?.redraw()
}
