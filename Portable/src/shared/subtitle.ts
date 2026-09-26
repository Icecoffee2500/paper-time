/**
 * The line under a title in the paper list — the Mac's `SubtitleField` and
 * `PaperRow.subtitle(_:fields:)`.
 *
 * Which fields, and in what order, is the reader's choice (Settings → Reading
 * → Under the Title), kept as the same comma-separated words the Mac keeps:
 * the order they were switched on in is the order they are read in.
 */
import { L } from './lang.js'
import type { PaperMeta } from './model.js'

export type SubtitleField = 'authors' | 'year' | 'venue' | 'citationKey' | 'fileName' | 'pageCount' | 'addedDate'

export const SUBTITLE_FIELDS: SubtitleField[] = ['authors', 'year', 'venue', 'citationKey', 'fileName', 'pageCount', 'addedDate']

export const DEFAULT_SUBTITLE = 'authors,year,venue'

export function subtitleName(field: SubtitleField): string {
  switch (field) {
    case 'authors': return L('저자', 'Authors')
    case 'year': return L('해', 'Year')
    case 'venue': return L('학술지·학회', 'Venue')
    case 'citationKey': return L('인용 키', 'Citation Key')
    case 'fileName': return L('파일 이름', 'File Name')
    case 'pageCount': return L('쪽 수', 'Pages')
    case 'addedDate': return L('더한 날', 'Date Added')
  }
}

/** The stored words, in order, without anything unknown; nothing known means
 *  the three the Mac starts with. */
export function parseSubtitle(raw: string | undefined): SubtitleField[] {
  const fields = (raw ?? '').split(',')
    .map((word) => word.trim())
    .filter((word): word is SubtitleField => (SUBTITLE_FIELDS as string[]).includes(word))
  const unique = [...new Set(fields)]
  return unique.length > 0 ? unique : ['authors', 'year', 'venue']
}

export function encodeSubtitle(fields: SubtitleField[]): string {
  return fields.join(',')
}

/** Switches one field, the Mac's way: on goes to the end, off leaves the rest in order. */
export function toggledSubtitle(fields: SubtitleField[], field: SubtitleField): SubtitleField[] {
  const rest = fields.filter((one) => one !== field)
  return fields.includes(field) ? rest : [...rest, field]
}

function value(field: SubtitleField, meta: PaperMeta): string | null {
  switch (field) {
    case 'authors': return meta.displayAuthors || null
    case 'year': return meta.year ? String(meta.year) : null
    case 'venue': return meta.venue || null
    case 'citationKey': return meta.bibKey || null
    case 'fileName': return meta.file.originalName || null
    case 'pageCount': return meta.file.pageCount > 0 ? L(`${meta.file.pageCount}쪽`, `${meta.file.pageCount} pages`) : null
    case 'addedDate': return meta.addedAt.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' })
  }
}

/**
 * The line itself. A paper's fields are a bibliography's; a manual has none
 * of them and its row came out bare, so a book, a lecture or a document with
 * nothing to say there says where it came from, its year and its length.
 */
export function subtitleLine(meta: PaperMeta, fields: SubtitleField[]): string {
  const line = fields.map((field) => value(field, meta)).filter(Boolean).join(' · ')
  if (line || meta.effectiveKind === 'paper') return line
  const pages = meta.file.pageCount
  return [
    meta.csl.publisher,
    meta.year ? String(meta.year) : null,
    pages > 0 ? L(`${pages}쪽`, `${pages} pages`) : null,
  ].filter(Boolean).join(' · ')
}
