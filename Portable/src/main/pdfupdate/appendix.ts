/**
 * The bytes an incremental update appends: the objects, a cross-reference
 * section of the same kind as the file's newest one, and a trailer pointing
 * back at the section before it. The port of `Appendix.swift`, kept
 * byte-compatible in shape so a file the Mac appended to and one this build
 * appended to read alike.
 */
import crypto from 'node:crypto'
import { PDFFile, SECTION_KEYS, type SectionKind } from './file.js'
import { Bytes, Filters, PDFDict, Serializer, obj, type PDFObj, type PDFRef } from './syntax.js'

/** An object's new version, either as a value to serialise or as text
 *  already in the file's own words (a page with one entry spliced). */
export type Body = { kind: 'object'; value: PDFObj } | { kind: 'raw'; text: Uint8Array }

/** An object this update frees, and the generation its free entry says —
 *  one more than the generation it was in use under. */
export interface Freed {
  num: number
  gen: number
}

type Row = { used: true; off: number; gen: number } | { used: false; next: number; gen: number }

export function appendixBytes(
  file: PDFFile,
  objects: [PDFRef, Body][],
  freed: Freed[],
  firstFree: number,
): { bytes: Uint8Array; kind: SectionKind } {
  const body = new Bytes()
  const base = file.count
  const last = file.bytes[file.bytes.length - 1]
  if (last !== 0x0a && last !== 0x0d) body.push('\n')
  const offsets: [PDFRef, number][] = []
  const sorted = [...objects].sort((a, b) => (a[0].num !== b[0].num ? a[0].num - b[0].num : a[0].gen - b[0].gen))
  for (const [r, content] of sorted) {
    offsets.push([r, base + body.length])
    body.push(`${r.num} ${r.gen} obj\n`)
    if (content.kind === 'object') {
      Serializer.write(file.security ? file.security.encrypting(content.value, r) : content.value, body)
    } else {
      // In the file's own words — and, in an encrypted file, its own
      // ciphertext, which stays good because the object keeps its number
      // and generation.
      body.push(content.text)
    }
    body.push('\nendobj\n')
  }

  // The trailer says everything the previous one said but /Prev, and the
  // second half of /ID changes because the file did.
  const trailer = new PDFDict()
  for (const [k, v] of file.trailer.pairs) if (!SECTION_KEYS.has(k) && k !== 'Size') trailer.pairs.push([k, v])
  const id = file.trailer.get('ID')
  if (id?.t === 'array' && id.v.length === 2) {
    const hasher = crypto.createHash('md5')
    hasher.update(id.v[0].t === 'string' ? id.v[0].v : new Uint8Array())
    hasher.update(body.bytes())
    trailer.set('ID', obj.array([id.v[0], obj.string(new Uint8Array(hasher.digest()), true)]))
  }

  // The free list: object 0 heads it, each freed number points at the next,
  // the last back at 0 (ISO 32000-1 §7.5.4).
  const freedSorted = [...freed].sort((a, b) => a.num - b.num)
  const nextFree = new Map<number, number>()
  freedSorted.forEach((f, i) => nextFree.set(f.num, i + 1 < freedSorted.length ? freedSorted[i + 1].num : 0))
  const head = freedSorted[0]?.num ?? 0

  const rows: [number, Row][] = [[0, { used: false, next: head, gen: 65535 }]]
  for (const [r, off] of offsets) rows.push([r.num, { used: true, off, gen: r.gen }])
  for (const f of freedSorted) rows.push([f.num, { used: false, next: nextFree.get(f.num) ?? 0, gen: Math.min(f.gen, 65535) }])

  const useStream = file.sections[0]?.kind === 'stream'
  if (!useStream) {
    const byNumber = new Map<number, Row>()
    for (const [num, row] of rows) if (!byNumber.has(num)) byNumber.set(num, row)
    const xrefOffset = base + body.length
    let size = Math.max(file.size, firstFree)
    for (const [num] of rows) size = Math.max(size, num + 1)
    body.push('xref\n')
    for (const group of consecutive(rows.map(([num]) => num))) {
      body.push(`${group[0]} ${group[1] - group[0] + 1}\n`)
      for (let n = group[0]; n <= group[1]; n += 1) {
        const row = byNumber.get(n)
        if (!row) continue
        if (row.used) body.push(`${pad(row.off, 10)} ${pad(row.gen, 5)} n\r\n`)
        else body.push(`${pad(row.next, 10)} ${pad(row.gen, 5)} f\r\n`)
      }
    }
    const t = new PDFDict([['Size', obj.int(size)]])
    t.pairs.push(...trailer.pairs)
    t.pairs.push(['Prev', obj.int(file.startxref)])
    body.push('trailer\n')
    Serializer.writeDict(t, body)
    body.push(`\nstartxref\n${xrefOffset}\n%%EOF\n`)
    return { bytes: body.bytes(), kind: 'table' }
  }

  // A cross-reference stream, which lists itself.
  let highest = 0
  for (const [num] of rows) highest = Math.max(highest, num + 1)
  const xrefNum = Math.max(file.size, firstFree, highest)
  const xrefOffset = base + body.length
  rows.push([xrefNum, { used: true, off: xrefOffset, gen: 0 }])
  const byNumber = new Map<number, Row>()
  for (const [num, row] of rows) if (!byNumber.has(num)) byNumber.set(num, row)
  let widest = 0
  for (const [, row] of rows) widest = Math.max(widest, row.used ? row.off : row.next)
  let w2 = 1
  while (w2 < 8 && 2 ** (8 * w2) <= widest) w2 += 1
  const data: number[] = []
  const index: PDFObj[] = []
  for (const group of consecutive(rows.map(([num]) => num))) {
    index.push(obj.int(group[0]), obj.int(group[1] - group[0] + 1))
    for (let n = group[0]; n <= group[1]; n += 1) {
      const row = byNumber.get(n)
      if (!row) continue
      const [type, f2, f3] = row.used ? [1, row.off, row.gen] : [0, row.next, row.gen]
      data.push(type)
      for (let s = 8 * (w2 - 1); s >= 0; s -= 8) data.push(Math.floor(f2 / 2 ** s) & 0xff)
      data.push((f3 >> 8) & 0xff, f3 & 0xff)
    }
  }
  const d = new PDFDict([
    ['Type', obj.name('XRef')],
    ['Size', obj.int(xrefNum + 1)],
    ['W', obj.array([obj.int(1), obj.int(w2), obj.int(2)])],
    ['Index', obj.array(index)],
    ['Prev', obj.int(file.startxref)],
    ['Filter', obj.name('FlateDecode')],
  ])
  d.pairs.push(...trailer.pairs)
  body.push(`${xrefNum} 0 obj\n`)
  Serializer.write(obj.stream(d, Filters.deflate(Uint8Array.from(data))), body)
  body.push(`\nendobj\nstartxref\n${xrefOffset}\n%%EOF\n`)
  return { bytes: body.bytes(), kind: 'stream' }
}

const pad = (n: number, width: number) => String(n).padStart(width, '0')

/** Runs of consecutive numbers, one subsection each. */
export function consecutive(numbers: number[]): [number, number][] {
  const groups: [number, number][] = []
  for (const n of [...numbers].sort((a, b) => a - b)) {
    const last = groups[groups.length - 1]
    if (last && last[1] + 1 === n) last[1] = n
    else if (!(last && n >= last[0] && n <= last[1])) groups.push([n, n])
  }
  return groups
}
