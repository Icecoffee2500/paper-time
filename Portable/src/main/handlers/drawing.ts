/** The layers on a page: shapes, ink, marks — and the file they go into. */
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import { isoTimestamp } from '../../shared/coding.js'
import { merged, reconcile, upgradeLegacy } from '../../shared/markJournal.js'
import { hasForeignInk, readDrawings, readMarks, writeRefusal, type MarkupRecord } from '../pdfwrite.js'
import { holdsAnything } from '../pdfFlush.js'
import type { Library } from '../library.js'
import * as L from '../layout.js'
import type { Context, Handlers } from './context.js'

/**
 * One queue per page and layer, so two saves of the same page are written in
 * the order they were asked for. Each save is its own request and the window
 * sends them without waiting; handled side by side, a drag's last save could
 * be overtaken by the one before it, and the file kept the older drawing.
 */
const queues = new Map<string, Promise<unknown>>()

function inOrder<T>(key: string, work: () => Promise<T>): Promise<T> {
  const next = (queues.get(key) ?? Promise.resolve()).catch(() => undefined).then(work)
  queues.set(key, next)
  void next.finally(() => { if (queues.get(key) === next) queues.delete(key) }).catch(() => undefined)
  return next
}

export function drawingHandlers(ctx: Context): Partial<Handlers> {
  const { libraries, flush, journals, windows } = ctx

  return {
    'sketch:load': async ({ id, pageIndex }) =>
      (await libraries.ownerOf(id))?.loadSketch(id, pageIndex) ?? null,

    'sketch:save': ({ id, pageIndex, elements }) => inOrder(`${id}:${pageIndex}:sketch`, async () => {
      await (await libraries.ownerOf(id))?.saveSketch(id, pageIndex, elements)
      flush.touched(id).sketch.add(pageIndex)
      flush.schedule(id)
    }),

    'ink:load': async ({ id, pageIndex }) =>
      (await libraries.ownerOf(id))?.loadInk(id, pageIndex) ?? null,

    'ink:save': ({ id, pageIndex, strokes }) => inOrder(`${id}:${pageIndex}:ink`, async () => {
      // Into the folder that holds the paper, as every other sidecar is.
      const holder = await libraries.ownerOf(id)
      if (!holder) return
      await holder.saveInk(id, pageIndex, strokes)
      await supersedeAppleInk(holder, id, pageIndex)
      flush.touched(id).ink.add(pageIndex)
      flush.schedule(id)
    }),

    'marks:load': async ({ id }) => {
      const holder = await libraries.ownerOf(id)
      const row = await holder?.paper(id)
      if (!holder || !row?.file || !row.exists) return {}
      const bytes = await fsp.readFile(row.file)
      const found = await readMarks(bytes)
      // This machine's journal from before 0.9.9 said only when each mark was
      // made, which the Mac reads as "taken away". Brought up to date from
      // the file the first time the paper is opened here.
      const own = await journals.own(id, holder.root)
      if (upgradeLegacy(own.journal, found)) {
        own.journal.updated = isoTimestamp(new Date())
        journals.keep(id, holder.root, own)
      }
      // What the file holds, overruled by what every device's journal says: a
      // mark made on a Mac a second ago, or one this machine could not put
      // into an encrypted file, is a mark all the same.
      const { pages, dirty } = reconcile(found, merged(await journals.all(id, holder.root)))
      // A mark only a journal holds — made on a Mac, or here before a quit
      // that did not wait — goes into the file now, not at the next change.
      if (dirty.size > 0) {
        for (const pageIndex of dirty) flush.touched(id).marks.add(pageIndex)
        flush.schedule(id)
      }
      const out: Record<number, MarkupRecord[]> = {}
      for (const [pageIndex, marks] of pages) out[pageIndex] = marks
      // An encrypted file carries none of what was made on it here, and the
      // window says so the moment the paper opens — not only after the next
      // save is turned away, which after a restart may be never.
      const refused = await writeRefusal(bytes)
      if (refused && await holdsAnything(holder, id, pages)) {
        windows.send('paper:kept', { id, reason: refused })
      }
      return out
    },

    'marks:save': ({ id, pageIndex, marks, before, elsewhere }) => inOrder(`${id}:${pageIndex}:marks`, async () => {
      const holder = await libraries.ownerOf(id)
      if (!holder) return
      // The window's own change, as the window saw it. A copy held here went
      // stale the moment another device wrote the page, and was empty when
      // the paper opened before its file was there.
      await journals.recordChange(id, holder.root, pageIndex, before ?? [], marks, new Set((elsewhere ?? []).map((one) => one.toUpperCase())))
      flush.touched(id).marks.add(pageIndex)
      flush.schedule(id)
    }),

    'drawing:pages': async ({ id }) =>
      (await libraries.ownerOf(id))?.annotatedPages(id) ?? { sketch: [], ink: [], appleInk: [] },

    'drawing:adoptFromFile': ({ id }) => adoptFromFile(libraries.ownerOf.bind(libraries), id),

    // Every drawn page in one answer: this machine's sidecars first, what
    // the file carries otherwise. The window used to ask twice per page, one
    // after another, and waited for all of it before the paper could show.
    'drawing:loadAll': async ({ id }) => {
      const adopted = await adoptFromFile(libraries.ownerOf.bind(libraries), id)
      const holder = await libraries.ownerOf(id)
      if (!holder) return { pages: {}, unreadable: [], foreignInk: false }
      const row = await holder.paper(id)
      const foreignInk = row?.file && row.exists ? hasForeignInk(await fsp.readFile(row.file)) : false
      const known = await holder.annotatedPages(id)
      const indices = new Set<number>([...known.sketch, ...known.ink, ...Object.keys(adopted.pages).map(Number)])
      const pages: Record<number, { elements: unknown[]; strokes: unknown[] }> = {}
      await Promise.all([...indices].map(async (pageIndex) => {
        const [elements, strokes] = await Promise.all([holder.loadSketch(id, pageIndex), holder.loadInk(id, pageIndex)])
        pages[pageIndex] = {
          elements: elements ?? adopted.pages[pageIndex]?.elements ?? [],
          strokes: strokes ?? adopted.pages[pageIndex]?.strokes ?? [],
        }
      }))
      return { pages, unreadable: adopted.unreadable, foreignInk }
    },

    // A paper the window names without an identifier is no paper: nothing
    // is written, rather than a path built from «undefined».
    'drawing:flush': ({ id }) => (typeof id === 'string' && id ? flush.flushAsked(id) : Promise.resolve({ written: 0 })),
  }
}

