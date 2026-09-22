/**
 * Why a PDF will not open — the port of `PDFLock.swift`.
 *
 * A PDF can be encrypted three ways and only one of them is ours to solve.
 * The standard handler takes a password, which pdf.js implements and we can
 * ask for. The other two hand the key to somebody else: a certificate in the
 * reader's own store, or a rights server at the company that published the
 * file. Those are not damaged files and not our failure — Acrobat opens them
 * because Acrobat carries the plug-in that asks the rights service, and no
 * amount of work here substitutes for that.
 *
 * And a fourth thing, which is not a lock at all: the bytes we were handed
 * are not the file. A cloud folder answers for a paper that has not finished
 * coming down, a company's filter hands back a sign-in page wearing the
 * paper's name, a rights agent leaves a container where the PDF was. pdf.js
 * says the same six words to all of them — "Invalid PDF structure." — so the
 * telling apart has to happen here, before it is asked.
 */
export type PDFLock = { kind: 'password' } | { kind: 'rights'; handler: string }

/** The handlers worth naming, in the order they are looked for. */
export const KNOWN_HANDLERS = ['MicrosoftIRMServices', 'FoxitIRM', 'Adobe.PubSec', 'EBX_HANDLER']

/**
 * What is wrong with the bytes themselves.
 *
 * - `empty` — nothing there at all.
 * - `placeholder` — the right length and no content: a cloud file that has
 *   not been fetched.
 * - `webpage` — HTML wearing a `.pdf` name, which is what a sign-in wall or
 *   a blocked-by-policy notice hands back.
 * - `wrapped` — an OLE or zip container, which is the shape a rights agent
 *   leaves behind. Vendor-independent on purpose: the container is the same
 *   whoever wrapped it, and guessing at brand names we have never seen in a
 *   real file would be inventing evidence.
 * - `cut` — a PDF that stops before it ends. Usually still arriving.
 * - `opaque` — bytes that are none of the above: not a PDF, not a page, not
 *   empty, not a container we know. On one machine and not another, with the
 *   same file opening in Acrobat, this is what an endpoint agent looks like
 *   from outside — it hands the real file to the readers the company
 *   registered and something else to everybody else.
 */
export type ByteTrouble = 'empty' | 'placeholder' | 'webpage' | 'wrapped' | 'cut' | 'opaque'

/**
 * The first bytes, as hex, for the reader to show and a person to send on.
 *
 * Eight bytes name the format of almost anything — `25504446` is a PDF,
 * `D0CF11E0` an OLE container, `504B0304` a zip, `3C21444F` an HTML page,
 * zeros a file that was never fetched. It costs a person nothing to send and
 * it turns a screenshot into a diagnosis, which is the whole point: the last
 * time a file would not open, telling which of these it was took a day.
 */
export function headBytes(bytes: Uint8Array, count = 8): string {
  return [...bytes.subarray(0, count)].map((b) => b.toString(16).padStart(2, '0').toUpperCase()).join(' ')
}

/**
 * The file's first line, when the file begins with readable characters.
 *
 * Eight bytes of hex say *which kind* of thing this is; a line of text says
 * *what it is*. A company machine handed this app a file whose first bytes
 * were `3C 23 23 20 4E 41 53 32`, which is a person reading eight numbers
 * down a phone before anybody could see that they spell `<## NAS2`. Whatever
 * stands in for a paper — a note saying the real file lives on some server, a
 * policy notice, a stub — says so in words, and the words are the diagnosis.
 *
 * Only a first line, only when every character of it is printable, and never
 * more than 120 of them: this goes on screen for somebody to read out, not to
 * be parsed.
 */
export function headLine(bytes: Uint8Array, limit = 120): string | null {
  const head = bytes.subarray(0, Math.min(bytes.length, limit))
  const breaks = head.findIndex((byte) => byte === 0x0a || byte === 0x0d || byte === 0)
  const line = head.subarray(0, breaks === -1 ? head.length : breaks)
  if (line.length < 4) return null
  // Decoded as UTF-8 so that a notice written in Korean is readable too; a
  // replacement character means these were never characters.
  const text = new TextDecoder('utf-8').decode(line)
  if (text.includes('\uFFFD')) return null
  if (/[\u0000-\u0008\u000b-\u001f\u007f]/.test(text)) return null
  return text.trim() || null
}

