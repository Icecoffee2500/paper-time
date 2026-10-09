import type { UpdateState } from './updates.js'
import type { Mark } from './marks.js'
import type { Glyph, Rule } from './mathReader/glyph.js'
import type { PDFLock, ByteTrouble } from './pdfLock.js'
import type { Settings } from './appSettings.js'

export type { Settings } from './appSettings.js'

/** The names on the bridge between the window and the process that owns the
 *  files. Kept in one place so both ends refer to the same strings. */
export const CHANNEL = {
  invoke: 'papertime:invoke',
  event: 'papertime:event',
} as const

export interface WindowBounds {
  x: number
  y: number
  width: number
  height: number
}

/**
 * Why what was made here stays out of the file: the PDF cannot be unlocked
 * with what this build knows (`encrypted`), forbids annotations
 * (`permissions`), or cannot be read without guessing at its structure
 * (`structure`). The writer never rewrites a file to get around any of them.
 */
/** Why marks are not in the file: the file refuses them, or (`io`) it could not be written just now. */
export type KeptReason = 'encrypted' | 'permissions' | 'structure' | 'unconfirmed' | 'io'

/** What the menu bar reflects of the window in front. */
export interface MenuState {
  panes: { sidebar: boolean; paperList: boolean; reader: boolean; inspector: boolean }
  focus: boolean
  hasPaper: boolean
  layout: 'continuous' | 'single' | 'book'
}

/** Where the file stands with what was made here: waiting to be written, being written, or written. */
export type SaveState = 'pending' | 'saving' | 'idle'

export interface WindowState {
  maximized: boolean
  fullScreen: boolean
  focused: boolean
}

