/**
 * What a PDF in the library is — the port of `DocumentKind.swift`.
 *
 * The app began as a reader for papers, and a paper is a strong shape: a
 * venue, a year, authors in citation order, a DOI, a key to cite it by.
 * Everything else somebody reads — a manual, a contract, a deck of slides —
 * has none of that, and a form asking a car manual for its journal makes the
 * app look silly and the reader wrong. So the library asks one question — is
 * it a paper? — with a guess offered.
 *
 * 0.9.2 to 0.9.37 had two more kinds, `book` and `lecture`; 1.0 folded them
 * back (Docs/Decisions-1.0.md). `PaperMeta` reads a record that still says
 * `book` as a paper — a book is cited, and its CSL type stays `book` — and
 * one that says `lecture` as a document.
 */
export type { DocumentKind } from './model.js'
import { identifiersAreEmpty, scanIdentifiers } from './metadata/identifiers.js'
import type { DocumentKind } from './model.js'

/** A paper is cited; a document is not. */
export function isCitable(kind: DocumentKind): boolean {
  return kind === 'paper'
}

/** Only a paper can be asked about: the lookup is by DOI or arXiv id. */
export function isLookedUp(kind: DocumentKind): boolean {
  return kind === 'paper'
}

export type GuessReason = 'identifier' | 'structure' | 'nothingFound'

export interface DocumentGuess {
  kind: DocumentKind
  reason: GuessReason
}

/** The kinds a record may still say on disk, and what each is read as. */
export function readKind(raw: unknown): DocumentKind | undefined {
  switch (raw) {
    case 'paper': case 'book': return 'paper'
    case 'document': case 'lecture': return 'document'
    default: return undefined
  }
}

/** A DOI, an arXiv identifier or a PubMed ID printed in the text — the
 *  Mac's `IdentifierScanner`, which the guess asks. Nobody prints one on a car
 *  manual, so this is close to proof. */
export function hasIdentifier(text: string): boolean {
  return !identifiersAreEmpty(scanIdentifiers(text))
}

/** An abstract, where a paper puts one: near the top of the first page. */
export function hasAbstract(firstPageText: string): boolean {
  const head = firstPageText.slice(0, 2500).toLowerCase()
  return ['abstract', '초록', '요약', 'résumé', 'zusammenfassung'].some((word) => head.includes(word))
}

/** A reference list, which is the other half of what makes a paper a paper.
 *  Looked for at the end: a heading called "References" in the middle of a
 *  manual is a section about references. */
export function hasReferences(endText: string): boolean {
  const text = endText.toLowerCase()
  return ['references', 'bibliography', 'works cited', '참고문헌', '참고 문헌', '인용문헌']
    .some((word) => text.includes(word))
}

export function guessKind(parts: { identifier: boolean; abstract: boolean; references: boolean }): DocumentGuess {
  if (parts.identifier) return { kind: 'paper', reason: 'identifier' }
  if (parts.abstract && parts.references) return { kind: 'paper', reason: 'structure' }
  return { kind: 'document', reason: 'nothingFound' }
}

/**
 * Whether a record wants a look: a paper whose lookup came back unsure. A
 * document has no registrar to disagree with, so it never is one
 * (`PaperRow.needsReview`, the «Needs Review» shelf).
 */
export function needsReview(meta: { effectiveKind: DocumentKind; confidence?: string }): boolean {
  return isLookedUp(meta.effectiveKind) && (meta.confidence === 'needsReview' || meta.confidence === 'unparsed')
}
