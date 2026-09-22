import fsp from 'node:fs/promises'
import { PDFDocument } from 'pdf-lib'
const HEAD=1024, TAIL=2048
const latin1=(b,f,t)=>new TextDecoder('latin1').decode(b.subarray(Math.max(0,f),Math.max(0,t)))
const looksLikePDF=b=>latin1(b,0,HEAD).includes('%PDF-')
const looksWhole=b=>looksLikePDF(b)&&latin1(b,b.length-TAIL,b.length).includes('%%EOF')
function containerKind(b){if(b.length<8||looksLikePDF(b))return null;const O=[0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1];if(O.every((x,i)=>b[i]===x))return 'ole';if(b[0]===0x50&&b[1]===0x4b&&b[2]===0x03&&b[3]===0x04)return 'zip';return null}
function diagnose(b){if(b.length===0)return 'empty';if(containerKind(b))return 'wrapped';if(looksLikePDF(b))return looksWhole(b)?null:'cut';const h=latin1(b,0,HEAD);if(/^\s*(<!doctype html|<html|<\?xml|\{)/i.test(h))return 'webpage';if(b.subarray(0,Math.min(b.length,HEAD)).every(x=>x===0))return 'placeholder';return 'webpage'}
const KNOWN=['MicrosoftIRMServices','FoxitIRM','Adobe.PubSec','EBX_HANDLER']
const rightsHandler=b=>{const t=new TextDecoder('latin1').decode(b);return KNOWN.find(h=>t.includes(h))??null}
async function rightsLock(b){ if(containerKind(b)) return {kind:'rights',handler:rightsHandler(b)??''}
  let enc=false
  try { const d=await PDFDocument.load(b,{ignoreEncryption:true,updateMetadata:false}); enc=d.isEncrypted }
  catch { const h=rightsHandler(b); return h?{kind:'rights',handler:h}:null }
  if(!enc) return null
  const h=rightsHandler(b); return h?{kind:'rights',handler:h}:{kind:'password'} }
const READ_AGAIN=new Set(['cut','placeholder','empty'])
let reads=0
async function readWhole(f){ let b=await fsp.readFile(f); reads++
  for(let a=1;a<6;a+=1){ if(looksWhole(b))break; const t=diagnose(b); if(!t||!READ_AGAIN.has(t))break
    await new Promise(r=>setTimeout(r,250)); b=await fsp.readFile(f); reads++ }
  return b }

const file=process.argv[2]
let ticks=0; const iv=setInterval(()=>ticks++,10); await new Promise(r=>setTimeout(r,100))
const t0=performance.now(); const before=ticks
const bytes=await readWhole(file)
const tRead=performance.now()
const trouble=diagnose(bytes)
await rightsLock(bytes)
const tLock=performance.now()
clearInterval(iv)
const wall=tLock-t0, expected=Math.round(wall/10), got=ticks-before
console.log(`${file.split('/').pop()}  size=${(bytes.length/1e6).toFixed(0)}MB reads=${reads} trouble=${trouble}`)
console.log(`  readWhole ${(tRead-t0).toFixed(0)}ms | rightsLock ${(tLock-tRead).toFixed(0)}ms | total before pdf.js is even handed anything: ${wall.toFixed(0)}ms`)
console.log(`  event loop: ${got} of ~${expected} 10ms ticks fired -> main process frozen ~${((expected-got)*10)}ms`)
