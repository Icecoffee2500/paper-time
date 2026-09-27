/** The window's frame, the outside world, the report sheet, About. */
import { app, clipboard, shell, systemPreferences } from 'electron'
import { isOpenableLink } from '../../shared/readerMath.js'
import { providerOf } from '../../shared/cloudProvider.js'
import { settings } from '../settings.js'
import { capture as captureWindow, send as sendFeedback } from '../feedback.js'
import type { Context, Handlers } from './context.js'

export function windowHandlers(ctx: Context): Partial<Handlers> {
  const { windows, libraries } = ctx
  const target = (sender: Parameters<Handlers['window:close']>[1]) => sender ?? windows.main

  return {
    'window:minimize': (_args, sender) => target(sender)?.minimize(),
    'window:toggleMaximize': (_args, sender) => {
      const one = target(sender)
      if (one?.isMaximized()) one.unmaximize()
      else one?.maximize()
    },
    'window:close': (_args, sender) => target(sender)?.close(),
    'window:state': (_args, sender) => windows.state(target(sender)),
    'window:bounds': () => windows.allBounds(),

    // Only the web's two schemes and mail — a link in a paper is written by
    // whoever wrote the paper (`isOpenableLink`).
    'shell:openExternal': ({ url }) => {
      if (isOpenableLink(url)) void shell.openExternal(url)
    },

    'menu:state': (state, sender) => {
      // The window in front speaks for the menu bar; one behind does not.
      const focused = windows.focused
      if (sender && focused && sender !== focused) return
      ctx.menuStateChanged(state)
    },

    'theme:accent': () => {
      if (process.platform !== 'darwin' && process.platform !== 'win32') return null
      try {
        const color = systemPreferences.getAccentColor()
        return /^[0-9a-f]{6,8}$/i.test(color) ? `#${color.slice(0, 6)}` : null
      } catch {
        return null
      }
    },

    'clipboard:write': ({ text }) => {
      if (typeof text === 'string') clipboard.writeText(text)
    },

    // The app speaks to the outside world here and nowhere else, and only
    // because somebody pressed 보내기.
    'feedback:capture': (_args, sender) => captureWindow(target(sender)),
    'feedback:send': (report) => {
      const main = windows.main && !windows.main.isDestroyed() ? windows.main : null
      return sendFeedback({
        ...report,
        context: {
          window: main ? `${main.getBounds().width}×${main.getBounds().height}` : undefined,
          layout: settings().pageLayout,
          paperCount: libraries.paperCount,
          libraryCloud: libraries.first ? providerOf(libraries.first.root) !== 'local' : undefined,
          recent: [],
        },
      })
    },

    // What the About section says: which version this is.
    'app:about': () => ({ version: app.getVersion() }),
  }
}
