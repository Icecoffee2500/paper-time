/**
 * Noticing that the folder changed under us.
 *
 * A library lives in a cloud folder, so a paper added on one machine arrives
 * on another as a file appearing — no notification, no push. `fs.watch` is
 * recursive on Windows and macOS, and on Linux where Node can do it; where
 * it cannot, the support folder is walked and watched directory by
 * directory. Either way the answer is the same: say which files changed,
 * and let `folderSync` decide what that means.
 *
 * Changes arrive in bursts — a sync writes a dozen files in a second — so the
 * callback is held back until things go quiet, and then told every name the
 * burst carried.
 *
 * An `fs.watch` handle emits `error` when what it watches goes away under it —
 * an unplugged disk, a dropped network share, a cloud drive signing out — and
 * an `error` nobody listens for is thrown, which in the main process is the
 * end of the app. So each handle listens: it closes, and the folder is tried
 * again after a while, longer each time, until it answers or the watch is
 * stopped.
 */
import fs from 'node:fs'
import path from 'node:path'

const QUIET_PERIOD = 400
const RETRY = [5_000, 15_000, 60_000]

/** One changed path, absolute, or null when the platform gave no name. */
export type ChangedFile = string | null

export function watchLibrary(root: string, onChange: (changed: ChangedFile[]) => void): () => void {
  const watchers = new Set<fs.FSWatcher>()
  const retries = new Set<NodeJS.Timeout>()
  let timer: NodeJS.Timeout | null = null
  let stopped = false
  let burst = new Set<string>()
  let unnamed = false

  const settle = () => {
    if (stopped) return
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => {
      timer = null
      const changed: ChangedFile[] = [...burst]
      if (unnamed) changed.push(null)
      burst = new Set()
      unnamed = false
      onChange(changed)
    }, QUIET_PERIOD)
  }

  const noticed = (directory: string, name: string | Buffer | null) => {
    if (typeof name === 'string' && name.length > 0) burst.add(path.join(directory, name))
    else unnamed = true
    settle()
  }

  const watch = (directory: string, recursive: boolean, attempt = 0) => {
    if (stopped) return
    let watcher: fs.FSWatcher
    try {
      watcher = fs.watch(directory, { recursive }, (_event, name) => noticed(directory, name))
    } catch (error) {
      // A folder that cannot be watched — a permission, a network mount, a
      // folder not there yet — is not a reason to fail; the window can still
      // be refreshed by hand. A folder that was being watched is tried again.
      if (recursive && (error as NodeJS.ErrnoException).code === 'ERR_FEATURE_UNAVAILABLE_ON_PLATFORM') {
        watchWalked(directory)
        return
      }
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
      unnamed = true
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

  /**
   * Linux without recursive watching: the root, the support folder, the
   * slip-box, and every record folder. A record folder that appears later
   * (a paper added on another machine) is picked up when the support folder
   * reports it.
   */
  const watched = new Set<string>()
  const watchOne = (directory: string) => {
    if (watched.has(directory)) return
    watched.add(directory)
    watch(directory, false)
  }
  const watchWalked = (directory: string) => {
    const support = path.join(directory, '.papertime')
    const papers = path.join(support, 'papers')
    watchOne(directory)
    watchOne(support)
    watchOne(path.join(support, 'notes'))
    const addRecordFolders = () => {
      try {
        for (const entry of fs.readdirSync(papers)) watchOne(path.join(papers, entry))
      } catch {
        // No records yet.
      }
    }
    addRecordFolders()
    try {
      const overPapers = fs.watch(papers, { recursive: false }, (_event, name) => {
        addRecordFolders()
        noticed(papers, name)
      })
      watchers.add(overPapers)
      overPapers.on('error', () => {
        watchers.delete(overPapers)
        try {
          overPapers.close()
        } catch {
          // Already gone.
        }
      })
    } catch {
      // No support folder yet; the root's watcher sees it appear.
    }
  }

  watch(root, true)

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
