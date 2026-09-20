/**
 * pdf.js's worker, bundled into the app rather than fetched.
 *
 * The renderer has no network at all — the content security policy in
 * `index.html` says `default-src 'none'` — so the worker has to ship beside
 * the page and be loaded from it.
 */
import 'pdfjs-dist/build/pdf.worker.mjs'
