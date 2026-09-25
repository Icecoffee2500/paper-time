/**
 * Latex Suite's text engine, against the plugin's own answers.
 *
 * The fixtures are the Mac engine's, read from where the Swift tests read
 * them (`Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures`): keystroke cases
 * and random keystrokes recorded by running the plugin headless, where the
 * caret is at every offset of 820 notes, and what each regex trigger matched.
 * A case that passes here and in `swift test` is a keystroke that does the
 * same thing on every desktop.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { LatexEngine, LatexSuite, Tabstops, type LatexChange, type LatexEdit, type LatexInput, type TextRange } from '../shared/latexSuite.js'
import { ChangeSet } from '../shared/latexSuite/changes.js'
import { Context } from '../shared/latexSuite/context.js'
import { PatternShape, RegexInput, type RegexMatch } from '../shared/latexSuite/regex.js'
import { Library } from '../shared/latexSuite/snippets.js'

type TestFn = (name: string, body: () => void | Promise<void>) => Promise<void>

function fixture<T>(name: string): T {
  const file = path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures', `${name}.json`)
  return JSON.parse(fs.readFileSync(file, 'utf8')) as T
}

// MARK: - The keystroke fixtures

interface Selection { anchor: number; head: number }
interface State { doc: string; selection: Selection[]; tabstops?: { group: number; ranges: number[][] }[]; tabstopIndex?: number }
interface Case {
  id: string
  name: string
  before: string
  input: string | string[]
  after: string
  handled: boolean[]
  flags: string[]
  beforeState: State
  afterState: State
}

const rangeOf = (s: Selection): TextRange => ({ from: Math.min(s.anchor, s.head), to: Math.max(s.anchor, s.head) })
const byStart = (a: TextRange, b: TextRange) => a.from - b.from

/** One keypress per character, or a named key, as the harness split them. */
function steps(c: Case): string[] {
  const named = new Set(['Tab', 'Shift+Tab', 'Enter', 'Shift+Enter', 'Backspace', 'Undo'])
  const out: string[] = []
  for (const item of typeof c.input === 'string' ? [c.input] : c.input) {
    if (named.has(item) || item.startsWith('Caret:')) out.push(item)
    else for (const scalar of item) out.push(scalar)
  }
  return out
}

interface Outcome {
  doc: string
  selection: TextRange[]
  groups: TextRange[][]
  index: number | null
  handled: boolean[]
}

function expected(c: Case): Outcome {
  const groups = (c.afterState.tabstops ?? []).map((g) => g.ranges.map((r) => ({ from: r[0], to: r[1] })))
  return {
    doc: c.afterState.doc,
    selection: c.afterState.selection.map(rangeOf).sort(byStart),
    groups,
    index: groups.length === 0 ? null : c.afterState.tabstopIndex ?? null,
    handled: c.handled,
  }
}

/**
 * A small editor that plays a fixture's keystrokes through the engine the way
 * the harness that recorded them played them through the plugin: a key the
 * engine leaves alone is typed over the selection, a pass-through Tab or Enter
 * changes nothing, Undo steps back one history entry and drops the tabstops,
 * `Caret:N` clicks. The Mac's `LatexSuiteFixtures.Editor`, line for line.
 */
class Editor {
  tabstops = Tabstops.none
  private history: [string, TextRange[]][] = []

  constructor(public text: string, public selection: TextRange[]) {}

  static apply(changes: LatexChange[], text: string): string {
    let out = text
    for (const change of [...changes].sort((a, b) => b.from - a.from)) {
      out = out.slice(0, change.from) + change.text + out.slice(change.to)
    }
    return out
  }

