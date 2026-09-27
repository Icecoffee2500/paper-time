import type { Mark } from './marks.js'
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
export type KeptReason = 'encrypted' | 'permissions' | 'structure' | 'io'

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
  'library:reload': { args: void; result: LibrarySnapshot | { error: string } }
  /** No paths: the desktop's picker. `root`: the library to add them to. */
  'library:import': { args: { paths?: string[]; root?: string }; result: LibrarySnapshot | { error: string } }
  /** No root: the desktop's picker. */
  'library:addFolder': { args: { root?: string }; result: LibrarySnapshot | { error: string; refused?: true } }
  'library:removeFolder': { args: { root: string }; result: LibrarySnapshot | { error: string } }
  'library:revealFolder': { args: { root: string }; result: void }
  'library:adoptLoose': { args: void; result: LibrarySnapshot | { error: string } }
  'library:trash': { args: { id: string }; result: LibrarySnapshot | { error: string } }
  /** The PDF's bytes, or why there are none to read. */
  'paper:bytes': { args: { id: string }; result: PaperBytesDTO }
  /** `null` in a patch takes the key off. Answers with the record as written. */
  'paper:state': { args: { id: string; patch: Record<string, unknown> }; result: Record<string, unknown> | null }
  'paper:meta': { args: { id: string; patch: Record<string, unknown> }; result: Record<string, unknown> | null }
  'paper:rename': {
    args: { id: string; name: string }
    result: { name: string } | { error: 'empty' | 'notAName' | 'taken' | 'missing' }
  }
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
  /** Every page's marks: the file, overruled by every device's journal. */
  'marks:load': { args: { id: string }; result: Record<number, Mark[]> }
  'marks:save': { args: { id: string; pageIndex: number; marks: Mark[] }; result: void }
  'drawing:flush': {
    args: { id: string }
    /** `kept`: nothing went into the file, and everything stays in Paper Time. */
    result: { written: number } | { kept: KeptReason } | { error: string }
  }
  'collections:save': { args: { collections: unknown[] }; result: null }
  /** The sheet's «Save…»: the text it previewed, where the person says. */
  'bibtex:save': { args: { text: string }; result: { path: string } | { cancelled: true } }
  'app:about': { args: void; result: { version: string } }
  /** The words inside the papers: read ahead, search (answers come as events), stop, and — for a probe — what it cost. */
  'text:warm': { args: { ids: string[] }; result: void }
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
  /** The window's own page, as a PNG data URL, for the report sheet. */
  'feedback:capture': { args: void; result: string | null }
  'feedback:send': {
    args: {
      kind: 'bug' | 'wish'
      body: string
      name: string
      reply?: string | null
      shot?: string | null
    }
    result: { ok: boolean; url?: string; kept?: string; error?: string }
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
  /** Asks for a folder for the notes about no paper and moves them there. */
  'notes:chooseFolder': { args: void; result: { moved: number; kept: number; notesFolder: NotesFolderDTO } | { error: string } | null }
  /** The way back: the loose notes return to the app's own folder. */
  'notes:useAppFolder': { args: void; result: { moved: number; kept: number; notesFolder: NotesFolderDTO } }
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
  root: string
  /** Every folder being read, the first one first. */
  roots: string[]
  manifest: Record<string, unknown>
  collections: Record<string, unknown>
  papers: PaperRowDTO[]
  looseCount: number
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
