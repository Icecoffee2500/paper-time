/**
 * Saves annotation changes as a PDF incremental update (ISO 32000-1 §7.5.6):
 * the original bytes stay exactly as they were, and the new annotation
 * objects, new versions of the pages whose /Annots changed, a cross-
 * reference section and a trailer pointing back with /Prev are appended.
 *
 * The port of the Mac's `IncrementalWriter.swift`, with one difference of
 * shape: there PDFKit makes the annotations and the writer lifts them out of
 * a scratch document; here `pdfwrite.ts` builds the dictionaries itself and
 * hands them in already numbered (`NewObjects`). What is the same is
 * everything that decides whether a file is written at all. When anything
 * about the file is in doubt the writer refuses, with a `Refusal` that says
 * why, and writes nothing. It never falls back to rewriting the paper — a
 * rewrite is what the Mac reads as "another app touched this file", and
 * what takes the original bytes, and with them the text layer's guarantee,
 * away for good.
 */
import { appendixBytes, type Body, type Freed } from './appendix.js'
import { isOurs, reach } from './canonical.js'
import { SecurityFailure, StandardSecurity } from './crypt.js'
import { PDFFile, type PageInfo } from './file.js'
import {
  Bytes,
  PDFDict,
  Serializer,
  arrayOf,
  dictOf,
  intOf,
  nameOf,
  obj,
  ref,
  refOf,
  refString,
  sameRef,
  spansOf,
  stringBytesOf,
  type PDFObj,
  type PDFRef,
  type Spans,
} from './syntax.js'

export type RefusalKind =
  /** Another security handler, or a cipher this writer does not know. */
  | 'encrypted'
  /** The file needs a user password nobody gave. */
  | 'needsPassword'
  /** The file's permissions, or its certification, forbid annotations. */
  | 'permissions'
  /** The file's structure could not be read without guessing. */
  | 'unreadableStructure'
  /** A page's annotations cannot be matched to what the file says. */
  | 'annotationMapping'
  /** The result did not read back as it should have. */
  | 'verificationFailed'

/** Why a save was not made. The caller keeps the marks where they already
 *  are (journal, sidecars) and says so; nothing is written. */
export class Refusal extends Error {
  constructor(readonly kind: RefusalKind, why: string) {
    super(`${kind}: ${why}`)
    this.name = 'Refusal'
  }
}

export interface Stats {
  bytesBefore: number
  bytesAfter: number
  xrefKind: string
  pagesChanged: number
  annotationsAdded: number
  annotationsRemoved: number
  objectsWritten: number
  objectsFreed: number
  pagesSpliced: number
  pagesSerialised: number
  ms: number
}

export type Outcome =
  | { kind: 'unchanged'; stats: Stats }
  /** The original bytes followed by the update. */
  | { kind: 'appended'; bytes: Uint8Array; stats: Stats }

export interface Options {
  /** The user password, for a file that asks for one. Empty for the usual
   *  encrypted paper, which opens without asking. */
  password?: Uint8Array
  /** Whether objects the update takes out of use are marked free. */
  freeRemovedObjects?: boolean
  /** Whether the result is read back and checked before it is handed back. */
  verify?: boolean
}

/** New objects for the update, numbered after the file's. */
export class NewObjects {
  readonly objects: [PDFRef, PDFObj][] = []
  constructor(public next: number) {}

  add(value: PDFObj): PDFRef {
    const r = ref(this.next, 0)
    this.next += 1
    this.objects.push([r, value])
    return r
  }
}

/** What one page's save takes out and puts in. */
export interface PageEdit {
  /** Index into the file's pages. */
  index: number
  /** Indices into the page's /Annots elements, as `Opened.annots` lists them. */
  removed: number[]
  /** References to annotations registered with `NewObjects`, in the order
   *  they go onto the end of the page's list. */
  added: PDFRef[]
}

/** The live elements of a page's /Annots. */
export interface PageAnnots {
  index: number
  info: PageInfo
  /** The /Annots array as written. */
  elements: PDFObj[]
  /** Each element's text as the file wrote it, when it can be had. */
  elementTexts: Uint8Array[] | null
  /** The elements that are annotation dictionaries, resolved. */
  dicts: (PDFDict | null)[]
  /** When /Annots is an indirect array. */
  indirectArray: PDFRef | null
}

