/**
 * What a PDF in the library is — the port of `DocumentKind.swift`.
 *
 * The app began as a reader for papers, and a paper is a strong shape: a
 * venue, a year, authors in citation order, a DOI, a key to cite it by.
 * Everything else somebody reads — a manual, a contract, a deck of slides —
 * has none of that, and a form asking a car manual for its journal makes the
 * app look silly and the reader wrong. So the library holds three kinds and
 * asks which one it has, with a guess offered.
 *
 * A book is its own kind rather than a document, because a book is cited.
 * Sent through the paper's form it comes back wrong in a way that is hard to
 * notice — a textbook matched to a journal article of the same name, with a
 * volume, an issue and a page range of `1054-1054` — and sent through the
 * document's form it cannot be cited at all.
 */
export type { DocumentKind } from './model.js'
import type { DocumentKind } from './model.js'

/** A book is cited; a document is not. */
export function isCitable(kind: DocumentKind): boolean {
  return kind !== 'document'
}

/** Only a paper can be asked about: the lookup is by DOI or arXiv id. */
export function isLookedUp(kind: DocumentKind): boolean {
  return kind === 'paper'
}

/** Where a PDF stops being long and starts being a book. */
export const BOOK_LENGTH = 100

export type GuessReason = 'identifier' | 'structure' | 'length' | 'nothingFound'

export interface DocumentGuess {
  kind: DocumentKind
  reason: GuessReason
}

/** A DOI or an arXiv identifier printed in the text. Nobody prints one on a
 *  car manual, so this is close to proof. */
export function hasIdentifier(text: string): boolean {
  return /\b10\.\d{4,9}\/[-._;()/:A-Z0-9]+/i.test(text) || /arxiv\s*:\s*\d{4}\.\d{4,5}/i.test(text)
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

export function guessKind(parts: {
  identifier: boolean
  abstract: boolean
  references: boolean
  pageCount?: number
}): DocumentGuess {
  if (parts.identifier) return { kind: 'paper', reason: 'identifier' }
  if (parts.abstract && parts.references) return { kind: 'paper', reason: 'structure' }
  // Long, and with a reference list at the back. The length alone is not
  // enough — a scanned manual is long too — and the references alone are not
  // either, since a short paper without an abstract has them. Both together,
  // at this length, is a book.
  if (parts.references && (parts.pageCount ?? 0) >= BOOK_LENGTH) {
    return { kind: 'book', reason: 'length' }
  }
  return { kind: 'document', reason: 'nothingFound' }
}
