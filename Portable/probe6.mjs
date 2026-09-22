import fsp from 'node:fs/promises'
import { PDFDocument } from 'pdf-lib'
const KNOWN=['MicrosoftIRMServices','FoxitIRM','Adobe.PubSec','EBX_HANDLER']
const rightsHandler=b=>{const t=new TextDecoder('latin1').decode(b);return KNOWN.find(h=>t.includes(h))??null}
const file=process.argv[2]
const b=await fsp.readFile(file)
let t=performance.now(); let threw=false
try { await PDFDocument.load(b,{ignoreEncryption:true,updateMetadata:false}) } catch(e){ threw=true; var err=String(e).slice(0,80) }
console.log('pdf-lib load:', (performance.now()-t).toFixed(0),'ms threw=',threw, err??'')
if (threw){
  t=performance.now(); const h=rightsHandler(b)
  console.log('rightsHandler full-buffer decode:', (performance.now()-t).toFixed(0),'ms  size=',(b.length/1e6).toFixed(1),'MB  found=',h)
}
