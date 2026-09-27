/** The window's frame, the outside world, the report sheet, About. */
import { probeArgument } from '../probe.js'
import { fontFamilies } from '../fonts.js'
import { app, clipboard, shell, systemPreferences } from 'electron'
import { isOpenableLink } from '../../shared/readerMath.js'
import { providerOf } from '../../shared/cloudProvider.js'
import { settings } from '../settings.js'
import { capture as captureWindow, diagnosticRows, lastRunCrashed, recentActions, send as sendFeedback, type FeedbackContext } from '../feedback.js'
import type { Context, Handlers } from './context.js'

/** What the app knows about this moment — never about the papers. */
function feedbackContextFor(ctx: Context): FeedbackContext {
  const { windows, libraries } = ctx
  const main = windows.main && !windows.main.isDestroyed() ? windows.main : null
  const panes = settings().panes
  const open = (['sidebar', 'paperList', 'reader', 'inspector'] as const).filter((one) => panes?.[one])
  return {
    window: main ? `${main.getBounds().width}×${main.getBounds().height}` : undefined,
    layout: settings().pageLayout,
    panes: open.length > 0 ? open.join(', ') : undefined,
    paperCount: libraries.paperCount,
    libraryCloud: libraries.first ? providerOf(libraries.first.root) !== 'local' : undefined,
    recent: recentActions(),
  }
}


/** The last drawing copied in any window, with the words that went to the system clipboard with it. */
let sketchClipping: { clipping: string; text: string; formats: string } | null = null

export function windowHandlers(ctx: Context): Partial<Handlers> {
  const { windows, libraries } = ctx
  const target = (sender: Parameters<Handlers['window:close']>[1]) => sender ?? windows.main
  const feedbackContext = () => feedbackContextFor(ctx)

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

    'clipboard:read': () => clipboard.readText(),

    'fonts:list': () => fontFamilies(),

    // The drawing on the clipboard. Not a custom format — `writeBuffer`
    // clears the text on some desktops and is not read back on others — but
    // the clipping kept here with the words that went out with it: anything
    // copied since, in any app, changes the words, and the drawing is gone
    // from the clipboard as it would be on the Mac.
    'clipboard:writeSketch': ({ clipping, text }) => {
      if (typeof clipping !== 'string' || typeof text !== 'string') return
      clipboard.writeText(text)
      sketchClipping = { clipping, text, formats: clipboard.availableFormats().join(',') }
    },

    'clipboard:readSketch': () => {
      if (!sketchClipping) return null
      // The words, and the kinds of thing on the clipboard: a picture copied
      // since has no words either.
      const same = clipboard.readText() === sketchClipping.text && clipboard.availableFormats().join(',') === sketchClipping.formats
      return same ? sketchClipping.clipping : null
    },

    // The app speaks to the outside world here and nowhere else, and only
    // because somebody pressed 보내기.
    'feedback:capture': (_args, sender) => captureWindow(target(sender)),
    'feedback:diagnostics': () => {
      const context = feedbackContext()
      return { rows: diagnosticRows(context), crashed: lastRunCrashed() }
    },

    // The same context the sheet listed, so the list and the payload cannot
    // drift apart (`FeedbackDiagnostics.rows`).
    'feedback:send': (report) => sendFeedback({ ...report, context: feedbackContext() }),

    // What the About section says: which version this is.
    'app:about': () => ({ version: app.getVersion(), whatsNew: probeArgument('whats-new') === '1' }),
  }
}
