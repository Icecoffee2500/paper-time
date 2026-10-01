/** The slip-box, and where the notes about no paper live. */
import { BrowserWindow, app, dialog } from 'electron'
import fsp from 'node:fs/promises'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { L as say } from '../../shared/lang.js'
import { samePath } from '../../shared/paths.js'
import * as L from '../layout.js'
import { update } from '../settings.js'
import { isFolder } from '../suggestions.js'
import { probe } from '../probeMode.js'
import type { Context, Handlers } from './context.js'

export function notesHandlers(ctx: Context): Partial<Handlers> {
  const { notes, sync, windows } = ctx
  const owner = (sender: BrowserWindow | null) => sender ?? windows.main!

  return {
    'notes:load': async () => ({ notes: await notes().load(), notesFolder: notes().info() }),

    'notes:save': async ({ note }, sender) => {
      const saved = await notes().save(note)
      // Back into search by meaning once the typing has settled; each
      // keystroke pushes that back.
      ctx.notesChanged(saved)
      windows.sendExcept(sender, 'notes:changed', { id: saved.id })
      return saved
    },

    'notes:delete': async ({ id }, sender) => {
      await notes().delete(id)
      ctx.notesChanged(null, id)
      windows.sendExcept(sender, 'notes:changed', { id })
    },

    /**
     * The note printed: the document the window built goes into a window
     * nobody sees — no scripts, sandboxed — and comes out as A4 pages. The
     * document is written to a file first: a note can be longer than a URL.
     */
    'notes:exportPDF': async ({ title, html, to }, sender) => {
      let chosen = to && probe.isRun ? to : null
      if (!chosen) {
        const result = await dialog.showSaveDialog(owner(sender), {
          title: say('PDF로 내보내기', 'Export as PDF'),
          defaultPath: `${fileStem(title)}.pdf`,
          filters: [{ name: 'PDF', extensions: ['pdf'] }],
        })
        if (result.canceled || !result.filePath) return { cancelled: true }
        chosen = result.filePath
      }
      const target = chosen.toLowerCase().endsWith('.pdf') ? chosen : `${chosen}.pdf`
      const scratch = path.join(app.getPath('temp'), `papertime-note-${process.pid}-${Date.now()}.html`)
      let printer: BrowserWindow | null = null
      try {
        // The bundled face sits beside the window's page; a `<base>` lets the
        // document find it from wherever the scratch file is.
        const base = pathToFileURL(path.join(__dirname, '../renderer/') + path.sep).href
        await fsp.writeFile(scratch, html.replace('<head>', `<head><base href="${base}">`), 'utf8')
        printer = new BrowserWindow({
          show: false,
          webPreferences: { sandbox: true, contextIsolation: true, nodeIntegration: false, javascript: false },
        })
        const loaded = new Promise<void>((resolve, reject) => {
          printer!.webContents.once('did-finish-load', () => resolve())
          printer!.webContents.once('did-fail-load', (_event, code, description) => reject(new Error(`${description} (${code})`)))
        })
        await printer.loadFile(scratch)
        await loaded
        const pdf = await printer.webContents.printToPDF({
          pageSize: 'A4',
          printBackground: true,
          margins: { top: 0.6, bottom: 0.6, left: 0.6, right: 0.6 },
        })
        await fsp.writeFile(target, pdf)
        return { path: target }
      } catch (error) {
        console.error('notes:exportPDF -', String((error as Error)?.message ?? error))
        return { error: say('PDF를 만들지 못했어요.', "Paper Time couldn't make the PDF.") }
      } finally {
        if (printer && !printer.isDestroyed()) printer.destroy()
        await fsp.unlink(scratch).catch(() => undefined)
      }
    },

    /**
     * A folder for the notes about no paper, and the notes moved into it — the
     * Mac's «Loose Notes» in the settings. Not a library's own records: a
     * second box over the same files would move every note about a paper out
     * of it. The choice is remembered before anything moves, so a move stopped
     * halfway is finished by the next launch.
     */
    'notes:chooseFolder': async (_args, sender) => {
      const result = await dialog.showOpenDialog(owner(sender), {
        title: say('논문 없는 노트를 둘 폴더', 'A folder for notes that are not about a paper'),
        message: say(
          '논문 없는 노트를 둘 폴더를 골라주세요. 지금 있는 노트도 그리로 옮겨요.',
          "Choose a folder for notes that aren't about a paper. The ones you have move there too.",
        ),
        properties: ['openDirectory', 'createDirectory'],
        buttonLabel: say('여기에 두기', 'Keep Notes Here'),
      })
      if (result.canceled || result.filePaths.length === 0) return null
      const chosen = result.filePaths[0]
      if (chosen.split(/[\\/]/).includes(L.SUPPORT_DIR)) {
        return { error: say('이 폴더에는 라이브러리의 기록이 있어요. 다른 폴더를 골라주세요.', "That folder holds a library's records. Choose another one.") }
      }
      if (samePath(path.resolve(chosen), path.resolve(notes().info().appFolder))) {
        return { error: say('그 폴더는 이미 앱의 노트 폴더예요.', "That is already the app's own notes folder.") }
      }
      if (!ctx.isProbe) update({ notesFolder: chosen })
      const moved = await notes().relocate(chosen)
      sync.start()
      windows.send('library:changed')
      return { ...moved, notesFolder: notes().info() }
    },

    'notes:reconnect': async () => {
      const where = notes().info()
      if (!where.away || !where.chosenPath) return null
      if (!isFolder(where.chosenPath)) return null
      const moved = await notes().relocate(where.chosenPath)
      sync.start()
      windows.send('library:changed')
      return { ...moved, notesFolder: notes().info() }
    },

    'notes:reveal': async () => {
      const where = notes().info()
      const target = where.away ? where.appFolder : where.loose
      if (isFolder(target)) await (await import('electron')).shell.openPath(target)
    },

    'notes:comeBack': async () => {
      const moved = await notes().comeBack()
      if (!moved || (moved.moved === 0 && moved.kept === 0)) return null
      windows.send('library:changed')
      return { ...moved, notesFolder: notes().info() }
    },

    'notes:useAppFolder': async () => {
      if (!ctx.isProbe) update({ notesFolder: null })
      const moved = await notes().relocate(null)
      sync.start()
      windows.send('library:changed')
      return { ...moved, notesFolder: notes().info() }
    },
  }
}

/**
 * A note's title as a file name every desktop takes: the characters Windows
 * forbids and the two the Mac does are spaces, a long title stops at eighty
 * characters, and a title with nothing left is «Note».
 */
export function fileStem(title: string): string {
  const cleaned = [...title.replace(/[\\/:*?"<>|\u0000-\u001f]/g, ' ')].slice(0, 80).join('')
    .replace(/\s+/g, ' ').trim().replace(/[. ]+$/, '')
  return cleaned.length > 0 ? cleaned : 'Note'
}
