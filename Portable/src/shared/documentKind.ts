/**
 * What a PDF in the library is — the port of `DocumentKind.swift`.
 *
 * The app began as a reader for papers, and a paper is a strong shape: a
 * venue, a year, authors in citation order, a DOI, a key to cite it by.
 * Everything else somebody reads — a manual, a contract, a deck of slides —
 * has none of that, and a form asking a car manual for its journal makes the
 * app look silly and the reader wrong. So the library holds four kinds and
 * asks which one it has, with a guess offered.
 *
 * A book is its own kind rather than a document, because a book is cited.
 * Sent through the paper's form it comes back wrong in a way that is hard to
 * notice — a textbook matched to a journal article of the same name, with a
 * volume, an issue and a page range of `1054-1054` — and sent through the
 * document's form it cannot be cited at all.
 *
 * Course material is the fourth, and for the opposite reason: not because it
 * is cited but because there is so much of it. A term is thirty files that
 * are not papers, and as documents they sit among the contracts. It is a
 * shelf before it is a citation.
 */
export type { DocumentKind } from './model.js'
import type { DocumentKind } from './model.js'

/** A paper and a book are cited; a document and a term's slides are not. */
export function isCitable(kind: DocumentKind): boolean {
  return kind === 'paper' || kind === 'book'
}

/** Only a paper can be asked about: the lookup is by DOI or arXiv id. */
export function isLookedUp(kind: DocumentKind): boolean {
  return kind === 'paper'
}

/** Where a PDF stops being long and starts being a book. */
export const BOOK_LENGTH = 100

export type GuessReason = 'identifier' | 'structure' | 'length' | 'slides' | 'course' | 'nothingFound'

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

/**
 * What a course calls its own reading, in both languages. Looked for in the
 * file's name and the front of the first page, and only once the paper tests
 * have failed — "lecture" appears in the prose of plenty of papers.
 */
export const COURSE_WORDS = [
  'lecture', 'syllabus', 'problem set', 'homework', 'midterm', 'final exam',
  'course notes', 'class notes', 'tutorial',
  '강의', '강의자료', '강의노트', '수업', '주차', '차시', '과제', '중간고사', '기말고사', '실습',
]

/** Whether a course names itself here: its words, or a course code. */
export function namesACourse(text: string): boolean {
  const lower = text.toLowerCase()
  if (COURSE_WORDS.some((word) => lower.includes(word))) return true
  return /\b[a-z]{2,4}\s?-?\s?\d{3}\b/.test(lower)
}

export function guessKind(parts: {
  identifier: boolean
  abstract: boolean
  references: boolean
  pageCount?: number
  landscape?: boolean
  courseWords?: boolean
}): DocumentGuess {
  if (parts.identifier) return { kind: 'paper', reason: 'identifier' }
  if (parts.abstract && parts.references) return { kind: 'paper', reason: 'structure' }
  // Slides first, then the words. A landscape page is the one thing no paper
  // and no book has — but only after the paper tests, because a conference
  // paper printed two-up is landscape and has an abstract.
  if (parts.landscape) return { kind: 'lecture', reason: 'slides' }
  if (parts.courseWords) return { kind: 'lecture', reason: 'course' }
  // Long, and with a reference list at the back. The length alone is not
  // enough — a scanned manual is long too — and the references alone are not
  // either, since a short paper without an abstract has them. Both together,
  // at this length, is a book.
  if (parts.references && (parts.pageCount ?? 0) >= BOOK_LENGTH) {
    return { kind: 'book', reason: 'length' }
  }
  return { kind: 'document', reason: 'nothingFound' }
}
