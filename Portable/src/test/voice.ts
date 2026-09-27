/**
 * The voice (`Docs/Voice.md`), checked in the source (`WR8`): every
 * `L(ko, en)` pair in the window, the main process and the shared code —
 * the Korean in 해요체, never the formal 습니다; the English without the
 * words the voice forbids; neither side left empty or copied from the other.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

/** Every `L('…', '…')` with two plain string arguments, and where it is. */
function pairs(): { file: string; ko: string; en: string }[] {
  const root = path.resolve(__dirname, '../../src')
  const out: { file: string; ko: string; en: string }[] = []
  const walk = (dir: string) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) {
        if (entry.name !== 'test') walk(full)
        continue
      }
      if (!entry.name.endsWith('.ts')) continue
      const text = fs.readFileSync(full, 'utf8')
      const string = String.raw`'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"`
      const pattern = new RegExp(String.raw`\b(?:L|say)\(\s*(${string})\s*,\s*(${string})\s*\)`, 'g')
      for (const match of text.matchAll(pattern)) {
        out.push({ file: path.relative(root, full), ko: match[1].slice(1, -1), en: match[2].slice(1, -1) })
      }
    }
  }
  walk(root)
  return out
}

export async function voiceSuite(test: Test, suite: (name: string) => void) {
  suite('The voice')
  const found = pairs()

  await test('the pairs were found', () => {
    assert.ok(found.length > 300, `found ${found.length}`)
  })

  await test('the Korean is 해요체, not the formal register', () => {
    const formal = found.filter((one) => /(습니다|습니까|십시오)[.?!]?$/.test(one.ko.trim()))
    assert.deepEqual(formal.map((one) => `${one.file}: ${one.ko}`), [])
  })

  await test('the English leaves out the words the voice forbids', () => {
    const banned = /\b(powerful|seamless(ly)?|simply|effortless(ly)?|oops|sorry)\b/i
    const hits = found.filter((one) => banned.test(one.en))
    assert.deepEqual(hits.map((one) => `${one.file}: ${one.en}`), [])
  })

  await test('neither side is empty, and the Korean is not the English again', () => {
    const bad = found.filter((one) => (one.ko.trim() === '') !== (one.en.trim() === '')
      || (one.ko === one.en && /[a-z]{4,}/i.test(one.ko) && !/[가-힣]/.test(one.ko) && one.ko.includes(' ')))
    assert.deepEqual(bad.map((one) => `${one.file}: ${one.ko} / ${one.en}`), [])
  })
}
