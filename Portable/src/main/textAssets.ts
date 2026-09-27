/**
 * The two kinds of file pdf.js asks for while it reads a paper's text — a
 * packed character map, a standard font — from the folders the window loads
 * the same files from. Readers on other threads ask the main process, which
 * can read inside the app's archive.
 */
import fsp from 'node:fs/promises'
import path from 'node:path'

/** The files pdf.js may ask for, by name — nothing with a path in it. */
const ASSET_NAME = /^[A-Za-z0-9][A-Za-z0-9_.+-]*$/

export async function textAsset(kind: 'cmap' | 'font', name: string): Promise<Uint8Array | null> {
  // The name comes out of a PDF, which anybody can write. Only a bare file
  // name, only from the two folders the window loads the same files from.
  if (!ASSET_NAME.test(name) || name.includes('..')) return null
  const file = kind === 'cmap'
    ? path.join(__dirname, '../renderer/cmaps', `${name}.bcmap`)
    : path.join(__dirname, '../renderer/standard_fonts', name)
  try {
    return new Uint8Array(await fsp.readFile(file))
  } catch {
    return null
  }
}
