import { promises as fsp } from 'node:fs'

/**
 * A rename over a file another program has open. On Windows that fails —
 * EPERM, EBUSY, EACCES — while an antivirus scans the file it just saw
 * change, a sync client uploads it, or a reader shows it, and each of them
 * lets go within moments. Tried a few times before the save is given back.
 */
export async function renameHeld(
  from: string,
  to: string,
  rename: (from: string, to: string) => Promise<void> = (a, b) => fsp.rename(a, b),
  waits: number[] = [100, 300, 1000, 2000],
) {
  for (let attempt = 0; ; attempt += 1) {
    try {
      await rename(from, to)
      return
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code
      if (attempt >= waits.length || !['EPERM', 'EBUSY', 'EACCES'].includes(code ?? '')) throw error
      await new Promise((resolve) => setTimeout(resolve, waits[attempt]))
    }
  }
}
