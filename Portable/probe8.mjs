import fsp from 'node:fs/promises'
// 2 KB of junk in front of a real PDF: pdf.js is famously tolerant of this.
const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs')
const src = process.argv[2]
const real = await fsp.readFile(src)
const junk = Buffer.alloc(2048, 0x41) // 'A' x 2048
const b = new Uint8Array(Buffer.concat([junk, real]))
const HEAD=1024
const latin1=(x,f,t)=>new TextDecoder('latin1').decode(x.subarray(Math.max(0,f),Math.max(0,t)))
const looksLikePDF=x=>latin1(x,0,HEAD).includes('%PDF-')
function containerKind(x){if(x.length<8||looksLikePDF(x))return null;const O=[0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1];if(O.every((v,i)=>x[i]===v))return 'ole';if(x[0]===0x50&&x[1]===0x4b&&x[2]===0x03&&x[3]===0x04)return 'zip';return null}
function diagnose(x){if(x.length===0)return 'empty';if(containerKind(x))return 'wrapped';if(looksLikePDF(x))return null;const h=latin1(x,0,HEAD);if(/^\s*(<!doctype html|<html|<\?xml|\{)/i.test(h))return 'webpage';if(x.subarray(0,Math.min(x.length,HEAD)).every(v=>v===0))return 'placeholder';return 'webpage'}
console.log('diagnose(2KB junk + real pdf) =', diagnose(b), '-> paper:bytes would REFUSE if webpage')
try { const d = await pdfjs.getDocument({data:b.slice(), isEvalSupported:false}).promise; console.log('pdf.js OPENED it, pages =', d.numPages); await d.destroy() }
catch(e){ console.log('pdf.js FAILED ->', String(e).slice(0,80)) }
