/**
 * Noticing that the folder changed under us.
 *
 * A library lives in a cloud folder, so a paper added on one machine arrives
 * on another as a file appearing — no notification, no push. `fs.watch` is
 * recursive on Windows and macOS and not on Linux, so there the support folder
 * is walked and watched directory by directory. Either way the answer is the
 * same: tell the window, let it re-read.
 *
 * Changes arrive in bursts — a sync writes a dozen files in a second — so the
 * callback is held back until things go quiet.
 */
import fs from 'node:fs'
import path from 'node:path'

const QUIET_PERIOD = 400

export function watchLibrary(root: string, onChange: () => void): () => void {
  const watchers: fs.FSWatcher[] = []
  let timer: NodeJS.Timeout | null = null

  const settle = () => {
    if (timer) clearTimeout(timer)
    timer = setTimeout(onChange, QUIET_PERIOD)
  }

  const watch = (directory: string, recursive: boolean) => {
    try {
      watchers.push(fs.watch(directory, { recursive }, settle))
    } catch {
      // A folder that cannot be watched — a permission, a network mount —
      // is not a reason to fail; the window can still be refreshed by hand.
    }
  }

  const recursive = process.platform !== 'linux'
  watch(root, recursive)
  if (!recursive) {
    const support = path.join(root, '.papertime', 'papers')
    watch(path.join(root, '.papertime'), false)
    try {
      for (const entry of fs.readdirSync(support)) {
        watch(path.join(support, entry), false)
      }
    } catch {
      // No records yet.
    }
  }

  return () => {
    if (timer) clearTimeout(timer)
    for (const watcher of watchers) watcher.close()
  }
}