/**
 * Builds sidecars for a paper whose drawing is only in the PDF.
 *
 * That is what a paper annotated on a Mac looks like the first time it is
 * opened here: the shapes are in the file, carrying their own JSON in
 * `/PTSketch`, and the pen's strokes are ordinary ink annotations. Both come
 * across; what does not is the pressure in the Mac's `.drawing`, which no
 * format but PencilKit's own can hold.
 */
export async function adoptFromFile(ownerOf: (id: string) => Promise<Library | null>, id: string) {
  const holder = await ownerOf(id)
  if (!holder) return { pages: {}, unreadable: [] as number[] }
  const row = await holder.paper(id)
  if (!row?.file || !row.exists) return { pages: {}, unreadable: [] as number[] }
  const found = await readDrawings(await fsp.readFile(row.file))
  const pages: Record<number, { elements: unknown[]; strokes: unknown[] }> = {}
  for (const [pageIndex, drawing] of found) {
    // Shapes are lossless in the file — the annotation carries the element's
    // own JSON — so a sidecar built from it is exactly the sidecar the Mac
    // had, and worth writing.
    if (!(await holder.loadSketch(id, pageIndex)) && drawing.elements.length > 0) {
      await holder.saveSketch(id, pageIndex, drawing.elements.map((e) => e.encode()))
    }
    // Ink is not. The strokes in the file have one width each, where the
    // Mac's `.drawing` still holds the pressure at every point. They are
    // handed to the window to *show* — a reader must see the handwriting on
    // the page — but no sidecar is written for them, because writing one
    // would be this machine claiming a page it has not been asked to touch.
    pages[pageIndex] = {
      elements: drawing.elements.map((e) => e.encode()),
      strokes: drawing.strokes.map((s) => s.encode()),
    }
  }
  // A page whose handwriting exists only as PencilKit's own file, which no
  // format outside Apple's frameworks can read. Rather than quietly showing a
  // page with the writing missing, the window is told which pages they are.
  const unreadable: number[] = []
  const pageList = await holder.annotatedPages(id)
  for (const pageIndex of pageList.appleInk) {
    if (await holder.loadInk(id, pageIndex)) continue
    if ((found.get(pageIndex)?.strokes.length ?? 0) > 0) continue
    unreadable.push(pageIndex)
  }
  return { pages, unreadable }
}

/**
 * Moves the Mac's PencilKit sidecar aside once this machine has drawn on that
 * page. Both sidecars would otherwise claim the same page and the two
 * machines would show different things. Renamed rather than deleted — the
 * pressure in it is the user's work, and nothing in this app deletes that.
 */
export async function supersedeAppleInk(holder: Library, id: string, pageIndex: number) {
  const file = L.appleInkPath(holder.root, id, pageIndex)
  if (!fs.existsSync(file)) return
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  await fsp.rename(file, `${file}.superseded-${stamp}`)
}