/**
 * A file opened for writing into: the chain read, the key found, the pages
 * listed — and every reason not to go on already raised.
 */
export class Opened {
  readonly file: PDFFile
  readonly pages: PageInfo[]
  readonly password: Uint8Array

  private constructor(file: PDFFile, pages: PageInfo[], password: Uint8Array) {
    this.file = file
    this.pages = pages
    this.password = password
  }

  static open(original: Uint8Array, options: Options = {}): Opened {
    let file: PDFFile
    try {
      file = new PDFFile(original)
    } catch (error) {
      throw new Refusal('unreadableStructure', String((error as Error).message ?? error))
    }
    if (file.repaired) {
      throw new Refusal('unreadableStructure', `cross-reference chain needs repair: ${file.notes.join('; ')}`)
    }
    const password = options.password ?? new Uint8Array()
    Opened.openSecurity(file, password)
    let pages: PageInfo[]
    try {
      pages = file.pages()
    } catch (error) {
      throw new Refusal('unreadableStructure', `page tree: ${String((error as Error).message ?? error)}`)
    }
    const opened = new Opened(file, pages, password)
    opened.refuseGuesses()
    opened.checkCertification()
    return opened
  }

  /** The standard security handler with the user password (usually the
   *  empty one) is written into; anything else is refused. */
  static openSecurity(file: PDFFile, password: Uint8Array) {
    if (!file.isEncrypted) return
    const encrypt = dictOf(file.resolveQuietly(file.trailer.get('Encrypt')))
    if (!encrypt) throw new Refusal('encrypted', 'no /Encrypt dictionary')
    const id0 = stringBytesOf(arrayOf(file.trailer.get('ID'))?.[0]) ?? new Uint8Array()
    try {
      file.security = new StandardSecurity(encrypt, id0, password)
    } catch (error) {
      if (error instanceof SecurityFailure && error.kind === 'wrongPassword') throw new Refusal('needsPassword', error.message)
      throw new Refusal('encrypted', String((error as Error).message ?? error))
    }
    if (!file.security!.allowsAnnotations) throw new Refusal('permissions', 'the file\'s permissions do not allow adding annotations')
  }

  /** Anything read so far that this reader had to guess at — an object
   *  found by scanning, a stream whose length was repaired — means the save
   *  is off: another reader may have guessed differently. */
  refuseGuesses() {
    if (this.file.guessedReads > 0) {
      throw new Refusal('unreadableStructure', `the reader had to guess: ${this.file.notes.join('; ')}`)
    }
  }

  /** A certified document (ISO 32000-1 §12.8.2.2) says how much may change
   *  after it was signed; below 3, annotations may not. */
  private checkCertification() {
    const f = this.file
    const root = dictOf(f.resolveQuietly(f.trailer.get('Root')))
    const perms = dictOf(f.resolveQuietly(root?.get('Perms')))
    const mdp = dictOf(f.resolveQuietly(perms?.get('DocMDP')))
    if (!mdp) return
    let p = 2 // absent /P means 2
    for (const r of arrayOf(f.resolveQuietly(mdp.get('Reference'))) ?? []) {
      const tp = dictOf(f.resolveQuietly(dictOf(f.resolveQuietly(r))?.get('TransformParams')))
      const v = intOf(tp?.get('P'))
      if (v !== undefined) p = v
    }
    if (p < 3) throw new Refusal('permissions', 'the document is certified against annotations')
  }

  /** The elements of a page's /Annots, each resolved to its dictionary. */
  annots(index: number): PageAnnots {
    const f = this.file
    const info = this.pages[index]
    if (info.dict.count('Annots') > 1) {
      throw new Refusal('annotationMapping', `page ${index}: the page dictionary has more than one /Annots`)
    }
    let elements: PDFObj[] = []
    let indirect: PDFRef | null = null
    const a = info.dict.get('Annots')
    if (a) {
      const r = refOf(a)
      if (r) indirect = ref(r.num, f.generation(r.num))
      let resolved: PDFObj
      try {
        resolved = f.resolve(a)
      } catch (error) {
        throw new Refusal('unreadableStructure', `page ${index}: /Annots: ${String((error as Error).message ?? error)}`)
      }
      if (resolved.t === 'array') elements = resolved.v
      else if (resolved.t !== 'null') throw new Refusal('annotationMapping', `page ${index}: /Annots is not an array`)
    }
    const dicts = elements.map((e) => {
      const d = dictOf(f.resolveQuietly(e))
      return d && (d.has('Subtype') || d.has('Rect')) ? d : null
    })
    return { index, info, elements, elementTexts: this.annotsElementTexts(info, indirect, elements.length), dicts, indirectArray: indirect }
  }

