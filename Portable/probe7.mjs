import fsp from 'node:fs/promises'
const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs')
pdfjs.GlobalWorkerOptions.workerSrc = 'pdfjs-dist/legacy/build/pdf.worker.mjs'
const file = process.argv[2]
const data = new Uint8Array(await fsp.readFile(file))
const t = performance.now()
try {
  const doc = await pdfjs.getDocument({ data, isEvalSupported:false, useSystemFonts:false }).promise
  console.log('pdf.js OPENED', file.split('/').pop(), 'pages=', doc.numPages, (performance.now()-t).toFixed(0)+'ms')
  await doc.destroy()
} catch (e) {
  console.log('pdf.js FAILED', file.split('/').pop(), '->', String(e).slice(0,90))
}
