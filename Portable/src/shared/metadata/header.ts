/**
 * `HeaderExtractor` and `CompositeHeaderExtractor` (MetadataPipeline): a
 * guess at the title and authors from the paper's own signals, before any
 * registrar confirms it. The Mac may also ask its on-device model; this
 * build has none, so the heuristics are the whole guess — as on an iPad.
 */

import type { CSLName } from '../model.js'
import { parseName } from '../model.js'
import { trimWhitespace } from '../zettel.js'
import { graphemes, isNumber } from './chars.js'
import { isStamp, type DocumentSignals } from './signals.js'
import { collapsingWhitespace, firstYear, foldedTitle, titleSimilarity } from './text.js'

export type ProvenanceSource =
  | 'doiContentNegotiation' | 'crossref' | 'openAlex' | 'arxiv' | 'semanticScholar' | 'pdfDocumentInfo'
  | 'onDeviceModel' | 'heuristic' | 'importedBibTeX' | 'importedRIS' | 'manual'

export interface ExtractedHeader {
  title: string
  authors: CSLName[]
  venueHint?: string
  year?: number
  strength: number
  source: ProvenanceSource
}

function header(title: string, authors: CSLName[], signals: DocumentSignals, strength: number, source: ProvenanceSource): ExtractedHeader {
  const out: ExtractedHeader = { title, authors, strength, source }
  if (signals.embeddedSubject !== undefined) out.venueHint = signals.embeddedSubject
  const year = yearHint(signals)
  if (year !== undefined) out.year = year
  return out
}

/** Swift's `sorted { $0.strength > $1.strength }` is not stable; the
 *  strengths here are distinct constants except when two share one, which
 *  keeps the order they were made in on both sides in practice. */
function strongestFirst(headers: ExtractedHeader[]): ExtractedHeader[] {
  return headers.map((one, index) => ({ one, index }))
    .sort((a, b) => b.one.strength - a.one.strength || a.index - b.index)
    .map(({ one }) => one)
}

export function headerCandidates(signals: DocumentSignals): ExtractedHeader[] {
  const results: ExtractedHeader[] = []
  if (signals.embeddedTitle !== undefined) {
    results.push(header(
      signals.embeddedTitle, signals.embeddedAuthors.map(parseName), signals,
      signals.embeddedAuthors.length === 0 ? 0.75 : 0.85, 'pdfDocumentInfo',
    ))
  }
  const largest = signals.largestFontText
  if (largest !== undefined && graphemes(largest).length >= 12) {
    const title = collapsingWhitespace(largest)
    if (!results.some((one) => areEquivalent(one.title, title))) {
      results.push(header(title, authorsFollowingTitle(title, signals.firstPageLines), signals, 0.6, 'heuristic'))
    }
  }
  const line = firstMeaningfulLine(signals.firstPageLines)
  if (line !== undefined && !results.some((one) => areEquivalent(one.title, line))) {
    results.push(header(line, authorsFollowingTitle(line, signals.firstPageLines), signals, 0.4, 'heuristic'))
  }
  return strongestFirst(results)
}

/** `CompositeHeaderExtractor`: several lists merged, near-duplicates out. */
export function mergeHeaders(lists: ExtractedHeader[][]): ExtractedHeader[] {
  const merged: ExtractedHeader[] = []
  for (const list of lists) {
    for (const one of list) {
      if (!merged.some((kept) => titleSimilarity(kept.title, one.title) > 0.95)) merged.push(one)
    }
  }
  return strongestFirst(merged)
}

export function areEquivalent(lhs: string, rhs: string): boolean {
  return titleSimilarity(lhs, rhs) > 0.95
}

export function firstMeaningfulLine(lines: string[]): string | undefined {
  const buffer: string[] = []
  for (const line of lines.slice(0, 25)) {
    if (isStamp(line) || looksLikeBoilerplate(line) || graphemes(line).length < 4) continue
    buffer.push(line)
    const joined = buffer.join(' ')
    if (graphemes(joined).length >= 25 && !endsMidPhrase(line)) return collapsingWhitespace(joined)
    if (buffer.length >= 3) break
  }
  const joined = buffer.join(' ')
  return graphemes(joined).length >= 12 ? collapsingWhitespace(joined) : undefined
}

const PHRASE_WORDS = ['a', 'an', 'the', 'of', 'for', 'with', 'and', 'or', 'in', 'on', 'to', 'via']

export function endsMidPhrase(line: string): boolean {
  const trimmed = trimWhitespace(line)
  const characters = graphemes(trimmed)
  const last = characters[characters.length - 1]
  if (last === undefined) return false
  if (last === '-' || last === ':' || last === ',') return true
  const words = trimmed.split(' ').filter(Boolean)
  const lastWord = (words[words.length - 1] ?? '').toLowerCase()
  return PHRASE_WORDS.includes(lastWord)
}

const BOILERPLATE = [
  'proceedings of', 'workshop on', 'published as a conference paper', 'under review as a conference paper',
  'accepted at', 'to appear in', 'copyright', 'all rights reserved', 'license', 'issn', 'isbn',
  'downloaded from', 'authorized licensed use', 'ieee transactions on', 'journal of', 'volume', 'preprint',
]

export function looksLikeBoilerplate(line: string): boolean {
  const lowered = line.toLowerCase()
  if (BOILERPLATE.some((marker) => lowered.startsWith(marker))) return true
  const characters = graphemes(line)
  const digits = characters.filter(isNumber).length
  return digits > Math.floor(characters.length / 2)
}

export function authorsFollowingTitle(title: string, lines: string[]): CSLName[] {
  const foldedTitleText = foldedTitle(title)
  const titleEnd = lines.findIndex((line) => {
    const folded = foldedTitle(line)
    return foldedTitleText.includes(folded) && graphemes(folded).length > 8
  })
  if (titleEnd < 0) return []
  for (const line of lines.slice(titleEnd + 1, titleEnd + 5)) {
    if (looksLikeBoilerplate(line)) continue
    if (line.toLowerCase().startsWith('abstract')) break
    const names = splitAuthorLine(line)
    if (names.length >= 1 && names.every((name) => sortingSurname(name) !== undefined)) return names
  }
  return []
}

export function splitAuthorLine(line: string): CSLName[] {
  let cleaned = ''
  for (const character of graphemes(line)) {
    if (!isNumber(character) && !'*†‡§¶∗'.includes(character)) cleaned += character
  }
  const parts = cleaned.replaceAll(' and ', ', ').split(',').map(trimWhitespace)
    .filter((part) => graphemes(part).length > 3 && part.includes(' '))
  if (parts.length === 0 || parts.length > 20) return []
  return parts.map(parseName)
}

export function yearHint(signals: DocumentSignals): number | undefined {
  if (signals.embeddedSubject !== undefined) {
    const year = firstYear(signals.embeddedSubject)
    if (year !== undefined) return year
  }
  return firstYear(signals.firstPageLines.slice(0, 6).join(' '))
}

/** `CSLName.sortingSurname`: the family name with its particle, or the
 *  literal — untrimmed, as the Swift property reads them. */
export function sortingSurname(name: CSLName): string | undefined {
  if (name.family) {
    const particle = name['non-dropping-particle']
    return particle ? `${particle} ${name.family}` : name.family
  }
  return name.literal ? name.literal : undefined
}
