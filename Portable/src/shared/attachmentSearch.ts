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
import { foldTitle, graphemes } from './textFold.js'
import { isNumber } from './metadata/chars.js'
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

// MARK: - Which paper a supplement belongs to (`SupplementDetector`)

const MARKERS = [
  'supplement', 'supplementary', 'supplemental',
  'appendix', 'appendices',
  'supp material', 'supp_material', 'supmat',
]

/** Whether the name or title reads as supplementary material. */
export function looksLikeSupplement(fileName: string, title: string | undefined): boolean {
  const haystack = [fileName, title ?? ''].map(foldTitle).join(' ')
  return MARKERS.some((marker) => haystack.includes(foldTitle(marker)))
}

/**
 * The paper a supplement most likely belongs to, or null unless one is a
 * clear match — attaching a supplement to the wrong paper hides it where it
 * will not be found. The supplementary words are taken out longest first
 * («supplement» out of «supplementary» left «ary» behind).
 */
export function bestParent(fileName: string, title: string | undefined, candidates: { id: string; title: string }[]): string | null {
  const needle = strippedNeedle(fileName, title)
  if ([...needle].length < 10) return null
  let best: { id: string; score: number } | null = null
  let runnerUp = 0
  for (const candidate of candidates) {
    const score = jaroWinkler(needle, foldTitle(candidate.title))
    if (score > (best?.score ?? 0)) {
      runnerUp = best?.score ?? 0
      best = { id: candidate.id, score }
    } else if (score > runnerUp) {
      runnerUp = score
    }
  }
  if (!best || best.score < 0.82 || best.score - runnerUp < 0.04) return null
  return best.id
}

/**
 * The paper to offer first, only for a document that says it is
 * supplementary (`AttachmentSearch.suggestion`): two papers whose titles
 * begin with the same words are not a supplement and its paper, and a wrong
 * answer under «Looks Like the One» is worse than none.
 */
export function suggestedParent(
  child: { id: string; title: string; fileName: string },
  candidates: { id: string; title: string }[],
): string | null {
  if (!looksLikeSupplement(child.fileName, child.title)) return null
  return bestParent(child.fileName, child.title, candidates.filter((one) => one.id !== child.id))
}

/** A file name without its extension (`deletingPathExtension`). */
const stemOf = (fileName: string) => fileName.replace(/\.[^./\\]*$/, '')

/** The file stem and title, folded, with the supplementary words taken out (longest first). */
function strippedNeedle(fileName: string, title: string | undefined): string {
  let needle = foldTitle([stemOf(fileName), title ?? ''].join(' '))
  for (const marker of [...MARKERS].sort((a, b) => b.length - a.length)) {
    needle = needle.split(foldTitle(marker)).join(' ')
  }
  return needle.split(' ').filter(Boolean).join(' ')
}

const ROLES = new Set(['paper', 'main', 'supplement', 'supplementary', 'supplemental', 'supp', 'appendix',
  'appendices', 'material', 'materials', 'supmat', 'sm'])

/** A file name with its role taken off: `…_CVPR_2024_supplemental` and
 *  `…_CVPR_2024_paper` are the same stem. Numbers at the end go too — the
 *  year, and the « 14.54.16» a second download of the same name is given. */
export function twinStem(fileName: string): string {
  const words = foldTitle(stemOf(fileName).replaceAll('_', ' ')).split(' ').filter(Boolean)
  while (words.length > 0) {
    const last = words[words.length - 1]
    if (!ROLES.has(last) && !graphemes(last).every(isNumber)) break
    words.pop()
  }
  return words.join(' ')
}

/** Whether one stem is the other with words left out of its middle: the same
 *  first word and last word, four words or more, the rest in order. */
export function isShortening(short: string, long: string): boolean {
  const few = short.split(' ').filter(Boolean)
  const many = long.split(' ').filter(Boolean)
  if (few.length < 4 || few.length >= many.length || few[0] !== many[0] || few[few.length - 1] !== many[many.length - 1]) return false
  let index = 0
  for (const word of few) {
    const found = many.indexOf(word, index)
    if (found < 0) return false
    index = found + 1
  }
  return true
}

/**
 * The paper a supplement belongs to, when that is certain enough to attach it
 * without asking (`SupplementDetector.confidentParent`; 2026-11-16:
 * «supplemental은 논문 목록에서 보이는게 아니라 본 논문의 "자료"에 등록되어야지»).
 *
 * Three witnesses, strongest first, each of which must point at exactly one
 * paper: the two files are twins — the same name but for `_supplemental` and
 * `_paper` (or the supplement's name a shortening of the paper's, the way the
 * Computer Vision Foundation names them); the paper's whole title (three words
 * or more) is inside the supplement's title or file name; or the titles are
 * all but equal. Anything less is left to the inspector's question.
 */
export function confidentParent(
  fileName: string,
  title: string | undefined,
  candidates: { id: string; title: string; fileName: string }[],
): string | null {
  if (!looksLikeSupplement(fileName, title)) return null

  const own = twinStem(fileName)
  if (graphemes(own).length >= 12) {
    const twins = candidates.filter((one) => twinStem(one.fileName) === own)
    if (twins.length === 1) return twins[0].id
    const shortened = candidates.filter((one) => isShortening(own, twinStem(one.fileName)))
    if (twins.length === 0 && shortened.length === 1) return shortened[0].id
  }

  const haystack = foldTitle([stemOf(fileName), title ?? ''].join(' ').replaceAll('_', ' '))
  const containing = candidates.filter((one) => {
    const folded = foldTitle(one.title)
    return folded.split(' ').filter(Boolean).length >= 3 && graphemes(folded).length >= 20 && haystack.includes(folded)
  })
  if (containing.length === 1) return containing[0].id

  const best = bestParent(fileName, title, candidates.map((one) => ({ id: one.id, title: one.title })))
  if (best === null) return null
  const needle = strippedNeedle(fileName, title)
  const scores = candidates.map((one) => jaroWinkler(needle, foldTitle(one.title))).sort((a, b) => b - a)
  const top = scores[0]
  if (top === undefined || top < 0.93 || top - (scores[1] ?? 0) < 0.08) return null
  return best
}