  /** The text of each /Annots element, as the file wrote it. */
  private annotsElementTexts(info: PageInfo, indirect: PDFRef | null, count: number): Uint8Array[] | null {
    const f = this.file
    if (!info.dict.has('Annots')) return count === 0 ? [] : null
    let arrayText: Uint8Array
    if (indirect) {
      const raw = f.rawText(indirect.num)
      if (!raw || (f.isEncrypted && raw.inObjectStream)) return null
      arrayText = raw.text
    } else {
      const raw = f.rawText(info.ref.num)
      if (!raw || (f.isEncrypted && raw.inObjectStream)) return null
      let spans: Spans
      try { spans = spansOf(raw.text, 0) } catch { return null }
      const entry = spans.entries.find((e) => e.key === 'Annots')
      if (!entry) return null
      arrayText = raw.text.subarray(entry.valueStart, entry.valueEnd)
    }
    let spans: Spans
    try { spans = spansOf(arrayText, 0) } catch { return null }
    if (spans.entries.length !== count) return null
    return spans.entries.map((e) => arrayText.subarray(e.valueStart, e.valueEnd))
  }

  /** Where new objects start: after every number the file knows. */
  newObjects(): NewObjects {
    return new NewObjects(this.file.size)
  }

  /** Appends the edits, or says there is nothing to append. */
  perform(edits: PageEdit[], fresh: NewObjects, options: Options = {}): Outcome {
    const started = Date.now()
    const file = this.file
    const original = file.bytes
    const stats: Stats = {
      bytesBefore: original.length, bytesAfter: original.length, xrefKind: '', pagesChanged: 0,
      annotationsAdded: 0, annotationsRemoved: 0, objectsWritten: 0, objectsFreed: 0,
      pagesSpliced: 0, pagesSerialised: 0, ms: 0,
    }
    const finished = (): Outcome => ({ kind: 'unchanged', stats: { ...stats, ms: Date.now() - started } })

    const sharedArrays = new Map<number, number>()
    for (const p of this.pages) {
      const r = refOf(p.dict.get('Annots'))
      if (r) sharedArrays.set(r.num, (sharedArrays.get(r.num) ?? 0) + 1)
    }

    const pageUpdates: [PDFRef, Body][] = []
    const removedRefs: PDFRef[] = []
    const finalAnnots = new Map<number, PDFObj[]>()
    for (const edit of edits) {
      if (edit.index < 0 || edit.index >= this.pages.length) continue
      const pa = this.annots(edit.index)
      const removed = new Set(edit.removed.filter((k) => k >= 0 && k < pa.elements.length))
      // A popup goes with the annotation it belongs to.
      const goneRefs = new Set<number>()
      for (const k of removed) {
        const r = refOf(pa.elements[k])
        if (r) goneRefs.add(r.num)
      }
      pa.dicts.forEach((d, k) => {
        if (removed.has(k) || !d || nameOf(d.get('Subtype')) !== 'Popup') return
        const parent = refOf(d.get('Parent'))
        if (parent && goneRefs.has(parent.num)) removed.add(k)
      })
      const incoming = edit.added
      if (removed.size === 0 && incoming.length === 0) continue
      const kept: number[] = []
      pa.elements.forEach((_, k) => { if (!removed.has(k)) kept.push(k) })
      for (const k of [...removed].sort((a, b) => a - b)) {
        const r = refOf(pa.elements[k])
        if (r) removedRefs.push(r)
      }
      stats.annotationsAdded += incoming.length
      stats.annotationsRemoved += removed.size
      stats.pagesChanged += 1
      finalAnnots.set(edit.index, [...kept.map((k) => pa.elements[k]), ...incoming.map((r) => obj.ref(r))])
      const ownArray = pa.indirectArray ? sharedArrays.get(pa.indirectArray.num) === 1 : false
      pageUpdates.push(this.newVersion(pa, kept, incoming, ownArray, stats))
    }

    if (pageUpdates.length === 0 && fresh.objects.length === 0) return finished()
    if (pageUpdates.length === 0) {
      // Objects with no page pointing at them: nothing a reader could see.
      return finished()
    }
    this.refuseGuesses()

    let freed: Freed[] = []
    if ((options.freeRemovedObjects ?? true) && removedRefs.length > 0) {
      const written = new Set(pageUpdates.map(([r]) => r.num))
      const arriving = fresh.objects.map(([, o]) => o)
      const [found, guessed] = file.tolerant(() => this.freeable(removedRefs, finalAnnots, written, arriving))
      if (!guessed) freed = found
    }

    const objects: [PDFRef, Body][] = [
      ...fresh.objects.map(([r, o]): [PDFRef, Body] => [r, { kind: 'object', value: o }]),
      ...pageUpdates,
    ]
    const { bytes: appendix, kind } = appendixBytes(file, objects, freed, fresh.next)
    stats.xrefKind = kind
    stats.objectsWritten = objects.length
    stats.objectsFreed = freed.length
    const out = Buffer.concat([Buffer.from(original), Buffer.from(appendix)])
    stats.bytesAfter = out.length

    if (options.verify ?? true) this.verify(out, finalAnnots, new Set(fresh.objects.map(([r]) => r.num)))
    stats.ms = Date.now() - started
    return { kind: 'appended', bytes: new Uint8Array(out), stats }
  }

