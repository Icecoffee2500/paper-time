import fsp from 'node:fs/promises'
const KNOWN=['MicrosoftIRMServices','FoxitIRM','Adobe.PubSec','EBX_HANDLER']
const rightsHandler=b=>{const t=new TextDecoder('latin1').decode(b);return KNOWN.find(h=>t.includes(h))??null}
const b = await fsp.readFile(process.argv[2])
// how long is the event loop unavailable while this runs?
let ticks = 0
const iv = setInterval(()=>ticks++, 10)
await new Promise(r=>setTimeout(r,200))
const before = ticks
const t0 = performance.now()
rightsHandler(b)
const dt = performance.now()-t0
const stalled = ticks - before
clearInterval(iv)
console.log(`size=${(b.length/1e6).toFixed(0)}MB  decode=${dt.toFixed(0)}ms  10ms-timers that fired during it=${stalled} (expected ~${Math.round(dt/10)} if not blocking)`)
