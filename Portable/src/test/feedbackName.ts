/**
 * The name a report goes on the page with, as the Mac cleans it —
 * `feedback-names.json` is the Mac's own `FeedbackNickname`
 * (`Scripts/feedback-names-fixture.swift`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { NICKNAME_LIMIT, nickname } from '../shared/feedbackName.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

export async function feedbackNameSuite(test: Test, suite: (name: string) => void) {
  suite('A nickname goes on the page as the Mac sends it')
  const file = path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures', 'feedback-names.json')
  const fixture = JSON.parse(fs.readFileSync(file, 'utf8')) as { limit: number; cases: { raw: string; clean: string }[] }

  await test(`${fixture.cases.length} names: the same name, to the character`, () => {
    assert.equal(NICKNAME_LIMIT, fixture.limit)
    for (const one of fixture.cases) assert.equal(nickname(one.raw), one.clean, JSON.stringify(one.raw))
  })

  await test('nothing in a name can close the comment it is kept in', () => {
    for (const raw of ['-->', 'a-->b', '<!-- x -->', '--->', '- - >']) {
      const clean = nickname(raw)
      assert.ok(!clean.includes('-->') && !/[<>]/.test(clean), `${raw} → ${clean}`)
    }
  })
}
