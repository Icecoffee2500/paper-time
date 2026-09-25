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
export type KeptReason = 'encrypted' | 'permissions' | 'structure'

export interface WindowState {
  maximized: boolean
  fullScreen: boolean
  focused: boolean
}

/** What the window can ask the file-owning process to do. */
export interface Requests {
  'settings:get': { args: void; result: unknown }
  'settings:set': { args: Record<string, unknown>; result: unknown }
  'library:choose': { args: void; result: string | null }
  'library:open': { args: { root: string }; result: LibrarySnapshot | { error: string } }
  'library:reload': { args: void; result: LibrarySnapshot | { error: string } }
  'library:import': { args: { paths?: string[] }; result: LibrarySnapshot | { error: string } }
  'library:adoptLoose': { args: void; result: LibrarySnapshot | { error: string } }
  'library:trash': { args: { id: string }; result: LibrarySnapshot }
  'paper:bytes': { args: { id: string }; result: { data: Uint8Array } | { error: string } }
  'paper:state': { args: { id: string; patch: Record<string, unknown> }; result: unknown }
  'paper:meta': { args: { id: string; patch: Record<string, unknown> }; result: unknown }
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
  'drawing:adoptFromFile': { args: { id: string }; result: Record<number, { elements: unknown[]; strokes: unknown[] }> }
  'drawing:flush': {
    args: { id: string }
    /** `kept`: nothing went into the file, and everything stays in Paper Time. */
    result: { written: number } | { kept: KeptReason } | { error: string }
  }
  'collections:save': { args: { collections: unknown[] }; result: unknown }
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
  /** For a probe: builds now and waits. */
  'semantic:build': { args: void; result: { status: SemanticStatusDTO; stats: unknown; unread: string[] } }
}

export interface MeaningHitDTO {
  passage: { paperID: string; pageIndex: number; location: number; length: number }
  snippet: string
  score: number
}

export interface SemanticStatusDTO {
  enabled: boolean
  ready: boolean
  passages: number
  progress: { done: number; total: number } | null
}

export type RequestName = keyof Requests

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
}
