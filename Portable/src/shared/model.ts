/**
 * The library's records, as they sit on disk.
 *
 * Every record keeps the object it was decoded from and writes back over a
 * copy of it. That is deliberate: a Mac running a later version may have put
 * fields in `meta.json` this build has never heard of, and a reader that
 * dropped them on the next save would quietly destroy the user's data the
 * first time they opened a paper on Windows. Known fields are typed; unknown
 * ones are carried.
 */
import { dateFromISO, isoTimestamp, makeUUID } from './coding.js'

export type RawRecord = Record<string, unknown>

export const SCHEMA = 1

// MARK: - CSL

/** A CSL-JSON item. Left as a bag of fields, with accessors for the ones the
 *  interface shows — the Swift side has thirty typed properties and a coding
 *  key for each, but nothing here needs to reason about `event-place`. */
export interface CSLName {
  family?: string
  given?: string
  literal?: string
  suffix?: string
  'dropping-particle'?: string
  'non-dropping-particle'?: string
}

export interface CSLDate {
  'date-parts'?: number[][]
  raw?: string
  literal?: string
}

export interface CSLItem extends RawRecord {
  id?: string
  type?: string
  title?: string
  subtitle?: string
  'title-short'?: string
  author?: CSLName[]
  editor?: CSLName[]
  issued?: CSLDate
  'container-title'?: string
  'container-title-short'?: string
  publisher?: string
  volume?: string
  issue?: string
  page?: string
  DOI?: string
  URL?: string
  ISSN?: string
  ISBN?: string
  abstract?: string
  note?: string
  language?: string
  genre?: string
}

export function cslYear(item: CSLItem | undefined): number | undefined {
  const parts = item?.issued?.['date-parts']
  const first = parts?.[0]?.[0]
  if (typeof first === 'number') return first
  const raw = item?.issued?.raw ?? item?.issued?.literal
  const match = raw?.match(/\d{4}/)
  return match ? Number(match[0]) : undefined
}

/** The family name a list sorts and displays by, the way `CSLName` does it. */
export function surname(name: CSLName): string | undefined {
  if (name.family && name.family.trim()) {
    const particle = name['non-dropping-particle']
    return particle ? `${particle} ${name.family}` : name.family
  }
  if (name.literal && name.literal.trim()) return name.literal
  return undefined
}

export function fullName(name: CSLName): string {
  if (name.literal && name.literal.trim()) return name.literal
  return [name.given, surname(name)].filter(Boolean).join(' ').trim()
}

export function cslFullTitle(item: CSLItem | undefined): string | undefined {
  if (!item?.title) return undefined
  return item.subtitle ? `${item.title}: ${item.subtitle}` : item.title
}

// MARK: - meta.json

export type Confidence = 'unparsed' | 'low' | 'medium' | 'high' | 'verified' | 'manual' | 'needsReview'

export interface FileInfo {
  relativePath: string
  byteSize: number
  pageCount: number
  importDigest: string
  originalName: string
}

/** What a PDF in the library is — the port of `DocumentKind.swift`.
 *  Declared here as well as in `documentKind.ts` because the record type came
 *  first; the two are one type, and `documentKind.ts` re-exports this one so
 *  they cannot drift apart. */
export type DocumentKind = 'paper' | 'book' | 'lecture' | 'document'

export class PaperMeta {
  raw: RawRecord
  id: string
  csl: CSLItem
  bibKey: string
  confidence: Confidence
  /** The answer to "what is this?", absent until somebody gives one. */
  kind?: DocumentKind
  /** What the app thought when the file arrived. */
  guessedKind?: DocumentKind
  file: FileInfo
  tagIDs: string[]
  collectionIDs: string[]
  parentID?: string
  addedAt: Date
  updatedAt: Date
  updatedBy: string

  constructor(raw: RawRecord) {
    this.raw = raw
    this.id = String(raw.id ?? makeUUID())
    this.csl = (raw.csl as CSLItem) ?? {}
    this.bibKey = String(raw.bibKey ?? '')
    this.confidence = (raw.confidence as Confidence) ?? 'unparsed'
    this.kind = raw.kind ? (String(raw.kind) as DocumentKind) : undefined
    this.guessedKind = raw.guessedKind ? (String(raw.guessedKind) as DocumentKind) : undefined
    const file = (raw.file as RawRecord) ?? {}
    this.file = {
      // A library written before the flat layout stored the file name under
      // `name`, inside a per-paper folder. The Swift side still reads that.
      relativePath: String(file.relativePath ?? file.name ?? ''),
      byteSize: Number(file.byteSize ?? 0),
      pageCount: Number(file.pageCount ?? 0),
      importDigest: String(file.importDigest ?? ''),
      originalName: String(file.originalName ?? ''),
    }
    this.tagIDs = (raw.tagIDs as string[]) ?? []
    this.collectionIDs = (raw.collectionIDs as string[]) ?? []
    this.parentID = raw.parentID ? String(raw.parentID) : undefined
    this.addedAt = raw.addedAt ? dateFromISO(String(raw.addedAt)) : new Date()
    this.updatedAt = raw.updatedAt ? dateFromISO(String(raw.updatedAt)) : new Date()
    this.updatedBy = String(raw.updatedBy ?? '')
  }

  static make(id: string, file: FileInfo, device: string): PaperMeta {
    const now = new Date()
    return new PaperMeta({
      schema: SCHEMA,
      id,
      csl: { id: '', type: 'other', author: [], editor: [] },
      bibKey: '',
      confidence: 'unparsed',
      identifiers: {},
      // `fetchedAt` is not optional on the Mac: a record without it fails to
      // decode, and the Mac drops the paper rather than showing it. Written
      // the same way the Mac writes it.
      provenance: { source: 'heuristic', fetchedAt: isoTimestamp(now) },
      candidates: [],
      file: { ...file },
      tagIDs: [],
      collectionIDs: [],
      addedAt: isoTimestamp(now),
      updatedAt: isoTimestamp(now),
      updatedBy: device,
    })
  }

