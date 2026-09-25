/**
 * Search Everything — the palette, the port of the Mac's `SearchPalette`.
 *
 * One field for everything the library holds: papers by title, author, venue,
 * year, key or file; the notes written about them; collections, tags and the
 * handful of actions; and, a moment later, the words inside the papers
 * themselves — the sentence on page nine that no title contains.
 *
 * The groups and their order are the Mac's, and so is the ranking
 * (`shared/searchRank.ts`) and the timing: the library is folded once when
 * the palette opens, every keystroke only compares, the papers' text is
 * warmed 700 ms after the palette appears rather than with it, and a query is
 * sent into the text 220 ms after the typing stops — "un", "unl", "unle" are
 * three searches of the whole library nobody asked for.
 */
import { clear, el, on } from '../dom.js'
import { iconNode } from '../icons.js'
import { L } from '../../shared/lang.js'
import { graphemes } from '../../shared/textFold.js'
import {
  noteTitle, notePreview, prepare, rank,
  type ActionName, type Prepared, type RankedResult, type RankWords,
} from '../../shared/searchRank.js'
import { searchable, store, textSources } from '../state.js'
import { passageSubtitle, searchText, warmText, type TextHit } from '../textSearch.js'
import { asTextHit, meaningFooter, meaningStatus, noteSubtitle, onMeaningStatus, searchMeaning, type MeaningHit } from '../meaningSearch.js'
import { placeKey } from '../../shared/semantic/results.js'

export interface PaletteActions {
  openPaper: (id: string) => void
  openPassage: (hit: TextHit, query: string) => void
  /** A summary note: its paper, with the Notes tab in front. */
  openNote: (paperID: string) => void
  openCollection: (id: string) => void
  openTag: (id: string) => void
  /** The search shelf, with this query — «Show All Results». */
  showAll: (query: string) => void
  perform: (action: ActionName) => void
}

/** The groups, in the order they are shown — the Mac's `ResultGroup`. */
const GROUPS = ['showAll', 'paper', 'note', 'collection', 'tag', 'action', 'passage', 'meaning'] as const
type Group = (typeof GROUPS)[number]

function groupTitle(group: Group): string {
  switch (group) {
    case 'showAll': return L('라이브러리', 'Library')
    case 'paper': return L('논문', 'Papers')
    case 'note': return L('노트', 'Notes')
    case 'collection': return L('컬렉션', 'Collections')
    case 'tag': return L('태그', 'Tags')
    case 'action': return L('동작', 'Actions')
    // Last on purpose: a title match is a surer thing than a word in the
    // middle of page nine, and these arrive a moment later anyway.
    case 'passage': return L('논문 본문', 'In the Papers')
    // After the words themselves: a passage that says the words is a surer
    // thing than one that means them, and these arrive a moment later too.
    case 'meaning': return L('뜻이 비슷한 구절', 'Similar in Meaning')
  }
}

const WORDS = (): RankWords => ({
  showAll: (query) => L(`“${query}”에 맞는 논문 모두 보기`, `Show All Results for “${query}”`),
  paperCount: (count) => L(`논문 ${count}편`, `${count} papers`),
  note: L('노트', 'Note'),
  collection: L('컬렉션', 'Collection'),
  smartCollection: L('스마트 컬렉션', 'Smart Collection'),
  tag: L('태그', 'Tag'),
  action: L('동작', 'Action'),
})

/** What this build can do from the palette. The Mac's other two — resolving
 *  metadata, importing another library — are not in this build, and a row
 *  that does nothing is worse than no row. */
const ACTIONS = (): { name: ActionName; title: string; icon: string }[] => [
  { name: 'addPDFs', title: L('PDF 더하기…', 'Add PDFs…'), icon: 'plus' },
  { name: 'exportBibTeX', title: L('BibTeX 내보내기…', 'Export BibTeX…'), icon: 'square.and.arrow.up' },
  { name: 'refresh', title: L('라이브러리 다시 읽기', 'Refresh Library'), icon: 'arrow.clockwise' },
  { name: 'settings', title: L('설정…', 'Settings…'), icon: 'gear' },
]

/** One row as the palette shows it. */
interface Row {
  group: Group
  title: string
  subtitle: string
  icon: string
  run: () => void
}

/** How many rows the palette shows before it would need a scroll bar. */
const SHOWN = 8