  press(step: string, engine: LatexEngine): boolean {
    if (step === 'Undo') {
      const entry = this.history.pop()
      if (!entry) return false
      ;[this.text, this.selection] = entry
      this.tabstops = Tabstops.none
      return true
    }
    if (step.startsWith('Caret:')) {
      const p = Number(step.slice(6))
      this.selection = [{ from: p, to: p }]
      this.tabstops = this.tabstops.selecting(this.selection)
      return true
    }
    const input: LatexInput = step === 'Tab' ? 'tab' : step === 'Shift+Tab' ? 'shiftTab' : step === 'Enter' ? 'enter'
      : step === 'Shift+Enter' ? 'shiftEnter' : step === 'Backspace' ? 'backspace' : { text: step }
    const edit = engine.handle(input, this.text, this.selection, this.tabstops)
    if (edit) {
      // One history entry per undo step, each remembering the selection it started from.
      let sel = this.selection
      edit.undoSteps.forEach((changes, n) => {
        this.history.push([this.text, sel])
        this.text = Editor.apply(changes, this.text)
        if (n === 0 && edit.undoSteps.length > 1) {
          // The echoed key: the caret after it.
          const set = new ChangeSet(changes.map((c) => ({ from: c.from, to: c.to, insert: c.text })))
          sel = sel.map((r) => {
            const p = set.mapped(r.from, 1)
            return { from: p, to: p }
          })
        }
      })
      this.selection = edit.selection
      this.tabstops = edit.tabstops
      return true
    }
    if (typeof input !== 'object') return false
    // The editor's own typing: every range replaced, the caret after it.
    this.history.push([this.text, this.selection])
    const key = input.text
    const changes = this.selection.map((r) => ({ from: r.from, to: r.to, text: key }))
    this.text = Editor.apply(changes, this.text)
    let shift = 0
    const carets: TextRange[] = []
    for (const range of [...this.selection].sort(byStart)) {
      const p = range.from + shift + key.length
      carets.push({ from: p, to: p })
      shift += key.length - (range.to - range.from)
    }
    this.selection = carets
    this.tabstops = this.tabstops.afterEdit(changes, carets)
    return false
  }
}

function play(c: Case, engine: LatexEngine): Outcome {
  const editor = new Editor(c.beforeState.doc, c.beforeState.selection.map(rangeOf))
  const handled = steps(c).map((step) => editor.press(step, engine))
  return {
    doc: editor.text,
    selection: [...editor.selection].sort(byStart),
    groups: editor.tabstops.groups.map((g) => g.ranges),
    index: editor.tabstops.isActive ? editor.tabstops.index : null,
    handled,
  }
}

const describeOutcome = (o: Outcome) => JSON.stringify(o)

/** Renders a document with its selection the way the fixtures write it. */
function render(doc: string, selection: TextRange[]): string {
  let s = doc.replace(/\|/g, '¦')
  for (const r of [...selection].sort((a, b) => b.from - a.from)) {
    s = r.to === r.from ? `${s.slice(0, r.from)}|${s.slice(r.from)}` : `${s.slice(0, r.from)}«${s.slice(r.from, r.to)}»${s.slice(r.to)}`
  }
  return s
}

// MARK: - The context fixture

interface ContextFixture {
  header: { divergent: { doc: number; reason: string }[] }
  docs: { set: string; doc: string; runs: [number, number, string, number[] | null, string[]][]; equations?: [number, number[][]][] }[]
}

/** The context at `pos`, written the fixture's way. */
function describeContext(doc: string, pos: number): { mode: string; bounds: number[] | null; stack: string[] } {
  const ctx = new Context(doc, [{ from: pos, to: pos }], Library.shared, ['math'])
  const m = ctx.mode
  const flags: string[] = []
  if (m.text) flags.push('t')
  if (m.inlineMath) flags.push('n')
  if (m.blockMath) flags.push('M')
  if (m.codeMath) flags.push('k')
  if (typeof m.codeBlock === 'object') flags.push(`c=${m.codeBlock.language}`)
  if (m.code) flags.push('C')
  if (m.textEnv) flags.push('T')
  if (m.snippetlessEnv) flags.push('S')
  const eq = ctx.equation
  const bounds = eq ? [eq.outerStart, eq.innerStart, eq.innerEnd, eq.outerEnd] : null
  const stack = ctx.scopes(pos).map((s) => (s.kind === 'math' ? 'math' : s.kind === 'environment' ? `environment:${s.name}` : `command:${s.name}:${s.argumentIndex}`))
  return { mode: flags.join(','), bounds: m.codeBlock === false ? bounds : null, stack }
}

const sameContext = (a: ReturnType<typeof describeContext>, run: ContextFixture['docs'][number]['runs'][number]) =>
  a.mode === run[2] && JSON.stringify(a.bounds) === JSON.stringify(run[3]) && JSON.stringify(a.stack) === JSON.stringify(run[4])