/** What the window can ask the file-owning process to do. */
export interface Requests {
  /** The settings, with the library that is open now (a probe's own). */
  'settings:get': { args: void; result: Settings }
  /** Only the keys the file has, of the kinds they hold (`acceptedPatch`). */
  'settings:set': { args: Partial<Settings>; result: Settings }
  'library:choose': { args: void; result: string | null }
  /** `refused`: the folder was not opened — nothing changed, and `error` says why in the app's voice. */
  'library:open': { args: { root: string }; result: LibrarySnapshot | { error: string; refused?: true } }
  /** `unavailable`: the folder in the settings is not there — a disk not
   *  plugged in, a cloud drive not mounted yet — and which folder it was. */
  'library:reload': { args: void; result: LibrarySnapshot | { error: string; unavailable?: string } }
  /** Folders this machine already syncs, for the first-run screen, and the
   *  libraries opened before that are still there. */
  /** Whether a dropped path is a folder — one to open as a library. */
  'path:isFolder': { args: { path: string }; result: boolean }
  'library:suggestions': { args: void; result: { suggested: { path: string; provider: string }[]; recent: string[] } }
  /** No paths: the desktop's picker. `root`: the library to add them to. */
  'library:import': { args: { paths?: string[]; root?: string }; result: LibrarySnapshot | { error: string } }
  /** No root: the desktop's picker. */
  'library:addFolder': { args: { root?: string }; result: LibrarySnapshot | { error: string; refused?: true } }
  'library:removeFolder': { args: { root: string }; result: LibrarySnapshot | { error: string } }
  'library:revealFolder': { args: { root: string }; result: void }
  'library:adoptLoose': { args: void; result: LibrarySnapshot | { error: string } }
  'library:trash': { args: { id: string }; result: LibrarySnapshot | { error: string } }
  /** The PDF's bytes, or why there are none to read. */
  /** One page's glyphs and rules as the Mac's scanner reads them (`MathScanner`), and what the paper's other first pages say about where it keeps its variables — Ultracopy and ⌘L read the mathematics from them. Null when the file cannot be read. */
  'math:page': { args: { id: string; pageIndex: number }; result: { glyphs: Glyph[]; rules: Rule[]; cropBox: { x: number; y: number; width: number; height: number }; italicElsewhere: { ownLetters: boolean; evidence: boolean } } | null }
  'paper:bytes': { args: { id: string }; result: PaperBytesDTO }
  /** The formula lasso's last resort: the rectangle of the page as a picture — the model's normalised 3×384×384 tensor (`shared/formulaOCRInput.ts`) — read by the formula OCR model (`ocrWorker.ts`). `latex` is wrapped as Ultracopy wraps a displayed formula; null when nothing was read. */
  'ocr:read': { args: { pixels: Float32Array | number[] }; result: { latex: string; tokens: number; seconds: number } | null }
  /** Whether the model files are with this build. */
  'ocr:available': { args: void; result: boolean }
  /** `null` in a patch takes the key off. Answers with the record as written. */
  'paper:state': { args: { id: string; patch: Record<string, unknown> }; result: Record<string, unknown> | null }
  /** `stamp: false`: written without `updatedAt`/`updatedBy` — the app's own guess, not the reader's edit. */
  'paper:meta': { args: { id: string; patch: Record<string, unknown>; stamp?: boolean }; result: Record<string, unknown> | null }
  /** «Re-run Metadata»: these papers looked up again (never a record somebody edited by hand). */
  'metadata:resolve': { args: { ids: string[] }; result: void }
  /** What these papers look like — paper, book, lecture, document — read off the files, nothing looked up. */
  'metadata:guess': { args: { ids: string[] }; result: void }
  /** «Resolve Missing Metadata»: every paper not yet confirmed; how many were queued. */
  'metadata:resolvePending': { args: void; result: number }
  /** The papers being looked up now, for a window that just opened. */
  'metadata:resolving': { args: void; result: string[] }
  'paper:rename': {
    args: { id: string; name: string }
    result: { name: string } | { error: 'empty' | 'notAName' | 'taken' | 'missing' | 'busy' }
  }
  /** Where the file stands against the one imported (`FileProvenance`). */
  'paper:provenance': { args: { id: string }; result: 'pristine' | 'appended' | 'rewritten' | 'unknown' }
  /** What is on the clipboard, for «Paste Names». */
  'clipboard:read': { args: void; result: string }
  /** A drawing copied: kept by the main process for every window, and the
   *  system clipboard given its words (or emptied), as the Mac's pasteboard
   *  takes a private type and plain text. */
  /** The font families this machine has, as the desktop lists them (`NSFontManager`); empty where it cannot say. */
  'fonts:list': { args: void; result: string[] }
  'clipboard:writeSketch': { args: { clipping: string; text: string }; result: void }
  /** The drawing on the clipboard, if what is on the system clipboard is still what went with it. */
  'clipboard:readSketch': { args: void; result: string | null }
  'paper:reveal': { args: { id: string }; result: void }
  'sketch:load': { args: { id: string; pageIndex: number }; result: unknown[] | null }
  'sketch:save': { args: { id: string; pageIndex: number; elements: unknown[] }; result: void }
  'ink:load': { args: { id: string; pageIndex: number }; result: unknown[] | null }
  'ink:save': { args: { id: string; pageIndex: number; strokes: unknown[] }; result: void }
  'drawing:pages': { args: { id: string }; result: { sketch: number[]; ink: number[]; appleInk: number[] } }
  /** What the file holds on pages this machine has no sidecar for, and which pages would not be read. */
  'drawing:adoptFromFile': {
    args: { id: string }
    result: { pages: Record<number, { elements: unknown[]; strokes: unknown[] }>; unreadable: number[] }
  }
  /** Every drawn page's shapes and strokes — this machine's sidecar, or the file's copy. */
  'drawing:loadAll': {
    args: { id: string }
    result: { pages: Record<number, { elements: unknown[]; strokes: unknown[] }>; unreadable: number[]; foreignInk: boolean }
  }
  /** Every page's marks: the file, overruled by every device's journal. */
  'marks:load': { args: { id: string }; result: Record<number, Mark[]> }
  /** One page's marks as the window now has them, `before` as it had them —
   *  the window's own change, which is what goes into the journal — and the
   *  identifiers still on its other pages, which a move is not a removal of. */
  'marks:save': { args: { id: string; pageIndex: number; marks: Mark[]; before: Mark[]; elsewhere: string[] }; result: void }
  'drawing:flush': {
    args: { id: string }
    /** `kept`: nothing went into the file, and everything stays in Paper Time. */
    result: { written: number } | { kept: KeptReason } | { error: string }
  }
  /** `root`: the library a new collection goes into — the one being looked at. */
  'collections:save': { args: { collections: unknown[]; root?: string }; result: null }
  /** The sheet's «Save…»: the text it previewed, where the person says. */
  'bibtex:save': { args: { text: string }; result: { path: string } | { cancelled: true } }
  /** The version, and whether a probe asked for What's New (`--papertime-whats-new=1`, never marked seen). */
  'app:about': { args: void; result: { version: string; whatsNew?: boolean } }
  /** A newer version: what the notice shows, a look now (Settings' «Check Now»), and its buttons (`main/updates.ts`). */
  'update:state': { args: void; result: UpdateState }
  'update:check': { args: { userInitiated: boolean }; result: void }
  'update:act': { args: { action: 'install' | 'later' | 'skip' | 'hideBar' | 'showChanges' | 'closeSheet' }; result: void }
  /** The words inside the papers: read ahead, search (answers come as events), stop, and — for a probe — what it cost. */
  'text:warm': { args: { ids: string[] }; result: void }
  'text:warm-cancel': { args: void; result: void }
  'text:search': {
    args: { token: number; query: string; ids: string[]; titles: Record<string, string>; limit?: number }
    result: void
  }
  'text:cancel': { args: { token: number }; result: void }
  'text:stats': { args: void; result: unknown }
  'window:minimize': { args: void; result: void }
  'window:toggleMaximize': { args: void; result: void }
  'window:close': { args: void; result: void }
  'window:state': { args: void; result: WindowState }
  /** Every window of ours, in screen points — to tell a drag out from a drop. */
  'window:bounds': { args: void; result: WindowBounds[] }
  /** A window of its own for one paper, put at the point when there is one. */
  'paper:openWindow': { args: { id: string; x?: number; y?: number }; result: void }
  'shell:openExternal': { args: { url: string }; result: void }
  /** Words onto the clipboard, for when the page's own clipboard is refused. */
  'clipboard:write': { args: { text: string }; result: void }
  /** What the window in front shows, for the menu bar's words and greyed items. */
  'menu:state': { args: MenuState; result: void }
  /** The desktop's accent colour as `#rrggbb`, where it has one (macOS, Windows). */
  'theme:accent': { args: void; result: string | null }
  /** The window's own page, as a PNG data URL, for the report sheet. */
  'feedback:capture': { args: void; result: string | null }
  /** Exactly what a report carries beside its words, as rows the sheet
   *  lists — and whether the last run ended in a crash. */
  'feedback:diagnostics': { args: void; result: { rows: [string, string][]; crashed: boolean } }
  'feedback:send': {
    args: {
      kind: 'bug' | 'wish'
      body: string
      name: string
      reply?: string | null
      shot?: string | null
    }
    /** `number` is the issue's, for the page to find the name by. */
    result: { ok: boolean; url?: string; number?: number; kept?: string; error?: string }
  }
  /**
   * Search by meaning: the passages closest to what was typed, best first —
   * at most `k`, at most three from one paper, none at a place in `shown`
   * (`"paperID#page"`, the exact search's). `ready` false means the index is
   * not built, or the switch is off, and the palette shows no section.
   */
  'semantic:search': {
    args: { query: string; k?: number; shown?: string[] }
    result: { hits: MeaningHitDTO[]; ms: number; ready: boolean }
  }
  'semantic:status': { args: void; result: SemanticStatusDTO }
  /** The slip-box: every note in every open folder, and the loose ones. */
  'notes:load': { args: void; result: { notes: NoteDTO[]; notesFolder: NotesFolderDTO } }
  /** Writes a note into its box; an empty note takes its file away. Answers with the box it went to. */
  'notes:save': { args: { note: NoteDTO }; result: NoteDTO }
  'notes:delete': { args: { id: string }; result: void }
  /** The note's ⋯ «Export as PDF…»: the document the window built, printed where the person says. */
  /** `to`: a probe's file, written without asking — in a probe run only. */
  'notes:exportPDF': { args: { title: string; html: string; to?: string }; result: { path: string } | { cancelled: true } | { error: string } }
  /** Asks for a folder for the notes about no paper and moves them there. */
  'notes:chooseFolder': { args: void; result: { moved: number; kept: number; notesFolder: NotesFolderDTO } | { error: string } | null }
  /** The way back: the loose notes return to the app's own folder. */
  'notes:useAppFolder': { args: void; result: { moved: number; kept: number; notesFolder: NotesFolderDTO } }
  /** The chosen folder looked for again — a disk plugged back in — and the
   *  notes written meanwhile carried into it; null while it is still away. */
  'notes:reconnect': { args: void; result: { moved: number; kept: number; notesFolder: NotesFolderDTO } | null }
  /** The notes' folder in the desktop's file manager: the chosen one, or the
   *  app's own while the chosen one is away. */
  'notes:reveal': { args: void; result: void }
  /** The chosen folder, back while the app is open: the notes that fell back
   *  meanwhile go across now (`NotesModel.comeBack`); null when nothing moved. */
  'notes:comeBack': { args: void; result: { moved: number; kept: number; notesFolder: NotesFolderDTO } | null }
  /** For a probe: builds now and waits. */
  'semantic:build': { args: void; result: { status: SemanticStatusDTO; stats: unknown; unread: string[] } }
}