/** For a probe: what each query cost. */
export interface QueryTiming {
  query: string
  /** Ranking the library for this keystroke. */
  rankMs: number
  /** From sending the query into the text to its first passage. */
  firstPassageMs: number | null
  /** …and to the text search's end. */
  doneMs: number | null
  passages: number
  searched: number
}

let current: {
  close: () => void
  setQuery: (text: string) => void
  activate: (index: number) => void
  rows: () => Row[]
  rankMs: () => number
  meaningMs: () => number | null
} | null = null
export const timings: QueryTiming[] = []

export function isPaletteOpen(): boolean {
  return current !== null
}

export function closePalette() {
  current?.close()
}

export function openPalette(actions: PaletteActions, initial = '') {
  if (current) return closePalette()

  const input = el('input', {
    type: 'text',
    spellcheck: 'false',
    placeholder: L('Paper Time 찾기', 'Paper Time Search'),
    'aria-label': L('Paper Time 찾기', 'Paper Time Search'),
  }) as HTMLInputElement
  const glass = iconNode('magnifyingglass')
  const field = el('div', { class: 'palette-field' }, glass ? [glass, input] : [input])
  const list = el('div', { class: 'palette-results', role: 'listbox' })
  const box = el('div', { class: 'palette', role: 'dialog', 'aria-label': L('Paper Time 찾기', 'Paper Time Search') }, [field, list])
  const scrim = el('div', { class: 'scrim palette-scrim' })

  // Everything the library holds, folded once. The palette is about the
  // library as it was when it opened; a paper added while it is open shows up
  // the next time.
  const actionList = ACTIONS()
  const prepared: Prepared = prepare({
    papers: store.papers.map(searchable),
    notes: store.papers
      .filter((entry) => entry.state.summaryNote.trim().length > 0)
      .map((entry) => ({
        paperID: entry.id,
        title: noteTitle(entry.state.summaryNote) || L('노트', 'Note'),
        preview: notePreview(entry.state.summaryNote),
        paperTitle: entry.meta.displayTitle,
      })),
    collections: store.collections.map((one) => ({ id: one.id, name: one.name, smart: Boolean(one.rule) })),
    tags: store.tags.map((one) => ({ id: one.id, name: one.name })),
    actions: actionList.map(({ name, title }) => ({ name, title })),
  })
  const words = WORDS()

  let typed: RankedResult[] = []
  let passages: TextHit[] = []
  let meanings: MeaningHit[] = []
  let meaningTimer: ReturnType<typeof setTimeout> | null = null
  let meaningAsked = 0
  let scanning = false
  let highlighted = 0
  let stopScan: (() => void) | null = null
  let scanTimer: ReturnType<typeof setTimeout> | null = null
  let rows: Row[] = []

  const rowFor = (result: RankedResult): Row => {
    const kind = result.kind
    switch (kind.type) {
      case 'showAll':
        return { group: 'showAll', title: result.title, subtitle: result.subtitle, icon: 'line.3.horizontal.decrease.circle', run: () => actions.showAll(kind.query) }
      case 'paper':
        return { group: 'paper', title: result.title, subtitle: result.subtitle, icon: 'text.page', run: () => actions.openPaper(kind.id) }
      case 'note':
        return { group: 'note', title: result.title, subtitle: result.subtitle, icon: 'note', run: () => actions.openNote(kind.paperID) }
      case 'collection': {
        const smart = store.collections.find((one) => one.id === kind.id)?.rule
        return { group: 'collection', title: result.title, subtitle: result.subtitle, icon: smart ? 'folder.badge.gearshape' : 'folder', run: () => actions.openCollection(kind.id) }
      }
      case 'tag':
        return { group: 'tag', title: result.title, subtitle: result.subtitle, icon: 'tag', run: () => actions.openTag(kind.id) }
      case 'action': {
        const icon = actionList.find((one) => one.name === kind.name)?.icon ?? 'gear'
        return { group: 'action', title: result.title, subtitle: result.subtitle, icon, run: () => actions.perform(kind.name) }
      }
    }
  }

  const passageRow = (hit: TextHit, query: string): Row => ({
    group: 'passage',
    // The passage leads and the paper follows it: the sentence is what was
    // being looked for, and the title is how you know which paper it is in.
    title: hit.snippet,
    subtitle: passageSubtitle(hit),
    icon: 'text.magnifyingglass',
    run: () => actions.openPassage(hit, query),
  })

  /**
   * The rows, in the order they are shown and walked.
   *
   * Room is made for the words inside the papers as soon as they are being
   * looked for: eight title matches and then a scroll bar is the same as not
   * having searched the text at all. The arrows walk the rows as they are
   * shown — down goes to the row below, whichever group it is in.
   */
  /** A passage by meaning: the same row, and the reader is sent to the
   *  passage itself rather than to the words typed, which it need not say. */
  const meaningRow = (hit: MeaningHit): Row => {
    const text = asTextHit(hit)
    if (hit.note) {
      // A note's passage: the note's name and «노트», and it opens the
      // note — the paper's, with the Notes tab in front.
      const paperID = hit.note.paperID ?? hit.note.id
      return {
        group: 'meaning',
        title: text.snippet,
        subtitle: noteSubtitle(text),
        icon: 'note',
        run: () => actions.openNote(paperID),
      }
    }
    return {
      group: 'meaning',
      title: text.snippet,
      subtitle: passageSubtitle(text),
      icon: 'text.magnifyingglass',
      run: () => actions.openPassage(text, ''),
    }
  }

  const build = () => {
    const query = input.value.trim()
    const room = scanning || passages.length > 0 ? SHOWN - 4 : SHOWN
    const flat = [
      ...typed.slice(0, room).map(rowFor),
      ...passages.map((hit) => passageRow(hit, query)),
      ...meanings.map(meaningRow),
    ]
    rows = GROUPS.flatMap((group) => flat.filter((row) => row.group === group))
    if (highlighted >= rows.length) highlighted = Math.max(rows.length - 1, 0)
    draw()
  }

  const draw = () => {
    clear(list)
    let index = 0
    for (const group of GROUPS) {
      const members = rows.filter((row) => row.group === group)
      if (members.length === 0) continue
      list.append(el('div', { class: 'palette-group', text: groupTitle(group) }))
      for (const row of members) {
        const at = index
        const icon = iconNode(row.icon)
        const node = el('div', {
          class: row.group === 'passage' ? 'palette-row passage' : 'palette-row',
          role: 'option',
          'aria-selected': String(at === highlighted),
        }, [
          el('span', { class: 'palette-icon' }, icon ? [icon] : []),
          el('div', { class: 'palette-main' }, [
            el('div', { class: 'palette-title', text: row.title }),
            ...(row.subtitle ? [el('div', { class: 'palette-subtitle', text: row.subtitle })] : []),
          ]),
        ])
        on(node, 'mousemove', () => {
          if (highlighted === at) return
          highlighted = at
          for (const [position, child] of [...list.querySelectorAll('.palette-row')].entries()) {
            child.setAttribute('aria-selected', String(position === at))
          }
        })
        on(node, 'mousedown', (event: MouseEvent) => event.preventDefault())
        on(node, 'click', () => activate(at))
        list.append(node)
        index += 1
      }
    }
    if (scanning) {
      // Said rather than spun silently: the first search of a session reads
      // every paper in the library, and a palette that simply sat there for
      // a few seconds would look broken rather than busy.
      list.append(el('div', { class: 'palette-scanning' }, [
        el('span', { class: 'spinner' }),
        el('span', { text: L('논문 본문을 읽는 중…', 'Reading the papers…') }),
      ]))
    }
    // Quietly, and only while something is typed: the index fills once, in
    // the background, and a section that is not there yet should say why.
    const footer = input.value.trim() ? meaningFooter(meaningStatus()) : null
    if (footer) list.append(el('div', { class: 'palette-footer', text: footer }))
    list.classList.toggle('empty', rows.length === 0 && !scanning && !footer)
    list.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' })
  }

  const activate = (index: number) => {
    const row = rows[index]
    if (!row) return
    close()
    row.run()
  }

  /** The text of the papers, searched for what has been typed. */
  const scan = (query: string) => {
    stopScan?.()
    stopScan = null
    if (scanTimer) clearTimeout(scanTimer)
    scanTimer = null
    passages = []
    scanning = false
    if (graphemes(query).length <= 1) return
    scanTimer = setTimeout(() => {
      scanTimer = null
      scanning = true
      build()
      // The papers already named by title are the ones just matched; there
      // is no reason to match them a second time.
      const named = new Set(typed.flatMap((result) => (result.kind.type === 'paper' ? [result.kind.id] : [])))
      const timing: QueryTiming = { query, rankMs: lastRankMs, firstPassageMs: null, doneMs: null, passages: 0, searched: 0 }
      timings.push(timing)
      if (timings.length > 50) timings.shift()
      const started = performance.now()
      stopScan = searchText(query, textSources(named), {
        limit: 4,
        hits: (hits) => {
          if (timing.firstPassageMs === null) timing.firstPassageMs = performance.now() - started
          passages = [...passages, ...hits].slice(0, 4)
          timing.passages = passages.length
          build()
        },
        done: (summary) => {
          timing.doneMs = performance.now() - started
          timing.searched = summary.searched
          scanning = false
          stopScan = null
          build()
        },
      })
    }, 220)
  }

  /**
   * The passages that mean what was typed, 150 ms after the typing stops —
   * a debounce of its own, so the exact results above never wait for it.
   * Nothing is asked while the index is not built; the footer says so.
   */
  const askMeaning = (query: string) => {
    if (meaningTimer) clearTimeout(meaningTimer)
    meaningTimer = null
    meanings = []
    const mine = (meaningAsked += 1)
    if (graphemes(query).length <= 2 || !meaningStatus().ready) return
    meaningTimer = setTimeout(() => {
      meaningTimer = null
      const shown = passages.map((hit) => placeKey(hit.passage))
      const started = performance.now()
      void searchMeaning(query, shown).then((answer) => {
        if (mine !== meaningAsked || !current) return
        meanings = answer.hits.filter((hit) => !passages.some((seen) => placeKey(seen.passage) === placeKey(hit.passage)))
        lastMeaningMs = performance.now() - started
        build()
      })
    }, 150)
  }

  let lastRankMs = 0
  let lastMeaningMs: number | null = null
  const match = () => {
    const query = input.value.trim()
    const started = performance.now()
    typed = query ? rank(query, prepared, words) : []
    lastRankMs = performance.now() - started
    highlighted = 0
    scan(query)
    askMeaning(query)
    build()
  }
  // The index became ready, or filled a little more, while the palette is
  // open: the footer moves on, and a query already typed gets its section.
  const stopWatchingMeaning = onMeaningStatus((status) => {
    if (!current) return
    if (status.ready && meanings.length === 0 && meaningTimer === null) askMeaning(input.value.trim())
    build()
  })

  const move = (by: number) => {
    if (rows.length === 0) return
    highlighted = ((highlighted + by) % rows.length + rows.length) % rows.length
    draw()
  }

  on(input, 'input', match)
  on(input, 'keydown', (event: KeyboardEvent) => {
    event.stopPropagation()
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      move(1)
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      move(-1)
    } else if (event.key === 'Enter') {
      event.preventDefault()
      activate(highlighted)
    } else if (event.key === 'Escape') {
      event.preventDefault()
      close()
    }
  })
  on(scrim, 'mousedown', () => close())

  const close = () => {
    stopScan?.()
    if (scanTimer) clearTimeout(scanTimer)
    if (meaningTimer) clearTimeout(meaningTimer)
    stopWatchingMeaning()
    clearTimeout(warming)
    scrim.remove()
    box.remove()
    current = null
  }

  document.body.append(scrim, box)
  input.focus()
  // Reading the library starts a moment after the palette opens rather than
  // with it: sixty PDFs is real work, and starting it in the same instant as
  // the palette made the palette wait for it.
  const warming = setTimeout(() => warmText(textSources()), 700)

  current = {
    close,
    setQuery: (text: string) => {
      input.value = text
      match()
    },
    activate,
    rows: () => rows,
    rankMs: () => lastRankMs,
    meaningMs: () => lastMeaningMs,
  }
  if (initial) current.setQuery(initial)
  else build()
}

/**
 * For a probe: the palette as data, so "does it find the word" can be asked
 * without a key being sent anywhere.
 */
;(window as unknown as { __papertimeSearch: unknown }).__papertimeSearch = {
  timings,
  isOpen: () => current !== null,
  type: (text: string) => current?.setQuery(text),
  rows: () => current?.rows().map(({ group, title, subtitle }) => ({ group, title, subtitle })) ?? [],
  activate: (index: number) => current?.activate(index),
  rankMs: () => current?.rankMs() ?? null,
  meaningMs: () => current?.meaningMs() ?? null,
}
