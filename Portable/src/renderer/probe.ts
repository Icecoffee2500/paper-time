/**
 * What an in-page probe (`--papertime-probe`) reaches: the window's state and
 * the ways into it, so «does it land on the word» or «does the Mac's note
 * show» can be asked from inside the page with nothing sent to the desktop.
 *
 * Put up only in a probe run — a window somebody reads in has no use for a
 * handle on its store.
 */
import type { DockZone } from '../shared/split.js'
import { latex as mathLatex, structured as mathStructured } from '../shared/mathReader/reader.js'
import { closeContentPane, inspectorPlaceNow, layoutPanes, reopenClosedPane, setInspectorFloating, showInspector, showPaneMenu, togglePane } from './layout.js'
import { dockZoneShown } from './dockDrop.js'
import { READER_PANE_DRAG_TYPE, writeDraggedPapers } from '../shared/split.js'
import { editProject, sampleProject, showProject } from './projects.js'
import { projectReport } from './ui/projects.js'
import { paneDropShown } from './ui/paneDrop.js'
import { paneTitle } from './ui/paneViews.js'
import { PAPER_DRAG_TYPE } from '../shared/split.js'
import { CONTENT_PANE_DRAG_TYPE, SHELF_DRAG_TYPE } from '../shared/split.js'
import type { ProjectEdit } from '../shared/project.js'
import { call, flags } from './bridge.js'
import { changed, kindsOnShelf, patchPaper, setShelf, shelfPapers, store, subfolders, tableKind } from './state.js'
import * as plans from './plans.js'
import { planOrder } from '../shared/readingPlan.js'
import { findBar, focused, pageArea } from './pageArea.js'
import { shell } from './shell.js'
import { dockPaper, showPaper } from './actions/openPapers.js'
import { setKind } from './actions/paper.js'
import { openNote, openNoteFromSearch } from './actions/notes.js'
import { openFind, openPassage } from './actions/search.js'
import { showSearchResults } from './listSearch.js'
import { readings, addPaperByAddress } from './library.js'
import { setSettings } from './settingsController.js'
import { createArea, createNote, moveNoteToArea, noteAreas, removeArea, renameArea, slipBoxList } from './notesModel.js'
import { NOTE_DRAG_TYPE } from '../shared/split.js'
import { backToNotes, openNoteInSlipBox, slipBoxEditor } from './ui/slipBox.js'
import { exportNoteHTML } from './ui/noteEditor.js'
import { setCodeCopier } from './ui/note/markdownView.js'
import { zettelDisplayTitle } from '../shared/zettel.js'
import { openEditor as openNoteEditor, openNoteInTab } from './ui/notesTab.js'
import { sketchEditor, sketchSelectionChanged } from './ui/sketchEditing.js'
import type { TextHit } from './textSearch.js'
import type { Settings } from './state.js'
import { Transaction } from '@codemirror/state'

