/**
 * `DocumentSignals` and the parts of `DocumentSignalsExtractor` that read
 * text rather than a PDF (MetadataPipeline): everything the resolver can
 * learn from a paper without going online.
 *
 * The Mac reads its signals through PDFKit; this build reads the same things
 * through pdf.js (`main/metadata/signals.ts`). What each signal *means* —
 * which title is a placeholder, which line is an author block, which pages
 * are looked at for a reference list, what the largest type says — lives
 * here, and is held to the Mac's answers on the same inputs.
 */

import { guessKind, namesACourse, type DocumentGuess } from '../documentKind.js'
import { trimWhitespace, trimWhitespaceAndNewlines } from '../zettel.js'
import { graphemes, isLetter, isNumber, isUppercase } from './chars.js'
import { identifiersAreEmpty, scanIdentifiers } from './identifiers.js'
import { collapsingWhitespace } from './text.js'

export interface DocumentSignals {
  pageCount: number
  embeddedTitle?: string
  embeddedAuthors: string[]
  embeddedSubject?: string
  embeddedKeywords: string[]
  firstPageLines: string[]
  openingText: string
  largestFontText?: string
  hasTextLayer: boolean
  hasAbstract: boolean
  hasReferences: boolean
  isLandscape: boolean
}

export function emptySignals(pageCount = 0): DocumentSignals {
  return {
    pageCount, embeddedAuthors: [], embeddedKeywords: [], firstPageLines: [], openingText: '',
    hasTextLayer: false, hasAbstract: false, hasReferences: false, isLandscape: false,
  }
}

/** `DocumentSignals.guess` — without the file's name, as the Mac asks it
 *  when a paper is resolved. */
export function guessFromSignals(signals: DocumentSignals, fileName?: string): DocumentGuess {
  const named = [fileName ?? '', graphemes(signals.openingText).slice(0, 1200).join('')].join(' ')
  return guessKind({
    identifier: !identifiersAreEmpty(scanIdentifiers(signals.openingText)),
    abstract: signals.hasAbstract,
    references: signals.hasReferences,
    pageCount: signals.pageCount,
    landscape: signals.isLandscape,
    courseWords: namesACourse(named),
  })
}

/** `components(separatedBy: .newlines)`, trimmed, the empty ones dropped —
 *  a page's text as its lines. */
export function pageLines(text: string): string[] {
  return text.split(/[\n\u000b\u000c\r\u0085\u2028\u2029]/).map(trimWhitespace).filter(Boolean)
}

/** An abstract near the top of the first page, in either language. */
export function looksLikeAbstract(firstPageText: string): boolean {
  const head = graphemes(firstPageText).slice(0, 2500).join('').toLowerCase()
  return ['abstract', '초록', '요약', 'résumé', 'zusammenfassung'].some((word) => head.includes(word))
}

/** The pages read for a reference list, last first. */
export function referencePageIndices(count: number): number[] {
  if (count <= 0) return []
  let indices: number[]
  if (count <= 40) indices = Array.from({ length: count }, (_, index) => index)
  else {
    indices = []
    for (let index = count - 1; index >= Math.max(0, count - 8); index -= 1) indices.push(index)
    const step = Math.max(1, Math.floor(count / 12))
    const sampled: number[] = []
    for (let index = 0; index < count && sampled.length < 12; index += step) sampled.push(index)
    indices.push(...sampled)
  }
  return [...new Set(indices)].sort((a, b) => b - a)
}

export const REFERENCE_HEADINGS = ['references', 'bibliography', 'works cited', '참고문헌', '참고 문헌', '인용문헌']

export function holdsReferenceHeading(pageText: string): boolean {
  const text = pageText.toLowerCase()
  return REFERENCE_HEADINGS.some((heading) => text.includes(heading))
}

// MARK: - Embedded attributes

const PLACEHOLDERS = [
  'untitled', 'microsoft word', 'no title', 'paper', 'manuscript', 'main', 'document', 'template',
  'acm sig proceedings', 'elsevier', 'print', 'output', 'final', 'camera ready', 'camera-ready',
]

/** The PDF's `/Title`, unless it is a producer's placeholder. */
export function cleanEmbeddedTitle(raw: string | undefined): string | undefined {
  if (raw === undefined) return undefined
  const value = trimWhitespaceAndNewlines(collapsingWhitespace(raw))
  if (graphemes(value).length < 12) return undefined
  const lowered = value.toLowerCase()
  if (PLACEHOLDERS.some((one) => lowered === one || lowered.startsWith(`${one} -`))) return undefined
  if (['.dvi', '.tex', '.pdf', '.doc', '.docx', '.ps'].some((suffix) => lowered.endsWith(suffix))) return undefined
  return value.includes(' ') ? value : undefined
}

/** The PDF's `/Author`, split into names. */
export function splitAuthorField(raw: string | undefined): string[] {
  if (raw === undefined) return []
  const value = collapsingWhitespace(raw)
  if (!value) return []
  for (const separator of [';', ' and ', ',']) {
    if (!value.includes(separator)) continue
    const parts = value.split(separator).map(trimWhitespace).filter((part) => graphemes(part).length > 1)
    // «Family, Given» is one author.
    if (separator === ',' && parts.length === 2) break
    if (parts.length > 1) return parts
  }
  return [value]
}

