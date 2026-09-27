/**
 * `Identifiers` (PaperCore) and `IdentifierScanner` (MetadataPipeline): the
 * DOIs, arXiv IDs and PubMed IDs a paper prints on itself. Only the opening
 * pages are scanned — a reference list is full of other papers' DOIs.
 */

import { swiftInt } from './text.js'
import { trimWhitespace, trimWhitespaceAndNewlines } from '../zettel.js'

export interface Identifiers {
  doi?: string
  arxiv?: string
  pmid?: string
  openAlex?: string
  semanticScholar?: string
  isbn?: string
}

/** `Identifiers.init`: the DOI and the arXiv ID normalised, or dropped. */
export function identifiers(parts: Identifiers = {}): Identifiers {
  const out: Identifiers = {}
  const doi = parts.doi === undefined ? undefined : normalizeDOI(parts.doi)
  const arxiv = parts.arxiv === undefined ? undefined : normalizeArxiv(parts.arxiv)
  if (doi) out.doi = doi
  if (arxiv) out.arxiv = arxiv
  if (parts.pmid !== undefined) out.pmid = parts.pmid
  if (parts.openAlex !== undefined) out.openAlex = parts.openAlex
  if (parts.semanticScholar !== undefined) out.semanticScholar = parts.semanticScholar
  if (parts.isbn !== undefined) out.isbn = parts.isbn
  return out
}

export function identifiersAreEmpty(ids: Identifiers): boolean {
  return ids.doi === undefined && ids.arxiv === undefined && ids.pmid === undefined
    && ids.openAlex === undefined && ids.semanticScholar === undefined && ids.isbn === undefined
}


const DOI_PREFIXES = ['https://doi.org/', 'http://doi.org/', 'https://dx.doi.org/', 'http://dx.doi.org/', 'doi:', 'DOI:', 'doi.org/']

/** `normalizeDOI`: the prefixes off, trailing sentence punctuation off,
 *  lowercased — or nothing, when what is left is not a DOI. */
export function normalizeDOI(raw: string): string | undefined {
  let value = trimWhitespaceAndNewlines(raw)
  // Each prefix is tried in turn against what the previous ones left, the
  // way the Swift loop does.
  for (const prefix of DOI_PREFIXES) {
    if (value.toLowerCase().startsWith(prefix.toLowerCase())) value = value.slice(prefix.length)
  }
  value = trimWhitespace(value)
  while (value && '.,;)]>'.includes(value[value.length - 1])) value = value.slice(0, -1)
  if (!value.startsWith('10.') || !value.includes('/') || [...value].length <= 7) return undefined
  return value.toLowerCase()
}

const ARXIV_PREFIXES = ['https://arxiv.org/abs/', 'http://arxiv.org/abs/', 'https://arxiv.org/pdf/', 'http://arxiv.org/pdf/', 'arxiv.org/abs/', 'arXiv:', 'arxiv:']
const MODERN = /^\p{Nd}{4}\.\p{Nd}{4,5}(v\p{Nd}+)?$/u
const LEGACY = /^[a-z-]+(\.[A-Z]{2})?\/\p{Nd}{7}(v\p{Nd}+)?$/u

/** `normalizeArxiv`: «arXiv:2403.18293v1», its URLs and bare IDs as
 *  `2403.18293v1`; old-style IDs (`cs/0501001`) kept. */
export function normalizeArxiv(raw: string): string | undefined {
  let value = trimWhitespaceAndNewlines(raw)
  for (const prefix of ARXIV_PREFIXES) {
    if (value.toLowerCase().startsWith(prefix.toLowerCase())) value = value.slice(prefix.length)
  }
  if (value.toLowerCase().endsWith('.pdf')) value = value.slice(0, -4)
  value = trimWhitespace(value)
  if (!value) return undefined
  return MODERN.test(value) || LEGACY.test(value) ? value : undefined
}

/** `arxivBaseID`: the ID without its version. */
export function arxivBaseID(arxiv: string | undefined): string | undefined {
  if (arxiv === undefined) return undefined
  const match = /v[0-9]+$/.exec(arxiv)
  return match ? arxiv.slice(0, match.index) : arxiv
}

/** `IdentifierScanner.scan`. */
export function scanIdentifiers(text: string): Identifiers {
  return identifiers({ doi: dois(text)[0], arxiv: arxivIDs(text)[0], pmid: pubmedID(text) })
}

export function dois(text: string): string[] {
  const found: string[] = []
  const seen = new Set<string>()
  for (const match of text.matchAll(/10\.\p{Nd}{4,9}\/[-._;()/:A-Za-z0-9]+/gu)) {
    const normalised = normalizeDOI(match[0])
    if (!normalised || seen.has(normalised)) continue
    seen.add(normalised)
    found.push(normalised)
  }
  return found
}

export function arxivIDs(text: string): string[] {
  const found: string[] = []
  const seen = new Set<string>()
  const take = (value: string) => {
    const normalised = normalizeArxiv(value)
    if (normalised && !seen.has(normalised)) {
      seen.add(normalised)
      found.push(normalised)
    }
  }
  for (const match of text.matchAll(/arxiv[:\p{White_Space}]\p{White_Space}*(\p{Nd}{4}\.\p{Nd}{4,5}(?:v\p{Nd}+)?)/giu)) take(match[1])
  for (const match of text.matchAll(/arxiv[:\p{White_Space}]\p{White_Space}*([a-z-]+(?:\.[A-Z]{2})?\/\p{Nd}{7}(?:v\p{Nd}+)?)/giu)) take(match[1])
  for (const match of text.matchAll(/arxiv\.org\/(?:abs|pdf)\/([^\p{White_Space},)]+)/gu)) take(match[1])
  return found
}

export function pubmedID(text: string): string | undefined {
  return /pmid[:\p{White_Space}]\p{White_Space}*(\p{Nd}{6,9})/iu.exec(text)?.[1]
}

/** An arXiv ID from a downloaded file's name: `2403.18293v1.pdf`. */
export function arxivIDFromFileName(name: string): string | undefined {
  const dot = name.lastIndexOf('.')
  // `deletingPathExtension`: an extension only after the last slash, and
  // never the whole name.
  const stem = dot > 0 && !name.slice(dot).includes('/') ? name.slice(0, dot) : name
  const match = /^(\p{Nd}{4}\.\p{Nd}{4,5}(?:v\p{Nd}+)?)$/u.exec(stem)
  return match ? normalizeArxiv(match[1]) : undefined
}

export { swiftInt }
