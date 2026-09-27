/**
 * What this process wrote a moment ago, so the folder watcher can tell its
 * own writes from a change that arrived from elsewhere.
 *
 * Every save lands in the library folder — a record, a journal, a sidecar,
 * the PDF itself — and the watcher saw each one as «the folder changed»,
 * which meant a full read of every folder and a second one for the PDF
 * write 1.5 seconds later. One highlight was two library reads and two
 * folder walks; on a cloud folder that is seconds, and the list scrolled to
 * the top each time. The Mac's `DocumentWatcher` suppresses its own writes;
 * this is that.
 *
 * A write is remembered for a short while, keyed the way paths are compared
 * (`pathKey`): the watcher reports a name, not the file we wrote through.
 */
import { pathKey } from '../shared/paths.js'

const OWN_WRITE_TTL = 2500

const recent = new Map<string, number>()

/** Says that this process just wrote here. */
export function noteOwnWrite(file: string, at = Date.now()) {
  recent.set(pathKey(file), at + OWN_WRITE_TTL)
  if (recent.size > 4096) prune(at)
}

/** Whether a change at this path is one of ours, still within the window. */
export function isOwnWrite(file: string, at = Date.now()): boolean {
  const key = pathKey(file)
  const until = recent.get(key)
  if (until === undefined) return false
  if (until < at) {
    recent.delete(key)
    return false
  }
  return true
}

function prune(at: number) {
  for (const [key, until] of recent) if (until < at) recent.delete(key)
}

/** For tests. */
export function forgetOwnWrites() {
  recent.clear()
}
