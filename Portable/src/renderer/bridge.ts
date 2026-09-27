import { setKorean } from '../shared/lang.js'

/** The typed side of the one channel the window is given. */
declare global {
  interface Window {
    papertime: {
      invoke: (name: string, args?: unknown) => Promise<unknown>
      on: (handler: (event: string, payload: unknown) => void) => () => void
      platform: string
      korean: boolean
      /** Set when this window shows one paper on its own. */
      paper: string | null
      flags: { split: boolean }
      /** Where a dropped file is on disk, or '' when it has no path. */
      pathForFile: (file: File) => string
    }
  }
}

export const platform = window.papertime.platform
/** The paper this window is for, when it is a window for one paper. */
export const soloPaperID: string | null = window.papertime.paper ?? null
export const flags = window.papertime.flags ?? { split: false }

// Before anything draws: the main process already decided, and every string
// below this line reads the answer — and so does the document, which said
// `lang="ko"` in any language (hyphenation, the screen reader's voice).
setKorean(window.papertime.korean)
document.documentElement.lang = window.papertime.korean ? 'ko' : 'en'

/** A request the main process answered by throwing, with which one it was. */
export class BridgeError extends Error {
  constructor(public request: string, message: string) {
    super(message)
    this.name = 'BridgeError'
  }
}

export function call<T = unknown>(name: string, args?: unknown): Promise<T> {
  return (window.papertime.invoke(name, args) as Promise<T>).catch((error: unknown) => {
    // Electron wraps the main process's message in its own sentence about
    // the channel; what is left is `<request>: <why>`, logged here once.
    const message = String((error as Error)?.message ?? error)
      .replace(/^Error invoking remote method '[^']*': (Error: )?/, '')
    console.error(`${name} -`, message)
    throw new BridgeError(name, message)
  })
}

export function onEvent(handler: (event: string, payload: unknown) => void) {
  return window.papertime.on(handler)
}

/** The paths behind dropped files, in the order they were dropped. */
export function droppedPaths(list: FileList | null | undefined): string[] {
  return [...(list ?? [])]
    .map((file) => window.papertime.pathForFile?.(file) ?? '')
    .filter((path) => path.length > 0)
}

/** The modifier this desktop uses, for anything drawn rather than in a menu. */
export const COMMAND_KEY = platform === 'darwin' ? 'metaKey' : 'ctrlKey'

export function isCommand(event: KeyboardEvent | MouseEvent): boolean {
  return platform === 'darwin' ? event.metaKey : event.ctrlKey
}

export const COMMAND_SYMBOL = platform === 'darwin' ? '⌘' : 'Ctrl+'
