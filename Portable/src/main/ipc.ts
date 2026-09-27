/**
 * The one channel the window is given, answered by the handlers.
 *
 * A handler that throws is said here, with the request's name, and passed on
 * so the window's caller hears it too: Electron's own rethrow carried
 * neither. A name no handler has is refused rather than answered.
 */
import { BrowserWindow, ipcMain } from 'electron'
import { CHANNEL, type RequestName } from '../shared/api.js'
import type { Handlers } from './handlers/context.js'

export function registerIPC(handlers: Handlers) {
  ipcMain.handle(CHANNEL.invoke, async (event, name: string, args: unknown) => {
    if (!Object.hasOwn(handlers, name)) throw new Error(`Unknown request: ${name}`)
    const handler = handlers[name as RequestName] as (args: unknown, sender: BrowserWindow | null) => unknown
    try {
      return await handler(args, BrowserWindow.fromWebContents(event.sender))
    } catch (error) {
      const id = args && typeof args === 'object' && 'id' in args ? ` (${String((args as { id: unknown }).id)})` : ''
      console.error(`${name}${id} -`, error)
      throw new Error(`${name}: ${(error as Error)?.message ?? String(error)}`)
    }
  })
}