  /** The page's (or its /Annots array's) new version: the file's own text
   *  with the one value spliced in where it can be, and the parse
   *  serialised again where it cannot. */
  private newVersion(pa: PageAnnots, kept: number[], added: PDFRef[], ownArray: boolean, stats: Stats): [PDFRef, Body] {
    const file = this.file
    let listText: Uint8Array | null = null
    // In an encrypted file an element's strings are encrypted for the
    // object they sit in: text from a shared array cannot move into the
    // page.
    const crossesObjects = pa.indirectArray !== null && !ownArray
    if (pa.elementTexts && !(file.isEncrypted && crossesObjects)) {
      const t = new Bytes()
      t.push('[')
      kept.forEach((k, n) => {
        if (n > 0) t.push(' ')
        t.push(pa.elementTexts![k])
      })
      added.forEach((r, n) => {
        if (n > 0 || kept.length > 0) t.push(' ')
        t.push(refString(r))
      })
      t.push(']')
      listText = t.bytes()
    }
    const list: PDFObj[] = [...kept.map((k) => pa.elements[k]), ...added.map((r) => obj.ref(r))]

    if (pa.indirectArray && ownArray) {
      if (listText) {
        stats.pagesSpliced += 1
        return [pa.indirectArray, { kind: 'raw', text: listText }]
      }
      if (file.irregular.has(pa.indirectArray.num)) {
        throw new Refusal('unreadableStructure', `the /Annots array of page ${pa.index} cannot be written back`)
      }
      stats.pagesSerialised += 1
      return [pa.indirectArray, { kind: 'object', value: obj.array(list) }]
    }

    // The page itself, with its /Annots spliced in its own text.
    const pageRef = pa.info.ref
    const raw = file.rawText(pageRef.num)
    if (listText && raw && !(file.isEncrypted && raw.inObjectStream)) {
      let spans: Spans | null = null
      try { spans = spansOf(raw.text, 0) } catch { spans = null }
      if (spans) {
        const text = raw.text
        const entry = spans.entries.find((e) => e.key === 'Annots')
        let out: Uint8Array
        if (entry) {
          out = list.length === 0
            ? Buffer.concat([text.subarray(0, entry.keyStart), text.subarray(entry.valueEnd)])
            : Buffer.concat([text.subarray(0, entry.valueStart), listText, text.subarray(entry.valueEnd)])
        } else if (list.length > 0) {
          out = Buffer.concat([text.subarray(0, spans.close), Buffer.from(' /Annots ', 'latin1'), listText, Buffer.from(' ', 'latin1'), text.subarray(spans.close)])
        } else {
          out = text
        }
        stats.pagesSpliced += 1
        return [pageRef, { kind: 'raw', text: out }]
      }
    }
    if (file.irregular.has(pageRef.num)) {
      throw new Refusal('unreadableStructure', `page ${pa.index} cannot be written back`)
    }
    const dict = pa.info.dict.clone()
    dict.set('Annots', list.length === 0 ? undefined : obj.array(list))
    stats.pagesSerialised += 1
    return [pageRef, { kind: 'object', value: obj.dict(dict) }]
  }

