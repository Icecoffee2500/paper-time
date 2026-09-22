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
  'drawing:flush': { args: { id: string }; result: { written: number } | { error: string } }
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
