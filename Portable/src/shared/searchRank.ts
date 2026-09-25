/**
 * What the search palette offers for a query, and in what order — the port
 * of the Mac's `SearchIndex` and of the `LibraryModel.matches` it counts with.
 *
 * Deliberately simple and title-first, as on the Mac: Spotlight reads as
 * predictable because a prefix always beats a fuzzy match, not because the
 * ranking is clever. The ladder is the Mac's to the digit — a title that
 * starts with the query 1.0, a word of it that does 0.9, the query anywhere
 * in it 0.75, a Jaro–Winkler above 0.82 for a typo, 0.6 for the author, the
 * venue, the year, the key or the file, and up to 0.15 for having been open
 * lately — because two desktops that order the same library differently for
 * the same letters are two apps.
 *
 * Everything that can be folded ahead of the typing is folded once, when the
 * palette opens (`prepare`), and every keystroke only compares. Folding the
 * library on every letter is what made the Mac's palette slow as a library
 * grew: measured there, 6.2 ms a keystroke at 63 papers, 62.6 ms at 600.
 */
import { foldTitle, graphemes } from './textFold.js'

// MARK: - Similarity

/**
 * Jaro–Winkler, in 0…1 — `StringSimilarity.jaroWinkler`, on graphemes as
 * Swift counts them.
 *
 * Chosen over edit distance because it rewards a shared prefix, and the
 * difference between a real match and a wrong one is almost always in the
 * tail of the title.
 */
export function jaroWinkler(lhs: string | string[], rhs: string | string[]): number {
  const left = typeof lhs === 'string' ? graphemes(lhs) : lhs
  const right = typeof rhs === 'string' ? graphemes(rhs) : rhs
  const similarity = jaro(left, right)
  if (!(similarity > 0.7)) return similarity
  let prefix = 0
  for (let index = 0; index < Math.min(4, left.length, right.length); index += 1) {
    if (left[index] === right[index]) prefix += 1
    else break
  }
  return similarity + prefix * 0.1 * (1 - similarity)
}

function jaro(left: string[], right: string[]): number {
  if (left.length === 0 && right.length === 0) return 1
  if (left.length === 0 || right.length === 0) return 0
  const window = Math.floor(Math.max(left.length, right.length) / 2) - 1
  if (window < 0) return left[0] === right[0] ? 1 : 0

  const leftMatches = new Array<boolean>(left.length).fill(false)
  const rightMatches = new Array<boolean>(right.length).fill(false)
  let matches = 0
  for (let index = 0; index < left.length; index += 1) {
    const start = Math.max(0, index - window)
    const end = Math.min(index + window + 1, right.length)
    for (let candidate = start; candidate < end; candidate += 1) {
      if (rightMatches[candidate]) continue
      if (left[index] === right[candidate]) {
        leftMatches[index] = true
        rightMatches[candidate] = true
        matches += 1
        break
      }
    }
  }
  if (matches === 0) return 0

  let transpositions = 0
  let rightIndex = 0
  for (let index = 0; index < left.length; index += 1) {
    if (!leftMatches[index]) continue
    while (!rightMatches[rightIndex]) rightIndex += 1
    if (left[index] !== right[rightIndex]) transpositions += 1
    rightIndex += 1
  }
  // Swift divides the integers first; so does this.
  return (matches / left.length + matches / right.length
    + (matches - Math.floor(transpositions / 2)) / matches) / 3
}

// MARK: - The ladder

const FUZZY_THRESHOLD = 0.82

/** A field folded for matching, with the graphemes the fuzzy match walks. */
export interface FoldedField {
  text: string
  /** Worked out the first time a query needs the fuzzy match, then kept. */
  graphemes?: string[]
}

export function foldedField(raw: string): FoldedField {
  return { text: foldTitle(raw) }
}

/**
 * Prefix match on the whole string, then prefix match on any word, then
 * substring anywhere, then a fuzzy fallback for typos.
 */
export function matchScore(query: FoldedField, field: FoldedField): number | null {
  const text = field.text
  if (text.length === 0) return null
  const needle = query.text
  if (text.startsWith(needle)) return 1
  if (text.split(' ').some((word) => word.length > 0 && word.startsWith(needle))) return 0.9
  if (text.includes(needle)) return 0.75
  query.graphemes ??= graphemes(needle)
  field.graphemes ??= graphemes(text)
  const similarity = jaroWinkler(query.graphemes, field.graphemes)
  return similarity > FUZZY_THRESHOLD ? similarity : null
}

