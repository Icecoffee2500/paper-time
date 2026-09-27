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

/**
 * An `fs.watch` handle emits `error` when what it watches goes away under it —
 * an unplugged disk, a dropped network share, a cloud drive signing out — and
 * an `error` nobody listens for is thrown, which in the main process is the
 * end of the app. So each handle listens: it closes, and the folder is tried
 * again after a while, longer each time, until it answers or the watch is
 * stopped. The window is told once, so it can re-read what is left.
 */
const RETRY = [5_000, 15_000, 60_000]

export function watchLibrary(root: string, onChange: () => void): () => void {
  const watchers = new Set<fs.FSWatcher>()
  const retries = new Set<NodeJS.Timeout>()
  let timer: NodeJS.Timeout | null = null
  let stopped = false

  const settle = () => {
    if (stopped) return
    if (timer) clearTimeout(timer)
    timer = setTimeout(onChange, QUIET_PERIOD)
  }

  const watch = (directory: string, recursive: boolean, attempt = 0) => {
    if (stopped) return
    let watcher: fs.FSWatcher
    try {
      watcher = fs.watch(directory, { recursive }, settle)
    } catch {
      // A folder that cannot be watched — a permission, a network mount, a
      // folder not there yet — is not a reason to fail; the window can still
      // be refreshed by hand. A folder that was being watched is tried again.
      if (attempt > 0) again(directory, recursive, attempt)
      return
    }
    watchers.add(watcher)
    watcher.on('error', (error) => {
      console.error(`watcher - ${directory} stopped answering:`, error)
      watchers.delete(watcher)
      try {
        watcher.close()
      } catch {
        // Already gone.
      }
      settle()
      again(directory, recursive, attempt + 1)
    })
  }

  const again = (directory: string, recursive: boolean, attempt: number) => {
    if (stopped) return
    const wait = RETRY[Math.min(attempt - 1, RETRY.length - 1)]
    const retry = setTimeout(() => {
      retries.delete(retry)
      watch(directory, recursive, attempt)
    }, wait)
    retries.add(retry)
  }

  const recursive = process.platform !== 'linux'
  watch(root, recursive)
  if (!recursive) {
    const support = path.join(root, '.papertime', 'papers')
    watch(path.join(root, '.papertime'), false)
    // The slip-box: a note the Mac wrote arrives as a file appearing here.
    watch(path.join(root, '.papertime', 'notes'), false)
    try {
      for (const entry of fs.readdirSync(support)) {
        watch(path.join(support, entry), false)
      }
    } catch {
      // No records yet.
    }
  }

  return () => {
    stopped = true
    if (timer) clearTimeout(timer)
    for (const retry of retries) clearTimeout(retry)
    for (const watcher of watchers) {
      try {
        watcher.close()
      } catch {
        // Already gone.
      }
    }
    watchers.clear()
  }
}
