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
    }
  }
}

export const platform = window.papertime.platform
/** The paper this window is for, when it is a window for one paper. */
export const soloPaperID: string | null = window.papertime.paper ?? null
export const flags = window.papertime.flags ?? { split: false }

// Before anything draws: the main process already decided, and every string
// below this line reads the answer.
setKorean(window.papertime.korean)

export function call<T = unknown>(name: string, args?: unknown): Promise<T> {
  return window.papertime.invoke(name, args) as Promise<T>
}

export function onEvent(handler: (event: string, payload: unknown) => void) {
  return window.papertime.on(handler)
}

/** The modifier this desktop uses, for anything drawn rather than in a menu. */
export const COMMAND_KEY = platform === 'darwin' ? 'metaKey' : 'ctrlKey'

export function isCommand(event: KeyboardEvent | MouseEvent): boolean {
  return platform === 'darwin' ? event.metaKey : event.ctrlKey
}

export const COMMAND_SYMBOL = platform === 'darwin' ? '⌘' : 'Ctrl+'
