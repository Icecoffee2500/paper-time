import fs from 'node:fs/promises'
import { PDFDocument } from 'pdf-lib'
const KNOWN = ['MicrosoftIRMServices','FoxitIRM','Adobe.PubSec','EBX_HANDLER']
function rightsHandler(bytes){
  const text = new TextDecoder('latin1').decode(bytes)
  return KNOWN.find(h=>text.includes(h)) ?? null
}
const list = (await fs.readFile(process.argv[2],'utf8')).split('\n').filter(Boolean)
let throws = []
for (const p of list) {
  let b; try { b = await fs.readFile(p) } catch { continue }
  if (b.length < 8) continue
  try {
    await PDFDocument.load(b, { ignoreEncryption: true, updateMetadata: false })
  } catch (e) {
    const t0 = performance.now()
    rightsHandler(b)
    const dt = performance.now() - t0
    throws.push([b.length, dt.toFixed(0), String(e).slice(0,70), p])
  }
}
console.log('pdf-lib threw on', throws.length, 'of', list.length)
throws.sort((a,b)=>b[0]-a[0])
for (const t of throws.slice(0,20)) console.log('  size=',t[0],'rightsHandler ms=',t[1], '|', t[2], '|', t[3].split('/').pop())
