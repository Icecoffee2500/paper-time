import fsp from 'node:fs/promises'
import fs from 'node:fs'
// --- faithful copy of shared/pdfLock.ts pieces ---
const HEAD=1024, TAIL=2048
const latin1=(b,f,t)=>new TextDecoder('latin1').decode(b.subarray(Math.max(0,f),Math.max(0,t)))
const looksLikePDF=b=>latin1(b,0,HEAD).includes('%PDF-')
const looksWhole=b=>looksLikePDF(b)&&latin1(b,b.length-TAIL,b.length).includes('%%EOF')
function containerKind(b){if(b.length<8||looksLikePDF(b))return null;const O=[0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1];if(O.every((x,i)=>b[i]===x))return 'ole';if(b[0]===0x50&&b[1]===0x4b&&b[2]===0x03&&b[3]===0x04)return 'zip';return null}
function diagnose(b){if(b.length===0)return 'empty';if(containerKind(b))return 'wrapped';if(looksLikePDF(b))return looksWhole(b)?null:'cut';const h=latin1(b,0,HEAD);if(/^\s*(<!doctype html|<html|<\?xml|\{)/i.test(h))return 'webpage';if(b.subarray(0,Math.min(b.length,HEAD)).every(x=>x===0))return 'placeholder';return 'webpage'}
// --- faithful copy of main.ts readWhole, instrumented ---
const READ_AGAIN = new Set(['cut','placeholder','empty'])
let reads = 0, bytesRead = 0
async function readWhole(file){
  let bytes = await fsp.readFile(file); reads++; bytesRead += bytes.length
  for (let attempt=1; attempt<6; attempt+=1){
    if (looksWhole(bytes)) break
    const trouble = diagnose(bytes)
    if (!trouble || !READ_AGAIN.has(trouble)) break
    await new Promise(r=>setTimeout(r,250))
    bytes = await fsp.readFile(file); reads++; bytesRead += bytes.length
  }
  return bytes
}
const file = process.argv[2]
reads=0; bytesRead=0
let t0=performance.now()
let b = await readWhole(file)
console.log(`${file.split('/').pop()}: reads=${reads} bytesRead=${(bytesRead/1e6).toFixed(1)}MB wall=${(performance.now()-t0).toFixed(0)}ms diagnose=${diagnose(b)}`)