  /**
   * The objects the removed annotations leave behind that nothing in the
   * current version refers to any more. Ours go with everything under them;
   * another app's go alone — their appearances may share what the page
   * uses, and freeing a font the page draws with would take its text off
   * the page.
   */
  private freeable(removed: PDFRef[], finalAnnots: Map<number, PDFObj[]>, written: Set<number>, arriving: PDFObj[]): Freed[] {
    const file = this.file
    const candidates = new Set<number>()
    for (const r of removed) {
      let d: PDFDict | undefined
      try { d = dictOf(file.object(r.num)) } catch { d = undefined }
      if (!d) continue
      // The structure tree points at it.
      if (d.has('StructParent')) continue
      candidates.add(r.num)
      const ours = isOurs(obj.dict(d)) || (nameOf(d.get('Subtype')) === 'Popup' && isOurs(file.resolveQuietly(d.get('Parent'))))
      if (ours) reach(obj.dict(d), file, candidates)
    }
    if (candidates.size === 0) return []

    // Everything still in use: every annotation on every page, what this
    // update brings in, and whatever the form and the structure tree hold.
    const live = new Set<number>()
    for (const o of arriving) reach(o, file, live)
    this.pages.forEach((info, i) => {
      live.add(info.ref.num)
      const r = refOf(info.dict.get('Annots'))
      if (r) live.add(r.num)
      const elements = finalAnnots.get(i) ?? arrayOf(file.resolveQuietly(info.dict.get('Annots'))) ?? []
      for (const element of elements) reach(element, file, live)
    })
    const rootRef = refOf(file.trailer.get('Root'))
    const root = dictOf(file.resolveQuietly(file.trailer.get('Root')))
    if (root) {
      if (rootRef) live.add(rootRef.num)
      for (const key of ['AcroForm', 'StructTreeRoot']) {
        const value = root.get(key)
        if (value) reach(value, file, live)
      }
    }
    return [...candidates]
      .filter((num) => !live.has(num) && !written.has(num) && file.isInUse(num))
      .sort((a, b) => a - b)
      .map((num) => ({ num, gen: Math.min(file.generation(num) + 1, 65535) }))
  }

  /** Opens the result as any reader would, and checks it says what the
   *  edit meant: the same pages, the right annotations on the changed ones. */
  private verify(out: Uint8Array, finalAnnots: Map<number, PDFObj[]>, added: Set<number>) {
    let ours: PDFFile
    try {
      ours = new PDFFile(out)
    } catch (error) {
      throw new Refusal('verificationFailed', `the result does not read back: ${String((error as Error).message ?? error)}`)
    }
    if (ours.repaired) throw new Refusal('verificationFailed', 'the cross-reference chain does not read back')
    // The same key opens it: the /Encrypt dictionary and the first half of
    // /ID are the ones it had.
    ours.security = this.file.security
    let pages: PageInfo[]
    try {
      pages = ours.pages()
    } catch {
      throw new Refusal('verificationFailed', 'the page tree does not read back')
    }
    if (pages.length !== this.pages.length) throw new Refusal('verificationFailed', `${pages.length} pages instead of ${this.pages.length}`)
    for (const [index, want] of finalAnnots) {
      const got = arrayOf(ours.resolveQuietly(pages[index].dict.get('Annots'))) ?? []
      if (got.length !== want.length) throw new Refusal('verificationFailed', `page ${index}: ${got.length} annotations instead of ${want.length}`)
      for (let k = 0; k < want.length; k += 1) {
        const a = want[k]
        const b = got[k]
        const same = a.t === 'ref' && b.t === 'ref' ? sameRef(a.v, b.v) : Buffer.compare(Serializer.bytes(a), Serializer.bytes(b)) === 0
        if (!same) throw new Refusal('verificationFailed', `page ${index}: annotation ${k} is not the one written`)
        // The ones this update wrote must read back; one the file already
        // listed and could not resolve is kept as it was, dangling and all.
        if (b.t === 'ref' && added.has(b.v.num) && !dictOf(ours.resolveQuietly(b))) {
          throw new Refusal('verificationFailed', `page ${index}: annotation ${k} does not resolve`)
        }
      }
    }
    if (ours.guessedReads > 0) throw new Refusal('verificationFailed', `the result needs guessing: ${ours.notes.join('; ')}`)
  }
}
