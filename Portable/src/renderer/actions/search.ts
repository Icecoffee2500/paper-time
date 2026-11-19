/**
 * Search Everything — the palette (`ui/search.ts`), what its rows do — and
 * Find in Document.
 */
import { changed, mixesKinds, paper as findPaper, setShelf, shelfPapers, store } from '../state.js'
import { togglePane } from '../layout.js'
import { findBar, focused, readerOf } from '../pageArea.js'
import { showPaper } from './openPapers.js'
import { openNoteFromSearch } from './notes.js'
import { showSearchResults } from '../listSearch.js'
import { addByAddress, addPapers, reload } from '../library.js'
import { openSettings } from '../settingsController.js'
import { runCommand } from '../commands.js'
import { openPalette } from '../ui/search.js'
import { toast } from '../ui/toolbar.js'
import { L } from '../../shared/lang.js'
import type { Shelf } from '../state.js'
import type { TextHit } from '../textSearch.js'

export function openSearch(initial = '') {
  const shelf = (to: Shelf) => {
    setShelf(to)
    changed('shelf')
  }
  openPalette({
    openPaper: (id) => void revealPaper(id),
    openPassage: (hit, query) => void openPassage(hit, query, true),
    openNote: (id, words) => openNoteFromSearch(id, words),
    openCollection: (id) => shelf({ kind: 'collection', id }),
    openTag: (id) => shelf({ kind: 'tag', id }),
    showAll: (query) => showSearchResults(query),
    perform: (action) => {
      switch (action) {
        case 'addPDFs': void addPapers(); break
        case 'addByAddress': void addByAddress(); break
        case 'exportBibTeX': runCommand('exportBibTeX'); break
        case 'resolveMetadata': runCommand('resolveMetadata'); break
        case 'refreshMetadata': runCommand('refreshMetadata'); break
        case 'refresh': void reload(); break
        case 'settings': openSettings(); break
      }
    },
  }, initial)
}

/**
 * Opens the paper a word was found in and sends the reader to the line.
 *
 * The reader is asked only once the paper is in it: opening a paper is a
 * round trip for its bytes and a parse, and the line has no place until then.
 */
export async function openPassage(hit: TextHit, query: string, reveals = false) {
  const id = hit.passage.paperID
  if (!findPaper(id)) return
  // From the palette the list goes to the paper too; from the found list,
  // the list is already where the passage is.
  if (reveals) await revealPaper(id)
  else await showPaper(id)
  const reader = readerOf(id)
  if (!reader) return
  if (findBar.isOpen) findBar.close()
  await reader.revealPassage(hit.passage, query)
}

/**
 * Opens a paper chosen in Search Everything and brings the list to its row
 * (the Mac's `LibraryModel.reveal`). «논문이 논문 창에 켜지기는 하는데, 2번째
 * 창은 가만히 있거든» (1.1): the reader went to the paper and the list stayed
 * where it was. The shelf stays when the paper is on it; otherwise the chips
 * turn to its kind, and last the shelf of its kind is shown. The found list
 * keeps what it found. A supplement's row is its paper's.
 */
export async function revealPaper(id: string) {
  const chosen = findPaper(id)
  if (!chosen) return
  const parent = chosen.meta.parentID ? findPaper(chosen.meta.parentID) : null
  const row = parent ? parent.id : id
  const onList = () => shelfPapers().some((entry) => entry.id === row)
  if (!onList()) {
    const kind = (parent ?? chosen).meta.shelfKind
    let moved = false
    if (mixesKinds(store.shelf) && store.shownKind !== kind) {
      store.shownKind = kind
      moved = true
    }
    if (!onList() && store.shelf.kind !== 'search') {
      setShelf({ kind: 'kind', of: kind })
      moved = true
    }
    if (moved) changed('shelf')
  }
  store.revealRequest = { paper: row, serial: (store.revealRequest?.serial ?? 0) + 1, at: Date.now() }
  await showPaper(id)
  // Chosen again while it shows: the list still goes to it.
  changed('selection')
}

export function openFind() {
  // The bar goes over the paper, so the paper has to be showing: with its
  // pane hidden the bar was put on a reader out of the window.
  if (!store.settings.panes.reader) togglePane('reader')
  const reader = focused()
  if (!reader || !reader.document) {
    toast(L('먼저 논문을 열어주세요.', 'Open a paper first.'))
    return
  }
  findBar.open(reader)
}
