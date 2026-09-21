/**
 * pdf.js, set up once.
 *
 * The character maps and the standard fourteen fonts are copied into the build
 * because a paper set in a CJK face, or one that leans on Times rather than
 * embedding it, renders as empty boxes without them — and a reader that cannot
 * show a Korean paper is not much of a reader here.
 */
// The ESM build carries no types of its own; the package's `types/` does.
// @ts-expect-error -- pdfjs-dist ships the declarations beside the CJS entry
import * as pdfjs from 'pdfjs-dist/build/pdf.mjs'
import type { PDFDocumentProxy, PDFPageProxy } from 'pdfjs-dist'

pdfjs.GlobalWorkerOptions.workerSrc = new URL('pdf.worker.js', document.baseURI).toString()

export type { PDFDocumentProxy, PDFPageProxy }

/** Thrown when the file wants a password and nobody was there to ask. */
export class NeedsPassword extends Error {
  constructor(public readonly wrong: boolean) {
    super(wrong ? 'wrong password' : 'password needed')
  }
}

/**
 * @param askPassword what to show when the file is locked. Returning null
 *   gives up, and the reader says so rather than waiting: pdf.js keeps the
 *   promise pending for as long as nobody answers, which is how a locked
 *   paper used to sit on a blank page forever with no message at all.
 */
export async function loadDocument(
  data: Uint8Array,
  askPassword?: (wrong: boolean) => Promise<string | null>,
): Promise<PDFDocumentProxy> {
  const task = pdfjs.getDocument({
    // pdf.js takes ownership of the buffer it is handed, and the same bytes
    // are wanted again when the file is re-read after a save.
    data: data.slice(),
    cMapUrl: new URL('cmaps/', document.baseURI).toString(),
    cMapPacked: true,
    standardFontDataUrl: new URL('standard_fonts/', document.baseURI).toString(),
    // Nothing in a paper should be able to reach out of the window.
    isEvalSupported: false,
    disableAutoFetch: false,
  })
  task.onPassword = (supply: (password: string) => void, reason: number) => {
    // 1 is "needs one", 2 is "the one you gave is wrong".
    const wrong = reason === 2
    if (!askPassword) {
      void task.destroy()
      throw new NeedsPassword(wrong)
    }
    void askPassword(wrong).then((password) => {
      if (password === null) void task.destroy()
      else supply(password)
    })
  }
  return task.promise
}

export const { TextLayer, Util } = pdfjs