export interface MeaningHitDTO {
  /** For a note, `paperID` is `note:<id>` — see `note`. */
  passage: { paperID: string; pageIndex: number; location: number; length: number }
  snippet: string
  score: number
  /** Which note the passage is in, when it is in one: its id (the paper's), the paper, and its title. */
  note?: { id: string; paperID: string | null; title: string }
}

/** One note of the slip-box, as it crosses to the window — `shared/zettel.ts` with the box it is in. */
export interface NoteDTO {
  id: string
  kind: 'note' | 'map' | 'draft'
  title: string
  body: string
  /** The paper it was written against, an upper-case UUID, or null. */
  paperID: string | null
  /** Milliseconds since 1970: a Date does not cross the bridge. */
  created: number
  modified: number
  /** The box it was read from and goes back to: a library's root, or the loose folder. */
  box: string
}

/** Where the notes about no paper live. */
export interface NotesFolderDTO {
  /** The folder they are read from and written to now. */
  loose: string
  /** Whether that is a folder the reader chose rather than the app's own. */
  chosen: boolean
  /** The folder the reader chose, whether or not it can be reached. */
  chosenPath: string | null
  appFolder: string
  /** The chosen folder cannot be reached: notes go to the app's own meanwhile. */
  away: boolean
  /** Folders a move left notes in, because a name was taken where they were going. */
  leftBehind: string[]
  /** What the last move made without being asked did — at launch, or when the chosen folder came back. */
  lastMove?: { moved: number; kept: number } | null
}

