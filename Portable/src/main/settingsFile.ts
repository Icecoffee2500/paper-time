/**
 * The settings file's shape and how a file on disk is read into it — apart
 * from `settings.ts` so the reading can be tested without Electron.
 */
import { DEFAULT_TINT_COLOR, pageTintFrom, tintColorFrom, type PageTint } from '../shared/pageTint.js'

export interface Settings {
  libraryRoot: string | null
  /** Folders opened beside the first one, in the order they were added. */
  extraRoots: string[]
  recentLibraries: string[]
  window: { width: number; height: number; x?: number; y?: number; maximized?: boolean }
  panes: { sidebar: boolean; paperList: boolean; reader: boolean; inspector: boolean }
  columns: { sidebar: number; paperList: number; inspector: number }
  inspectorTab: 'details' | 'marks' | 'note'
  sort: { field: 'title' | 'author' | 'year' | 'added' | 'opened'; ascending: boolean }
  /** 'system' follows the desktop; the other two are the reader's choice. */
  appearance: 'system' | 'light' | 'dark'
  /** Same shape as `appearance`: the desktop's locale, or the reader's word. */
  language: 'system' | 'ko' | 'en'
  /** A ground for the page and how the paper is drawn on it — the Mac's
   *  model (`shared/pageTint.ts`). */
  pageTint: PageTint
  /** The custom tint's ground, `#rrggbb`. */
  pageTintColor: string
  pageLayout: 'single' | 'continuous' | 'book'
  selectedPaperID: string | null
  /** Latex Suite's shortcuts in the note and on the cards. On unless turned off. */
  latexShortcuts: boolean
  /** Search by meaning in the palette, and the index it needs. On unless turned off. */
  semanticSearch: boolean
  /** What stands under a title in the list — the Mac's `listSubtitleFields`. */
  listSubtitle: string
  /** «Protect Case in Titles» for the `.bib`. On unless turned off. */
  bibtexProtectCase: boolean
  /** The folder the notes about no paper live in, when the reader chose one — the Mac's «Loose Notes» folder. */
  notesFolder: string | null
}

export const DEFAULTS: Settings = {
  libraryRoot: null,
  extraRoots: [],
  recentLibraries: [],
  window: { width: 1440, height: 900 },
  panes: { sidebar: true, paperList: true, reader: true, inspector: true },
  columns: { sidebar: 240, paperList: 320, inspector: 320 },
  inspectorTab: 'details',
  sort: { field: 'added', ascending: false },
  appearance: 'system',
  language: 'system',
  pageTint: 'none',
  pageTintColor: DEFAULT_TINT_COLOR,
  pageLayout: 'continuous',
  selectedPaperID: null,
  latexShortcuts: true,
  semanticSearch: true,
  listSubtitle: 'authors,year,venue',
  bibtexProtectCase: true,
  notesFolder: null,
}

/** What the file says, over the defaults, each group merged key by key. */
export function fromFile(raw: Partial<Settings>): Settings {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('settings.json is not an object')
  return {
    ...DEFAULTS,
    ...raw,
    extraRoots: Array.isArray(raw.extraRoots) ? raw.extraRoots.filter((one) => typeof one === 'string') : [],
    recentLibraries: Array.isArray(raw.recentLibraries) ? raw.recentLibraries.filter((one) => typeof one === 'string') : [],
    libraryRoot: typeof raw.libraryRoot === 'string' ? raw.libraryRoot : null,
    window: { ...DEFAULTS.window, ...raw.window },
    panes: { ...DEFAULTS.panes, ...raw.panes },
    columns: { ...DEFAULTS.columns, ...raw.columns },
    sort: { ...DEFAULTS.sort, ...raw.sort },
    // The old four washes under their new names: «grey» was a paler white
    // and is Paper White now, «night» a blue-grey multiplied over black
    // words and is Dimmed. Read that way rather than rewritten, so the file
    // changes only when somebody next changes a setting.
    pageTint: pageTintFrom(raw.pageTint),
    pageTintColor: tintColorFrom(raw.pageTintColor),
  }
}

