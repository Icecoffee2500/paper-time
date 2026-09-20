/** The typed side of the one channel the window is given. */
declare global {
  interface Window {
    papertime: {
      invoke: (name: string, args?: unknown) => Promise<unknown>
      on: (handler: (event: string, payload: unknown) => void) => () => void
      platform: string
    }
  }
}

export const platform = window.papertime.platform

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