  /** The original object with the fields this build owns written over it. */
  encode(): RawRecord {
    return {
      ...this.raw,
      schema: this.raw.schema ?? SCHEMA,
      id: this.id,
      csl: this.csl,
      bibKey: this.bibKey,
      confidence: this.confidence,
      // Written only when there is one: a record this build merely read is
      // written back byte for byte.
      kind: this.kind,
      guessedKind: this.guessedKind,
      file: { ...(this.raw.file as RawRecord), ...this.file, name: undefined },
      tagIDs: this.tagIDs,
      collectionIDs: this.collectionIDs,
      parentID: this.parentID,
      addedAt: isoTimestamp(this.addedAt),
      updatedAt: isoTimestamp(this.updatedAt),
      updatedBy: this.updatedBy,
    }
  }

  /** What the app treats this as: the answer, then the guess, then a paper. */
  get effectiveKind(): DocumentKind {
    return this.kind ?? this.guessedKind ?? 'paper'
  }

  get kindIsUnanswered(): boolean {
    return this.kind === undefined
  }

  get displayTitle(): string {
    const title = cslFullTitle(this.csl)
    if (title && title.trim()) return title
    if (this.file.originalName) return this.file.originalName.replace(/\.[^./\\]+$/, '')
    return 'Untitled'
  }

  get displayAuthors(): string {
    const names = (this.csl.author ?? []).map(surname).filter(Boolean) as string[]
    if (names.length === 0) return ''
    if (names.length === 1) return names[0]
    if (names.length === 2) return `${names[0]} & ${names[1]}`
    return `${names[0]} et al.`
  }

  get year(): number | undefined {
    return cslYear(this.csl)
  }

  get venue(): string | undefined {
    return this.csl['container-title']
  }
}

// MARK: - state.json

export type ReadingStatus = 'unread' | 'reading' | 'read'

export class PaperState {
  raw: RawRecord
  readingStatus: ReadingStatus
  isFavorite: boolean
  rating?: number
  lastPageIndex: number
  lastPageOffset: number
  summaryNote: string
  lastOpenedAt?: Date
  updatedAt: Date
  updatedBy: string

  constructor(raw: RawRecord = {}) {
    this.raw = raw
    this.readingStatus = (raw.readingStatus as ReadingStatus) ?? 'unread'
    this.isFavorite = Boolean(raw.isFavorite ?? false)
    this.rating = raw.rating === undefined || raw.rating === null ? undefined : Number(raw.rating)
    this.lastPageIndex = Number(raw.lastPageIndex ?? 0)
    this.lastPageOffset = Number(raw.lastPageOffset ?? 0)
    this.summaryNote = String(raw.summaryNote ?? '')
    this.lastOpenedAt = raw.lastOpenedAt ? dateFromISO(String(raw.lastOpenedAt)) : undefined
    this.updatedAt = raw.updatedAt ? dateFromISO(String(raw.updatedAt)) : new Date()
    this.updatedBy = String(raw.updatedBy ?? '')
  }

  encode(): RawRecord {
    return {
      ...this.raw,
      schema: this.raw.schema ?? SCHEMA,
      readingStatus: this.readingStatus,
      isFavorite: this.isFavorite,
      rating: this.rating,
      lastPageIndex: this.lastPageIndex,
      lastPageOffset: this.lastPageOffset,
      summaryNote: this.summaryNote,
      lastOpenedAt: this.lastOpenedAt ? isoTimestamp(this.lastOpenedAt) : undefined,
      updatedAt: isoTimestamp(this.updatedAt),
      updatedBy: this.updatedBy,
    }
  }

  /** Newest write wins, whole record — the rule `PaperState.resolve` uses. */
  static resolve(local: PaperState, remote: PaperState): PaperState {
    return local.updatedAt >= remote.updatedAt ? local : remote
  }
}

// MARK: - library.json and collections.json

export type TagColor =
  | 'red' | 'orange' | 'yellow' | 'green' | 'mint'
  | 'teal' | 'blue' | 'indigo' | 'purple' | 'pink' | 'gray'

export interface Tag {
  id: string
  name: string
  color: TagColor
}

export interface SmartCondition {
  field: 'title' | 'author' | 'year' | 'venue' | 'tag' | 'readingStatus' | 'confidence' | 'dateAdded'
  comparison: 'contains' | 'equals' | 'notEquals' | 'greaterThan' | 'lessThan'
  value: string
}

export interface SmartRule {
  matchAll: boolean
  conditions: SmartCondition[]
}

export interface Collection {
  id: string
  name: string
  parentID?: string
  symbolName: string
  rule?: SmartRule
  sortIndex: number
}

export interface LibraryManifest extends RawRecord {
  schema: number
  libraryID: string
  displayName: string
  createdAt: string
  tags: Tag[]
}

export function newManifest(displayName = 'Paper Time'): LibraryManifest {
  return {
    schema: SCHEMA,
    libraryID: makeUUID(),
    displayName,
    createdAt: isoTimestamp(new Date()),
    tags: [],
  }
}

export interface CollectionSet extends RawRecord {
  schema: number
  collections: Collection[]
  updatedAt: string
  updatedBy: string
}

export function newCollectionSet(device: string): CollectionSet {
  return { schema: SCHEMA, collections: [], updatedAt: isoTimestamp(new Date()), updatedBy: device }
}