export function keywordList(raw: unknown): string[] {
  if (Array.isArray(raw)) return raw.filter((one): one is string => typeof one === 'string')
  if (typeof raw !== 'string') return []
  return raw.split(/[,;]/).map(trimWhitespace).filter(Boolean)
}

export function nonEmpty(raw: string | undefined): string | undefined {
  if (raw === undefined) return undefined
  const value = collapsingWhitespace(raw)
  return value ? value : undefined
}

// MARK: - Typography

export interface FontRun {
  size: number
  /** UTF-16 offset and length in the page's text. */
  location: number
  length: number
}

/** Swift's `(size * 10).rounded() / 10`: halves away from zero. */
function roundTenth(size: number): number {
  const scaled = size * 10
  return (scaled < 0 ? -Math.round(-scaled) : Math.sign(scaled) * Math.floor(Math.abs(scaled) + 0.5)) / 10
}

/** The text set in the largest type on the page, as whole lines. */
export function largestFontText(runs: FontRun[], fullText: string): string | undefined {
  if (runs.length === 0) return undefined
  const sizes = [...new Set(runs.map((run) => roundTenth(run.size)))].sort((a, b) => b - a)
  for (const size of sizes) {
    const group = runs.filter((run) => run.size >= size * 0.97)
    if (group.length === 0) continue
    const rawText = collapsingWhitespace(group.map((run) => fullText.slice(run.location, run.location + run.length)).join(' '))
    if (graphemes(rawText).length < 2) continue
    if (isStamp(rawText)) continue
    const candidate = collapsingWhitespace(expandToLines(group, fullText))
    if (graphemes(candidate).length < 12 || isStamp(candidate)) continue
    return candidate
  }
  return undefined
}

const LINE_BREAKS = new Set([0x0a, 0x0d, 0x85, 0x2028, 0x2029])

/** `NSString.lineRange(for:)` at one location: the whole line, its end
 *  included. */
function lineRange(text: string, location: number): { start: number; end: number } {
  let start = location
  while (start > 0) {
    const code = text.charCodeAt(start - 1)
    if (LINE_BREAKS.has(code)) break
    start -= 1
  }
  let end = location
  while (end < text.length && !LINE_BREAKS.has(text.charCodeAt(end))) end += 1
  if (end < text.length) {
    if (text.charCodeAt(end) === 0x0d && text.charCodeAt(end + 1) === 0x0a) end += 2
    else end += 1
  }
  return { start, end }
}

/** Ranges grown out to the lines that hold them, stopping at the author
 *  block. */
export function expandToLines(ranges: { location: number; length: number }[], text: string): string {
  if (ranges.length === 0) return ''
  const lower = Math.min(...ranges.map((range) => range.location))
  const upper = Math.max(...ranges.map((range) => range.location + range.length))
  const clampedLower = Math.max(0, Math.min(lower, text.length))
  const clampedUpper = Math.max(clampedLower, Math.min(upper, text.length))
  const first = lineRange(text, clampedLower)
  const last = lineRange(text, Math.max(clampedLower, clampedUpper - 1))
  const block = text.slice(first.start, last.end)
  const kept: string[] = []
  for (const line of block.split(/[\n\u000b\u000c\r\u0085\u2028\u2029]/)) {
    const trimmed = trimWhitespace(line)
    if (!trimmed) continue
    if (kept.length > 0 && isLikelyAuthorOrAffiliationLine(trimmed)) break
    kept.push(trimmed)
    if (kept.length === 4) break
  }
  return kept.join(' ')
}

const AFFILIATION_WORDS = [
  'university', 'institute', 'laborator', 'inc.', 'corporation', 'research', 'college', 'school of',
  'department', 'academy', 'google', 'microsoft', 'meta ai', 'openai', 'nvidia', 'deepmind',
]

/** The author and affiliation block under a title. */
export function isLikelyAuthorOrAffiliationLine(line: string): boolean {
  if (line.includes('@')) return true
  const characters = graphemes(line)
  if (characters.some((character) => '∗†‡§¶→'.includes(character))) return true
  const lowered = line.toLowerCase()
  if (AFFILIATION_WORDS.some((word) => lowered.includes(word))) return true
  const tokens = line.split(' ').filter(Boolean)
  if (tokens.length < 2) return false
  for (const token of tokens) {
    const chars = graphemes(token)
    for (let index = 1; index < chars.length; index += 1) {
      if (isNumber(chars[index]) && isLetter(chars[index - 1])) return true
    }
    if (chars.length > 2 && isNumber(chars[0]) && isUppercase(chars[1])) return true
  }
  const commas = characters.filter((character) => character === ',').length
  if (commas >= 2) {
    const capitalised = tokens.filter((token) => isUppercase(graphemes(token)[0] ?? '')).length
    if (capitalised * 2 >= tokens.length) return true
  }
  return false
}

/** The preprint server's stamp and the open-access watermarks. */
export function isStamp(text: string): boolean {
  const lowered = text.toLowerCase()
  if (lowered.startsWith('arxiv:')) return true
  return [
    'this iccv paper is the open access version', 'this cvpr paper is the open access version',
    'this wacv paper is the open access version', 'provided by the computer vision foundation',
    'except for this watermark', 'preprint. under review', 'biorxiv preprint',
  ].some((mark) => lowered.includes(mark))
}