/** The pairs auto-enlarge can rewrite, deduplicated. */
function rewritable(pairs: number[][], doc: string): Set<string> {
  return new Set(pairs.filter((p) => {
    const open = doc.slice(p[0], p[1])
    const close = doc.slice(p[2], p[3])
    return !(open === '{' || open === '\\(' || open.startsWith('\\left') || close.startsWith('\\right'))
  }).map((p) => p.join(',')))
}

// MARK: - The regex fixture

interface RegexFixture {
  corpus: string[]
  cases: { id: number; matches: (number | number[] | null)[][] }[]
}

interface Pattern {
  id: number
  regex: RegExp
  source: string
  shape: PatternShape
  groupNames: (string | null)[]
}

/** What the fixture says JavaScript matched on corpus entry `index`. */
function expectedMatch(fx: RegexFixture, id: number, index: number): string | null {
  const c = fx.cases.find((entry) => entry.id === id)
  const hit = c?.matches.find((m) => m[0] === index)
  return hit ? JSON.stringify(hit.slice(1)) : null
}

function shapeOf(m: RegexMatch | null, shift = 0): string | null {
  if (!m) return null
  return JSON.stringify([m.index - shift, ...m.groupRanges.map((r) => (r ? [r.from - shift, r.to - shift] : null))])
}

/** The rewritten pattern on the whole text, the plain JavaScript way. */
function whole(source: string, text: string): string | null {
  const m = new RegExp(source, 'd').exec(text) as (RegExpExecArray & { indices: [number, number][] }) | null
  if (!m) return null
  const groups: (number[] | null)[] = []
  for (let g = 1; g < m.length; g += 1) groups.push(m[g] === undefined ? null : [m.indices[g][0], m.indices[g][1]])
  return JSON.stringify([m.index, ...groups])
}

const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/

// MARK: - The note the timing runs on

/**
 * A note of just over 20,000 characters, as the Mac's timing test builds it:
 * headings, paragraphs that are one long line each, inline and display math,
 * lists, fenced code — and a last paragraph whose inline equation the caret
 * is in. `paragraph: 0` is the hardest shape: the whole note one line.
 */
function timingNote(paragraph: number): { text: string; caret: number } {
  const sentence = "The posterior $p(\\theta \\mid x)$ follows from Bayes' rule, and the evidence costs a sum over every $z$. "
  let text = ''
  if (paragraph === 0) {
    while (text.length < 20_000) text += sentence
  } else {
    let section = 0
    while (text.length < 20_000) {
      section += 1
      text += `## Section ${section}\n\n`
      let body = ''
      while (body.length < paragraph) body += sentence
      text += `${body}\n\n`
      text += '$$\n\\mathcal{L}(\\theta) = \\sum_{i=1}^{N} \\log p(x_i \\mid \\theta)\n$$\n\n'
      text += '- a point with $x^{2}$ in it\n- another with `code $not math$`\n\n'
      if (section % 3 === 0) text += '```python\nprice = "$5"\nprint(price)\n```\n\n'
    }
  }
  text += 'Finally the bound is $\\frac{a}{b} + q'
  const caret = text.length
  return { text: `${text} + y$ which closes the note.\n`, caret }
}

function time(runs: number, body: () => void): { median: number; p95: number } {
  body()
  const samples: number[] = []
  for (let i = 0; i < runs; i += 1) {
    const start = performance.now()
    body()
    samples.push(performance.now() - start)
  }
  samples.sort((a, b) => a - b)
  return { median: samples[samples.length >> 1], p95: samples[Math.floor((samples.length * 95) / 100)] }
}

// MARK: - The tests

