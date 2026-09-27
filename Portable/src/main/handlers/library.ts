/**
 * The library as a whole: settings, folders, importing, the Trash, the
 * vocabulary, the `.bib`.
 */
import { dialog, type BrowserWindow } from 'electron'
import fsp from 'node:fs/promises'
import path from 'node:path'
import type { Collection } from '../../shared/model.js'
import { acceptedPatch } from '../../shared/appSettings.js'
import { L as say } from '../../shared/lang.js'
import { settings, update } from '../settings.js'
import { folderRefusal } from '../libraries.js'
import { collectionsByFolder } from '../vocabulary.js'
import { isFile, pageCount } from './shared.js'
import type { Context, Handlers } from './context.js'

export function libraryHandlers(ctx: Context): Partial<Handlers> {
  const { libraries, sync, windows } = ctx
  const owner = (sender: BrowserWindow | null) => sender ?? windows.main!

  return {
    // The effective root, not the remembered one: a probe run opens a folder
    // of its own and the window must be told about that one.
    'settings:get': () => ({ ...settings(), libraryRoot: libraries.first?.root ?? settings().libraryRoot }),

    'settings:set': (asked, sender) => {
      const patch = acceptedPatch(asked as Record<string, unknown>)
      const before = settings().language
      const next = update(patch)
      // The other windows follow what this one chose — a tint, a layout —
      // rather than keeping what they had until they are opened again.
      windows.sendExcept(sender, 'settings:changed', patch)
      if ('language' in patch && next.language !== before) ctx.languageChanged()
      // The switch for search by meaning: off ends the worker and what it was
      // doing; on starts the build the way a library read would.
      if ('semanticSearch' in patch) {
        if (next.semanticSearch === false) ctx.semantic().stop()
        else ctx.semantic().schedule(500)
      }
      return next
    },

    'library:choose': async (_args, sender) => {
      const result = await dialog.showOpenDialog(owner(sender), {
        title: say('라이브러리 폴더 고르기', 'Choose your library folder'),
        message: say(
          '논문이 있는 폴더를 골라주세요. 클라우드 폴더면 다른 기기에서도 같은 라이브러리를 봐요.',
          'Pick the folder your papers live in. A cloud folder is how a library follows you between machines.',
        ),
        properties: ['openDirectory', 'createDirectory'],
        buttonLabel: say('이 폴더 쓰기', 'Use This Folder'),
      })
      if (result.canceled || result.filePaths.length === 0) return null
      return result.filePaths[0]
    },

    'library:open': async ({ root }) => {
      const refusal = folderRefusal(root)
      if (refusal) return { error: refusal, refused: true }
      return ctx.openLibrary(root)
    },

    'library:reload': () => ctx.snapshot(),

    'library:import': async ({ paths, root }, sender) => {
      // Into the folder being looked at, as on the Mac (`importDestination`):
      // a paper added while one library's own shelf is showing belongs to
      // that library. Anything else — every other shelf, a folder inside a
      // library — goes to the first one.
      const destination = libraries.destination(root)
      if (!destination) return { error: say('열린 라이브러리가 없어요.', 'No library is open.') }
      let chosen = paths
      if (!chosen || chosen.length === 0) {
        const result = await dialog.showOpenDialog(owner(sender), {
          title: say('PDF 더하기', 'Add PDFs'),
          message: say('라이브러리에 더할 PDF를 골라주세요.', 'Choose PDFs to add to the library.'),
          filters: [{ name: 'PDF', extensions: ['pdf'] }],
          properties: ['openFile', 'multiSelections'],
        })
        if (result.canceled) return ctx.snapshot()
        chosen = result.filePaths
      }
      // PDFs only, and ones that are there: a drop carries whatever was
      // dragged, and the window's list is not a promise about the disk.
      const pdfs = chosen.filter((file) => /\.pdf$/i.test(file) && isFile(file))
      // Through the folder sync's queue: it is reading the folder this
      // writes into, and two passes over one file are two records for it.
      await sync.run(async () => {
        for (const file of pdfs) {
          await destination.importPDF(file, await pageCount(ctx.pageCounter, file))
        }
      })
      const snapshot = await ctx.snapshot()
      windows.sendExcept(sender, 'library:changed')
      return snapshot
    },

    'library:adoptLoose': async (_args, sender) => {
      if (!libraries.first) return { error: say('열린 라이브러리가 없어요.', 'No library is open.') }
      // Each folder takes in its own: adopting a PDF must never move it to
      // another folder. One file at a time, and a file that will not be read
      // does not take the rest of the folder with it: this loop used to throw
      // on the first unreadable PDF, so two hundred good papers waited behind
      // one bad one and the window was told nothing at all.
      const refused: string[] = []
      await sync.run(async () => {
        for (const one of libraries.all()) {
          for (const file of await one.looseFiles()) {
            try {
              await one.importPDF(file, await pageCount(ctx.pageCounter, file))
            } catch {
              refused.push(path.basename(file))
            }
          }
        }
      })
      const snapshot = await ctx.snapshot(refused)
      windows.sendExcept(sender, 'library:changed')
      return snapshot
    },

    // Another folder, read beside the ones already open. Nothing is copied or
    // moved: it keeps its own `.papertime`, so disconnecting leaves it exactly
    // as it was.
    'library:addFolder': async ({ root }, sender) => {
      let chosen = root
      if (!chosen) {
        const result = await dialog.showOpenDialog(owner(sender), {
          title: say('폴더 더하기', 'Add a Folder'),
          message: say(
            '이 라이브러리 옆에서 함께 읽을 폴더를 골라주세요. 그 폴더의 논문이 같은 목록에 들어와요. 옮기지는 않아요.',
            'Choose another folder to read beside this one. Its papers join the same list, and nothing is moved.',
          ),
          properties: ['openDirectory', 'createDirectory'],
          buttonLabel: say('이 폴더도 열기', 'Open This Folder Too'),
        })
        if (result.canceled || result.filePaths.length === 0) return ctx.snapshot()
        chosen = result.filePaths[0]
      }
      if (!libraries.first) return ctx.snapshot()
      const refusal = await libraries.attach(chosen)
      if (refusal) return refusal
      sync.start()
      const snapshot = await ctx.snapshot()
      windows.sendExcept(sender, 'library:changed')
      return snapshot
    },

    /** Stops reading a folder. Its files and its records stay where they are. */
    'library:removeFolder': async ({ root }, sender) => {
      libraries.detach(root)
      sync.start()
      const snapshot = await ctx.snapshot()
      windows.sendExcept(sender, 'library:changed')
      return snapshot
    },

    // A library's folder in the desktop's own file manager, from its row's
    // menu. Only a folder the library is reading: the window does not get to
    // open arbitrary paths.
    'library:revealFolder': async ({ root }) => {
      const known = libraries.roots.find((one) => one === root)
      if (known) await (await import('electron')).shell.openPath(known)
    },

    'library:trash': async ({ id }, sender) => {
      const holder = await libraries.ownerOf(id)
      if (holder) {
        // The write behind the reader finishes first, or it would put the
        // file back beside the record that just left.
        await ctx.flush.settle(id)
        await holder.trashPaper(id)
        ctx.flush.forget(id)
        await ctx.journals.forget(id)
        libraries.forgetPaper(id)
      }
      const snapshot = await ctx.snapshot()
      windows.sendExcept(sender, 'library:changed')
      return snapshot
    },

    // The window sends the whole list; it is put back folder by folder. Each
    // folder keeps the collections it already had, and a new one goes into
    // the folder being looked at, or the first — the folder a paper added
    // now would go into.
    'collections:save': async ({ collections, root }, sender) => {
      const all = collections as Collection[]
      const folders = libraries.all()
      if (folders.length === 0) return null
      const held = await Promise.all(folders.map(async (one) => ({
        one,
        ids: new Set(((await one.collections()).collections ?? []).map((entry) => entry.id)),
      })))
      const destination = libraries.destination(root)?.root ?? folders[0].root
      const plan = collectionsByFolder(all, held.map(({ one, ids }) => ({ root: one.root, ids })), destination)
      for (const { root: target, collections: mine } of plan) {
        await folders.find((one) => one.root === target)?.saveCollections(mine)
      }
      windows.sendExcept(sender, 'library:changed')
      return null
    },

    // The sheet's «Save…»: the text it previewed, where the person says.
    'bibtex:save': async ({ text }, sender) => {
      const result = await dialog.showSaveDialog(owner(sender), {
        title: say('BibTeX 내보내기', 'Export BibTeX'),
        defaultPath: 'references.bib',
        filters: [{ name: 'BibTeX', extensions: ['bib'] }],
      })
      if (result.canceled || !result.filePath) return { cancelled: true }
      await fsp.writeFile(result.filePath, text, 'utf8')
      return { path: result.filePath }
    },
  }
}