/** Whether the inspector's form is drawn now — it is not while it cannot be seen. */
function shellInspectorRendered(): { connected: boolean; drawn: number } {
  return { connected: shell.inspector.node.isConnected, drawn: shell.inspector.drawnCount() }
}

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
        kind: entry.meta.shelfKind,
        parentID: entry.meta.parentID ?? null,
        lastPage: entry.state.lastPageIndex,
      })),
      selected: () => store.selectedID,
      selection: () => [...store.selection],
      // Which kind the shelf in front shows, and the chips over it (1.1).
      kinds: () => ({ shelf: store.shelf, shown: store.shownKind, table: tableKind(), chips: kindsOnShelf(), visible: shelfPapers().length }),
      setKind: (id: string, kind: 'paper' | 'book' | 'document') => setKind(id, kind),
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
      focusedPane: () => store.focusedPane,
      /** A paper chosen the way the list or the palette chooses one. */
      show: (id: string) => showPaper(id),
      /** A paper into a zone — or, with the pane's key, that pane moved. */
      dock: (id: string, zone: DockZone, pane?: string) => dockPaper(id, zone, pane),
      trail: () => ({ trail: [...store.trail], index: store.trailIndex }),
      readings: () => readings,
      /** The disk's folders as the last read found them, and the tree under a folder. */
      folders: () => [...store.folders],
      /** A paper from an address, the way the sheet adds one; the outcome, not a toast. */
      addByAddress: (text: string) => addPaperByAddress(text),
      subfolders: (folder: string) => subfolders(folder).map((one) => `${one.name}(${one.count})`),
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
      /** A change from the format panel made to the slip-box's note, and what the panel then shows. */
      formatSlipBox: (command: Parameters<NonNullable<ReturnType<typeof slipBoxEditor>>['format']>[0]) => {
        const editor = slipBoxEditor()
        if (!editor) return null
        editor.format(command)
        return editor.formatState()
      },
      /** The format panel in the inspector, as its words and what is lit — empty when it is not shown. */
      formatPanel: () => {
        const panel = document.querySelector('.note-format-panel')
        if (!panel) return null
        return {
          idle: panel.classList.contains('idle'),
          paragraph: panel.querySelector('.nf-paragraph')?.textContent ?? '',
          fields: [...panel.querySelectorAll('.nf-field')].map((one) => one.textContent ?? ''),
          lit: [...panel.querySelectorAll('[aria-pressed="true"]')].map((one) => one.getAttribute('title') ?? one.textContent ?? ''),
        }
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
      // The slip-box's places (1.1): 문헌 노트, and 지식 with its areas.
      /** The areas of knowledge the loose box holds. */
      areas: () => noteAreas(),
      createArea: (name: string, inside = '') => createArea(name, inside),
      renameArea: (area: string, name: string) => renameArea(area, name),
      removeArea: (area: string) => removeArea(area),
      /** A note filed in an area — '' for none — the way «Move to Area» files it. */
      moveToArea: (id: string, area: string) => moveNoteToArea(id, area),
      /** 문헌 노트 in front, or 지식 — `null` every area, '' the unfiled. */
      showLiterature: () => {
        setShelf({ kind: 'notes' })
        changed('shelf')
      },
      showKnowledge: (area: string | null = null) => {
        setShelf({ kind: 'knowledge', area })
        changed('shelf')
      },
      /** The list's order and 문헌 노트's kind, held in memory as a probe holds settings. */
      setOrder: (order: 'edited' | 'created' | 'title') => {
        store.settings.slipBoxNoteOrder = order
        changed('settings')
      },
      setKind: (kind: '' | 'paper' | 'book' | 'document') => {
        store.settings.literatureNoteKind = kind
        changed('settings')
      },
      /** A note dragged onto a sidebar row (`area:<area>`, `knowledge`), in the page: a real drop, no desktop. */
      dropNote: (id: string, rowKey: string) => {
        const row = document.querySelector<HTMLElement>(`.sidebar-column .row[data-key="${CSS.escape(rowKey)}"]`)
        if (!row) return false
        const data = new DataTransfer()
        data.setData(NOTE_DRAG_TYPE, id)
        data.effectAllowed = 'move'
        for (const type of ['dragenter', 'dragover', 'drop']) row.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: data }))
        return true
      },
      /** What the slip-box's list shows: its head, the kind chips, each row, and the sidebar's slip-box rows. */
      listReport: () => {
        const column = document.querySelector('.panel.slipbox')
        const section = [...document.querySelectorAll<HTMLElement>('.sidebar-column .sidebar-section')].find((one) => /슬립박스|Slip-Box/.test(one.textContent ?? ''))
        const sidebar: string[] = []
        for (let at = section?.nextElementSibling; at && !at.classList.contains('sidebar-section'); at = at.nextElementSibling) {
          const row = at as HTMLElement
          sidebar.push(`${row.style.paddingLeft ? `[${row.style.paddingLeft}] ` : ''}${row.getAttribute('aria-selected') === 'true' ? '● ' : ''}${row.textContent}`)
        }
        return {
          shelf: store.shelf,
          head: column?.querySelector('.shelf-head h2')?.textContent ?? null,
          sub: column?.querySelector('.shelf-sub')?.textContent ?? null,
          pen: (() => {
            const pen = column?.querySelectorAll<HTMLButtonElement>('.shelf-trailing .icon-button')[1]
            return pen ? { disabled: pen.disabled, title: pen.title } : null
          })(),
          kinds: [...(column?.querySelectorAll<HTMLElement>('.slipbox-kind') ?? [])].map((chip) => `${chip.getAttribute('aria-pressed') === 'true' ? '● ' : ''}${chip.textContent}`),
          rows: [...(column?.querySelectorAll<HTMLElement>('.slip-row') ?? [])].map((row) => ({
            id: row.dataset.note,
            title: row.querySelector('.note-row-title')?.textContent,
            second: row.querySelector('.slip-row-second')?.textContent ?? null,
            date: row.querySelector('.note-row-date')?.textContent,
          })),
          empty: column?.querySelector('.empty h2')?.textContent ?? null,
          listed: slipBoxList().map((note) => `${note.id}@${note.area}`),
          sidebar,
        }
      },
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
    // The row of panes (1.1): what the window wears, and the ways a hand
    // changes it — the ×, the ⌄, the «+», drops from the sidebar and from a
    // pane's head (made in the page, as a drag would, with a `DataTransfer`).
    __papertimePanes: {
      state: () => ({
        row: store.row.panes.map((pane) => ({ id: pane.id, kind: pane.content.kind, title: paneTitle(pane), width: pane.width })),
        closed: store.row.closed.map((entry) => `${entry.pane.content.kind}:${paneTitle(entry.pane)}`),
        switches: { ...store.settings.panes },
        focus: store.focus.on,
        inspector: inspectorPlaceNow(),
        shown: [...document.querySelectorAll<HTMLElement>('.panes > *')].map((one) => one.dataset.paneKind
          ? `${one.dataset.paneKind}:${one.getBoundingClientRect().width.toFixed(0)}`
          : one.className.split(' ')[0]),
        drop: paneDropShown(),
        page: dockZoneShown(),
        split: store.split,
        focusedPane: store.focusedPane,
        selected: store.selectedID,
        plus: Boolean(document.querySelector('.panes > .pane-plus')),
        inspectorShown: store.settings.panes.inspector,
        inspectorRendered: shellInspectorRendered(),
        toast: document.querySelector('.toast')?.textContent ?? null,
      }),
      showInspector: (floating: boolean) => showInspector(floating),
      /**
       * A paper dragged as the hand drags it: from a row of the table
       * (`{paper: id}` — the row's own dragstart when it is on screen) or by a
       * side-by-side pane's title (`{reader: key}`), let go of over the `to`th
       * pane, the «+» column or the page, at `at` (fractions of its box).
       * `hold` stops before the drop, so the zones can be photographed.
       */
      dragPaper: (from: { paper?: string; reader?: string }, to: number | 'plus' | 'page', at: [number, number] = [0.5, 0.5], hold = false) => {
        const data = new DataTransfer()
        let source: HTMLElement | null = null
        if (from.paper) {
          source = document.querySelector<HTMLElement>(`.pb-row[data-id="${CSS.escape(from.paper)}"]`)
          if (source) source.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: data }))
          if (!data.types.includes(PAPER_DRAG_TYPE)) {
            writeDraggedPapers(data, [from.paper])
            data.effectAllowed = 'copyMove'
          }
        } else if (from.reader) {
          const paper = from.reader.split('@')[0]
          writeDraggedPapers(data, [paper])
          data.setData(READER_PANE_DRAG_TYPE, from.reader)
          data.effectAllowed = 'move'
        }
        const target = to === 'plus' ? document.querySelector<HTMLElement>('.pane-plus')
          : to === 'page' ? pageArea
            : document.querySelector<HTMLElement>(`.panes > [data-pane-id="${CSS.escape(store.row.panes[to]?.id ?? '')}"]`)
        if (!target) return { landed: false }
        const box = target.getBoundingClientRect()
        const point = { clientX: box.left + box.width * at[0], clientY: box.top + box.height * at[1] }
        const over = (document.elementFromPoint(point.clientX, point.clientY) as HTMLElement | null) ?? target
        const node = target.contains(over) ? over : target
        for (const type of ['dragenter', 'dragover']) node.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: data, ...point }))
        if (hold) return { landed: true, held: { panes: paneDropShown(), page: dockZoneShown() } }
        node.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: data, ...point }))
        ;(source ?? window).dispatchEvent(new DragEvent('dragend', { bubbles: true, cancelable: true, dataTransfer: data }))
        return { landed: true }
      },
      toggle: (pane: 'sidebar' | 'paperList' | 'reader' | 'inspector') => togglePane(pane),
      close: (index: number) => {
        const pane = store.row.panes[index]
        if (pane) closeContentPane(pane.id)
      },
      /** The × itself pressed, on the `index`th pane. */
      pressClose: (index: number) => {
        const node = document.querySelector<HTMLElement>(`[data-pane-id="${CSS.escape(store.row.panes[index]?.id ?? '')}"]`)
        const button = node?.querySelector<HTMLElement>('.pane-close')
        button?.click()
        return Boolean(button)
      },
      reopen: () => reopenClosedPane(),
      paneMenu: (index: number) => {
        const pane = store.row.panes[index]
        const node = pane ? document.querySelector<HTMLElement>(`[data-pane-id="${CSS.escape(pane.id)}"] .pane-menu`) : null
        if (pane && node) showPaneMenu(pane.id, node)
        return Boolean(node)
      },
      /** The «+» column pressed, as a hand presses it. */
      plusMenu: () => {
        const button = document.querySelector<HTMLElement>('.pane-plus-button')
        button?.click()
        return Boolean(button)
      },
      float: (on: boolean) => setInspectorFloating(on),
      /**
       * A drag let go of over a pane, made as the hand would make it: from a
       * sidebar row (`from: {row: <data-key>}`) or a pane's head (`from:
       * {pane: <index>}`), over the `to`th pane's `zone` — or `to: 'plus'`.
       * `hold` stops before the drop, so the zones can be photographed.
       */
      drag: (from: { row?: string; pane?: number }, to: number | 'plus', zone: 'left' | 'middle' | 'right' = 'middle', hold = false) => {
        const data = new DataTransfer()
        let source: HTMLElement | null = null
        if (from.row) {
          source = document.querySelector<HTMLElement>(`.sidebar-column .row[data-key="${CSS.escape(from.row)}"]`)
          source?.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: data }))
        } else if (from.pane !== undefined) {
          const pane = store.row.panes[from.pane]
          source = pane ? document.querySelector<HTMLElement>(`[data-pane-id="${CSS.escape(pane.id)}"] .pane-handle, [data-pane-id="${CSS.escape(pane.id)}"].pane-handle`) : null
          source?.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: data }))
        }
        if (!source || (![...data.types].includes(SHELF_DRAG_TYPE) && ![...data.types].includes(CONTENT_PANE_DRAG_TYPE))) return { dragged: false, types: [...data.types] }
        const target = to === 'plus'
          ? document.querySelector<HTMLElement>('.pane-plus')
          : document.querySelector<HTMLElement>(`[data-pane-id="${CSS.escape(store.row.panes[to]?.id ?? '')}"]`)
        if (!target) return { dragged: true, landed: false }
        const box = target.getBoundingClientRect()
        const across = zone === 'left' ? 0.1 : zone === 'right' ? 0.9 : 0.5
        const point = { clientX: box.left + box.width * across, clientY: box.top + box.height * 0.5 }
        // The innermost element at that point, as a real pointer would be over.
        const over = (document.elementFromPoint(point.clientX, point.clientY) as HTMLElement | null) ?? target
        const at = target.contains(over) ? over : target
        for (const type of ['dragenter', 'dragover']) at.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: data, ...point }))
        if (hold) return { dragged: true, landed: true, held: paneDropShown() }
        at.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: data, ...point }))
        source.dispatchEvent(new DragEvent('dragend', { bubbles: true, cancelable: true, dataTransfer: data }))
        return { dragged: true, landed: true }
      },
      /** The drag held by `drag(…, true)` let go of outside. */
      cancelDrag: () => window.dispatchEvent(new DragEvent('dragend')),
    },
    // The projects (1.1): made, changed, shown — and what the page says.
    __papertimeProjects: {
      list: () => store.projects.map((one) => ({
        id: one.project.id, name: one.project.name, status: one.project.status, root: one.root,
        deadline: one.project.deadline ?? null, todos: one.project.todos.map((todo) => `${todo.state}:${todo.title}:${todo.start ?? ''}..${todo.due ?? ''}:${todo.papers.length}`),
        milestones: one.project.milestones.map((milestone) => `${milestone.title}@${milestone.day}${milestone.done ? '✓' : ''}`),
        papers: one.project.papers.length, notes: one.project.notes.length,
      })),
      sample: () => sampleProject(),
      show: (id: string | null) => showProject(id),
      edit: (id: string, edit: ProjectEdit) => editProject(id, edit),
      view: (view: 'board' | 'timeline') => {
        store.settings.projectView = view
        changed('settings')
      },
      report: () => projectReport(),
      /** Papers dropped on whatever `selector` finds (the `index`th), the way a drag from a pane of papers lands. */
      dropPapers: (selector: string, ids: string[], index = 0) => {
        const node = document.querySelectorAll<HTMLElement>(selector)[index]
        if (!node) return false
        const data = new DataTransfer()
        data.setData(PAPER_DRAG_TYPE, ids.join('\n'))
        data.effectAllowed = 'copyMove'
        for (const type of ['dragenter', 'dragover', 'drop']) node.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: data }))
        return true
      },
      /** A card dragged to another column: the `index`th card onto the column of `state`. */
      moveCard: (index: number, state: 'todo' | 'doing' | 'done') => {
        const card = document.querySelectorAll<HTMLElement>('.pj-card')[index]
        const column = document.querySelector<HTMLElement>(`.pj-col[data-state="${state}"]`)
        if (!card || !column) return false
        const data = new DataTransfer()
        card.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: data }))
        for (const type of ['dragenter', 'dragover', 'drop']) column.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: data }))
        card.dispatchEvent(new DragEvent('dragend', { bubbles: true, cancelable: true, dataTransfer: data }))
        return true
      },
    },
    // The reading plans: made, filled, given days, spread and pushed, and
    // what the board says — from inside the page.
    __papertimePlans: {
      list: () => store.plans.map((one) => ({ id: one.plan.id, name: one.plan.name, root: one.root, order: planOrder(one.plan), sections: one.plan.sections })),
      create: (name: string, papers: string[] = []) => plans.createPlan(name, papers),
      add: (id: string, papers: string[], section: string | null = null) => plans.addToPlan(id, papers, section),
      edit: (id: string, edit: unknown) => plans.editPlan(id, edit as never, 'probe'),
      show: (id: string) => {
        setShelf({ kind: 'plan', id })
        changed('shelf')
      },
      showWeek: () => {
        setShelf({ kind: 'week' })
        changed('shelf')
      },
      showShelf: (shelf: unknown) => {
        setShelf(shelf as never)
        changed('shelf')
      },
      view: () => ({ shelf: store.shelf, view: plans.viewOf(), board: plans.boardShowing(), place: plans.boardPlaceNow() }),
      setView: (view: 'list' | 'table' | 'calendar') => plans.setView(view),
      setDay: (id: string, date: string | null) => plans.setDay(id, date),
      status: (id: string, value: 'unread' | 'reading' | 'read', lastPageIndex?: number) =>
        call('paper:state', { id, patch: { readingStatus: value, ...(lastPageIndex === undefined ? {} : { lastPageIndex }) } })
          .then((state) => { if (state) { patchPaper(id, { state }); changed('papers') } return state?.readingStatus }),
      spread: (id: string, days: number[] = [0, 2, 4], per = 1, from: 'today' | 'next' = 'today') => plans.spread(id, { days, per, from }),
      push: (id: string) => plans.pushWeek(id),
      pull: () => plans.pullBehind(),
      undo: (redo = false) => plans.undoPlan(redo),
      addLink: (id: string, url: string) => plans.addMaterial(id, url),
      addFiles: (id: string, files: string[]) => plans.addMaterialFiles(id, files),
      addAddresses: (id: string, text: string) => plans.addFromAddresses(id, text),
      remove: (id: string) => plans.deletePlan(id),
      select: (id: string) => plans.selectInBoard(id),
      /** The New Plan sheet, with a name and papers already chosen — what «Make a Plan» opens. */
      openNew: (name = '', papers: string[] = []) => plans.newPlan(papers, name),
      /** The Add Papers sheet for a plan. */
      openAdd: (id: string) => plans.addPapersTo(id),
      /** What the open plan sheet shows: its rows, which are chosen, which are already in. */
      sheet: () => {
        const sheet = document.querySelector<HTMLElement>('.plan-sheet')
        if (!sheet) return null
        return {
          title: sheet.querySelector('.fb-title')?.textContent,
          count: sheet.querySelector('.ps-count')?.textContent,
          button: [...sheet.querySelectorAll<HTMLButtonElement>('.set-foot button')].map((one) => ({ text: one.textContent, disabled: one.disabled })),
          rows: [...sheet.querySelectorAll<HTMLElement>('.ps-row')].map((row) => ({
            id: row.dataset.id,
            on: row.classList.contains('on'),
            locked: row.classList.contains('locked'),
            title: row.querySelector('.ps-title')?.textContent,
            who: row.querySelector('.ps-who')?.textContent,
          })),
          days: sheet.querySelector('.pp-spread-preview')?.textContent ?? null,
        }
      },
      setToday: (day: string) => {
        store.today = day
        changed('papers')
      },
      /** What the board and the sidebar show now. */
      report: () => ({
        today: store.today,
        shelf: store.shelf,
        view: plans.viewOf(),
        board: plans.boardShowing(),
        place: plans.boardPlaceNow(),
        columns: [...document.querySelectorAll<HTMLElement>('.plan-board .pb-thead > *')].map((one) => one.textContent),
        head: [...document.querySelectorAll<HTMLElement>('.shelf-head h2')].map((one) => one.textContent),
        rows: [...document.querySelectorAll<HTMLElement>('.plan-board .pb-row')].map((row) => ({
          id: row.dataset.id,
          title: row.querySelector('.pb-title')?.textContent,
          date: row.querySelector('.pb-date')?.textContent ?? null,
        })),
        groups: [...document.querySelectorAll('.plan-board .pb-grp')].map((one) => one.textContent),
        days: [...document.querySelectorAll<HTMLElement>('.plan-board .pb-day')].filter((day) => day.querySelector('.pb-pill')).map((day) => ({
          day: day.dataset.dropDay,
          pills: [...day.querySelectorAll('.pb-pill')].map((pill) => pill.textContent),
        })),
        stats: [...document.querySelectorAll('.plan-board .pb-stat')].map((one) => one.textContent),
        sidebar: [...document.querySelectorAll('.sidebar-column .row')].map((one) => one.textContent).filter((text) => text),
        papers: store.papers.filter((entry) => entry.schedule || entry.links).map((entry) => ({ id: entry.id, schedule: entry.schedule, links: entry.links?.length ?? 0 })),
      }),
    },
  }
  Object.assign(window, surfaces)
}
