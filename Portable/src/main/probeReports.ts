/**
 * What a probe asks of the library, said on stderr in the Mac's words —
 * `--papertime-add-folder=<path>`, `--papertime-adopt-loose=1` and
 * `--papertime-folders=1`. Only in a probe run, which writes none of the
 * person's settings.
 */
import path from 'node:path'
import * as L from './layout.js'
import type { LibrarySet } from './libraries.js'
import type { NotesStore } from './slipBox.js'
import type { Handlers } from './handlers/context.js'

const say = (line: string) => process.stderr.write(`${line}\n`)

export async function runLibraryProbes(options: {
  argument: (name: string) => string | null | undefined
  libraries: LibrarySet
  notes: () => NotesStore
  handlers: Partial<Handlers>
}) {
  const { argument, libraries, notes, handlers } = options
  const adding = argument('add-folder')
  if (adding) {
    const refusal = await libraries.attach(adding)
    say(refusal ? `add folder: refused — ${refusal.error}` : `add folder: ${adding}`)
  }
  if (argument('adopt-loose') === '1') {
    const loose = (await Promise.all(libraries.all().map((one) => one.looseFiles()))).flat()
    const answer = await handlers['library:adoptLoose']?.(undefined as never, null)
    const refused = answer && !('error' in answer) ? answer.refused : []
    say(`loose: ${loose.length} [${loose.map((one) => path.basename(one)).join(', ')}] refused: ${refused.length} [${refused.join(', ')}]`)
  }
  if (argument('folders') === '1') {
    const where = notes().info()
    say(`loose notes: ${where.away ? `chosen one away (${where.chosenPath ?? '?'}), using the app folder` : where.chosen ? 'chosen' : 'app folder'}`)
    for (const one of libraries.all()) {
      const { papers } = await one.read()
      const manifest = await one.manifest()
      const set = await one.collections()
      const noteIDs = await noteIDsIn(one.root)
      const { folders } = await one.walkFolder()
      say(`folder ${path.basename(one.root)}: papers=${papers.length}`
        + ` folders=[${folders.map((folder) => folder.slice(one.root.replace(/\\/g, '/').length + 1)).join(',')}]`
        + ` tags=[${(manifest.tags ?? []).map((tag) => tag.name).join(',')}]`
        + ` collections=[${(set.collections ?? []).map((collection) => collection.name).join(',')}]`
        + ` notes=[${noteIDs.join(',')}]`)
    }
    say(`loose box ${where.loose} [${where.chosen ? 'chosen' : where.away ? 'app folder (chosen one away)' : 'app folder'}]`)
  }
}

async function noteIDsIn(root: string): Promise<string[]> {
  const folder = L.slipBoxDir(root)
  try {
    const { readdir } = await import('node:fs/promises')
    return (await readdir(folder)).filter((name) => name.endsWith('.md')).map((name) => name.slice(0, -3)).sort()
  } catch {
    return []
  }
}

