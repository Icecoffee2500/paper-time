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
    this.name = 'NeedsPassword'
  }
}

/** A document being opened: its promise, and the way to stop it. */
export interface Opening {
  promise: Promise<PDFDocumentProxy>
  /** Stops the load — a reader closed, or given another paper, before it ended. */
  destroy: () => void
}

/**
 * @param askPassword what to show when the file is locked. Returning null
 *   gives up, and the reader says so rather than waiting: pdf.js keeps the
 *   promise pending for as long as nobody answers, which is how a locked
 *   paper used to sit on a blank page forever with no message at all.
 */
export function openDocument(
  data: Uint8Array,
  askPassword?: (wrong: boolean) => Promise<string | null>,
): Opening {
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
  // A password nobody gave ends the load with its own error. Thrown inside
  // `onPassword` it was swallowed by pdf.js, and the promise never settled.
  let refuse: (error: Error) => void = () => undefined
  const refused = new Promise<never>((_, reject) => { refuse = reject })
  task.onPassword = (supply: (password: string) => void, reason: number) => {
    // 1 is "needs one", 2 is "the one you gave is wrong".
    const wrong = reason === 2
    if (!askPassword) {
      refuse(new NeedsPassword(wrong))
      void task.destroy()
      return
    }
    void askPassword(wrong).then((password) => {
      if (password !== null) return supply(password)
      refuse(new NeedsPassword(wrong))
      void task.destroy()
    })
  }
  return {
    promise: Promise.race([task.promise as Promise<PDFDocumentProxy>, refused]),
    destroy: () => void task.destroy(),
  }
}

/** The same, for whoever wants only the document. */
export function loadDocument(
  data: Uint8Array,
  askPassword?: (wrong: boolean) => Promise<string | null>,
): Promise<PDFDocumentProxy> {
  return openDocument(data, askPassword).promise
}

/** Lets go of what pdf.js's text layers keep between pages — once no reader
 *  is left to use it. */
export function releaseTextCaches() {
  ;(TextLayer as unknown as { cleanup?: () => void }).cleanup?.()
}

export const { TextLayer, Util, OPS } = pdfjs
