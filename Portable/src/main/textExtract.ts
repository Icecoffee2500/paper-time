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
import { rightsHandler } from '../shared/pdfLock.js'
import {
  cleanEmbeddedTitle, emptySignals, holdsReferenceHeading, keywordList, largestFontText, looksLikeAbstract, nonEmpty,
  pageLines, referencePageIndices, splitAuthorField, type DocumentSignals, type FontRun,
} from '../shared/metadata/signals.js'
import { repairingHyphenation } from '../shared/metadata/text.js'
import { graphemes } from '../shared/metadata/chars.js'
import { trimWhitespaceAndNewlines } from '../shared/zettel.js'
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
  transform?: number[]
  width?: number
}

/** The run's size as set on the page: the text matrix's vertical scale,
 *  which is what PDFKit reports as the font's point size. */
function runSize(item: TextItem): number {
  const [a = 0, b = 0, c = 0, d = 0] = item.transform ?? []
  return Math.hypot(c, d) || Math.hypot(a, b)
}

/**
 * A space pdf.js put between two runs that almost touch — a small-caps
 * heading is a large capital and a smaller rest, and pdf.js reads the few
 * tenths of a point between them as a word break: «A BSTRACT», «C ON D A».
 * PDFKit reads «ABSTRACT», and the signals are the Mac's. The space item's
 * own width says nothing (a real space after a colon measured 0.65 across an
 * 11.5 pt gap), so the gap is measured: from where the run before it ends to
 * where the run after it starts, on the same line. Less than a sixth of the
 * type is not a word break. (Only the signals read text this way; the text
 * layer and search keep pdf.js's runs exactly.)
 */
function isHairSpace(items: TextItem[], index: number): boolean {
  const item = items[index]
  if (item.str === undefined || !item.str || item.str.trim() || item.hasEOL) return false
  const before = items[index - 1]
  const after = items[index + 1]
  if (!before?.str?.trim() || !after?.str?.trim() || before.hasEOL) return false
  const [a1 = 0, b1 = 0, c1 = 0, , x1 = 0, y1 = 0] = before.transform ?? []
  const [, b2 = 0, c2 = 0, , x2 = 0, y2 = 0] = after.transform ?? []
  // Upright text only: a rotated run's width is not along x.
  if (b1 !== 0 || c1 !== 0 || b2 !== 0 || c2 !== 0 || a1 <= 0) return false
  const size = Math.max(runSize(before), runSize(after))
  if (Math.abs(y1 - y2) > size * 0.5) return false
  const gap = x2 - (x1 + (before.width ?? 0))
  return gap < size * 0.15
}

/** A page's text for its signals: the text layer's, less hair spaces. */
async function signalText(document: pdfjs.PDFDocumentProxy, number: number): Promise<{ text: string; runs: FontRun[]; view: number[] }> {
  try {
    const page = await document.getPage(number)
    const content = await page.getTextContent()
    let text = ''
    const runs: FontRun[] = []
    const items = content.items as TextItem[]
    for (const [index, item] of items.entries()) {
      if (item.str === undefined || isHairSpace(items, index)) continue
      // Upright type only. The arXiv stamp runs up the left margin, larger
      // than the title; sized with the rest, it joins the title's group and
      // the title grows down through the author block to the stamp. A title
      // is never set on its side.
      const [, b = 0, c = 0] = item.transform ?? []
      if (item.str.trim() && Math.abs(b) < 1e-6 && Math.abs(c) < 1e-6) {
        runs.push({ size: runSize(item), location: text.length, length: item.str.length })
      }
      text += item.str
      if (item.hasEOL) text += '\n'
    }
    const view = page.view
    page.cleanup()
    return { text, runs, view }
  } catch {
    return { text: '', runs: [], view: [0, 0, 0, 0] }
  }
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
  const document = await openForText(bytes, assets)
  try {
    const pages: string[] = []
    for (let number = 1; number <= document.numPages; number += 1) {
      pages.push(await pageText(document, number))
    }
    return pages
  } finally {
    await document.destroy()
  }
}

/** One page's text as the text layer spells it — empty when the page will
 *  not give it up. */
async function pageText(document: pdfjs.PDFDocumentProxy, number: number): Promise<string> {
  try {
    const page = await document.getPage(number)
    const content = await page.getTextContent()
    let text = ''
    for (const item of content.items as TextItem[]) {
      if (item.str === undefined) continue
      text += item.str
      if (item.hasEOL) text += '\n'
    }
    page.cleanup()
    return text
  } catch {
    return ''
  }
}

async function openForText(bytes: Uint8Array, assets: ExtractAssets): Promise<pdfjs.PDFDocumentProxy> {
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
  return task.promise
}

/**
 * What a paper says about itself before anybody is asked — the Mac's
 * `DocumentSignalsExtractor`, read through pdf.js: the Info dictionary, the
 * first page as lines, the opening two pages, the largest type on page one,
 * an abstract near the top, a reference list, and the shape of the page.
 * What each of those means is decided in `shared/metadata/signals.ts`, which
 * is held to the Mac's answers; this only reads.
 *
 * A file behind a password or a rights handler says nothing but its length
 * — its title would be cipher.
 */
export async function extractSignals(bytes: Uint8Array, assets: ExtractAssets): Promise<DocumentSignals> {
  const probe = rightsHandler(bytes)
  let document: pdfjs.PDFDocumentProxy
  try {
    document = await openForText(bytes, assets)
  } catch {
    return emptySignals(0)
  }
  try {
    const signals = emptySignals(document.numPages)
    if (probe) {
      // A rights handler's name alone proves nothing (a paper about rights
      // management names one); no text on the first pages does.
      let text = ''
      for (let number = 1; number <= Math.min(3, document.numPages); number += 1) text += (await signalText(document, number)).text
      if (!text.trim()) return signals
    }
    const info = ((await document.getMetadata().catch(() => null))?.info ?? {}) as Record<string, unknown>
    const field = (key: string) => (typeof info[key] === 'string' ? info[key] as string : undefined)
    signals.embeddedTitle = cleanEmbeddedTitle(field('Title'))
    signals.embeddedAuthors = splitAuthorField(field('Author'))
    signals.embeddedSubject = nonEmpty(field('Subject'))
    signals.embeddedKeywords = keywordList(field('Keywords'))
    if (document.numPages === 0) return signals

    const { text: firstPage, runs, view } = await signalText(document, 1)
    signals.hasTextLayer = graphemes(trimWhitespaceAndNewlines(firstPage)).length > 200
    signals.firstPageLines = pageLines(firstPage)
    let opening = firstPage
    if (document.numPages > 1) opening += '\n' + (await signalText(document, 2)).text
    signals.openingText = repairingHyphenation(opening)
    signals.largestFontText = largestFontText(runs, firstPage)
    signals.hasAbstract = looksLikeAbstract(firstPage)
    for (const index of referencePageIndices(document.numPages)) {
      const text = index === 0 ? firstPage : (await signalText(document, index + 1)).text
      if (holdsReferenceHeading(text)) {
        signals.hasReferences = true
        break
      }
    }
    // The page as printed; a paper cropped for the screen can be landscape
    // without being slides.
    const width = Math.abs(view[2] - view[0])
    const height = Math.abs(view[3] - view[1])
    signals.isLandscape = width > height * 1.15
    return signals
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
