/**
 * When two annotations are the same, whose an annotation is, and what an
 * object reaches — the three small questions the writer asks of the file.
 * The port of `Canonical`, `Ownership` and `Reach` in `IncrementalWriter.swift`
 * and of `AnnotationFingerprint.swift`.
 */
import crypto from 'node:crypto'
import type { PDFFile } from './file.js'
import { Bytes, Serializer, dictOf, nameOf, textOf, type PDFObj } from './syntax.js'

/**
 * An annotation, references inlined, without the keys that say where it
 * lives or when it was written, or its appearance — what makes two copies
 * "the same". The appearance is left out because a writer names its
 * resources by what else was in the same file.
 */
export function canonicalForm(o: PDFObj, f: PDFFile): Uint8Array {
  const out = new Bytes()
  const visiting = new Set<number>()
  const emit = (x: PDFObj, depth: number) => {
    if (depth >= 32) { out.push('…'); return }
    switch (x.t) {
      case 'ref': {
        if (visiting.has(x.v.num)) { out.push('^'); return }
        let resolved: PDFObj
        try { resolved = f.object(x.v.num) } catch { out.push('?'); return }
        const type = nameOf(dictOf(resolved)?.get('Type'))
        if (type === 'Page' || type === 'Pages') { out.push('PAGE'); return }
        visiting.add(x.v.num)
        emit(resolved, depth + 1)
        visiting.delete(x.v.num)
        return
      }
      case 'array':
        out.push('[')
        for (const i of x.v) { emit(i, depth + 1); out.push(' ') }
        out.push(']')
        return
      case 'dict':
      case 'stream': {
        const d = x.t === 'dict' ? x.v : x.dict
        out.push('<<')
        for (const [k, v] of [...d.pairs].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))) {
          if (k === 'P' || k === 'M' || k === 'AP' || k === 'Popup' || k === 'Length') continue
          out.push(`/${k} `)
          emit(v, depth + 1)
          out.push(' ')
        }
        out.push('>>')
        if (x.t === 'stream') {
          out.push('stream')
          out.push(new Uint8Array(crypto.createHash('sha256').update(x.data).digest()))
        }
        return
      }
      case 'string':
        // Literal or hex is spelling, not meaning — and a decrypted string
        // comes back in whichever form it was stored.
        Serializer.writeString(x.v, true, out)
        return
      default:
        Serializer.write(x, out)
    }
  }
  emit(o, 0)
  return out.bytes()
}

/**
 * What an annotation says, digested — the hash of its canonical form. Two
 * digests are only ever compared within one save, to tell an annotation
 * the file already holds as this build would write it from one it must
 * write again.
 */
export function fingerprint(o: PDFObj, f: PDFFile): string {
  return crypto.createHash('sha256').update(canonicalForm(o, f)).digest('hex')
}

/** An annotation this app wrote: it carries one of our keys, or the title
 *  our writers give it. */
export function isOurs(o: PDFObj): boolean {
  const d = dictOf(o)
  if (!d) return false
  if (d.has('PTMarkupID') || d.has('PTSketchID') || d.has('PTInk')) return true
  const title = textOf(d.get('T'))
  return title === 'Paper Time' || title === 'Paper Time Sketch'
}

/** Every object number reachable from `o`, not through a page's /P and not
 *  into the page tree or the catalog. */
export function reach(o: PDFObj, f: PDFFile, into: Set<number>, depth = 0) {
  if (depth >= 48) return
  switch (o.t) {
    case 'ref': {
      if (into.has(o.v.num)) return
      let resolved: PDFObj
      try { resolved = f.object(o.v.num) } catch { return }
      const type = nameOf(dictOf(resolved)?.get('Type'))
      if (type === 'Page' || type === 'Pages' || type === 'Catalog') return
      into.add(o.v.num)
      reach(resolved, f, into, depth + 1)
      return
    }
    case 'array':
      for (const item of o.v) reach(item, f, into, depth + 1)
      return
    case 'dict':
    case 'stream': {
      const d = o.t === 'dict' ? o.v : o.dict
      for (const [k, v] of d.pairs) if (k !== 'P') reach(v, f, into, depth + 1)
      return
    }
    default:
  }
}
