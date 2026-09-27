/** Types for `release-notes-parser.mjs`, which the tests read the Swift with. */
export function readReleaseNotes(releaseSwift: string, contributorsSwift: string): {
  releases: { version: string; added: unknown[]; removed: unknown[]; fixed: unknown[] }[]
  highlights: unknown[]
  groups: unknown[]
  contributors: { name: string; reports: number }[]
}
