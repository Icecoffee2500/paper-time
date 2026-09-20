/**
 * Lists a PDF's annotations by subtype and owner.
 *
 * The quickest way to answer "did that actually get written into the file?",
 * which during this port was the question about half the time.
 *
 *   node tools/dump-annots.mjs <file.pdf>
 */
import { PDFArray, PDFDict, PDFDocument, PDFHexString, PDFName, PDFRef, PDFString } from 'pdf-lib'
import fs from 'node:fs'

const file = process.argv[2]
if (!file) {
  console.error('Usage: node tools/dump-annots.mjs <file.pdf>')
  process.exit(2)
}

const document = await PDFDocument.load(fs.readFileSync(file), {
  ignoreEncryption: true,
  updateMetadata: false,
})
const context = document.context
let total = 0

document.getPages().forEach((page, index) => {
  const annots = page.node.get(PDFName.of('Annots'))
  if (!(annots instanceof PDFArray)) return
  const counts = {}
  for (let k = 0; k < annots.size(); k += 1) {
    const entry = annots.get(k)
    const dict = entry instanceof PDFRef ? context.lookup(entry, PDFDict) : entry
    if (!(dict instanceof PDFDict)) continue
    const subtype = String(dict.get(PDFName.of('Subtype')))
    const title = dict.get(PDFName.of('T'))
    const owner = title instanceof PDFString || title instanceof PDFHexString
      ? title.decodeText()
      : String(title ?? '')
    const marks = [
      dict.get(PDFName.of('PTInk')) ? '+PTInk' : '',
      dict.get(PDFName.of('PTSketch')) ? '+PTSketch' : '',
      dict.get(PDFName.of('PTMarkupID')) ? '+PTMarkupID' : '',
    ].filter(Boolean).join(' ')
    const key = `${subtype} T=${owner}${marks ? ` ${marks}` : ''}`
    counts[key] = (counts[key] ?? 0) + 1
    total += 1
  }
  if (Object.keys(counts).length > 0) console.log(`page ${index}:`, counts)
})

console.log(total === 0 ? 'No annotations.' : `${total} annotations.`)
