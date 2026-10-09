/**
 * Path identity (`shared/paths.ts`) and everything that compares folders by
 * it — the sidebar's folder tree read with Windows roots, the rename rules,
 * the settings patch, the notes folder that is the same folder spelled
 * differently, and every icon the source names (`WR2`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { findPath, isInside, isUnder, pathKey, samePath, setPathPlatform, slashed } from '../shared/paths.js'
import { acceptedPatch } from '../shared/appSettings.js'
import { claimedBy, isAName } from '../main/library.js'
import { SlipBoxFolder, sameFolder } from '../main/slipBox.js'
import { folderAbove, folderOf, folderTrail, isUnderFolder, store, subfolders, type Paper } from '../renderer/state.js'
import { PaperMeta, PaperState } from '../shared/model.js'
import { hasIcon } from '../renderer/icons.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

function paper(id: string, root: string, relativePath: string): Paper {
  const meta = new PaperMeta({ id, file: { relativePath } } as never)
  return { id, meta, state: new PaperState({}), exists: true, root }
}

export async function pathsSuite(test: Test, suite: (name: string) => void) {
  suite('Paths: one place, however it is spelled')
  const platform = process.platform

  try {
    setPathPlatform('win32')

    await test('Windows spellings of one folder are one folder', () => {
      assert.ok(samePath('D:\\Papers', 'd:/papers/'))
      assert.ok(samePath('D:\\Papers\\', 'D:\\Papers'))
      assert.ok(!samePath('D:\\Papers', 'D:\\Papers2'))
      assert.equal(slashed('C:\\a\\b\\'), 'C:/a/b')
      assert.equal(slashed('/'), '/')
    })

    await test('inside is by whole names, and folded like the disk', () => {
      assert.ok(isUnder('d:\\papers\\week 1\\x.pdf', 'D:\\Papers'))
      assert.ok(!isUnder('D:\\Papers2\\x.pdf', 'D:\\Papers'))
      assert.ok(isInside('D:/Papers/a', 'D:\\Papers'))
      assert.ok(!isInside('D:\\Papers', 'd:/papers'))
      assert.equal(findPath(['D:\\Papers', 'E:\\Other'], 'd:/papers'), 'D:\\Papers')
    })

    await test('a record written with a backslash claims its file', () => {
      const rows = [{ meta: { file: { relativePath: '2026\\Week 1\\x.pdf' } } }] as never
      assert.ok(claimedBy(rows).has(pathKey('2026/week 1/X.pdf')))
    })

    await test('the folder tree reads the same with a Windows root', () => {
      store.roots = ['D:\\Papers']
      store.papers = [
        paper('A', 'D:\\Papers', '2026/week 1/a.pdf'),
        paper('B', 'D:\\Papers', '2026/week 2/b.pdf'),
        paper('C', 'D:\\Papers', 'loose.pdf'),
      ]
      assert.equal(folderOf(store.papers[0]), 'D:/Papers/2026/week 1')
      assert.ok(isUnderFolder(store.papers[0], 'd:\\papers\\2026'))
      assert.ok(!isUnderFolder(store.papers[2], 'D:\\Papers\\2026'))
      store.folders = []
      assert.deepEqual(subfolders('D:\\Papers').map((one) => [one.name, one.count]), [['2026', 2]])
      assert.deepEqual(subfolders('d:/papers/2026').map((one) => one.name), ['week 1', 'week 2'])
      // The disk's folders join the papers': one just made, holding nothing,
      // and one holding only PDFs not yet taken in, are in the tree too.
      store.folders = ['D:/Papers/2026', 'D:/Papers/2026/week 1', 'D:/Papers/2026/week 3', 'D:/Papers/New', 'D:/Papers/New/Inside']
      assert.deepEqual(subfolders('D:\\Papers').map((one) => [one.name, one.count]), [['2026', 2], ['New', 0]])
      assert.deepEqual(subfolders('d:/papers/2026').map((one) => [one.name, one.count]), [['week 1', 1], ['week 2', 1], ['week 3', 0]])
      assert.deepEqual(subfolders('D:/Papers/New').map((one) => one.name), ['Inside'])
      store.folders = []
      // The first step down is the library row as it is stored.
      assert.deepEqual(folderTrail('D:/Papers/2026/week 1'), ['D:\\Papers', 'D:/Papers/2026', 'D:/Papers/2026/week 1'])
      // And going up from the top folder lands on that row, not on `D:/Papers`.
      assert.equal(folderAbove('D:/Papers/2026'), 'D:\\Papers')
      assert.equal(folderAbove('D:\\Papers'), null)
    })

    setPathPlatform('linux')

    await test('on Linux case is a different folder', () => {
      assert.ok(!samePath('/home/a/Papers', '/home/a/papers'))
      assert.ok(samePath('/home/a/Papers/', '/home/a/Papers'))
    })
  } finally {
    setPathPlatform(platform)
    store.roots = []
    store.papers = []
  }

  await test('a file name follows the Mac everywhere and Windows on Windows', () => {
    assert.ok(!isAName('a/b.pdf', 'linux'))
    assert.ok(!isAName('a:b.pdf', 'darwin'))
    assert.ok(isAName('why? | because.pdf', 'linux'))
    assert.ok(!isAName('why?.pdf', 'win32'))
    assert.ok(!isAName('CON', 'win32'))
    assert.ok(!isAName('nul.pdf', 'win32'))
    assert.ok(isAName('console.pdf', 'win32'))
  })

  await test('a settings patch keeps to the keys and kinds the file has', () => {
    const patch = acceptedPatch({
      pageLayout: 'book',
      unknown: 1,
      latexShortcuts: 'yes',
      window: { width: Number.NaN, height: 700 },
      notesFolder: null,
      libraryRoot: 7,
      extraRoots: ['C:\\A', 3],
    })
    assert.deepEqual(patch, { pageLayout: 'book', window: { height: 700 }, notesFolder: null, extraRoots: ['C:\\A'] })
  })

  await test('the notes folder spelled another way is the same folder, and nothing moves', async () => {
    const base = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-same-'))
    try {
      const folder = path.join(base, 'Loose')
      fs.mkdirSync(folder)
      fs.writeFileSync(path.join(folder, '202609270900.md'), 'a thought', 'utf8')
      const other = path.join(base, 'LOOSE')
      // Only where the disk folds case, which is what the move has to survive.
      if (!fs.existsSync(other)) return
      assert.ok(sameFolder(folder, other))
      const moved = await new SlipBoxFolder(folder, folder).move(new SlipBoxFolder(other, other, true))
      assert.deepEqual(moved, { moved: 0, kept: 0 })
      assert.deepEqual(fs.readdirSync(folder), ['202609270900.md'])
    } finally {
      fs.rmSync(base, { recursive: true, force: true })
    }
  })

  await test('every icon the source names has a drawing', () => {
    const root = path.resolve(__dirname, '../../src/renderer')
    const missing = new Set<string>()
    const walk = (directory: string) => {
      for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        const file = path.join(directory, entry.name)
        if (entry.isDirectory()) walk(file)
        else if (file.endsWith('.ts') && !file.endsWith('icons.ts')) {
          const text = fs.readFileSync(file, 'utf8')
          for (const pattern of [/\bicon(?:Node)?\('([a-z][a-z0-9.]*)'/g, /\bicon: '([a-z][a-z0-9.]*)'/g, /\bicon\(\s*'([a-z][a-z0-9.]*)'/g]) {
            for (const match of text.matchAll(pattern)) if (!hasIcon(match[1])) missing.add(`${match[1]} (${path.basename(file)})`)
          }
        }
      }
    }
    walk(root)
    assert.deepEqual([...missing], [])
  })
}