/** Only the ends are read: a paper is twenty megabytes and this runs on open.
 *
 * The head is eight kilobytes rather than one because pdf.js will open a file
 * with rather a lot of rubbish glued to its front — a filter's banner, a mail
 * preamble — and a window that said "not a PDF" at a kilobyte and one byte
 * would be refusing papers the reader can read. Measured: pdf.js opens a
 * paper with four kilobytes of preamble. */
const HEAD = 8192
const TAIL = 2048

function latin1(bytes: Uint8Array, from: number, to: number): string {
  return new TextDecoder('latin1').decode(bytes.subarray(Math.max(0, from), Math.max(0, to)))
}

/**
 * Whether this is a PDF at all.
 *
 * The header is looked for in the first kilobyte rather than at byte zero:
 * a file with a byte-order mark, or a filter's banner glued to the front,
 * still opens perfectly well in pdf.js, and refusing it here would break
 * papers that work today.
 */
export function looksLikePDF(bytes: Uint8Array): boolean {
  return latin1(bytes, 0, HEAD).includes('%PDF-')
}

/**
 * Whether the whole of it arrived.
 *
 * A PDF ends in `%%EOF`, and everything that puts one together writes it
 * last — so its absence from the end means the end is missing. Measured
 * against every PDF on this machine: the marker sits within the last two
 * kilobytes of all of them, and no whole file was ever called cut.
 *
 * This is a question, never a door. pdf.js rebuilds a file whose last
 * kilobytes are gone and opens it, and a reader that refused what pdf.js can
 * read would be worse than the bug this was written for.
 */
export function looksWhole(bytes: Uint8Array): boolean {
  if (!looksLikePDF(bytes)) return false
  return latin1(bytes, bytes.length - TAIL, bytes.length).includes('%%EOF')
}

/**
 * The container a rights agent leaves in place of the file, if that is what
 * this is: an OLE compound file, or a zip. Only counts when there is no PDF
 * header anywhere near the front — a PDF is allowed to have anything inside
 * it, including zipped streams.
 */
export function containerKind(bytes: Uint8Array): 'ole' | 'zip' | null {
  if (bytes.length < 8 || looksLikePDF(bytes)) return null
  const OLE = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]
  if (OLE.every((byte, index) => bytes[index] === byte)) return 'ole'
  if (bytes[0] === 0x50 && bytes[1] === 0x4b && bytes[2] === 0x03 && bytes[3] === 0x04) return 'zip'
  return null
}

/**
 * What is wrong with these bytes, or nothing.
 *
 * Ordered by how sure each answer is: a container and a web page are what
 * they are, a run of zeros is a file that was never fetched, and `cut` is
 * the guess of last resort — which is why a cut file is still handed to
 * pdf.js afterwards rather than refused.
 */
export function diagnose(bytes: Uint8Array): ByteTrouble | null {
  if (bytes.length === 0) return 'empty'
  if (containerKind(bytes)) return 'wrapped'
  if (looksLikePDF(bytes)) return looksWhole(bytes) ? null : 'cut'
  const head = latin1(bytes, 0, HEAD)
  if (/^\s*(<!doctype html|<html|<\?xml|\{)/i.test(head)) return 'webpage'
  // A cloud placeholder reserves the length and leaves the content behind.
  if (bytes.subarray(0, Math.min(bytes.length, HEAD)).every((byte) => byte === 0)) return 'placeholder'
  return 'opaque'
}

/**
 * The `/Encrypt` dictionary's handler, read from the bytes.
 *
 * The handler's name is one of the few things in an encrypted PDF that cannot
 * itself be encrypted — a reader has to know who to ask before it can ask —
 * so it sits in the file as plain text. Only called once a document is known
 * to be unreadable: a paper *about* rights management has these words in its
 * prose, and refusing to open it would be a joke at this app's expense.
 */
export function rightsHandler(bytes: Uint8Array): string | null {
  const text = new TextDecoder('latin1').decode(bytes)
  return KNOWN_HANDLERS.find((handler) => text.includes(handler)) ?? null
}