export interface SemanticStatusDTO {
  enabled: boolean
  ready: boolean
  passages: number
  /** How many notes are in the index, and how many passages they cut to. */
  notes: number
  notePassages: number
  progress: { done: number; total: number } | null
}

export type RequestName = keyof Requests
export type RequestArgs<K extends RequestName> = Requests[K]['args']
export type RequestResult<K extends RequestName> = Requests[K]['result']

/**
 * What the main process tells every window, unasked.
 *
 * `library:changed` — the folders changed and the window should read again.
 * `paper:changed` — one paper's record or sidecars changed (another window,
 * or another machine through the cloud); `layers` says which.
 * `notes:changed` — a note was written or removed in another window.
 */
export interface Events {
  'library:changed': void
  /** «Add n PDFs» under way: how many are left, every twenty-five. */
  'library:adopting': { remaining: number }
  'library:opened': LibrarySnapshot | { error: string }
  'paper:changed': { id: string; layers: string[] }
  'paper:saved': { id: string }
  /** The papers being looked up now, gathered to one message a quarter second. */
  'metadata:resolving': { ids: string[] }
  /** The update notice changed (`main/updates.ts`). */
  'update:state': UpdateState
  'paper:kept': { id: string; reason: KeptReason | null }
  'paper:saveState': { id: string; state: SaveState }
  'settings:changed': Record<string, unknown>
  'notes:changed': { id: string }
  'window:state': WindowState
  'theme:changed': boolean
  'menu': string
  'menu:feedback': void
  'error': unknown
  'semantic:progress': unknown
  'semantic:ready': unknown
  'text:warmed': unknown
  'text:hits': unknown
  'text:done': unknown
}

/** What `paper:bytes` answers. */
export interface PaperBytesDTO {
  data?: Uint8Array
  error?: string
  locked?: PDFLock
  trouble?: ByteTrouble | null
  size?: number
  head?: string
  line?: string | null
}

export interface PaperRowDTO {
  id: string
  meta: Record<string, unknown>
  state: Record<string, unknown>
  exists: boolean
  /** The folder it came from. */
  root?: string
}

export interface LibrarySnapshot {
  /** What an «Add PDFs» did, when this snapshot answers one: new papers,
   *  PDFs the library already had, and the files that would not be read. */
  imported?: { added: number; duplicates: number; refused: string[] }
  root: string
  /** Every folder being read, the first one first. */
  roots: string[]
  manifest: Record<string, unknown>
  collections: Record<string, unknown>
  papers: PaperRowDTO[]
  looseCount: number
  /** Every folder under every root as the disk has them, `/`-spelt, the
   *  empty ones too — the tree, beside what the papers say. */
  folders?: string[]
  /**
   * PDFs the last "add the loose PDFs" could not take in, by name.
   *
   * A press that leaves the count where it was has to say why. Reading a PDF
   * can fail — a cloud file that has not come down, a file whose permissions
   * changed — and a button that answers a failure with silence is a button
   * people press again.
   */
  refused: string[]
  /**
   * Records the folders hold and this read could not get at — a file still
   * coming down a streamed drive, or one that arrived half written. One
   * sentence each, naming the record.
   *
   * A list and not a silence: before this, one such file took every paper with
   * it and the window showed an empty library with nothing to say. The names
   * matter as much as the count, because a record that is late comes good on
   * its own and a record that is broken has to be found.
   */
  unreadable?: string[]
  /** The slip-box, read with the folders: every note, and where the loose ones live. */
  notes?: NoteDTO[]
  notesFolder?: NotesFolderDTO
}