// MARK: - What is searched

/** The parts of a CSL name the palette reads. */
export interface NameParts {
  family?: string
  given?: string
  literal?: string
  suffix?: string
  'non-dropping-particle'?: string
}

/** "Given Family" for display — `CSLName.displayName`. */
export function displayName(name: NameParts): string {
  if (name.literal) return name.literal
  const tail = [name['non-dropping-particle'], name.family].filter((part) => part).join(' ')
  const head = name.given ? name.given : null
  const core = [head, tail || null].filter((part): part is string => part !== null).join(' ')
  return name.suffix ? `${core}, ${name.suffix}` : core
}

/** A paper as the palette needs it. */
export interface SearchablePaper {
  id: string
  title: string
  authors: NameParts[]
  /** "Kim et al." — what the subtitle shows. */
  displayAuthors: string
  venue?: string
  year?: number
  bibKey: string
  originalName: string
  parentID?: string
  lastOpenedAt?: Date
}

/**
 * Everything a person might type when they remember a paper but not its
 * exact title — `LibraryModel.matches`. Authors go in both orders because
 * "LeCun Yann" is how a citation prints the name the reader thinks of as
 * "Yann LeCun".
 */
export function paperHaystack(paper: SearchablePaper): string {
  const haystack = [
    paper.title,
    paper.venue ?? '',
    paper.year === undefined ? '' : String(paper.year),
    paper.bibKey,
    paper.originalName,
  ]
  for (const author of paper.authors) {
    haystack.push(displayName(author))
    haystack.push(`${author.family ?? ''} ${author.given ?? ''}`)
  }
  return foldTitle(haystack.join(' '))
}

export interface SearchableNote {
  /** The paper the note is about — Portable's notes are the papers' own. */
  paperID: string
  title: string
  preview: string
  /** Which paper, said under the note's own title. */
  paperTitle: string
}

export interface SearchableShelf {
  id: string
  name: string
  smart?: boolean
}

export type ActionName = 'addPDFs' | 'exportBibTeX' | 'refresh' | 'settings'

export interface SearchableAction {
  name: ActionName
  title: string
}

/** The palette's words, in whichever language it is speaking. */
export interface RankWords {
  showAll: (query: string) => string
  paperCount: (count: number) => string
  note: string
  collection: string
  smartCollection: string
  tag: string
  action: string
}

export type ResultKind =
  | { type: 'showAll'; query: string }
  | { type: 'paper'; id: string }
  | { type: 'note'; paperID: string }
  | { type: 'collection'; id: string }
  | { type: 'tag'; id: string }
  | { type: 'action'; name: ActionName }

export interface RankedResult {
  kind: ResultKind
  title: string
  subtitle: string
  score: number
}

// MARK: - Folded once

interface PreparedPaper {
  paper: SearchablePaper
  title: FoldedField
  subtitle: string
  others: string
  haystack: string
}

/** The library folded for searching, once per palette open. */
export interface Prepared {
  papers: PreparedPaper[]
  notes: { note: SearchableNote; field: FoldedField }[]
  collections: { shelf: SearchableShelf; field: FoldedField }[]
  tags: { shelf: SearchableShelf; field: FoldedField }[]
  actions: { action: SearchableAction; field: FoldedField }[]
}

export function prepare(input: {
  papers: SearchablePaper[]
  notes: SearchableNote[]
  collections: SearchableShelf[]
  tags: SearchableShelf[]
  actions: SearchableAction[]
}): Prepared {
  return {
    papers: input.papers.map((paper) => ({
      paper,
      title: foldedField(paper.title),
      subtitle: subtitleOf(paper),
      // The fields a person types when they remember the paper and not its
      // title — the authors, the venue, the year, the key, the file.
      others: foldTitle([
        paper.authors.map(displayName).join(' '),
        paper.venue ?? '',
        paper.year === undefined ? '' : String(paper.year),
        paper.bibKey,
        paper.originalName,
      ].join(' ')),
      haystack: paperHaystack(paper),
    })),
    notes: input.notes.map((note) => ({
      note,
      field: foldedField(`${note.title} ${[...note.preview].slice(0, 200).join('')}`),
    })),
    collections: input.collections.map((shelf) => ({ shelf, field: foldedField(shelf.name) })),
    tags: input.tags.map((shelf) => ({ shelf, field: foldedField(shelf.name) })),
    actions: input.actions.map((action) => ({ action, field: foldedField(action.title) })),
  }
}

