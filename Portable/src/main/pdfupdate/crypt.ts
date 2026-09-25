/**
 * The standard security handler (ISO 32000-1 §7.6.3, ISO 32000-2 §7.6.4),
 * enough to write an incremental update into an encrypted file: derive the
 * file key from a user password (usually the empty one — a paper that opens
 * without asking but carries permissions), and encrypt the strings and
 * streams of new objects with it. Also decrypts, so the reader can look into
 * object streams and compare strings. The port of `PDFCrypt.swift`.
 *
 * Anything else — another handler (certificate, rights management), crypt
 * filters other than V2/AESV2/AESV3, a password nobody gave us — is not
 * handled and the writer refuses.
 */
import crypto from 'node:crypto'
import { PDFDict, dictOf, intOf, nameOf, obj, stringBytesOf, type PDFObj, type PDFRef } from './syntax.js'

export type Method = 'identity' | 'rc4' | 'aesv2' | 'aesv3'

export class SecurityFailure extends Error {
  constructor(readonly kind: 'handler' | 'unsupported' | 'wrongPassword', message: string) {
    super(message)
    this.name = 'SecurityFailure'
  }
}

const PADDING = Uint8Array.from([
  0x28, 0xbf, 0x4e, 0x5e, 0x4e, 0x75, 0x8a, 0x41, 0x64, 0x00, 0x4e, 0x56, 0xff, 0xfa, 0x01, 0x08,
  0x2e, 0x2e, 0x00, 0xb6, 0xd0, 0x68, 0x3e, 0x80, 0x2f, 0x0c, 0xa9, 0xfe, 0x64, 0x53, 0x69, 0x7a,
])

const md5 = (...parts: Uint8Array[]) => {
  const h = crypto.createHash('md5')
  for (const p of parts) h.update(p)
  return new Uint8Array(h.digest())
}
const sha = (bits: 256 | 384 | 512, ...parts: Uint8Array[]) => {
  const h = crypto.createHash(`sha${bits}`)
  for (const p of parts) h.update(p)
  return new Uint8Array(h.digest())
}
const concat = (...parts: Uint8Array[]) => Buffer.concat(parts.map((p) => Buffer.from(p)))
const equal = (a: Uint8Array, b: Uint8Array) => a.length === b.length && Buffer.compare(Buffer.from(a), Buffer.from(b)) === 0

export class StandardSecurity {
  readonly revision: number
  readonly fileKey: Uint8Array
  readonly streamMethod: Method
  readonly stringMethod: Method
  readonly encryptMetadata: boolean
  /** The /P permission bits, as the file states them. */
  readonly permissions: number

  /** Bit 6 of /P (ISO 32000-1, Table 22): "add or modify text annotations". */
  get allowsAnnotations() { return (this.permissions & (1 << 5)) !== 0 }

