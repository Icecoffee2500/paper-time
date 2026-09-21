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
 */
export type PDFLock = { kind: 'password' } | { kind: 'rights'; handler: string }

/** The handlers worth naming, in the order they are looked for. */
export const KNOWN_HANDLERS = ['MicrosoftIRMServices', 'FoxitIRM', 'Adobe.PubSec', 'EBX_HANDLER']

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
