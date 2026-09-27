/**
 * Whether this run is a probe, and what a probe keeps apart.
 *
 * A probe is a run somebody is only looking at: one given a folder
 * (`--papertime-library=`), a list of steps (`--papertime-probe=`), or a
 * picture to take (`--papertime-shot=`). Such a run must never come in front
 * of what the person at this machine is doing, never write their settings,
 * and never read their library or notes — the probe and the installed copy
 * share one settings file and one app folder.
 */
import { app } from 'electron'
import path from 'node:path'
import { probeArgument } from './probe.js'

export const probe = {
  argument: probeArgument,

  /** This run was told which folder to open. */
  get hasLibrary(): boolean {
    return probeArgument('library') != null
  },

  /** Any run that is only being looked at. */
  get isRun(): boolean {
    return ['library', 'probe', 'shot'].some((name) => probeArgument(name) != null)
  },

  /**
   * Where the text is kept: the app's own folder, never the library's. A
   * probe keeps a folder of its own — its clean-up, which takes out the text
   * of papers that are gone, would otherwise judge the person's own cache by
   * the probe's library and empty it.
   */
  textCacheDirectory(): string {
    const chosen = probeArgument('text-cache')
    if (chosen) return chosen
    if (probe.isRun) return path.join(app.getPath('temp'), 'Paper Time probe', 'Text')
    return path.join(app.getPath('userData'), 'Text')
  },

  /** Where the vectors are kept: beside the text, under the same rule. */
  semanticCacheDirectory(): string {
    const chosen = probeArgument('semantic-cache')
    if (chosen) return chosen
    if (probe.isRun) return path.join(app.getPath('temp'), 'Paper Time probe', 'Semantic')
    return path.join(app.getPath('userData'), 'Semantic')
  },

  /**
   * `--papertime-language=ko|en`: a probe run in the language asked for, so
   * one machine can look at both — read in place of the person's setting,
   * never written over it.
   */
  language(): 'ko' | 'en' | null {
    if (!probe.isRun) return null
    const asked = probeArgument('language')
    return asked === 'ko' || asked === 'en' ? asked : null
  },

  /** The loose notes' box for a probe: beside its library, never the app's own. */
  looseNotesFolder(root: string): string {
    return `${root.replace(/[\\/]+$/, '')}-loose-notes`
  },
}
