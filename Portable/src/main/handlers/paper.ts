/** One paper: its bytes, its record, its name, its own window. */
import { shell } from 'electron'
import path from 'node:path'
import { diagnose, headBytes, headLine } from '../../shared/pdfLock.js'
import { rightsLock, stripOwnedForDisplay } from '../pdfwrite.js'
import { readWhole } from '../pdfBytes.js'
import type { Context, Handlers } from './context.js'

export function paperHandlers(ctx: Context): Partial<Handlers> {
  const { libraries, records, windows } = ctx

  return {
    'paper:bytes': async ({ id }) => {
      // Nothing in here throws. A rejected request reaches the window as an
      // unhandled rejection, which is a blank page with nothing said on it —
      // which is where the whole of this began.
      try {
        const row = await (await libraries.ownerOf(id))?.paper(id)
        if (!row?.file || !row.exists) return { error: 'The PDF for this paper is not in the folder.' }
        const bytes = await readWhole(row.file)
        const trouble = diagnose(bytes)
        const lock = await rightsLock(bytes)
        if (lock) return { locked: lock }
        // The diagnosis is never a door. pdf.js reads more than anything here
        // does — it opens a paper with four kilobytes of a filter's banner
        // glued to the front, and one whose last kilobytes are gone — so the
        // bytes always go to it, and what was found only chooses the sentence
        // if it fails.
        const about = { trouble, size: bytes.length, head: headBytes(bytes), line: headLine(bytes) }
        try {
          return { data: await stripOwnedForDisplay(bytes), ...about }
        } catch (error) {
          // Our own annotations could not be taken out, which is no reason to
          // refuse the file — pdf.js parses more than pdf-lib does. It is
          // handed the bytes as they are, ours included.
          console.error('paper:bytes - reading the annotations failed, showing the file as it is:', error)
          return { data: bytes, ...about }
        }
      } catch (error) {
        console.error('paper:bytes -', error)
        return { error: 'The PDF for this paper could not be read.' }
      }
    },

    'paper:state': async ({ id, patch }, sender) => {
      const holder = await libraries.ownerOf(id)
      if (!holder) return null
      const saved = await records.state(holder, id, patch)
      windows.sendExcept(sender, 'paper:changed', { id, layers: ['record'] })
      return saved
    },

    'paper:meta': async ({ id, patch, stamp }, sender) => {
      const holder = await libraries.ownerOf(id)
      if (!holder) return null
      const saved = await records.meta(holder, id, patch, { stamp })
      windows.sendExcept(sender, 'paper:changed', { id, layers: ['record'] })
      return saved
    },

    // Renaming the file, from the inspector. The reader may have it open: the
    // write behind it finishes first, then the window is told and re-reads
    // the paper from its new name.
    'paper:rename': async ({ id, name }) => {
      const holder = await libraries.ownerOf(id)
      if (!holder) return { error: 'missing' }
      await ctx.flush.settle(id)
      const result = await holder.rename(id, name)
      if ('error' in result) return result
      ctx.text.sourcesChanged()
      windows.send('library:changed')
      return { name: result.file ? path.basename(result.file) : name }
    },

    'paper:reveal': async ({ id }) => {
      const row = await (await libraries.ownerOf(id))?.paper(id)
      if (row?.file) shell.showItemInFolder(row.file)
    },

    'paper:openWindow': ({ id, x, y }) => {
      windows.createPaper(id, typeof x === 'number' && typeof y === 'number' ? { x, y } : undefined)
    },
  }
}
