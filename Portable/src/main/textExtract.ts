/**
 * The words on each page of a PDF, read the way the window reads them.
 *
 * Search finds a word by its place in a page's text and the reader shows it
 * by the same place in the page's text layer, so the two have to be the same
 * string, character for character. They are made the same way: pdf.js — the
 * same version the window runs — asked for `getTextContent()` with the same
 * defaults, each run followed by a line break where it ends a line. What the
 * window does not have to wait for is this: it runs away from the window,
 * in a process of its own (`textService.ts`), and none of it is on the path
 * that draws the page.
 *
 * Nothing here opens a file or reaches the disk. The bytes come in, and the
 * two kinds of file pdf.js asks for along the way — a character map for a
 * paper set in a CJK face, a standard font's data — are asked of whoever
 * called, because inside the packaged app those files are in an archive that
 * not every kind of thread can read.
 */
// Before pdf.js: in plain Node it looks for a canvas to render with and
// says so, at length, when there is none. Nothing here renders.
import './pdfjsQuiet.js'
import * as pdfjs from 'pdfjs-dist/legacy/build/pdf.mjs'
// @ts-expect-error -- the worker ships without declarations; nothing here
// touches it but pdf.js itself
import * as pdfjsWorker from 'pdfjs-dist/legacy/build/pdf.worker.mjs'

// pdf.js looks here for a worker it can run on this very thread: there is no
// Web Worker in Node, and a thread of our own is already where this runs.
;(globalThis as unknown as { pdfjsWorker: unknown }).pdfjsWorker = pdfjsWorker

/** How the files pdf.js asks for are fetched. */
export interface ExtractAssets {
  /** A packed character map, by name (`Adobe-Korea1-UCS2`). */
  cmap: (name: string) => Promise<Uint8Array>
  /** A standard font's data, by file name (`FoxitSymbol.pfb`). */
  font: (filename: string) => Promise<Uint8Array>
}

interface TextItem {
  str?: string
  hasEOL?: boolean
}

/**
 * Each page's text: every run pdf.js reports, in its order, with a line
 * break after each one that ends a line — exactly the runs, and the breaks,
 * the text layer is built from (`TextLayer` makes one span per run and a
 * `<br>` for each break).
 *
 * A document pdf.js will not open throws. A page that will not give up its
 * text is an empty page, not a paper with no pages: the pages after it still
 * say what they say, and the numbering stays right.
 */
export async function extractPages(bytes: Uint8Array, assets: ExtractAssets): Promise<string[]> {
  class CMapReader {
    constructor(_options: unknown) {}
    async fetch({ name }: { name: string }) {
      return { cMapData: await assets.cmap(name), isCompressed: true }
    }
  }
  class FontReader {
    constructor(_options: unknown) {}
    async fetch({ filename }: { filename: string }) {
      return assets.font(filename)
    }
  }
  const task = pdfjs.getDocument({
    data: bytes,
    // Only ever read through the two classes above; the addresses are there
    // because pdf.js will not go looking without one.
    cMapUrl: 'asset:cmaps/',
    cMapPacked: true,
    standardFontDataUrl: 'asset:fonts/',
    CMapReaderFactory: CMapReader,
    StandardFontDataFactory: FontReader,
    useWorkerFetch: false,
    // The window's own choice, which decides whether pdf.js reads the
    // standard fonts' files — and so, in a few documents, where the spaces
    // between runs fall. Nothing here draws a glyph either way.
    useSystemFonts: true,
    disableFontFace: true,
    isEvalSupported: false,
    verbosity: 0,
  })
  // A document that wants a password has no text anybody asked for, and
  // pdf.js otherwise waits for the answer for ever.
  task.onPassword = () => {
    void task.destroy()
  }
  const document = await task.promise
  try {
    const pages: string[] = []
    for (let number = 1; number <= document.numPages; number += 1) {
      try {
        const page = await document.getPage(number)
        const content = await page.getTextContent()
        let text = ''
        for (const item of content.items as TextItem[]) {
          if (item.str === undefined) continue
          text += item.str
          if (item.hasEOL) text += '\n'
        }
        pages.push(text)
        page.cleanup()
      } catch {
        pages.push('')
      }
    }
    return pages
  } finally {
    await document.destroy()
  }
}

/**
 * How many pages pdf.js finds in these bytes — nothing else read, no text
 * asked for. The appender's last check before a file goes into a paper's
 * place: pdf.js is what the window will open it with.
 */
export async function countPages(bytes: Uint8Array): Promise<number> {
  const task = pdfjs.getDocument({
    data: bytes,
    useWorkerFetch: false,
    disableFontFace: true,
    isEvalSupported: false,
    verbosity: 0,
  })
  // A document that wants a password is not one the appender writes; and
  // pdf.js otherwise waits for the answer for ever.
  task.onPassword = () => {
    void task.destroy()
  }
  const document = await task.promise
  try {
    return document.numPages
  } finally {
    await document.destroy()
  }
}
