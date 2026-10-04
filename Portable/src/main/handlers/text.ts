/** The words inside the papers, and search by meaning. */
import type { Context, Handlers } from './context.js'
import { OCRClient } from '../ocrClient.js'

export function textHandlers(ctx: Context): Partial<Handlers> {
  const { text } = ctx

  return {
    // The window says which papers, in which order, and under which titles;
    // this process knows where their files are.
    // And search by meaning catches up as the palette opens, as the Mac's
    // does — not only when a warm-up finishes, which a second open can stop.
    'text:warm': ({ ids }) => {
      text.warm(ids)
      ctx.semantic().schedule(2000)
    },
    'text:warm-cancel': () => text.stopWarming(),
    'text:search': ({ token, query, ids, titles, limit }, sender) => {
      if (sender) text.search(sender.webContents, token, query, ids, titles, limit)
    },
    'text:cancel': ({ token }, sender) => {
      if (sender) text.cancel(sender.webContents, token)
    },
    /** For a probe: what the service has read, and what it cost. */
    'text:stats': () => text.stats(),

    // Search by meaning. The window says what was typed and which places its
    // exact search already shows; the answer is passages, best first.
    'semantic:search': ({ query, k, shown }) => ctx.semantic().search(query, k ?? 8, shown ?? []),
    'semantic:status': () => ctx.semantic().status(),
    /** For a probe: builds now and waits, then says what the worker has. */
    'semantic:build': async () => {
      await ctx.semantic().build()
      return { status: ctx.semantic().status(), stats: await ctx.semantic().stats(), unread: ctx.semantic().unread }
    },

    // A formula read off a picture of the page, when the lasso's rectangle
    // holds nothing the reader can use. The window sends the picture as the
    // model takes it; the worker answers with LaTeX.
    'ocr:read': async ({ pixels }) => {
      const tensor = pixels instanceof Float32Array ? pixels : Float32Array.from(pixels)
      return ctx.ocr().read(tensor)
    },
    'ocr:available': () => OCRClient.isAvailable(),
  }
}
