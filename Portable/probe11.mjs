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
async function rightsLock(b){ if(containerKind(b))return{kind:'rights',handler:rightsHandler(b)??''}
  try{const d=await PDFDocument.load(b,{ignoreEncryption:true,updateMetadata:false}); if(!d.isEncrypted)return null}
  catch{const h=rightsHandler(b);return h?{kind:'rights',handler:h}:null}
  const h=rightsHandler(b); return h?{kind:'rights',handler:h}:{kind:'password'} }
const READ_AGAIN=new Set(['cut','placeholder','empty'])
let reads=0, bytesRead=0
async function readWhole(f){let b=await fsp.readFile(f);reads++;bytesRead+=b.length
  for(let a=1;a<6;a+=1){if(looksWhole(b))break;const t=diagnose(b);if(!t||!READ_AGAIN.has(t))break
    await new Promise(r=>setTimeout(r,250));b=await fsp.readFile(f);reads++;bytesRead+=b.length}
  return b}
async function paperBytes(f){ const b=await readWhole(f); const t=diagnose(b); await rightsLock(b); return t }

const file=process.argv[2], n=Number(process.argv[3]||4)
let ticks=0;const iv=setInterval(()=>ticks++,10);await new Promise(r=>setTimeout(r,100))
const before=ticks, t0=performance.now()
await Promise.all(Array.from({length:n},()=>paperBytes(file)))
const wall=performance.now()-t0; clearInterval(iv)
const expected=Math.round(wall/10), got=ticks-before
console.log(`${n} concurrent paper:bytes on ${file.split('/').pop()}`)
console.log(`  wall=${wall.toFixed(0)}ms  reads=${reads}  I/O=${(bytesRead/1e6).toFixed(0)}MB`)
console.log(`  main process frozen ~${(expected-got)*10}ms of that`)
