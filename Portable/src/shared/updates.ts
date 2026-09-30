/**
 * Whether there is a newer Paper Time, from the page's `releases.json` —
 * the Mac's `UpdateVersion`, `UpdateFeed` and `UpdateOffer`.
 *
 * The same file the download page draws its list from, so publishing a
 * version is announcing it; the notes it carries are the version's own entry
 * in `ReleaseNotes.swift`, written there by `publish-release.sh`.
 */

export interface Pair { ko: string; en: string }
export interface NoteItem { title: Pair; detail?: Pair | null }
export interface ReleaseNotesOf { note?: Pair | null; added?: NoteItem[] | null; fixed?: NoteItem[] | null }

export interface FeedRelease {
  version: string
  builds?: Record<string, { url: string }[]>
  notes?: ReleaseNotesOf | null
}

export interface UpdateOffer {
  /** The newest version. */
  version: string
  /** Every version newer than this one, newest first, six at most. */
  steps: { version: string; notes: ReleaseNotesOf | null }[]
  /** Where to get it by hand: the platform's first file, or the page. */
  download: string
}

export const FEED_URL = 'https://icecoffee2500.github.io/paper-time/releases.json'
export const PAGE_URL = 'https://icecoffee2500.github.io/paper-time/'

/** A version's numbers, or null when it is not one. Anything after a hyphen is ignored. */
export function versionParts(text: string): number[] | null {
  const core = String(text).split('-')[0]
  const parts = core.split('.')
  if (parts.length === 0 || parts.some((part) => !/^\d+$/.test(part))) return null
  return parts.map(Number)
}

/** Negative when `a` is older than `b`, zero when the same, positive when newer. */
export function compareVersions(a: string, b: string): number {
  const left = versionParts(a) ?? []
  const right = versionParts(b) ?? []
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const difference = (left[index] ?? 0) - (right[index] ?? 0)
    if (difference !== 0) return difference
  }
  return 0
}

/** Which of the page's lists a desktop reads its files from. */
export function feedPlatform(platform: string): 'windows' | 'linux' | 'mac' {
  return platform === 'win32' ? 'windows' : platform === 'darwin' ? 'mac' : 'linux'
}

/**
 * The offer in a feed for a copy running `current` on `platform`, if there
 * is one. Linux always goes to the page: which of its two packages
 * somebody has is not something the running app can tell.
 */
export function offerFrom(feed: unknown, current: string, platform: string): UpdateOffer | null {
  const releases = (feed as { releases?: unknown })?.releases
  if (!versionParts(current) || !Array.isArray(releases)) return null
  const newer = (releases as FeedRelease[])
    .filter((release) => release && typeof release.version === 'string' && versionParts(release.version))
    .filter((release) => compareVersions(release.version, current) > 0)
    .sort((a, b) => compareVersions(b.version, a.version))
  const newest = newer[0]
  if (!newest) return null
  const kind = feedPlatform(platform)
  const file = kind === 'linux' ? undefined : newest.builds?.[kind]?.[0]?.url
  return {
    version: newest.version,
    steps: newer.slice(0, 6).map((release) => ({ version: release.version, notes: release.notes ?? null })),
    download: typeof file === 'string' && /^https:\/\//.test(file) ? file : PAGE_URL,
  }
}

/** What the notice shows, as the main process holds it. */
export interface UpdateState {
  offer: UpdateOffer | null
  /** preparing → downloading → ready → installing; `manual` is «go and get it». */
  stage: 'preparing' | 'downloading' | 'ready' | 'installing' | 'manual'
  /** 0–1 once the size is known. */
  progress: number | null
  /** The bytes come down so far, and the whole once the server has said it. */
  received: number | null
  total: number | null
  /** Install Now pressed before the download had finished. */
  wantsInstall: boolean
  showsSheet: boolean
  showsBar: boolean
  checking: boolean
  lastCheck: number | null
  lastCheckFailed: boolean
  /** This desktop installs updates itself (Windows); elsewhere the buttons open the page. */
  installs: boolean
  /** The version running — or, for a probe, the one it pretends to be. */
  current: string
}

export const NO_UPDATE: UpdateState = {
  offer: null, stage: 'preparing', progress: null, received: null, total: null, wantsInstall: false,
  showsSheet: false, showsBar: false, checking: false, lastCheck: null, lastCheckFailed: false, installs: false,
  current: '',
}

/**
 * A size in the Finder's units — decimal, whole kilobytes, a tenth of a
 * megabyte, a hundredth of a gigabyte, a trailing zero dropped, and a size
 * that rounds up to the next unit said in it — with no words («Zero KB»,
 * «999 bytes»). The Mac's `UpdateMeasure.size`, which agrees with its
 * `ByteCountFormatter` from a kilobyte up; the tests hold both to one list.
 */
export function sizeText(bytes: number): string {
  const n = Math.max(0, Math.floor(bytes))
  // Half up in whole numbers: 17,450,000 is 17.5 MB, not the 17.4 that
  // 17.45 in floating point rounds to.
  const kilobytes = Math.floor((n + 500) / 1_000)
  if (kilobytes < 1_000) return `${kilobytes} KB`
  const tenths = Math.floor((n + 50_000) / 100_000)
  if (tenths < 10_000) return tenths % 10 === 0 ? `${tenths / 10} MB` : `${Math.floor(tenths / 10)}.${tenths % 10} MB`
  const hundredths = Math.floor((n + 5_000_000) / 10_000_000)
  const whole = Math.floor(hundredths / 100)
  const part = hundredths % 100
  if (part === 0) return `${whole} GB`
  return part % 10 === 0 ? `${whole}.${part / 10} GB` : `${whole}.${String(part).padStart(2, '0')} GB`
}

/** Rounded down, so 100% is only ever said of something finished. */
export function percentText(fraction: number): string {
  return `${Math.min(100, Math.max(0, Math.floor(fraction * 100)))}%`
}

/** «17.4 MB / 53.7 MB · 32%», or what has come so far when the size is not known yet. */
export function downloadText(received: number, total: number | null): string {
  if (!total || total <= 0) return sizeText(received)
  return `${sizeText(received)} / ${sizeText(total)} · ${percentText(received / total)}`
}
