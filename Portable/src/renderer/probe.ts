/**
 * What an in-page probe (`--papertime-probe`) reaches: the window's state and
 * the ways into it, so «does it land on the word» or «does the Mac's note
 * show» can be asked from inside the page with nothing sent to the desktop.
 *
 * Put up only in a probe run — a window somebody reads in has no use for a
 * handle on its store.
 */
import { layoutPanes } from './layout.js'
import { flags } from './bridge.js'
import { store } from './state.js'
import { findBar, focused } from './pageArea.js'
import { showPaper } from './actions/openPapers.js'
import { openNote, openNoteFromSearch } from './actions/notes.js'
import { openFind, openPassage } from './actions/search.js'
import { showSearchResults } from './listSearch.js'
import { readings } from './library.js'
import { setSettings } from './settingsController.js'
import { createNote } from './notesModel.js'
import { backToNotes, openNoteInSlipBox, slipBoxEditor } from './ui/slipBox.js'
import { openEditor as openNoteEditor, openNoteInTab } from './ui/notesTab.js'
import { sketchEditor, sketchSelectionChanged } from './ui/sketchEditing.js'
import type { TextHit } from './textSearch.js'
import type { Settings } from './state.js'

export function installProbeSurface() {
  if (!flags.probe) return
  const surfaces: Record<string, unknown> = {
    // The drawing contract, so a test can stand in for the page's editor and
    // look at the Tools tab.
    __papertimeSketch: { sketchEditor, sketchSelectionChanged, store },
    __papertimeFind: findBar,
    // The reader in focus, and the two ways a search sends somebody into a
    // paper.
    __papertimeReader: {
      focused: () => focused(),
      show: (id: string) => showPaper(id),
      openPassage: (hit: TextHit, query: string) => openPassage(hit, query),
      openFind: () => openFind(),
      showAll: (query: string) => showSearchResults(query),
    },
    // Settings changed the way the sheet changes them — held in memory by a
    // probe run, like everything else it sets.
    __papertimeSettings: {
      set: (patch: Partial<Settings>) => setSettings(patch),
      tint: () => focused()?.tintReport() ?? null,
    },
    // The library as the window holds it: whether a write reached the rows
    // without a reading of the library.
    __papertimeLibrary: {
      papers: () => store.papers.map((entry) => ({
        id: entry.id,
        title: entry.meta.displayTitle,
        file: String(entry.meta.file?.relativePath ?? ''),
        favorite: entry.state.isFavorite,
        status: entry.state.readingStatus,
        kind: entry.meta.effectiveKind,
        parentID: entry.meta.parentID ?? null,
        lastPage: entry.state.lastPageIndex,
      })),
      selected: () => store.selectedID,
      selection: () => [...store.selection],
      // The first-run screen, for a picture of it: a probe always has a library.
      showSetup: () => {
        store.root = null
        store.ready = true
        layoutPanes()
      },
      adopting: () => store.adopting,
      open: () => [...store.openPaperIDs],
      pinned: () => [...store.pinnedPaperIDs],
      split: () => store.split,
      trail: () => ({ trail: [...store.trail], index: store.trailIndex }),
      readings: () => readings,
    },
    // The slip-box as the window holds it, and the ways into a note.
    __papertimeNotes: {
      list: () => store.notes.map((note) => ({ id: note.id, kind: note.kind, title: note.title, body: note.body, paperID: note.paperID, box: note.box })),
      folder: () => store.notesFolder,
      open: (id: string) => openNote(id),
      create: (paperID: string | null) => createNote(paperID).id,
      openInSlipBox: (id: string) => openNoteInSlipBox(id),
      openInTab: (id: string) => openNoteInTab(id),
      tabEditor: () => openNoteEditor()?.id ?? null,
      slipBoxEditor: () => slipBoxEditor()?.id ?? null,
      /** Each editor's formula card and `[[` card. */
      tabEditorReport: () => openNoteEditor()?.report() ?? null,
      slipBoxEditorReport: () => slipBoxEditor()?.report() ?? null,
      /** The slip-box editor's text replaced, and the caret put somewhere — no keys typed. */
      setSlipBoxText: (text: string, caret?: number) => {
        const view = slipBoxEditor()?.view
        if (!view) return false
        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, selection: { anchor: caret ?? text.length } })
        return true
      },
      /** The Notes tab's editor's text replaced. */
      setTabText: (text: string, caret?: number) => {
        const view = openNoteEditor()?.view
        if (!view) return false
        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, selection: { anchor: caret ?? text.length } })
        return true
      },
      /** The slip-box editor's text and caret, and how its lines are drawn. */
      slipBoxState: () => {
        const view = slipBoxEditor()?.view
        if (!view) return null
        return {
          text: view.state.doc.toString(),
          caret: view.state.selection.main.head,
          lines: [...view.contentDOM.querySelectorAll('.cm-line')].map((line) => `${line.className.replace('cm-line', '').trim()} | ${line.textContent}`),
        }
      },
      /** A note from a search, at the words it was found by (`--papertime-note-reveal`). */
      reveal: (id: string, words: string) => openNoteFromSearch(id, words),
      /** Where the open note is shown beside a followed paper, and the way back. */
      slipBoxPaper: () => store.slipBox.paperID,
      back: () => backToNotes(),
      shelf: () => store.shelf.kind,
    },
  }
  Object.assign(window, surfaces)
}
