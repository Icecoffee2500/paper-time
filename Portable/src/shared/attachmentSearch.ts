/**
 * Finding the paper a document should be attached to — the Mac's
 * `AttachmentSearch` (`PaperCore/Model/AttachmentSearch.swift`), rung for rung.
 *
 * The one wanted is a supplement's parent, so it is as likely to be at Z as
 * at A: the list has to be searched, and from either of the two names a
 * reader has for a paper — its title, and its file's name (somebody who
 * downloaded `Karmanov_Efficient_Test-Time_Adaptation_CVPR_2024.pdf` types
 * «karmanov», which is in no title).
 */
import { foldTitle } from './textFold.js'
import { jaroWinkler } from './searchRank.js'

export interface AttachCandidate {
  id: string
  title: string
  fileName: string
  /** Folded once, when the candidate is made, not on every keystroke. */
  foldedTitle: string
  foldedFile: string
  titleWords: string[]
  fileWords: string[]
}

export function attachCandidate(id: string, title: string, fileName: string): AttachCandidate {
  const foldedTitle = foldTitle(title)
  const foldedFile = foldTitle(fileName)
  return {
    id,
    title,
    fileName,
    foldedTitle,
    foldedFile,
    titleWords: foldedTitle.split(' ').filter(Boolean),
    fileWords: foldedFile.split(' ').filter(Boolean),
  }
}

/**
 * How well one paper answers a query, or null. The title outranks the file
 * name at every rung: a phrase in a title is the paper being named, and the
 * same phrase in a file name may be the conference that published it.
 */
export function attachScore(candidate: AttachCandidate, needle: string, words: string[]): number | null {
  const title = candidate.foldedTitle
  const file = candidate.foldedFile
  if (title.startsWith(needle)) return 1
  if (title.includes(needle)) return 0.9
  if (file.startsWith(needle)) return 0.8
  if (file.includes(needle)) return 0.75

  // Word by word, and by prefix: «adapt» finds «adaptation», and Korean
  // attaches its particles to the noun, so «강화학습» finds «강화학습의».
  let inTitle = 0
  let inFile = 0
  for (const word of words) {
    if (candidate.titleWords.some((one) => one.startsWith(word))) inTitle += 1
    else if (candidate.fileWords.some((one) => one.startsWith(word))) inFile += 1
  }
  const found = inTitle + inFile
  if (found === 0) return null
  const coverage = found / words.length
  const fromTitle = inTitle / found
  return (coverage === 1 ? 0.6 : 0.5 * coverage) + 0.05 * fromTitle
}

/**
 * The candidates that answer a query, best first. Nothing typed: everything,
 * in title order. Nothing matching a word: whole-name similarity, which
 * survives a typo — an empty list would say «no such paper» when the truth is
 * «spelled differently».
 */
export function rankAttachments(candidates: AttachCandidate[], query: string): AttachCandidate[] {
  const needle = foldTitle(query)
  // `localizedStandardCompare` is Finder's order: numbers as numbers.
  if (!needle) return [...candidates].sort((a, b) => a.title.localeCompare(b.title, undefined, { numeric: true }))
  const words = needle.split(' ').filter(Boolean)
  let scored: { candidate: AttachCandidate; score: number }[] = []
  for (const candidate of candidates) {
    const score = attachScore(candidate, needle, words)
    if (score !== null) scored.push({ candidate, score })
  }
  if (scored.length === 0) {
    scored = candidates
      .map((candidate) => ({
        candidate,
        score: Math.max(jaroWinkler(needle, candidate.foldedTitle), jaroWinkler(needle, candidate.foldedFile)) - 1,
      }))
      .filter((one) => one.score >= 0.7 - 1)
  }
  // Ties on the folded title with a plain comparison, as the Mac breaks them.
  return scored
    .sort((a, b) => (a.score === b.score
      ? (a.candidate.foldedTitle < b.candidate.foldedTitle ? -1 : a.candidate.foldedTitle > b.candidate.foldedTitle ? 1 : 0)
      : b.score - a.score))
    .map((one) => one.candidate)
}
