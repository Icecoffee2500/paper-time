/**
 * What an in-page probe (`--papertime-probe`) reaches: the window's state and
 * the ways into it, so «does it land on the word» or «does the Mac's note
 * show» can be asked from inside the page with nothing sent to the desktop.
 *
 * Put up only in a probe run — a window somebody reads in has no use for a
 * handle on its store.
 */
import { latex as mathLatex, structured as mathStructured } from '../shared/mathReader/reader.js'
import { layoutPanes } from './layout.js'
import { call, flags } from './bridge.js'
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
import { exportNoteHTML } from './ui/noteEditor.js'
import { setCodeCopier } from './ui/note/markdownView.js'
import { zettelDisplayTitle } from '../shared/zettel.js'
import { openEditor as openNoteEditor, openNoteInTab } from './ui/notesTab.js'
import { sketchEditor, sketchSelectionChanged } from './ui/sketchEditing.js'
import type { TextHit } from './textSearch.js'
import type { Settings } from './state.js'
import { Transaction } from '@codemirror/state'

export function installProbeSurface() {
  if (!flags.probe) return
  // A block's copy button, pressed by a probe, copies here — never onto the
  // clipboard of the person whose desktop this is.
  const copiedCode: string[] = []
  setCodeCopier(async (text) => {
    copiedCode.push(text)
    return true
  })
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
    // What Ultracopy and ⌘L would make of the selection — read, not copied:
    // a probe never writes the person's clipboard.
    __papertimeMath: {
      read: async () => {
        const pages = (await focused()?.selectionForMath()) ?? []
        return { pages: pages.length, glyphs: pages.map((page) => page.glyphs.length), latex: mathLatex(pages), structured: mathStructured(pages) }
      },
      /** The formula lasso's catch of a rectangle on a page (page coordinates,
       *  as pointer-up would make it), and what ⇧⌘C and ⌘L would read for it. */
      lasso: async (pageIndex: number, x: number, y: number, width: number, height: number) => {
        const reader = focused()
        if (!reader) return null
        if (!reader.state.lasso) reader.setLasso(true)
        const caught = await reader.catchRect(pageIndex, { x, y, width, height })
        const pages = await reader.lassoForMath()
        return { caught, needsOCR: reader.caught?.needsOCR ?? false, glyphs: pages.map((page) => page.glyphs.length), latex: mathLatex(pages), structured: mathStructured(pages) }
      },
      /** The formula OCR's whole path on a rectangle of a page — the picture
       *  drawn, sent, read — and what came back; nothing goes to the clipboard. */
      ocr: async (pageIndex: number, x: number, y: number, width: number, height: number) => {
        const reader = focused()
        const page = reader?.pages[pageIndex]
        if (!reader || !page) return null
        return reader.readByOCR(page, { x, y, width, height })
      },
      /** Whether the lasso is out, what it holds, and where its box stands. */
      state: () => focused()?.lassoReport() ?? null,
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
        // Not a step of the note's history: ⌘Z after it is the keys' own.
        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, selection: { anchor: caret ?? text.length }, annotations: Transaction.addToHistory.of(false) })
        return true
      },
      /** The slip-box editor given the caret, and a selection from `anchor` to `head` — no keys, no pointer. */
      selectSlipBox: (anchor: number, head?: number) => {
        const view = slipBoxEditor()?.view
        if (!view) return false
        view.focus()
        view.dispatch({ selection: { anchor, head: head ?? anchor } })
        return true
      },
      /** The caret put where a press put it: the transaction a click makes (`select.pointer`) — a press on a list's marker. */
      pressSlipBox: (at: number) => {
        const view = slipBoxEditor()?.view
        if (!view) return false
        view.focus()
        view.dispatch({ selection: { anchor: at }, userEvent: 'select.pointer' })
        return true
      },
      /** The Notes tab's editor's text replaced. */
      setTabText: (text: string, caret?: number) => {
        const view = openNoteEditor()?.view
        if (!view) return false
        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, selection: { anchor: caret ?? text.length } })
        return true
      },
      /** The slip-box editor's text, caret and selection, how its lines are drawn, the selection bar, and the folds. */
      slipBoxState: () => {
        const editor = slipBoxEditor()
        const view = editor?.view
        if (!editor || !view) return null
        const report = editor.report()
        const range = view.state.selection.main
        return {
          text: view.state.doc.toString(),
          caret: range.head,
          selection: [range.from, range.to],
          lines: [...view.contentDOM.querySelectorAll('.cm-line')].map((line) => `${line.className.replace('cm-line', '').trim()} | ${line.textContent}`),
          /** The spans with a class, in order, as `class:text` — the syntax colour, the markers. */
          spans: [...view.contentDOM.querySelectorAll('.cm-line [class]')].map((span) => `${span.className}:${span.textContent}`),
          toolbar: report.toolbar,
          folded: report.folded,
        }
      },
      /** The slip-box editor's `index`th copy button pressed, in the page: what it copied (onto the probe's stand-in) and what the button says after. */
      copyCode: async (index = 0) => {
        const view = slipBoxEditor()?.view
        const button = view?.contentDOM.querySelectorAll<HTMLButtonElement>('.nm-code-copy')[index]
        if (!button) return null
        const before = copiedCode.length
        button.click()
        await new Promise((done) => setTimeout(done, 50))
        return { copied: copiedCode.slice(before), label: button.textContent }
      },
      /** A note from a search, at the words it was found by (`--papertime-note-reveal`). */
      reveal: (id: string, words: string) => openNoteFromSearch(id, words),
      /** Where the open note is shown beside a followed paper, and the way back. */
      slipBoxPaper: () => store.slipBox.paperID,
      back: () => backToNotes(),
      shelf: () => store.shelf.kind,
      /** The document «Export as PDF…» would print for a note, as a string — nothing is saved. */
      exportHTML: (id: string) => {
        const note = store.notes.find((one) => one.id === id)
        return note ? exportNoteHTML(note) : null
      },
      /** The PDF «Export as PDF…» makes, written to `to` with no dialog. */
      exportPDF: async (id: string, to: string) => {
        const note = store.notes.find((one) => one.id === id)
        if (!note) return null
        return call('notes:exportPDF', { title: zettelDisplayTitle(note), html: exportNoteHTML(note), to })
      },
    },
  }
  Object.assign(window, surfaces)
}