function subtitleOf(paper: SearchablePaper): string {
  const parts: string[] = []
  if (paper.displayAuthors) parts.push(paper.displayAuthors)
  if (paper.year !== undefined) parts.push(String(paper.year))
  if (paper.venue) parts.push(paper.venue)
  return parts.join(' · ')
}

// MARK: - Ranking

const collator = new Intl.Collator(undefined, { sensitivity: 'accent' })

/**
 * The results for one query, best first, at most twenty — `SearchIndex.results`.
 */
export function rank(query: string, prepared: Prepared, words: RankWords, now = Date.now()): RankedResult[] {
  const trimmed = query.trim()
  if (!trimmed) return []
  const folded: FoldedField = { text: foldTitle(trimmed) }
  if (!folded.text) return []
  const results: RankedResult[] = []

  const matched = prepared.papers.filter((entry) =>
    !entry.paper.parentID && entry.haystack.includes(folded.text)).length
  if (matched > 1) {
    // Searching for an author is searching for a body of work, not for one
    // paper. This row is what turns a lookup into a place.
    results.push({
      kind: { type: 'showAll', query: trimmed },
      title: words.showAll(trimmed),
      subtitle: words.paperCount(matched),
      score: 2,
    })
  }

  for (const entry of prepared.papers) {
    const score = paperScore(folded, entry)
    if (score === null) continue
    // The paper you had open this morning comes before the one you read in
    // March: the same title match, and recency decides.
    const opened = entry.paper.lastOpenedAt?.getTime()
    const recency = opened === undefined ? 0 : Math.max(0, 0.15 - (now - opened) / (30 * 86_400_000) * 0.15)
    results.push({
      kind: { type: 'paper', id: entry.paper.id },
      title: entry.paper.title,
      subtitle: entry.subtitle,
      score: score + recency,
    })
  }

  for (const { note, field } of prepared.notes) {
    const score = matchScore(folded, field)
    if (score === null) continue
    results.push({
      kind: { type: 'note', paperID: note.paperID },
      title: note.title,
      subtitle: note.paperTitle ? `${words.note} · ${note.paperTitle}` : words.note,
      score: score - 0.05,
    })
  }

  for (const { shelf, field } of prepared.collections) {
    const score = matchScore(folded, field)
    if (score === null) continue
    results.push({
      kind: { type: 'collection', id: shelf.id },
      title: shelf.name,
      subtitle: shelf.smart ? words.smartCollection : words.collection,
      score,
    })
  }

  for (const { shelf, field } of prepared.tags) {
    const score = matchScore(folded, field)
    if (score === null) continue
    results.push({ kind: { type: 'tag', id: shelf.id }, title: shelf.name, subtitle: words.tag, score })
  }

  for (const { action, field } of prepared.actions) {
    const score = matchScore(folded, field)
    if (score === null) continue
    results.push({ kind: { type: 'action', name: action.name }, title: action.title, subtitle: words.action, score })
  }

  results.sort((a, b) => (a.score !== b.score ? b.score - a.score : collator.compare(a.title, b.title)))
  return results.slice(0, 20)
}

/**
 * A paper matches on its title first; failing that, on the fields a person
 * types when they remember the paper but not its exact title.
 */
function paperScore(query: FoldedField, entry: PreparedPaper): number | null {
  const title = matchScore(query, entry.title)
  const subtitle = entry.others && entry.others.includes(query.text) ? 0.6 : null
  if (title !== null && subtitle !== null) return Math.max(title, subtitle)
  return title ?? subtitle
}

/** What a summary note is called in a result: its first line, as the Mac
 *  names a note that has no title of its own. */
export function noteTitle(text: string): string {
  const line = text.split('\n').map((one) => one.replace(/^[#>*\-\s]+/, '').trim()).find(Boolean) ?? ''
  return [...line].slice(0, 60).join('').trim()
}

/** The note as a line of text, for matching and for the row under it. */
export function notePreview(text: string): string {
  return text.split(/\s+/).filter(Boolean).join(' ')
}
