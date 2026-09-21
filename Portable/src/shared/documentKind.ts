/**
 * What a PDF in the library is — the port of `DocumentKind.swift`.
 *
 * The app began as a reader for papers, and a paper is a strong shape: a
 * venue, a year, authors in citation order, a DOI, a key to cite it by.
 * Everything else somebody reads — a manual, a contract, a deck of slides —
 * has none of that, and a form asking a car manual for its journal makes the
 * app look silly and the reader wrong. So the library holds two kinds and
 * asks which one it has, with a guess offered.
 */
export type DocumentKind = 'paper' | 'document'

export type GuessReason = 'identifier' | 'structure' | 'nothingFound'

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
}): DocumentGuess {
  if (parts.identifier) return { kind: 'paper', reason: 'identifier' }
  if (parts.abstract && parts.references) return { kind: 'paper', reason: 'structure' }
  return { kind: 'document', reason: 'nothingFound' }
}
