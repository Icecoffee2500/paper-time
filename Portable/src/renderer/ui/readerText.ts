/**
 * A paper's words, for finding in it and for guessing what it is.
 *
 * One `DocumentText` per open document: the text of each page as the text
 * layer holds it, read once, and each page's fold made the first time a
 * search looks at it. Kept apart from the pages — a page let go of drops its
 * text layer, and a search that had read it should not have to again.
 */
import { foldText, foldWithMap, occurrences, type Folded } from '../../shared/textFold.js'
import {
  guessKind, hasAbstract, hasIdentifier, hasReferences, namesACourse, type DocumentKind,
} from '../../shared/documentKind.js'
import type { PDFDocumentProxy } from '../pdf.js'
import type { PageView } from './pageView.js'

export interface Found {
  pageIndex: number
  start: number
  end: number
}

export class DocumentText {
  private all: Promise<string[]> | null = null
  private readonly pages = new Map<number, Promise<string>>()
  private readonly folds = new Map<number, Folded>()
  private closed = false

  constructor(private readonly views: PageView[]) {}

  /** No more reading: the document this was for has closed. */
  close() {
    this.closed = true
  }

  /** One page's text: every run, and a line break after each that ends a line. */
  page(index: number): Promise<string> {
    const known = this.pages.get(index)
    if (known) return known
    const view = this.views[index]
    if (!view) return Promise.resolve('')
    const made = view.textContent().then((content) => {
      let text = ''
      for (const item of content?.items ?? []) {
        if (item.str === undefined) continue
        text += item.str
        if (item.hasEOL) text += '\n'
      }
      return text
    })
    this.pages.set(index, made)
    return made
  }

  /**
   * The text of every page, asked of pdf.js in its worker page by page, so
   * the window's thread only joins the runs up.
   */
  every(): Promise<string[]> {
    if (!this.all) {
      this.all = (async () => {
        const out: string[] = []
        for (let index = 0; index < this.views.length; index += 1) {
          if (this.closed) return []
          out.push(await this.page(index))
        }
        return out
      })()
    }
    return this.all
  }

  private folded(index: number, text: string): Folded {
    let folded = this.folds.get(index)
    if (!folded) {
      folded = foldWithMap(text)
      this.folds.set(index, folded)
    }
    return folded
  }

  /**
   * Every place in the paper that says the query, folded the way the index
   * folds it — so the count here and the count the palette gave are counts
   * of the same thing, a word broken at the end of a line included.
   */
  async findAll(query: string): Promise<Found[]> {
    const needle = foldText(query.trim())
    if (!needle) return []
    const texts = await this.every()
    const found: Found[] = []
    texts.forEach((text, pageIndex) => {
      if (!text) return
      for (const range of occurrences(text, this.folded(pageIndex, text), needle)) found.push({ pageIndex, ...range })
    })
    return found
  }

  /**
   * Where a passage the index named is on its page. The index read this
   * paper in a process of its own, with the same pdf.js asked the same way,
   * so the place it names is the place the text layer has. Should the two
   * ever read a page differently, the query is found on the page afresh and
   * the occurrence nearest the named place is the one shown.
   */
  async passage(passage: { pageIndex: number; location: number; length: number }, query: string): Promise<{ start: number; end: number }> {
    const text = await this.page(passage.pageIndex)
    const needle = foldText(query.trim())
    const named = { start: passage.location, end: passage.location + passage.length }
    if (!needle || foldText(text.slice(named.start, named.end)).includes(needle)) return named
    let best: { start: number; end: number } | null = null
    for (const range of occurrences(text, this.folded(passage.pageIndex, text), needle)) {
      if (!best || Math.abs(range.start - passage.location) < Math.abs(best.start - passage.location)) best = range
    }
    return best ?? named
  }
}

/** Papers guessed this session: a guess that could not be written is not
 *  made again on every open — twenty pages of text read for nothing. */
const guessed = new Set<string>()

/**
 * Whether this reads as a paper, worked out from the pages themselves.
 *
 * The Mac guesses when the file is imported, because it has PDFKit there.
 * Here the text arrives with pdf.js, which lives in the window, so the guess
 * is made the first time the document is opened — which is also when
 * somebody is looking at the question. It never overrules an answer.
 */
export async function guessDocumentKind(
  paperID: string,
  document: PDFDocumentProxy,
  fileName: string,
  still: () => boolean,
): Promise<DocumentKind | null> {
  if (guessed.has(paperID)) return null
  guessed.add(paperID)
  try {
    const textOf = async (index: number) => {
      const page = await document.getPage(index)
      const content = await page.getTextContent()
      return content.items.map((item) => ('str' in item ? item.str : '')).join(' ')
    }
    const first = await textOf(1)
    if (!still()) return null
    // The end, and then through the second half: a paper with appendices
    // puts its bibliography in the middle, and looking only at the last
    // pages called such a paper a manual. At most a dozen pages are read.
    const count = document.numPages
    const wanted = new Set<number>()
    if (count <= 40) {
      // A paper is short enough to read all of, and its bibliography can be
      // anywhere: one of the papers this was tried on has it on page 9 of
      // 23, with appendices after it.
      for (let index = 1; index <= count; index += 1) wanted.add(index)
    } else {
      for (let index = count; index > count - 8; index -= 1) wanted.add(index)
      const step = Math.max(1, Math.floor(count / 12))
      for (let index = 1; index <= count && wanted.size < 20; index += step) wanted.add(index)
    }
    let end = ''
    for (const index of [...wanted].sort((a, b) => b - a)) end += await textOf(index)
    if (!still()) return null
    // The shape of the page, which nothing written to be read on paper has
    // and everything written to be projected does. Taken at scale 1 so it
    // is the page's own size and not the view's.
    const size = (await document.getPage(1)).getViewport({ scale: 1 })
    return guessKind({
      identifier: hasIdentifier(first),
      abstract: hasAbstract(first),
      references: hasReferences(end),
      pageCount: count,
      landscape: size.width > size.height * 1.15,
      // The name on disk is the more reliable half: a deck's first page
      // often says only the week's title, while the file is lecture06.pdf.
      courseWords: namesACourse(`${fileName} ${first.slice(0, 1200)}`),
    }).kind
  } catch {
    // A document whose text cannot be read is not a paper we can recognise,
    // and guessing wrong here is worse than not guessing.
    return null
  }
}
