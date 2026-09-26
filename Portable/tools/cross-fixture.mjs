/**
 * Writes a PDF annotated by this build's appender, for the Mac to fold.
 *
 *     node tools/cross-fixture.mjs --out <pdf> [--base <pdf> | --base-out <pdf>] [--saves N]
 *
 * Without `--base` the two Helvetica pages of the tests are the base, and
 * the result with no `--saves` is the Swift tests' fixture:
 *
 *     node tools/cross-fixture.mjs --base-out ../Packages/PaperTimeKit/Tests/PDFUpdateTests/Fixtures/portable-base.pdf \
 *         --out ../Packages/PaperTimeKit/Tests/PDFUpdateTests/Fixtures/portable-appended.pdf
 *
 * `--saves N` appends N more saves after the first (toggling a shape, ending
 * where it began) — a history long enough for the Mac's compaction to be due.
 * The source is `src/tools/crossFixture.ts`, bundled here so it runs on the
 * very same writer the app runs (`src/main/pdfwrite.ts`).
 */
import * as esbuild from 'esbuild'
import { createRequire } from 'node:module'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const portable = path.join(import.meta.dirname, '..')
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'cross-fixture-'))
const bundle = path.join(scratch, 'crossFixture.cjs')

await esbuild.build({
  entryPoints: [path.join(portable, 'src/tools/crossFixture.ts')],
  outfile: bundle,
  bundle: true,
  platform: 'node',
  format: 'cjs',
  target: 'node20',
  external: ['electron'],
  logLevel: 'warning',
  define: { 'process.env.NODE_ENV': '"production"', 'import.meta.url': '__importMetaUrl' },
  banner: { js: "const __importMetaUrl = require('url').pathToFileURL(__filename).href;" },
})

const { main } = createRequire(import.meta.url)(bundle)
await main(process.argv.slice(2))
fs.rmSync(scratch, { recursive: true, force: true })
