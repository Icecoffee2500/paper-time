/**
 * What must not take the app down or lose a file: the settings file read
 * whole or not at all, a watched folder that disappears, a library opened
 * without being written into (`WR1`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { DEFAULTS, fromFile } from '../main/settingsFile.js'
import { watchLibrary } from '../main/watcher.js'
import { Library } from '../main/library.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

export async function safetySuite(test: Test, suite: (name: string) => void) {
  suite('Safety: settings, watchers, opening a folder')

  await test('a settings file of an old shape keeps what it has and fills in the rest', () => {
    const read = fromFile({ libraryRoot: 'D:\\Papers', window: { width: 1000, height: 700 }, pageTint: 'night' as never } as never)
    assert.equal(read.libraryRoot, 'D:\\Papers')
    assert.equal(read.window.width, 1000)
    assert.deepEqual(read.panes, DEFAULTS.panes)
    assert.equal(read.pageTint, 'dim')
    assert.deepEqual(read.extraRoots, [])
  })

  await test('a settings file that is not an object is refused, not read as defaults', () => {
    assert.throws(() => fromFile(null as never))
    assert.throws(() => fromFile([] as never))
    assert.throws(() => fromFile(JSON.parse('"text"')))
  })

  await test('wrong types in a settings file do not leak into the settings', () => {
    const read = fromFile({ libraryRoot: 7, extraRoots: ['C:\\A', 3, null], recentLibraries: 'x' } as never)
    assert.equal(read.libraryRoot, null)
    assert.deepEqual(read.extraRoots, ['C:\\A'])
    assert.deepEqual(read.recentLibraries, [])
  })

  await test('a watched folder that goes away does not throw', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-watch-'))
    fs.mkdirSync(path.join(root, '.papertime', 'papers', 'x'), { recursive: true })
    const stop = watchLibrary(root, () => {})
    try {
      fs.rmSync(root, { recursive: true, force: true })
      // Long enough for the handles to notice; an error nobody listened for
      // would have ended this process here.
      await new Promise((resolve) => setTimeout(resolve, 300))
    } finally {
      stop()
    }
  })

  await test('opening a folder writes nothing into it', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-open-'))
    try {
      const library = await Library.open(root)
      assert.deepEqual(fs.readdirSync(root), [])
      const manifest = await library.manifest()
      assert.equal(manifest.name ?? path.basename(root), path.basename(root))
      assert.deepEqual((await library.collections()).collections, [])
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })
}
