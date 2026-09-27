/**
 * The search shelf's half of a search: the papers that say the words inside
 * them, and the passages that say the same thing in other words.
 *
 * The same work the palette does, kept when the palette is put away:
 * pressing Return on a search should not throw away the half of the answer
 * that was not in any title. Every paper is read, not four, and the hits go
 * on the list a batch at a frame — the Mac appended them one at a time, and
 * the list redrew itself once per paper.
 */
import { changed, setShelf, shelfPapers, store, textSources } from './state.js'
import { searchText } from './textSearch.js'
import { asTextHit, meaningStatus, onMeaningStatus, searchMeaning } from './meaningSearch.js'
import { graphemes } from '../shared/textFold.js'

/**
 * «Show All Results»: the search becomes a shelf, with its own row at the top
 * of the sidebar, and the list reads the papers' text for the same words.
 */
export function showSearchResults(query: string) {
  const trimmed = query.trim()
  if (!trimmed) return
  store.searchQuery = trimmed
  setShelf({ kind: 'search' })
  changed('shelf', 'papers')
}

export function clearSearchResults() {
  store.searchQuery = ''
  if (store.shelf.kind === 'search') setShelf({ kind: 'all' })
  changed('shelf', 'papers')
}

let scan: { key: string; stop: (() => void) | null; meaningAsked: boolean } = { key: '', stop: null, meaningAsked: false }
let drawSoon = 0

/** Starts reading for the search shelf's query, once per query. */
export function scanListText() {
  const key = store.shelf.kind === 'search' ? store.searchQuery : ''
  if (key === scan.key) return
  scan.stop?.()
  scan = { key, stop: null, meaningAsked: false }
  store.searchPassages = []
  store.searchScanning = false
  store.searchMeanings = []
  if (!key || graphemes(key).length <= 1) return
  askMeaning()
  // The papers already on the list by their titles are the ones not to read
  // for the same words again.
  const named = new Set(shelfPapers().map((entry) => entry.id))
  store.searchScanning = true
  scan.stop = searchText(key, textSources(named), {
    hits: (hits) => {
      store.searchPassages = [...store.searchPassages, ...hits]
      if (!drawSoon) {
        drawSoon = requestAnimationFrame(() => {
          drawSoon = 0
          changed('searchResults')
        })
      }
    },
    done: () => {
      store.searchScanning = false
      scan.stop = null
      changed('searchResults')
    },
  })
}

/**
 * The list's passages by meaning: the palette's rows, kept when the palette
 * is put away. Nothing is asked while the index is not built or the switch
 * is off — the group is left out, not shown empty — and asked once it is
 * built, for the search still showing: the index is often ready a minute
 * after the search was made, and the group never came (`PaperListView`
 * asks again the same way). The list drops what the words already found
 * when it draws, since those arrive after this answer.
 */
function askMeaning() {
  const key = scan.key
  if (!key || scan.meaningAsked || graphemes(key).length <= 2 || !meaningStatus().ready) return
  scan.meaningAsked = true
  void searchMeaning(key).then((answer) => {
    if (scan.key !== key) return
    if (!answer.ready) {
      scan.meaningAsked = false
      return
    }
    store.searchMeanings = answer.hits.map(asTextHit)
    changed('searchResults')
  })
}

export function installListSearch() {
  onMeaningStatus((status) => { if (status.ready) askMeaning() })
}
