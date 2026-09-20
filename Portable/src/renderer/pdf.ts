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

export async function loadDocument(data: Uint8Array): Promise<PDFDocumentProxy> {
  return pdfjs.getDocument({
    // pdf.js takes ownership of the buffer it is handed, and the same bytes
    // are wanted again when the file is re-read after a save.
    data: data.slice(),
    cMapUrl: new URL('cmaps/', document.baseURI).toString(),
    cMapPacked: true,
    standardFontDataUrl: new URL('standard_fonts/', document.baseURI).toString(),
    // Nothing in a paper should be able to reach out of the window.
    isEvalSupported: false,
    disableAutoFetch: false,
  }).promise
}

export const { TextLayer, Util } = pdfjs
