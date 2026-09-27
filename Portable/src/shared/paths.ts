/**
 * Whether two paths are the same place, and whether one is inside another —
 * one answer for both processes and every desktop.
 *
 * A path arrives in several spellings of the same place: a record says `/`
 * on every desktop while a root on Windows says `\`; a dialog hands back
 * `D:\Papers` and a drop `d:\papers\`; a folder picked twice may end in a
 * separator once. Compared as strings those are different folders, and they
 * were: a folder shelf that stopped lighting its row, a PDF copied into the
 * library it was already in, notes moved "into another folder" that was the
 * same one — and deleted from it.
 *
 * Windows and macOS disks do not tell case apart (by default), Linux ones
 * do. `setPathPlatform` says which this is; the main process knows from
 * `process.platform`, the window is told by the bridge.
 */
let caseless = typeof process !== 'undefined' && (process.platform === 'win32' || process.platform === 'darwin')

export function setPathPlatform(platform: string) {
  caseless = platform === 'win32' || platform === 'darwin'
}

/** Forward slashes, no separator at the end (a bare `/` stays). */
export function slashed(path: string): string {
  const forward = path.replace(/\\/g, '/')
  const trimmed = forward.replace(/\/+$/, '')
  return trimmed === '' && forward.startsWith('/') ? '/' : trimmed
}

/** What two spellings of one place have in common: the key to compare by. */
export function pathKey(path: string): string {
  const one = slashed(path)
  return caseless ? one.toLowerCase() : one
}

export function samePath(a: string | null | undefined, b: string | null | undefined): boolean {
  if (a == null || b == null) return false
  return pathKey(a) === pathKey(b)
}

/** At `parent` or anywhere beneath it — by whole names: `Papers2` is not under `Papers`. */
export function isUnder(child: string, parent: string): boolean {
  const inner = pathKey(child)
  const outer = pathKey(parent)
  if (inner === outer) return true
  return inner.startsWith(outer === '/' ? '/' : `${outer}/`)
}

/** Strictly beneath, not the folder itself. */
export function isInside(child: string, parent: string): boolean {
  return isUnder(child, parent) && !samePath(child, parent)
}

/** The one of `candidates` that is this place, as it was spelled there. */
export function findPath(candidates: readonly string[], path: string | null | undefined): string | undefined {
  if (path == null) return undefined
  const key = pathKey(path)
  return candidates.find((one) => pathKey(one) === key)
}