export async function latexSuiteTests(test: TestFn, suite: (name: string) => void) {
  const engine = new LatexEngine()
  const caret = (p: number): TextRange[] => [{ from: p, to: p }]

  suite('Latex Suite: the plugin\'s own answers')

  const cases = fixture<{ cases: Case[] }>('latex-suite-cases').cases
  await test(`every recorded case comes out the way the plugin produced it (${cases.length})`, () => {
    assert.equal(cases.length, 290)
    assert.equal(new Set(cases.map((c) => c.id)).size, cases.length)
    const differ: string[] = []
    for (const c of cases) {
      const got = play(c, engine)
      const want = expected(c)
      if (describeOutcome(got) !== describeOutcome(want)) {
        differ.push(`${c.id} ${c.name}: ${render(got.doc, got.selection)} ≠ ${c.after}\n got ${describeOutcome(got)}\nwant ${describeOutcome(want)}`)
      }
    }
    assert.equal(differ.length, 0, `${differ.length} of ${cases.length} differ:\n${differ.slice(0, 12).join('\n')}`)
  })

  const random = fixture<{ cases: Case[] }>('latex-suite-random').cases
  await test(`random keystrokes come out the way the plugin produced them (${random.length})`, () => {
    assert.equal(random.length, 500)
    const differ = random.filter((c) => describeOutcome(play(c, engine)) !== describeOutcome(expected(c)))
      .map((c) => `${c.id} ${JSON.stringify(c.before)} + ${JSON.stringify(c.input)}`)
    assert.equal(differ.length, 0, `${differ.length} differ: ${differ.slice(0, 10).join('; ')}`)
  })

  suite('Latex Suite: the contract')

  await test('the engine runs before the key is inserted, and Undo sees the key first', () => {
    const text = '$x@$'
    const edit = engine.handle({ text: 'a' }, text, caret(3))
    assert.ok(edit)
    assert.deepEqual(edit.changes, [{ from: 2, to: 3, text: '\\alpha' }])
    assert.equal(Editor.apply(edit.changes, text), '$x\\alpha$')
    assert.deepEqual(edit.selection, caret(8))
    assert.equal(edit.undoSteps.length, 2)
    const typed = Editor.apply(edit.undoSteps[0], text)
    assert.equal(typed, '$x@a$')
    assert.equal(Editor.apply(edit.undoSteps[1], typed), '$x\\alpha$')
    assert.equal(edit.tabstops.isActive, false)
  })

  await test('null means the editor does what it always does', () => {
    assert.equal(engine.handle({ text: 'q' }, '$x$', caret(2)), null)
    assert.equal(engine.handle({ text: 'a' }, 'x @', caret(3)), null)
    assert.equal(engine.handle('tab', 'no math here', caret(2)), null)
    assert.equal(engine.handle('enter', '$x$', caret(2)), null)
    assert.equal(engine.handle('backspace', '$xy$', caret(2)), null)
    assert.equal(engine.handle({ text: 'a' }, '$x@$', []), null)
    // More than one UTF-16 unit is not a keystroke Latex Suite reacts to.
    assert.equal(engine.handle({ text: '😀' }, '$x$', caret(2)), null)
    assert.equal(engine.handle({ text: 'ab' }, '$x@$', caret(3)), null)
  })

  await test('offsets are UTF-16, as JavaScript and NSRange count them', () => {
    const text = '$😀@$'
    const edit = engine.handle({ text: 'a' }, text, caret(4))
    assert.ok(edit)
    assert.equal(Editor.apply(edit.changes, text), '$😀\\alpha$')
    assert.deepEqual(edit.selection, caret(9))
  })

  await test('a selection passed out of range is clamped, not trapped on', () => {
    assert.equal(engine.handle({ text: 'a' }, '$x@$', [{ from: 99, to: 104 }]), null)
  })

  await test('typing inside a placeholder grows it; Tab then leaves it', () => {
    let text = '$$'
    let selection = caret(1)
    let tabstops = Tabstops.none
    const press = (input: LatexInput) => {
      const edit = engine.handle(input, text, selection, tabstops)
      if (edit) {
        text = Editor.apply(edit.changes, text)
        selection = edit.selection
        tabstops = edit.tabstops
      } else if (typeof input === 'object') {
        const change = { from: selection[0].from, to: selection[0].to, text: input.text }
        text = Editor.apply([change], text)
        selection = caret(selection[0].from + input.text.length)
        tabstops = tabstops.afterEdit([change], selection)
      }
    }
    for (const key of ['/', '/']) press({ text: key })
    assert.equal(text, '$\\frac{}{}$')
    assert.equal(tabstops.groups.length, 3)
    for (const key of ['a', '+', 'b']) press({ text: key })
    assert.equal(text, '$\\frac{a+b}{}$')
    assert.deepEqual(tabstops.groups[0].ranges, [{ from: 7, to: 10 }])
    assert.equal(tabstops.index, 0)
    press('tab')
    assert.deepEqual(selection, caret(12))
    press({ text: 'c' })
    press('tab')
    assert.equal(text, '$\\frac{a+b}{c}$')
    assert.deepEqual(selection, caret(14))
    assert.equal(tabstops.isActive, false)
  })

  await test('tabstops map through edits the editor makes elsewhere', () => {
    const tabstops = new Tabstops([
      { ranges: [{ from: 10, to: 10 }], color: 0 },
      { ranges: [{ from: 20, to: 22 }], color: 0 },
      { ranges: [{ from: 30, to: 30 }], color: 0 },
    ], 0)
    const shifted = tabstops.mapped([{ from: 0, to: 0, text: 'abc' }])
    assert.deepEqual(shifted.groups.map((g) => g.ranges), [[{ from: 13, to: 13 }], [{ from: 23, to: 25 }], [{ from: 33, to: 33 }]])
    const grown = tabstops.mapped([{ from: 22, to: 22, text: 'x' }])
    assert.deepEqual(grown.groups[1].ranges, [{ from: 20, to: 23 }])
    const deleted = tabstops.mapped([{ from: 5, to: 25, text: '' }])
    assert.deepEqual(deleted.groups[0].ranges, [])
    assert.deepEqual(deleted.groups[1].ranges, [{ from: 5, to: 5 }])
    assert.deepEqual(deleted.groups[2].ranges, [{ from: 10, to: 10 }])
    assert.equal(tabstops.selecting(caret(25)).isActive, false)
    assert.equal(tabstops.selecting([{ from: 21, to: 22 }]).index, 1)
    assert.equal(tabstops.selecting(caret(30)).isActive, false)
  })

  await test('math in Markdown reads the way the plugin reads it', () => {
    const marks: [string, string][] = [
      ['a $x‸$ b', 'n'], ['$$\nx‸\n$$', 'M'], ['a $$x‸$$ b', 'M'], ['```\n$x‸$\n```', 'c='], ['`$x‸$`', 't,C'],
      ['\\$x‸$', 't'], ['$a\\$b‸$', 'n'], ['$x‸\n$', 't'], ['> $$\n> x‸\n> $$', 'M'], ['```math\nx‸\n```', 'k'],
      ['[[a $x‸$]]', 't'], ['%%$x‸$%%', 't'], ['$x $ y‸$', 'n'], ['$x$1 y‸$', 'n'], ['a $‸$ b', 'n'],
    ]
    for (const [marked, mode] of marks) {
      const at = marked.indexOf('‸')
      assert.equal(describeContext(marked.replace('‸', ''), at).mode, mode, JSON.stringify(marked))
    }
  })

  await test('a long paragraph of stray dollars and code spans above does not reach the caret', () => {
    const text = `${'Plain prose, with a $5 price and a `$` in code. '.repeat(200)}\n\nNow $x‸ + y$ here.`
    const at = text.indexOf('‸')
    assert.equal(describeContext(text.replace('‸', ''), at).mode, 'n')
  })

  await test('a fraction that would start after the caret lets the key through', () => {
    // The one place the engine does not follow the plugin, on both desktops
    // alike: see `fractionBeforeDisplayDollars` in the Swift tests.
    assert.equal(engine.handle({ text: '/' }, '$$x$$', caret(0)), null)
    assert.notEqual(engine.handle({ text: 'a' }, '@$$x$$', caret(1)), null)
  })

  await test('two carets expand together', () => {
    const text = '$x@$ and $y@$'
    const edit = engine.handle({ text: 'a' }, text, [{ from: 3, to: 3 }, { from: 12, to: 12 }])
    assert.ok(edit)
    assert.equal(Editor.apply(edit.changes, text), '$x\\alpha$ and $y\\alpha$')
    assert.deepEqual(edit.selection, [{ from: 8, to: 8 }, { from: 22, to: 22 }])
  })

  await test('the licence travels with the data', () => {
    assert.equal(LatexSuite.version, '1.13.1')
    assert.ok(LatexSuite.licence.startsWith('MIT License\n\nCopyright (c) 2022 artisticat1\n'))
    assert.ok(LatexSuite.credit.includes('artisticat1') && LatexSuite.credit.includes('MIT'))
    assert.equal(LatexSuite.snippetCount, 199)
  })

  suite('Latex Suite: where the caret is')

  const context = fixture<ContextFixture>('latex-suite-context')
  for (const set of ['written', 'random']) {
    await test(`every caret position of the ${set} notes reads the way the plugin reads it`, () => {
      const divergent = new Set(context.header.divergent.map((d) => d.doc))
      let checked = 0
      const differ: string[] = []
      context.docs.forEach((doc, index) => {
        if (doc.set !== set || divergent.has(index)) return
        for (const run of doc.runs) {
          for (let pos = run[0]; pos <= run[1]; pos += 1) {
            const got = describeContext(doc.doc, pos)
            checked += 1
            if (!sameContext(got, run)) {
              differ.push(`${JSON.stringify(doc.doc.slice(0, pos) + '‸' + doc.doc.slice(pos))}: got ${JSON.stringify(got)}, want ${JSON.stringify(run.slice(2))}`)
            }
          }
        }
      })
      assert.ok(checked > (set === 'written' ? 2_500 : 14_000), `only ${checked} positions`)
      assert.equal(differ.length, 0, `${differ.length} of ${checked} differ:\n${differ.slice(0, 8).join('\n')}`)
    })

    await test(`auto-enlarge sees the bracket pairs the plugin sees (${set})`, () => {
      let checked = 0
      const differ: string[] = []
      for (const doc of context.docs) {
        if (doc.set !== set) continue
        for (const [pos, pairs] of doc.equations ?? []) {
          const ctx = new Context(doc.doc, caret(pos), Library.shared, ['math'])
          const bound = ctx.bounds.find((b) => b.tree !== null && b.innerStart <= pos && b.innerEnd >= pos)
          const latex = bound ? ctx.latex(bound) : null
          const got = latex ? latex.pairs().map((p) => [p.open.from, p.open.to, p.close.from, p.close.to]) : []
          checked += 1
          const a = [...rewritable(got, doc.doc)].sort().join(' ')
          const b = [...rewritable(pairs, doc.doc)].sort().join(' ')
          if (a !== b) differ.push(`${JSON.stringify(doc.doc)} at ${pos}: got ${a}, want ${b}`)
        }
      }
      assert.ok(checked > (set === 'written' ? 150 : 90), `only ${checked} equations`)
      assert.equal(differ.length, 0, differ.slice(0, 8).join('\n'))
    })
  }

  await test('the one divergence is still the known one', () => {
    const entry = context.header.divergent[0]
    assert.ok(entry)
    const doc = context.docs[entry.doc]
    let disagreements = 0
    for (const run of doc.runs) {
      for (let pos = run[0]; pos <= run[1]; pos += 1) if (!sameContext(describeContext(doc.doc, pos), run)) disagreements += 1
    }
    assert.ok(disagreements > 0, 'it agrees now: drop it from the fixture\'s `divergent`')
  })

  suite('Latex Suite: the regex dialect')

  const regexFixture = fixture<RegexFixture>('latex-suite-regex')
  const patterns: Pattern[] = Library.shared.snippets.flatMap((s) => (s.trigger.kind === 'regex'
    ? [{ id: s.id, regex: s.trigger.regex, source: s.trigger.regex.source, shape: s.trigger.shape, groupNames: s.trigger.groupNames }]
    : []))

  await test('every regex trigger compiles, and the fixture has each one', () => {
    assert.equal(patterns.length, 49)
    assert.deepEqual(new Set(patterns.map((p) => p.id)), new Set(regexFixture.cases.map((c) => c.id)))
  })

  await test('JavaScript reads every rewritten pattern the way it read the original', () => {
    const differ: string[] = []
    for (const pattern of patterns) {
      regexFixture.corpus.forEach((text, index) => {
        const got = whole(pattern.source, text)
        const want = expectedMatch(regexFixture, pattern.id, index)
        if (got !== want) differ.push(`snippet ${pattern.id} on ${JSON.stringify(text)}: ${got} ≠ ${want}`)
      })
    }
    assert.equal(differ.length, 0, differ.slice(0, 8).join('\n'))
  })

  await test('the windowed match agrees with the whole-prefix match, typed and on Tab', () => {
    const differ: string[] = []
    for (const pattern of patterns) {
      regexFixture.corpus.forEach((text, index) => {
        const want = expectedMatch(regexFixture, pattern.id, index)
        const onTab = shapeOf(new RegexInput(text, text.length, '').match(pattern.regex, pattern.shape, pattern.groupNames))
        if (onTab !== want) differ.push(`snippet ${pattern.id}, Tab after ${JSON.stringify(text)}: ${onTab} ≠ ${want}`)
        if (text.length === 0) return
        const typed = shapeOf(new RegexInput(text.slice(0, -1), text.length - 1, text.slice(-1)).match(pattern.regex, pattern.shape, pattern.groupNames))
        if (typed !== want) differ.push(`snippet ${pattern.id}, typing the last key of ${JSON.stringify(text)}: ${typed} ≠ ${want}`)
      })
    }
    assert.equal(differ.length, 0, differ.slice(0, 8).join('\n'))
  })

  await test('a long note in front changes nothing the window sees', () => {
    const differ: string[] = []
    for (const joint of ['', '\n\n', 'x', '\n  ', ' ']) {
      const prefix = 'Some prose with $x^2$ and \\alpha in it. '.repeat(60) + joint
      for (const pattern of patterns) {
        for (const text of regexFixture.corpus) {
          const units = prefix + text
          const want = whole(pattern.source, units)
          const got = shapeOf(new RegexInput(units, units.length, '').match(pattern.regex, pattern.shape, pattern.groupNames))
          if (got !== want) differ.push(`snippet ${pattern.id} after ${JSON.stringify(joint)}: ${JSON.stringify(text)}`)
        }
      }
    }
    assert.equal(differ.length, 0, differ.slice(0, 8).join('\n'))
  })

  await test('pattern shapes: lengths and last characters', () => {
    const greek = new PatternShape('(?:([^\\\\])((?:alpha|beta|pi)))(?![\\s\\S])')
    assert.equal(greek.maxLength, 6)
    assert.equal(greek.last?.contains(97), true)
    assert.equal(greek.last?.contains(105), true)
    assert.equal(greek.last?.contains(120), false)
    const letters = new PatternShape('(?:\\\\[A-Za-z]{2,})(?![\\s\\S])')
    assert.equal(letters.maxLength, null)
    assert.equal(letters.last?.contains(113), true)
    assert.equal(letters.last?.contains(50), false)
    const optional = new PatternShape('(?:(n?)e)(?![\\s\\S])')
    assert.equal(optional.maxLength, 2)
    assert.equal(optional.last?.contains(101), true)
    assert.equal(optional.last?.contains(110), false)
    const unknown = new PatternShape('(?:a\\pLx)')
    assert.equal(unknown.maxLength, null)
    assert.ok(unknown.last?.contains(0) && unknown.last.contains(0x3131))
    assert.equal(new PatternShape('(?:a*)(?![\\s\\S])').last, null)
  })

  suite('Latex Suite: whatever it is given')

  const inputs: LatexInput[] = [
    { text: 'a' }, { text: '/' }, { text: '$' }, { text: '\\' }, { text: '{' }, { text: '(' }, { text: ')' }, { text: '}' },
    { text: 'm' }, { text: '@' }, { text: '_' }, { text: '2' }, { text: ' ' }, { text: '"' }, { text: 'S' },
    'tab', 'shiftTab', 'enter', 'shiftEnter', 'backspace',
  ]

  /** An edit an editor can apply: in order, in range, the steps ending where the changes do, no half a pair lost. */
  const check = (edit: LatexEdit, text: string, label: string, problems: string[]) => {
    let last = 0
    for (const change of edit.changes) {
      if (!(change.from >= last && change.to <= text.length && change.from <= change.to)) problems.push(`${label}: change ${JSON.stringify(change)} out of order or range`)
      last = change.to
    }
    const after = Editor.apply(edit.changes, text)
    let stepped = text
    for (const step of edit.undoSteps) stepped = Editor.apply(step, stepped)
    if (stepped !== after) problems.push(`${label}: the undo steps end somewhere else`)
    for (const r of edit.selection) if (r.to > after.length) problems.push(`${label}: selection ${JSON.stringify(r)} past ${after.length}`)
    for (const g of edit.tabstops.groups) for (const r of g.ranges) if (r.to > after.length) problems.push(`${label}: tabstop past the end`)
    if (!LONE_SURROGATE.test(text) && LONE_SURROGATE.test(after)) problems.push(`${label}: half a surrogate pair was left behind`)
  }

  await test('every key at every caret of the context notes gives an edit an editor can apply', () => {
    const docs = context.docs.filter((d) => d.set === 'written' || d.doc.length <= 24).map((d) => d.doc)
      .concat(['😀 $x😀al$ 😀', '$$\n😀\\frac{a}{b}😀\n$$', '- 😀 item $x$', '> $$\n> \\begin{pmatrix}\n> a & b\n> \\end{pmatrix}\n> $$'])
    let edits = 0
    const problems: string[] = []
    for (const text of docs) {
      for (let pos = 0; pos <= text.length; pos += 1) {
        // Not between the halves of a surrogate pair, where no text view puts a caret.
        if (pos > 0 && pos < text.length && (text.charCodeAt(pos) & 0xfc00) === 0xdc00) continue
        for (const input of inputs) {
          const edit = engine.handle(input, text, caret(pos))
          if (!edit) continue
          edits += 1
          check(edit, text, `${JSON.stringify(text)} at ${pos}, ${JSON.stringify(input)}`, problems)
        }
      }
    }
    assert.ok(edits > 1_000, `only ${edits} edits`)
    assert.equal(problems.length, 0, problems.slice(0, 8).join('\n'))
    process.stdout.write(`    (${edits} edits from ${docs.length} notes)\n`)
  })

  await test('nonsense from the editor is clamped, not trapped on', () => {
    const text = '$x@$ and $\\frac{a}{b}$'
    const stale = new Tabstops([{ ranges: [{ from: 500, to: 503 }], color: 0 }, { ranges: [{ from: 900, to: 900 }], color: 0 }], 0)
    const selections: TextRange[][] = [
      [{ from: Number.NaN, to: Number.NaN }], [{ from: 3, to: -1 }], [{ from: 3, to: Number.MAX_SAFE_INTEGER }],
      [{ from: 3, to: 3 }, { from: 2, to: 7 }], [{ from: -5, to: 2 }],
    ]
    const problems: string[] = []
    for (const selection of selections) {
      for (const input of inputs) {
        for (const tabstops of [Tabstops.none, stale]) {
          const edit = engine.handle(input, text, selection, tabstops)
          if (edit) check(edit, text, `${JSON.stringify(selection)} ${JSON.stringify(input)}`, problems)
        }
      }
    }
    stale.mapped([{ from: Number.NaN, to: 2, text: 'x' }])
    stale.selecting([{ from: -5, to: -10 }])
    assert.equal(problems.length, 0, problems.slice(0, 8).join('\n'))
  })

  suite('Latex Suite: timing')

  for (const paragraph of [600, 5_000, 20_000, 0]) {
    await test(`a keystroke in a 20,000-character note stays cheap (paragraphs of ${paragraph})`, () => {
      const { text, caret: at } = timingNote(paragraph)
      assert.ok(text.length > 20_000)
      assert.equal(engine.handle({ text: 'x' }, text, caret(at)), null)
      assert.notEqual(engine.handle({ text: '/' }, text, caret(at)), null)
      const withAt = `${text.slice(0, at)}@${text.slice(at)}`
      const runs: [string, LatexInput, string, TextRange[]][] = [
        ['letter', { text: 'x' }, text, caret(at)],
        ['autofraction', { text: '/' }, text, caret(at)],
        ['snippet @a', { text: 'a' }, withAt, caret(at + 1)],
        ['Tab', 'tab', text, caret(at)],
        ['Enter', 'enter', text, caret(at)],
        ['letter in prose', { text: 'x' }, text, caret(200)],
      ]
      const report: string[] = []
      for (const [name, input, doc, selection] of runs) {
        const { median, p95 } = time(200, () => engine.handle(input, doc, selection))
        report.push(`${name} ${median.toFixed(3)}/${p95.toFixed(3)}`)
        // A net for gross mistakes — reading the whole note once per snippet —
        // rather than a benchmark: this machine may be busy with a build.
        assert.ok(median < 3, `${name}: median ${median} ms`)
      }
      process.stdout.write(`    median/p95 ms: ${report.join(', ')}\n`)
    })
  }
}
