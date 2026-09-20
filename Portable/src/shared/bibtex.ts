/**
 * Exporting a library as `.bib`.
 *
 * Ported from `BibTeXWriter.swift`, field for field, because an export is the
 * one thing in this app that leaves it: a citation key that came out one way
 * on a Mac and another on Windows would show up as a changed line in a
 * co-author's paper. The escaping table is not even ported — it is generated
 * from the Swift source (see `tools/generate-latex-table.mjs`).
 */
import { escapeLaTeX } from './latexTable.js'
import { cslYear, fullName, surname, type CSLItem, type CSLName, type PaperMeta } from './model.js'

export type EntryType =
  | 'article' | 'inproceedings' | 'incollection' | 'inbook' | 'book'
  | 'phdthesis' | 'mastersthesis' | 'techreport' | 'online' | 'misc'
  | 'unpublished'

/**
 * The order fields are written in.
 *
 * Fixed rather than alphabetical so that re-exporting a library produces a
 * minimal diff, and so a person reading the file sees the identifying fields
 * first.
 */
const FIELD_ORDER = [
  'author', 'editor', 'title', 'subtitle', 'booktitle', 'journal',
  'series', 'year', 'month', 'volume', 'number', 'pages', 'publisher',
  'school', 'institution', 'organization', 'address', 'edition',
  'eprint', 'archivePrefix', 'primaryClass', 'doi', 'issn', 'isbn',
  'url', 'urldate', 'language', 'note', 'keywords', 'abstract', 'file',
]

export interface ExportOptions {
  /** Brace words whose capitals a style would otherwise flatten. */
  protectCase: boolean
  includeAbstract: boolean
  includeFile: boolean
}

export const DEFAULT_EXPORT: ExportOptions = {
  protectCase: true,
  includeAbstract: false,
  includeFile: false,
}

function entryType(item: CSLItem): EntryType {
  const hasContainer = Boolean(item['container-title'])
  switch (item.type) {
    case 'article-journal': return 'article'
    case 'paper-conference': return 'inproceedings'
    case 'book': return 'book'
    case 'chapter': return hasContainer ? 'incollection' : 'inbook'
    case 'thesis':
      return (item.genre ?? '').toLowerCase().includes('master') ? 'mastersthesis' : 'phdthesis'
    case 'report': return 'techreport'
    case 'webpage': return 'online'
    default: return 'misc'
  }
}

/**
 * A list of names as BibTeX reads it: `Family, Given and Family, Given`.
 *
 * An institution is wrapped in braces so BibTeX does not split it into a
 * first and last name — "Association for Computing Machinery" would otherwise
 * be cited as "Machinery, A. f. C.".
 */
function nameList(names: CSLName[] | undefined): string | undefined {
  const rendered = (names ?? []).map((name) => {
    if (name.literal && name.literal.trim()) return `{${escapeLaTeX(name.literal)}}`
    const family = surname(name)
    if (!family) return null
    const escapedFamily = escapeLaTeX(family)
    if (!name.given) return escapedFamily
    if (name.suffix) {
      return `${escapedFamily}, ${escapeLaTeX(name.suffix)}, ${escapeLaTeX(name.given)}`
    }
    return `${escapedFamily}, ${escapeLaTeX(name.given)}`
  }).filter(Boolean)
  return rendered.length > 0 ? rendered.join(' and ') : undefined
}

const collapse = (text: string) => text.replace(/\s+/g, ' ').trim()

function titleValue(raw: string | undefined, options: ExportOptions): string | undefined {
  if (!raw || !raw.trim()) return undefined
  const escaped = escapeLaTeX(collapse(raw))
  return options.protectCase ? protectTitle(escaped) : escaped
}

/** True when the word carries capitalisation a style would destroy. */
export function needsProtection(word: string): boolean {
  for (const part of word.split('-')) {
    const characters = [...part]
    if (characters.length === 0) continue
    // Uppercase anywhere but the first position means BiSeNet, GANs,
    // ResNet50, or an all-caps acronym.
    if (characters.slice(1).some(isUpper)) return true
    // A leading digit next to a capital: "3D", "2D".
    if (characters.length > 1 && isDigit(characters[0]) && characters.slice(1).some(isUpper)) {
      return true
    }
  }
  return false
}

const isUpper = (c: string) => c !== c.toLowerCase() && c === c.toUpperCase()
const isDigit = (c: string) => c >= '0' && c <= '9'
const isLetterOrNumber = (c: string) => /\p{L}|\p{N}/u.test(c)

export function protectTitle(escaped: string): string {
  return escaped.split(' ').map(protectToken).join(' ')
}

