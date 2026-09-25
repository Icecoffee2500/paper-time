// One bundler for three targets: the Electron main process (CommonJS, Node),
// the preload bridge (CommonJS, sandboxed), and the renderer (ESM, browser).
// esbuild rather than a framework toolchain because the renderer is plain
// TypeScript and the whole point of this port is that it behaves identically
// everywhere — fewer moving parts, fewer places for a platform to differ.
import * as esbuild from 'esbuild'
import { cp, mkdir, rm } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.dirname(fileURLToPath(import.meta.url))
const out = path.join(root, 'out')
const watch = process.argv.includes('--watch')
const withTests = process.argv.includes('--test')

const common = {
  bundle: true,
  sourcemap: true,
  logLevel: 'info',
  define: { 'process.env.NODE_ENV': JSON.stringify(process.env.NODE_ENV ?? 'development') },
}

/**
 * pdf.js's legacy build asks `import.meta.url` where it is in Node, and a
 * CommonJS bundle has no `import.meta` — esbuild would hand it an empty
 * object. The file's own URL is what it means.
 */
const nodeImportMeta = {
  define: { ...common.define, 'import.meta.url': '__importMetaUrl' },
  banner: { js: "const __importMetaUrl = require('url').pathToFileURL(__filename).href;" },
}

/** @type {esbuild.BuildOptions[]} */
const targets = [
  {
    ...common,
    entryPoints: [path.join(root, 'src/main/main.ts')],
    outfile: path.join(out, 'main/main.js'),
    platform: 'node',
    format: 'cjs',
    target: 'node20',
    external: ['electron'],
  },
  // The text index, in a process of its own, and the threads it reads with.
  // pdf.js comes in whole — the legacy build, which runs outside a window.
  {
    ...common,
    entryPoints: [path.join(root, 'src/main/textService.ts')],
    outfile: path.join(out, 'main/textService.js'),
    platform: 'node',
    format: 'cjs',
    target: 'node20',
    external: ['electron'],
  },
  {
    ...common,
    entryPoints: [path.join(root, 'src/main/textWorker.ts')],
    outfile: path.join(out, 'main/textWorker.js'),
    platform: 'node',
    format: 'cjs',
    target: 'node20',
    external: ['electron'],
    ...nodeImportMeta,
  },
  {
    ...common,
    entryPoints: [path.join(root, 'src/main/preload.ts')],
    outfile: path.join(out, 'main/preload.js'),
    platform: 'node',
    format: 'cjs',
    target: 'node20',
    external: ['electron'],
  },
  {
    ...common,
    entryPoints: [path.join(root, 'src/renderer/index.ts')],
    outfile: path.join(out, 'renderer/index.js'),
    platform: 'browser',
    format: 'esm',
    target: 'chrome120',
    splitting: false,
  },
  {
    ...common,
    entryPoints: [path.join(root, 'src/renderer/pdf.worker.entry.ts')],
    outfile: path.join(out, 'renderer/pdf.worker.js'),
    platform: 'browser',
    format: 'iife',
    target: 'chrome120',
  },
]

if (withTests) {
  targets.push({
    ...common,
    entryPoints: [path.join(root, 'src/test/run.ts')],
    outfile: path.join(out, 'test/run.js'),
    platform: 'node',
    format: 'cjs',
    target: 'node20',
    external: ['electron'],
    ...nodeImportMeta,
  })
}

async function copyStatic() {
  await mkdir(path.join(out, 'renderer'), { recursive: true })
  await cp(path.join(root, 'src/renderer/index.html'), path.join(out, 'renderer/index.html'))
  await cp(path.join(root, 'src/renderer/style.css'), path.join(out, 'renderer/style.css'))
  const fonts = path.join(root, 'assets/fonts')
  if (existsSync(fonts)) await cp(fonts, path.join(out, 'renderer/fonts'), { recursive: true })
  // Latex Suite's snippets are inside the renderer bundle (esbuild's JSON
  // loader reads the Mac's own file), and its MIT licence asks for the notice
  // to travel with them — so the file beside them on the Mac goes beside them
  // here too.
  await cp(path.join(root, '../Packages/PaperTimeKit/Sources/PaperCore/Resources/LatexSuite-LICENSE.md'),
    path.join(out, 'renderer/LatexSuite-LICENSE.md'))
  // pdf.js ships the character maps and standard fonts as data files; a PDF
  // with a CJK font or one that relies on the base-14 fonts needs them, and a
  // paper in Korean is exactly that case.
  const pdfjs = path.join(root, 'node_modules/pdfjs-dist')
  for (const dir of ['cmaps', 'standard_fonts']) {
    const from = path.join(pdfjs, dir)
    if (existsSync(from)) await cp(from, path.join(out, 'renderer', dir), { recursive: true })
  }
}

if (watch) {
  await rm(out, { recursive: true, force: true })
  await copyStatic()
  for (const target of targets) {
    const ctx = await esbuild.context(target)
    await ctx.watch()
  }
  console.log('watching')
} else {
  await rm(out, { recursive: true, force: true })
  await Promise.all(targets.map((t) => esbuild.build(t)))
  await copyStatic()
  console.log('built')
}
