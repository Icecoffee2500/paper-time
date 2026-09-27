/**
 * BibTeX citation keys — the Mac's `CitationKey`, rule for rule.
 *
 * `surnameYEARword`, the form people already type from memory. The same
 * folder has to export the same keys on both desktops: a key that came out
 * one way on a Mac and another on Windows is a changed line in a co-author's
 * paper and a broken `\cite`.
 */
import { foldTitle } from './textFold.js'
import { cslFullTitle, cslYear, surname, type CSLItem } from './model.js'

const STOP_WORDS = new Set([
  'a', 'an', 'the', 'on', 'of', 'in', 'for', 'to', 'and', 'or', 'with',
  'at', 'by', 'from', 'into', 'is', 'are', 'how', 'what', 'why', 'when',
  'can', 'do', 'does', 'toward', 'towards', 'via', 'using', 'learning',
])

/** `TextNormalization.firstSignificantWord`: the first folded word that is
 *  not a stop word and longer than two letters, else the first word. */
export function firstSignificantWord(title: string): string | undefined {
  const words = foldTitle(title).split(' ').filter(Boolean)
  return words.find((word) => !STOP_WORDS.has(word) && [...word].length > 2) ?? words[0]
}

/** Accents folded away, lower case, ASCII letters and digits only. */
function asciiWord(raw: string): string {
  return raw.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().replace(/[^a-z0-9]/g, '')
}

export function makeKey(item: CSLItem, fallback = 'untitled'): string {
  const first = item.author?.[0] ?? item.editor?.[0]
  const family = first ? surname(first) : undefined
  const namePart = family ? asciiWord(family) : ''
  const year = cslYear(item)
  const yearPart = year !== undefined ? String(year) : ''
  const title = cslFullTitle(item)
  const word = title ? firstSignificantWord(title) : undefined
  const titlePart = word ? asciiWord(word) : ''
  const combined = namePart + yearPart + titlePart
  return combined || asciiWord(fallback)
}

/** `a`, `b`, `c`… after a key already taken, then `-2`, `-3`. */
export function uniqued(key: string, taken: Set<string>): string {
  if (!taken.has(key)) {
    taken.add(key)
    return key
  }
  for (const suffix of 'abcdefghijklmnopqrstuvwxyz') {
    const candidate = key + suffix
    if (!taken.has(candidate)) {
      taken.add(candidate)
      return candidate
    }
  }
  let counter = 2
  while (taken.has(`${key}-${counter}`)) counter += 1
  const candidate = `${key}-${counter}`
  taken.add(candidate)
  return candidate
}

/** Everything BibTeX cannot carry in a key taken out. */
export function sanitise(raw: string): string {
  let out = ''
  for (const character of raw) {
    if (/^[A-Za-z0-9]$/.test(character)) out += character
    else if ('-_:'.includes(character) && out) out += character
  }
  return out
}

/**
 * Keys for a whole export in one pass: the keys papers already have kept
 * first — an export never silently changes a key somebody has cited — then
 * new ones minted and made unique, in the order given.
 */
export function assignKeys(items: { id: string; item: CSLItem; preferred?: string | null }[]): Map<string, string> {
  const taken = new Set<string>()
  const result = new Map<string, string>()
  for (const entry of items) {
    if (!entry.preferred) continue
    const clean = sanitise(entry.preferred)
    if (taken.has(clean)) continue
    taken.add(clean)
    result.set(entry.id, clean)
  }
  for (const entry of items) {
    if (result.has(entry.id)) continue
    result.set(entry.id, uniqued(makeKey(entry.item), taken))
  }
  return result
}
