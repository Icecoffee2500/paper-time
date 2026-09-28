/**
 * What every handler can reach: the modules the launch script composed.
 *
 * A handler file exports a `Partial<Handlers>` built from this; `main.ts`
 * spreads them into one `Handlers`, which the compiler checks for
 * completeness against `shared/api.ts`.
 */
import type { MetadataQueue } from '../metadata/queue.js'
import type { Updates } from '../updates.js'
import type { MenuState } from '../../shared/api.js'
import type { BrowserWindow } from 'electron'
import type { LibrarySnapshot, RequestArgs, RequestName, RequestResult } from '../../shared/api.js'
import type { LibrarySet } from '../libraries.js'
import type { FolderSync } from '../folderSync.js'
import type { PDFFlusher } from '../pdfFlush.js'
import type { Journals } from '../journal.js'
import type { Records } from '../records.js'
import type { TextBridge } from '../textBridge.js'
import type { SemanticSearch } from '../semantic.js'
import type { NotesStore } from '../slipBox.js'
import type { Windows } from '../windows.js'
import type { PageCounter } from '../pdfBytes.js'

export type Handlers = {
  [K in RequestName]: (args: RequestArgs<K>, sender: BrowserWindow | null) => RequestResult<K> | Promise<RequestResult<K>>
}

export interface Context {
  libraries: LibrarySet
  sync: FolderSync
  flush: PDFFlusher
  journals: Journals
  records: Records
  text: TextBridge
  semantic: () => SemanticSearch
  notes: () => NotesStore
  windows: Windows
  pageCounter: PageCounter
  /** Papers looked up at the registrars, one after another (`metadata/queue.ts`). */
  metadata: MetadataQueue
  /** Whether there is a newer version, and installing it on Windows (`updates.ts`). */
  updates: Updates
  /** Whether this run is a probe, which reads a folder of its own and remembers nothing. */
  isProbe: boolean
  /** The folder a probe was told to open, or null. */
  probeLibrary: string | null
  /** Reads the folders and says what is in them; `refused` is one press of «add the loose PDFs». */
  snapshot: (refused?: string[]) => Promise<LibrarySnapshot | { error: string }>
  /** Opens the first folder (and the ones remembered beside it) and re-arms the watchers. */
  openLibrary: (root: string) => Promise<LibrarySnapshot | { error: string }>
  /** The window in front says what it shows: the menu bar follows. */
  menuStateChanged: (state: MenuState) => void
  /** The reader chose another language: the menu and the windows are made again in it. */
  languageChanged: () => void
  /** The keys changed: the menu is built again with them. */
  shortcutsChanged: () => void
  /** The slip-box's note sources changed: search by meaning catches up. */
  notesChanged: (saved: { id: string; title: string; body: string; paperID: string | null } | null, removed?: string) => void
}
