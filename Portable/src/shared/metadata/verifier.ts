/**
 * `MetadataVerifier` (MetadataPipeline): whether a registrar's record is
 * really the paper in front of us. The bias is one-directional on purpose — a
 * wrong record stored silently ends up in a submitted manuscript; a record
 * flagged for a two-second confirmation does not.
 */

import type { CSLItem } from '../model.js'
import type { Confidence } from '../model.js'
import { fullTitle, itemYear } from './csl.js'
import { sortingSurname, type ExtractedHeader } from './header.js'
import { foldedTitle, jaroWinkler, titleSimilarity } from './text.js'

export interface MatchAssessment {
  titleSimilarity: number
  firstAuthorMatches?: boolean
  yearDifference?: number
  identifierCameFromDocument: boolean
  verdict: Confidence
  explanation: string
}

export const TITLE_THRESHOLD = 0.90
export const STRONG_TITLE_THRESHOLD = 0.98
export const IDENTIFIER_TITLE_THRESHOLD = 0.80
export const CANDIDATE_FLOOR = 0.80

/** The title carries most of the weight: 0.85, then 0.10 for the first
 *  author and 0.05 for a year within one. */
export function score(assessment: MatchAssessment): number {
  let value = assessment.titleSimilarity * 0.85
  if (assessment.firstAuthorMatches === true) value += 0.10
  if (assessment.yearDifference !== undefined && assessment.yearDifference <= 1) value += 0.05
  return Math.min(1, value)
}

export function assess(candidate: CSLItem, header: ExtractedHeader | undefined, identifierCameFromDocument: boolean): MatchAssessment {
  if (!header) {
    return {
      titleSimilarity: 0,
      identifierCameFromDocument,
      verdict: identifierCameFromDocument ? 'verified' : 'needsReview',
      explanation: identifierCameFromDocument
        ? 'Matched by an identifier printed in the document.'
        : 'No title could be read from the document to check against.',
    }
  }
  const full = fullTitle(candidate)
  const similarity = full === undefined ? 0 : titleSimilarity(full, header.title)
  const authorMatch = compareFirstAuthor(candidate, header)
  const yearGap = compareYear(candidate, header)
  const verdict = decide(similarity, authorMatch, yearGap, identifierCameFromDocument)
  const out: MatchAssessment = {
    titleSimilarity: similarity,
    identifierCameFromDocument,
    verdict,
    explanation: explain(similarity, authorMatch, yearGap, identifierCameFromDocument, verdict),
  }
  if (authorMatch !== undefined) out.firstAuthorMatches = authorMatch
  if (yearGap !== undefined) out.yearDifference = yearGap
  return out
}

export function decide(similarity: number, authorMatch: boolean | undefined, yearGap: number | undefined, fromDocument: boolean): Confidence {
  if (fromDocument) return similarity >= IDENTIFIER_TITLE_THRESHOLD || similarity === 0 ? 'verified' : 'needsReview'
  if (similarity >= STRONG_TITLE_THRESHOLD) return 'verified'
  if (similarity < TITLE_THRESHOLD) return 'needsReview'
  if (authorMatch === true) return 'verified'
  if (authorMatch === undefined && yearGap !== undefined && yearGap <= 1) return 'verified'
  return 'needsReview'
}

function compareFirstAuthor(candidate: CSLItem, header: ExtractedHeader): boolean | undefined {
  const expected = header.authors[0] ? sortingSurname(header.authors[0]) : undefined
  const actual = candidate.author?.[0] ? sortingSurname(candidate.author[0]) : undefined
  if (expected === undefined || actual === undefined) return undefined
  const left = foldedTitle(expected)
  const right = foldedTitle(actual)
  if (!left || !right) return undefined
  if (left === right) return true
  if (left.includes(right) || right.includes(left)) return true
  return jaroWinkler(left, right) >= 0.92
}

function compareYear(candidate: CSLItem, header: ExtractedHeader): number | undefined {
  const actual = itemYear(candidate)
  if (header.year === undefined || actual === undefined) return undefined
  return Math.abs(header.year - actual)
}

/** Swift's `(x * 100).rounded()`: halves away from zero. */
function percent(similarity: number): number {
  const scaled = similarity * 100
  return Math.sign(scaled) * Math.floor(Math.abs(scaled) + 0.5)
}

function explain(similarity: number, authorMatch: boolean | undefined, yearGap: number | undefined, fromDocument: boolean, verdict: Confidence): string {
  const parts: string[] = []
  if (fromDocument) parts.push('identifier printed in the document')
  parts.push(`title match ${percent(similarity)}%`)
  parts.push(authorMatch === true ? 'first author matches' : authorMatch === false ? 'first author differs' : 'no author to compare')
  if (yearGap !== undefined) parts.push(yearGap === 0 ? 'same year' : `year differs by ${yearGap}`)
  const reason = parts.join(', ')
  return verdict === 'verified' ? `Confirmed: ${reason}.` : `Needs a check: ${reason}.`
}

/** `rank`: a verdict first, then the title, then the blend. */
export function rankOf(assessment: MatchAssessment): [number, number, number] {
  return [assessment.verdict === 'verified' ? 1 : 0, assessment.titleSimilarity, score(assessment)]
}

export function compareRank(lhs: MatchAssessment, rhs: MatchAssessment): number {
  const a = rankOf(lhs)
  const b = rankOf(rhs)
  for (let index = 0; index < 3; index += 1) if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1
  return 0
}
