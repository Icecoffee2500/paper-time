/** The slip-box, and where the notes about no paper live. */
import { dialog, type BrowserWindow } from 'electron'
import path from 'node:path'
import { L as say } from '../../shared/lang.js'
import { samePath } from '../../shared/paths.js'
import * as L from '../layout.js'
import { update } from '../settings.js'
import { isFolder } from '../suggestions.js'
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

    'notes:useAppFolder': async () => {
      if (!ctx.isProbe) update({ notesFolder: null })
      const moved = await notes().relocate(null)
      sync.start()
      windows.send('library:changed')
      return { ...moved, notesFolder: notes().info() }
    },
  }
}
