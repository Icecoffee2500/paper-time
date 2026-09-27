/**
 * One person, however their name was written — the Mac's
 * `PaperGraphBuilder.authorKey` and `CSLName.sortingSurname`.
 *
 * «Y. LeCun» and «Yann LeCun» are one author: the surname and the first
 * initial, folded, are enough to join the ways one name gets written and not
 * so loose that two people collide. The sidebar's Authors section and the
 * list's author sort read names through here, so the two builds rank and
 * order the same library the same way.
 */
import type { CSLName } from './model.js'

/** The surname used for sorting and keys; an institution's whole name. */
export function sortingSurname(name: CSLName): string | null {
  if (name.family) {
    const particle = name['non-dropping-particle']
    return particle ? `${particle} ${name.family}` : name.family
  }
  return name.literal || null
}

/** Case and accents folded away — `folding([.diacriticInsensitive, .caseInsensitive])`. */
export function foldName(text: string): string {
  return text.normalize('NFD').replace(/\p{M}/gu, '').normalize('NFC').toLowerCase()
}

/** `surname|initial`, folded, or null for a name with no surname at all. */
export function authorKey(name: CSLName): string | null {
  const surname = sortingSurname(name)
  const folded = surname === null ? '' : foldName(surname).trim()
  if (!folded) return null
  const given = name.given ? foldName(name.given) : ''
  const initial = given ? ([...given][0] ?? '') : ''
  return `${folded}|${initial}`
}

/** «Given Family», the way a row shows a name — `CSLName.displayName`. */
export function nameShown(name: CSLName): string {
  if (name.literal) return name.literal
  const tail = [name['non-dropping-particle'], name.family].filter(Boolean).join(' ')
  const core = [name.given || undefined, tail || undefined].filter(Boolean).join(' ')
  return name.suffix ? `${core}, ${name.suffix}` : core
}

/** Finder's order: case and accents aside, and «Week 2» before «Week 10» —
 *  `localizedStandardCompare`. One collator for every list that sorts names. */
export const standardOrder = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })

/** A title's or a surname's order: case aside, accents and digits as
 *  written — `localizedCaseInsensitiveCompare`, which the Mac's list sorts by. */
export const caseInsensitiveOrder = new Intl.Collator(undefined, { sensitivity: 'accent' })
