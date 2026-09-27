/** Small things more than one handler file needs. */
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import type { PageCounter } from '../pdfBytes.js'

export const isFile = (file: string) => {
  try {
    return fs.statSync(file).isFile()
  } catch {
    return false
  }
}

/** How many pages a PDF has, read without rendering it; 0 when it will not open. */
export async function pageCount(counter: PageCounter, file: string): Promise<number> {
  try {
    return (await counter.countOrNull(await fsp.readFile(file))) ?? 0
  } catch {
    return 0
  }
}
