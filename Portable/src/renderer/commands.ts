/**
 * Every command a menu item, a key or the palette can ask for, in one table —
 * and what the main process says unasked.
 *
 * The menu's commands and the keyboard's (`shared/shortcuts.ts`) are names;
 * each name is a row here. A name with no row used to fall to a toast saying
 * the command was not in this build, which is how Ctrl+N and Ctrl+L went
 * dead; `src/test/commands.ts` now reads the menu and the shortcut list and
 * fails when one of their names has no row.
 */
import { copyText } from './ui/clipboard.js'
import { call, onEvent } from './bridge.js'
import { changed, shelfPapers, store } from './state.js'
import { solo } from './shell.js'
import { focused, readers } from './pageArea.js'
import {
  closeWindowOrPane,
  goBack,
  goForward,
  openInWindow,
  showOpenPapersPopup,
  showPagesPopup,
  stepPaper,
} from './actions/openPapers.js'
import { copyKey } from './actions/paper.js'
import { linkSelectionToNote, newNote } from './actions/notes.js'
import { openFind, openSearch } from './actions/search.js'
import { addLibraryFolder, addPapers, libraryOpened, reload } from './library.js'
import { applyTheme, openSettings, setLayout } from './settingsController.js'
import { toggleFocus, togglePane } from './layout.js'
import { couldNot } from './notices.js'
import { handleTextEvent } from './textSearch.js'
import { handleMeaningEvent } from './meaningSearch.js'
import { showFeedback } from './ui/feedback.js'
import { showExportSheet } from './ui/exportSheet.js'
import { shell } from './shell.js'
import { toast } from './ui/toolbar.js'
import { L } from '../shared/lang.js'

const selectFirst = () => toast(L('먼저 글을 골라주세요.', 'Select some text first.'))

export const COMMANDS = {
  settings: () => openSettings(),
  addPapers: () => void addPapers(),
  refreshFolder: () => void reload(),
  addFolder: () => void addLibraryFolder(),
  searchEverything: () => openSearch(),
  findInDocument: () => openFind(),
  sidebar: () => togglePane('sidebar'),
  paperList: () => togglePane('paperList'),
  reader: () => togglePane('reader'),
  inspector: () => togglePane('inspector'),
  focus: () => toggleFocus(),
  back: () => goBack(),
  forward: () => goForward(),
  zoomIn: () => focused()?.zoomBy(1.15),
  zoomOut: () => focused()?.zoomBy(1 / 1.15),
  actualSize: () => focused()?.setZoom(1),
  draw: () => {
    const reader = focused()
    if (!reader) return
    reader.setDrawing(!reader.state.drawing)
    reader.update()
    changed('sketch')
  },
  highlight: () => { if (!focused()?.markSelection('highlight')) selectFirst() },
  underline: () => { if (!focused()?.markSelection('underline')) selectFirst() },
  exportBibTeX: () => exportBibTeX(),
  copyCitationKey: () => { if (store.selectedID) void copyKey(store.selectedID) },
  layoutContinuous: () => setLayout('continuous'),
  layoutSinglePage: () => setLayout('single'),
  layoutBook: () => setLayout('book'),
  openPapers: () => showOpenPapersPopup(),
  pages: () => showPagesPopup(),
  openInNewWindow: () => { if (store.selectedID && !solo) openInWindow(store.selectedID) },
  closeWindow: () => closeWindowOrPane(),
  newNote: () => newNote(),
  linkToNote: () => linkSelectionToNote(),
  nextPage: () => focused()?.turnPage(1),
  previousPage: () => focused()?.turnPage(-1),
  nextPaper: () => stepPaper(1),
  previousPaper: () => stepPaper(-1),
  feedback: () => void showFeedback(),
} satisfies Record<string, () => void>

export type Command = keyof typeof COMMANDS

export function runCommand(command: string) {
  const run = (COMMANDS as Record<string, (() => void) | undefined>)[command]
  if (run) return run()
  toast(L(`“${command}”은 아직 이 빌드에 없어요.`, `“${command}” is not in this build yet.`))
}

/** The Mac's export sheet: the scope, the options, the file previewed. */
function exportBibTeX() {
  showExportSheet({
    view: () => shelfPapers(),
    copy: (text) => {
      void copyText(text).then((copied) => toast(copied
        ? L('BibTeX를 복사했어요', 'BibTeX copied')
        : L('복사하지 못했어요', "Paper Time couldn't copy that.")))
    },
    save: async (text) => {
      const result = await call('bibtex:save', { text })
      if (!('path' in result)) return false
      toast(L('BibTeX를 저장했어요', 'BibTeX saved'))
      return true
    },
  })
}

/** What the main process says unasked. */
export function installMainEvents() {
  onEvent((event, payload) => {
    switch (event) {
      case 'text:hits':
      case 'text:done':
      case 'text:warmed':
        handleTextEvent(event, payload)
        break
      case 'semantic:progress':
      case 'semantic:ready':
        handleMeaningEvent(event, payload)
        break
      case 'menu:feedback':
        void showFeedback()
        break
      case 'library:changed':
        void reload()
        break
      case 'library:opened':
        libraryOpened(payload as never)
        break
      case 'paper:changed': {
        // Another window wrote this paper's record: read it with the rest.
        // Its sidecars — marks, ink, drawings — are the reader's (WR10).
        const { layers } = payload as { id: string; layers: string[] }
        if (layers.includes('record')) void reload()
        break
      }
      case 'window:state':
        store.windowState = payload as typeof store.windowState
        shell.toolbar.update()
        break
      case 'theme:changed':
        if (store.settings.appearance === 'system') applyTheme()
        break
      case 'paper:saved': {
        const { id } = payload as { id: string }
        readers.get(id)?.noteKept(null)
        break
      }
      case 'paper:kept': {
        // What was made here is in Paper Time and not in the file. The reader
        // for that paper says so, once, where it says the page and the zoom;
        // no reason means there is nothing left to say it about.
        const { id, reason } = payload as { id: string; reason: never }
        readers.get(id)?.noteKept(reason)
        break
      }
      case 'menu':
        runCommand(String(payload))
        break
      case 'error':
        couldNot('finish', payload)
        break
    }
  })
}
