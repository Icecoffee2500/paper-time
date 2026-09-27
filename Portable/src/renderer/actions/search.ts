/**
 * Search Everything — the palette (`ui/search.ts`), what its rows do — and
 * Find in Document.
 */
import { changed, paper as findPaper, setShelf, store } from '../state.js'
import { togglePane } from '../layout.js'
import { findBar, focused, readers } from '../pageArea.js'
import { showPaper } from './openPapers.js'
import { openNoteFromSearch } from './notes.js'
import { showSearchResults } from '../listSearch.js'
import { addPapers, reload } from '../library.js'
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
    openPaper: (id) => void showPaper(id),
    openPassage: (hit, query) => void openPassage(hit, query),
    openNote: (id, words) => openNoteFromSearch(id, words),
    openCollection: (id) => shelf({ kind: 'collection', id }),
    openTag: (id) => shelf({ kind: 'tag', id }),
    showAll: (query) => showSearchResults(query),
    perform: (action) => {
      switch (action) {
        case 'addPDFs': void addPapers(); break
        case 'exportBibTeX': runCommand('exportBibTeX'); break
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
export async function openPassage(hit: TextHit, query: string) {
  const id = hit.passage.paperID
  if (!findPaper(id)) return
  await showPaper(id)
  const reader = readers.get(id)
  if (!reader) return
  if (findBar.isOpen) findBar.close()
  await reader.revealPassage(hit.passage, query)
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
