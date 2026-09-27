/**
 * Tags and collections across folders — pure, so it can be tested without a
 * folder.
 *
 * A tag and a collection are names the reader gave a shelf, and they are kept
 * in the folder whose papers wear them rather than in one folder for all of
 * them — so a folder carried to another machine arrives with its papers still
 * tagged and still filed. A name two folders use is written in both under the
 * same identifier and shows once in the window.
 */
import type { Collection, Tag } from '../shared/model.js'

export interface FolderVocabulary {
  root: string
  tags: Tag[]
  collections: Collection[]
}

export interface Vocabulary {
  tags: Tag[]
  collections: Collection[]
}

/** Every folder's tags and collections, merged into the one list the window shows. */
export function mergeVocabulary(folders: FolderVocabulary[]): Vocabulary {
  const tags: Tag[] = []
  const seenTags = new Set<string>()
  const collections: Collection[] = []
  const seenCollections = new Set<string>()
  for (const one of folders) {
    for (const tag of one.tags) {
      if (seenTags.has(tag.id)) continue
      seenTags.add(tag.id)
      tags.push(tag)
    }
    for (const collection of one.collections) {
      if (seenCollections.has(collection.id)) continue
      seenCollections.add(collection.id)
      collections.push(collection)
    }
  }
  // The name breaks a tie, as on the Mac: every folder numbers its own
  // collections from nought.
  collections.sort((a, b) =>
    (a.sortIndex ?? 0) - (b.sortIndex ?? 0) || a.name.localeCompare(b.name))
  return { tags, collections }
}

/** A paper as the settle needs it: which folder, which names it wears. */
export interface WearingRow {
  root: string
  tagIDs: string[]
  collectionIDs: string[]
}

/**
 * What each folder is missing: the tags and collections its own papers wear
 * that its files do not define. A library that was one folder kept all of it
 * in that folder, and a tag put on a paper while its folder was away was
 * written where the paper was not. Both are mended by the same pass, which
 * runs on every read and writes nothing at all once every folder has what it
 * needs.
 */
export function missingVocabulary(
  rows: WearingRow[],
  folders: FolderVocabulary[],
  merged: Vocabulary = mergeVocabulary(folders),
): { root: string; tags: Tag[]; collections: Collection[] }[] {
  if (folders.length < 2) return []
  const out: { root: string; tags: Tag[]; collections: Collection[] }[] = []
  for (const one of folders) {
    const mine = rows.filter((row) => row.root === one.root)
    if (mine.length === 0) continue
    const wantedTags = new Set(mine.flatMap((row) => row.tagIDs))
    const wantedCollections = new Set(mine.flatMap((row) => row.collectionIDs))
    const hasTags = new Set(one.tags.map((tag) => tag.id))
    const hasCollections = new Set(one.collections.map((entry) => entry.id))
    const tags = merged.tags.filter((tag) => wantedTags.has(tag.id) && !hasTags.has(tag.id))
    const collections = merged.collections.filter((entry) => wantedCollections.has(entry.id) && !hasCollections.has(entry.id))
    if (tags.length > 0 || collections.length > 0) out.push({ root: one.root, tags, collections })
  }
  return out
}

/**
 * Where a saved list of collections goes: each folder keeps the ones it
 * already had, and a new one goes into `destination` — the folder being
 * looked at, or the first — as on the Mac.
 */
export function collectionsByFolder(
  all: Collection[],
  folders: { root: string; ids: Set<string> }[],
  destination: string,
): { root: string; collections: Collection[] }[] {
  const known = new Set<string>()
  for (const one of folders) for (const id of one.ids) known.add(id)
  const home = folders.some((one) => one.root === destination) ? destination : folders[0]?.root
  const out: { root: string; collections: Collection[] }[] = []
  for (const one of folders) {
    const mine = all.filter((entry) => one.ids.has(entry.id) || (one.root === home && !known.has(entry.id)))
    if (mine.length === 0 && one.ids.size === 0) continue
    out.push({ root: one.root, collections: mine })
  }
  return out
}
