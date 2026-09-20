/**
 * Builds the packages and then looks at what came out.
 *
 * electron-builder reports success for a `.deb` that macOS's `ar` quietly
 * mangled into ninety-six bytes — Apple's `ar` writes Mach-O archives, not the
 * GNU ones a Debian package is, and fpm does not notice. A packaging step that
 * can hand you a broken installer without saying so is worse than one that
 * fails, so every artefact is weighed afterwards.
 *
 *   node tools/package.mjs win
 *   node tools/package.mjs linux
 *   node tools/package.mjs win linux
 */
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const root = path.join(import.meta.dirname, '..')
const dist = path.join(root, 'dist')

/** Targets that can honestly be built on this machine. */
const TARGETS = {
  win: { flag: '--win', targets: ['nsis', 'zip'], on: 'any' },
  linux: { flag: '--linux', targets: ['AppImage', 'tar.gz'], on: 'any' },
  // `.deb` and `.rpm` go through fpm, which needs GNU `ar` and GNU `tar`.
  // On a Mac those are Apple's, and the package comes out empty. Build these
  // on Linux — or on a Mac with `brew install binutils gnu-tar` on PATH.
  'linux-packages': { flag: '--linux', targets: ['deb', 'rpm'], on: 'linux' },
  mac: { flag: '--mac', targets: ['dir'], on: 'darwin' },
}

const wanted = process.argv.slice(2)
if (wanted.length === 0) {
  console.error('Usage: node tools/package.mjs <win|linux|linux-packages|mac> …')
  process.exit(2)
}

const before = new Set(fs.existsSync(dist) ? fs.readdirSync(dist) : [])

for (const name of wanted) {
  const target = TARGETS[name]
  if (!target) {
    console.error(`Unknown target: ${name}`)
    process.exit(2)
  }
  if (target.on !== 'any' && target.on !== process.platform) {
    console.error(
      `\n  ${name} can only be built on ${target.on}; this is ${process.platform}.\n` +
      '  Nothing was built for it. See Docs/Porting.md.\n',
    )
    process.exit(1)
  }
  console.log(`\n── ${name} ──`)
  execFileSync(
    'npx',
    ['electron-builder', target.flag, ...target.targets, '--publish', 'never'],
    { cwd: root, stdio: 'inherit' },
  )
}

// ------------------------------------------------------------------ weighing

/** Below this an artefact cannot possibly contain a Chromium. */
const FLOOR = 20 * 1024 * 1024
const INSTALLER = /\.(exe|dmg|AppImage|deb|rpm|zip|tar\.gz|tar\.xz)$/

const made = fs.readdirSync(dist).filter((name) => !before.has(name) || INSTALLER.test(name))
const suspect = []
console.log('\n── what came out ──')
for (const name of made.sort()) {
  const file = path.join(dist, name)
  if (!fs.statSync(file).isFile() || !INSTALLER.test(name)) continue
  const size = fs.statSync(file).size
  const mb = (size / 1024 / 1024).toFixed(1)
  const ok = size >= FLOOR
  console.log(`  ${ok ? '✓' : '✗'} ${name}  ${mb} MB`)
  if (!ok) suspect.push(`${name} is only ${mb} MB — it cannot hold a working app`)
}

if (suspect.length > 0) {
  console.error('\nThese packages are broken:')
  for (const line of suspect) console.error(`  ${line}`)
  console.error('\nA `.deb` or `.rpm` this small means fpm ran with Apple\'s `ar`. Build on Linux.')
  process.exit(1)
}
console.log('\nAll packages are a plausible size.')
