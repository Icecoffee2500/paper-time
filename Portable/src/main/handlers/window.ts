/** The window's frame, the outside world, the report sheet, About. */
import { app, shell } from 'electron'
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

    'shell:openExternal': ({ url }) => {
      if (/^https?:/.test(url)) void shell.openExternal(url)
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