  constructor(d: PDFDict, id0: Uint8Array, password: Uint8Array = new Uint8Array()) {
    const filter = nameOf(d.get('Filter'))
    if (filter !== 'Standard') throw new SecurityFailure('handler', `security handler ${filter ?? 'none'}`)
    const v = intOf(d.get('V')) ?? 0
    const r = intOf(d.get('R')) ?? 0
    this.revision = r
    const em = d.get('EncryptMetadata')
    this.encryptMetadata = em?.t === 'bool' ? em.v : true
    const o = stringBytesOf(d.get('O')) ?? new Uint8Array()
    const u = stringBytesOf(d.get('U')) ?? new Uint8Array()
    const p = (intOf(d.get('P')) ?? 0) | 0
    this.permissions = p

    // Which cipher: V 1–2 are RC4 throughout; V 4–5 name crypt filters.
    const method = (filterName: string | undefined): Method => {
      if (v < 4) return 'rc4'
      if (!filterName || filterName === 'Identity') return 'identity'
      const cf = dictOf(dictOf(d.get('CF'))?.get(filterName))
      if (!cf) throw new SecurityFailure('unsupported', `unsupported encryption: crypt filter ${filterName}`)
      const cfm = nameOf(cf.get('CFM'))
      switch (cfm) {
        case 'V2': return 'rc4'
        case 'AESV2': return 'aesv2'
        case 'AESV3': return 'aesv3'
        case 'None': case undefined: return 'identity'
        default: throw new SecurityFailure('unsupported', `unsupported encryption: CFM ${cfm}`)
      }
    }
    if (![1, 2, 4, 5].includes(v)) throw new SecurityFailure('unsupported', `unsupported encryption: V ${v}`)
    this.streamMethod = method(nameOf(d.get('StmF')))
    this.stringMethod = method(nameOf(d.get('StrF')))

    if (r <= 4) {
      // Algorithm 2: the key from the padded password, O, P, the first ID
      // and (R4, metadata left clear) four 0xFF.
      const n = r === 2 ? 5 : Math.max(5, Math.min(16, Math.floor((intOf(d.get('Length')) ?? 40) / 8)))
      const pBytes = new Uint8Array(4)
      new DataView(pBytes.buffer).setInt32(0, p, true)
      const parts = [concat(password, PADDING).subarray(0, 32), o.subarray(0, 32), pBytes, id0]
      if (r >= 4 && !this.encryptMetadata) parts.push(Uint8Array.from([0xff, 0xff, 0xff, 0xff]))
      let key = md5(...parts)
      if (r >= 3) for (let i = 0; i < 50; i += 1) key = md5(key.subarray(0, n))
      key = key.subarray(0, n)
      // Algorithms 4 and 5: the key is right if it reproduces U.
      if (r === 2) {
        const check = rc4(key, PADDING)
        if (!equal(check, u.subarray(0, 32))) throw new SecurityFailure('wrongPassword', 'the user password is not empty (or not the one given)')
      } else {
        let x = rc4(key, md5(PADDING, id0))
        for (let i = 1; i <= 19; i += 1) x = rc4(key.map((b) => b ^ i), x)
        if (!equal(x.subarray(0, 16), u.subarray(0, 16))) throw new SecurityFailure('wrongPassword', 'the user password is not empty (or not the one given)')
      }
      this.fileKey = key
    } else if (r === 6 || r === 5) {
      // Algorithm 2.A: validate against U's validation salt, then unwrap UE
      // with a key made from its key salt.
      const ue = stringBytesOf(d.get('UE'))
      if (u.length < 48 || !ue || ue.length < 32) throw new SecurityFailure('unsupported', `unsupported encryption: R${r} without U/UE`)
      const pw = password.subarray(0, 127)
      const hash = (salt: Uint8Array, extra: Uint8Array) =>
        r === 5 ? sha(256, pw, salt, extra) : hash2B(pw, salt, extra)
      if (!equal(hash(u.subarray(32, 40), new Uint8Array()), u.subarray(0, 32))) {
        throw new SecurityFailure('wrongPassword', 'the user password is not empty (or not the one given)')
      }
      const intermediate = hash(u.subarray(40, 48), new Uint8Array())
      const key = aes(true, intermediate, new Uint8Array(16), ue.subarray(0, 32), false)
      if (!key) throw new SecurityFailure('unsupported', 'unsupported encryption: UE')
      this.fileKey = key
    } else {
      throw new SecurityFailure('unsupported', `unsupported encryption: R ${r}`)
    }
  }

  // MARK: Objects

  private objectKey(r: PDFRef, forAES: boolean): Uint8Array {
    const parts = [
      this.fileKey,
      Uint8Array.from([r.num & 0xff, (r.num >> 8) & 0xff, (r.num >> 16) & 0xff, r.gen & 0xff, (r.gen >> 8) & 0xff]),
    ]
    if (forAES) parts.push(Buffer.from('sAlT', 'latin1'))
    return md5(...parts).subarray(0, Math.min(this.fileKey.length + 5, 16))
  }

  encrypt(data: Uint8Array, r: PDFRef, method: Method): Uint8Array {
    switch (method) {
      case 'identity': return data
      case 'rc4': return rc4(this.objectKey(r, false), data)
      default: {
        const key = method === 'aesv3' ? this.fileKey : this.objectKey(r, true)
        const iv = new Uint8Array(crypto.randomBytes(16))
        return concat(iv, aes(false, key, iv, data, true) ?? new Uint8Array())
      }
    }
  }

  decrypt(data: Uint8Array, r: PDFRef, method: Method): Uint8Array {
    switch (method) {
      case 'identity': return data
      case 'rc4': return rc4(this.objectKey(r, false), data)
      default: {
        if (data.length < 32) return new Uint8Array()
        const key = method === 'aesv3' ? this.fileKey : this.objectKey(r, true)
        return aes(true, key, data.subarray(0, 16), data.subarray(16), true) ?? new Uint8Array()
      }
    }
  }