function protectToken(token: string): string {
  if (!token) return token
  // Leave anything that already contains markup or protection untouched.
  if (token.includes('\\') || token.includes('{') || token.includes('$')) return token
  const characters = [...token]
  let start = 0
  while (start < characters.length && !isLetterOrNumber(characters[start])) start += 1
  let end = characters.length
  while (end > start && !isLetterOrNumber(characters[end - 1])) end -= 1
  if (start >= end) return token
  const leading = characters.slice(0, start).join('')
  const core = characters.slice(start, end).join('')
  const trailing = characters.slice(end).join('')
  if (!needsProtection(core)) return token
  return `${leading}{${core}}${trailing}`
}

export interface Field {
  name: string
  value: string
}

export function entryFor(meta: PaperMeta, options: ExportOptions = DEFAULT_EXPORT): {
  type: EntryType
  key: string
  fields: Field[]
} {
  const item = meta.csl
  const type = entryType(item)
  const fields: Field[] = []
  const put = (name: string, value: string | undefined) => {
    if (!value || !value.trim()) return
    fields.push({ name, value })
  }

  put('author', nameList(item.author))
  put('editor', nameList(item.editor))
  const title = item.subtitle ? `${item.title}: ${item.subtitle}` : item.title
  put('title', titleValue(title, options))

  const container = titleValue(item['container-title'], options)
  switch (type) {
    case 'inproceedings':
    case 'incollection':
    case 'inbook':
      put('booktitle', container)
      break
    case 'article':
      put('journal', container)
      break
    default:
      if (container) put('series', container)
      break
  }

  const year = cslYear(item)
  if (year) put('year', String(year))
  const month = item.issued?.['date-parts']?.[0]?.[1]
  if (month) put('month', MONTHS[month - 1])

  put('volume', item.volume)
  put('number', item.issue)
  put('pages', item.page?.replace(/[–—]/g, '--'))
  put('publisher', escapeIf(item.publisher))
  if (type === 'phdthesis' || type === 'mastersthesis') put('school', escapeIf(item.publisher))
  if (type === 'techreport') put('institution', escapeIf(item.publisher))
  put('doi', item.DOI)
  put('issn', item.ISSN)
  put('isbn', item.ISBN)
  put('url', item.URL)
  put('language', item.language)
  put('note', escapeIf(item.note))
  if (options.includeAbstract) put('abstract', escapeIf(item.abstract))
  if (options.includeFile) put('file', meta.file.relativePath)

  fields.sort((a, b) => order(a.name) - order(b.name))
  return { type, key: meta.bibKey || fallbackKey(meta), fields }
}

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec']

function escapeIf(raw: string | undefined): string | undefined {
  return raw && raw.trim() ? escapeLaTeX(collapse(raw)) : undefined
}

function order(name: string): number {
  const index = FIELD_ORDER.indexOf(name)
  return index === -1 ? FIELD_ORDER.length : index
}

/** A key for a record that never got one: surname, year, first title word. */
function fallbackKey(meta: PaperMeta): string {
  const first = (meta.csl.author ?? [])[0]
  const family = (first ? surname(first) : '') ?? ''
  const year = cslYear(meta.csl) ?? ''
  const word = (meta.csl.title ?? '').split(/\s+/).find((w) => w.length > 3) ?? ''
  const slug = (text: string) =>
    text.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9]/g, '').toLowerCase()
  return `${slug(family)}${year}${slug(word)}` || meta.id.slice(0, 8).toLowerCase()
}

/**
 * One entry, laid out as `BibTeXWriter.write` lays it out: the field names
 * padded to a common width, and no comma after the last one — which some
 * parsers accept and some do not, so the Swift side leaves it off and this
 * does too.
 */
export function formatEntry(entry: ReturnType<typeof entryFor>): string {
  if (entry.fields.length === 0) return `@${entry.type}{${entry.key}}\n`
  const width = Math.max(...entry.fields.map((field) => field.name.length))
  const lines = [`@${entry.type}{${entry.key},`]
  entry.fields.forEach((field, index) => {
    const padding = ' '.repeat(width - field.name.length)
    const comma = index === entry.fields.length - 1 ? '' : ','
    lines.push(`  ${field.name}${padding} = {${field.value}}${comma}`)
  })
  lines.push('}')
  return `${lines.join('\n')}\n`
}

export function formatBibliography(
  metas: PaperMeta[],
  options: ExportOptions = DEFAULT_EXPORT,
  generatedAt = new Date(),
): string {
  const stamp = generatedAt.toISOString().slice(0, 10)
  const header =
    `% Exported by Paper Time on ${stamp}\n` +
    `% ${metas.length} reference${metas.length === 1 ? '' : 's'}\n\n`
  return header + metas.map((meta) => formatEntry(entryFor(meta, options))).join('\n')
}

export { fullName }
