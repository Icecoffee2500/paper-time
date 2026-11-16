/**
 * The reading plan's rules, answered as the Mac answers them —
 * `reading-plans.json` is the Mac's own `ReadingPlan.swift`
 * (`Scripts/reading-plan-fixture.swift`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { encodeSwiftJSON } from '../shared/coding.js'
import {
  addSection, addToPlan, dayFromOrdinal, dayOrdinal, materialAddress, materialHost, materialKindOfAddress,
  materialKindOfFile, materialTitle, mondayOf, moveBefore, moveSection, moveToEnd, planGroups, planOrder, readDay,
  readLinks, readPlan, readSchedule, removeFromPlan, removeSection, renameSection, spreadDays, venueName, weekdayOf, type ReadingPlan,
} from '../shared/readingPlan.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Fixture {
  days: { ordinal: number; text: string; weekday: number; monday: string }[]
  parse: { today: string; text: string; day?: string }[]
  spread: { count: number; weekdays: number[]; perDay: number; from: string; days: string[] }[]
  plan: { op: string; args: string[]; json: string; groups: { section?: string; papers: string[] }[]; order: string[] }[]
  addresses: { text: string; address?: string; kind?: string; title?: string; host?: string }[]
  files: { name: string; kind: string }[]
  encoded: { schedule: string; links: string }
  venues: { full?: string; short?: string; name?: string }[]
}

export async function readingPlanSuite(test: Test, suite: (name: string) => void) {
  suite('Reading plans, as the Mac reads them')
  const file = path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures', 'reading-plans.json')
  const fixture = JSON.parse(fs.readFileSync(file, 'utf8')) as Fixture

  await test(`${fixture.days.length} days: the same calendar, weekdays and Mondays`, () => {
    for (const day of fixture.days) {
      assert.equal(dayFromOrdinal(day.ordinal), day.text, String(day.ordinal))
      if (day.ordinal > -719000) assert.equal(dayOrdinal(day.text), day.ordinal, day.text)
      assert.equal(weekdayOf(day.text), day.weekday, day.text)
      assert.equal(mondayOf(day.text), day.monday, day.text)
    }
  })

  await test(`${fixture.parse.length} typed days read to the same day`, () => {
    for (const c of fixture.parse) assert.equal(readDay(c.text, c.today), c.day ?? null, `${JSON.stringify(c.text)} on ${c.today}`)
  })

  await test(`${fixture.spread.length} spreads land on the same days`, () => {
    for (const c of fixture.spread) assert.deepEqual(spreadDays(c.count, c.weekdays, c.perDay, c.from), c.days, JSON.stringify(c))
  })

  await test(`${fixture.plan.length} edits to a plan give the same file, byte for byte`, () => {
    let plan = readPlan(JSON.parse(fixture.plan[0].json)) as ReadingPlan
    assert.equal(encodeSwiftJSON(plan), fixture.plan[0].json)
    for (const step of fixture.plan.slice(1)) {
      const a = step.args
      const section = (s: string) => (s === '-' ? null : s)
      switch (step.op) {
        case 'add': addToPlan(plan, a.slice(0, -1), section(a[a.length - 1])); break
        case 'addSection': addSection(plan, a[0], a[1]); break
        case 'moveToEnd': moveToEnd(plan, a.slice(0, -1), section(a[a.length - 1])); break
        case 'moveBefore': moveBefore(plan, a.slice(0, -1), a[a.length - 1]); break
        case 'renameSection': renameSection(plan, a[0], a[1]); break
        case 'moveSection': moveSection(plan, a[0], Number(a[1])); break
        case 'removeSection': removeSection(plan, a[0]); break
        case 'remove': removeFromPlan(plan, a); break
        case 'rename': plan.name = a[0]; break
        default: throw new Error(step.op)
      }
      assert.equal(encodeSwiftJSON(plan), step.json, `${step.op} ${a.join(' ')}`)
      assert.deepEqual(planGroups(plan).map((g) => ({ section: g.section?.id, papers: g.papers })),
        step.groups.map((g) => ({ section: g.section, papers: g.papers })), step.op)
      assert.deepEqual(planOrder(plan), step.order)
      plan = readPlan(JSON.parse(encodeSwiftJSON(plan))) as ReadingPlan
    }
  })

  await test(`${fixture.addresses.length} pasted addresses: the same address, kind, name and host`, () => {
    for (const c of fixture.addresses) {
      const address = materialAddress(c.text)
      assert.equal(address, c.address ?? null, JSON.stringify(c.text))
      if (!address) continue
      assert.equal(materialKindOfAddress(address), c.kind, address)
      assert.equal(materialTitle(address), c.title, address)
      assert.equal(materialHost(address), c.host, address)
    }
    for (const c of fixture.files) assert.equal(materialKindOfFile(c.name), c.kind, c.name)
  })

  await test(`${fixture.venues.length} venues are named the way the Mac names them`, () => {
    for (const c of fixture.venues) assert.equal(venueName(c.full, c.short), c.name ?? null, JSON.stringify(c))
  })

  await test('a day and a list of materials the Mac wrote come back byte for byte', () => {
    assert.equal(encodeSwiftJSON(readSchedule(JSON.parse(fixture.encoded.schedule))), fixture.encoded.schedule)
    assert.equal(encodeSwiftJSON(readLinks(JSON.parse(fixture.encoded.links))), fixture.encoded.links)
    assert.equal(readSchedule({ date: '2026-02-30' }), null)
    assert.equal(readLinks({ links: [{ id: 'x', addedAt: '2026-11-16T00:00:00Z', kind: 'hologram' }] })?.links[0].kind, 'file')
  })
}