  /** An object as it goes into the file under `ref`: every string and the
   *  stream's data encrypted. */
  encrypting(o: PDFObj, r: PDFRef): PDFObj {
    switch (o.t) {
      case 'string': return obj.string(this.encrypt(o.v, r, this.stringMethod), true)
      case 'array': return obj.array(o.v.map((x) => this.encrypting(x, r)))
      case 'dict': return obj.dict(new PDFDict(o.v.pairs.map(([k, v]) => [k, this.encrypting(v, r)])))
      case 'stream': {
        const dict = new PDFDict(o.dict.pairs.map(([k, v]) => [k, this.encrypting(v, r)]))
        if (nameOf(o.dict.get('Type')) === 'Metadata' && !this.encryptMetadata) return obj.stream(dict, o.data)
        return obj.stream(dict, this.encrypt(o.data, r, this.streamMethod))
      }
      default: return o
    }
  }

  decrypting(o: PDFObj, r: PDFRef): PDFObj {
    switch (o.t) {
      case 'string': return obj.string(this.decrypt(o.v, r, this.stringMethod), o.hex)
      case 'array': return obj.array(o.v.map((x) => this.decrypting(x, r)))
      case 'dict': return obj.dict(new PDFDict(o.v.pairs.map(([k, v]) => [k, this.decrypting(v, r)])))
      case 'stream': {
        const dict = new PDFDict(o.dict.pairs.map(([k, v]) => [k, this.decrypting(v, r)]))
        const type = nameOf(o.dict.get('Type'))
        if (type === 'XRef') return obj.stream(dict, o.data)
        if (type === 'Metadata' && !this.encryptMetadata) return obj.stream(dict, o.data)
        return obj.stream(dict, this.decrypt(o.data, r, this.streamMethod))
      }
      default: return o
    }
  }
}

/** Algorithm 2.B (ISO 32000-2): SHA-256, then rounds of AES-128-CBC and
 *  SHA-256/384/512 until the last byte says stop. */
export function hash2B(password: Uint8Array, salt: Uint8Array, extra: Uint8Array): Uint8Array {
  let k = sha(256, password, salt, extra)
  let round = 0
  for (;;) {
    const k1base = concat(password, k, extra)
    const k1 = Buffer.alloc(k1base.length * 64)
    for (let i = 0; i < 64; i += 1) k1base.copy(k1, i * k1base.length)
    const e = aes(false, k.subarray(0, 16), k.subarray(16, 32), k1, false)
    if (!e) return k
    let sum = 0
    for (let i = 0; i < 16; i += 1) sum += e[i]
    const mod = sum % 3
    k = mod === 0 ? sha(256, e) : mod === 1 ? sha(384, e) : sha(512, e)
    round += 1
    if (round >= 64 && e[e.length - 1] <= round - 32) break
  }
  return k.subarray(0, 32)
}

export function rc4(key: Uint8Array, data: Uint8Array): Uint8Array {
  const s = new Uint8Array(256)
  for (let i = 0; i < 256; i += 1) s[i] = i
  let j = 0
  for (let i = 0; i < 256; i += 1) {
    j = (j + s[i] + key[i % key.length]) & 0xff
    const t = s[i]; s[i] = s[j]; s[j] = t
  }
  const out = new Uint8Array(data.length)
  let i = 0
  j = 0
  for (let n = 0; n < data.length; n += 1) {
    i = (i + 1) & 0xff
    j = (j + s[i]) & 0xff
    const t = s[i]; s[i] = s[j]; s[j] = t
    out[n] = data[n] ^ s[(s[i] + s[j]) & 0xff]
  }
  return out
}

export function aes(decrypt: boolean, key: Uint8Array, iv: Uint8Array, data: Uint8Array, padding: boolean): Uint8Array | null {
  try {
    const algorithm = key.length === 32 ? 'aes-256-cbc' : key.length === 24 ? 'aes-192-cbc' : 'aes-128-cbc'
    const cipher = decrypt ? crypto.createDecipheriv(algorithm, key, iv) : crypto.createCipheriv(algorithm, key, iv)
    cipher.setAutoPadding(padding)
    return concat(new Uint8Array(cipher.update(data)), new Uint8Array(cipher.final()))
  } catch {
    return null
  }
}
