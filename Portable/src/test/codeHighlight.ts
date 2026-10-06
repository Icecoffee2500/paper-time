/**
 * The colours of fenced code — the module the Mac runs too (`CodeHighlight.js`).
 */
import assert from 'node:assert/strict'
import { codeLanguageId, highlightCode } from '../shared/codeHighlight.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

function painted(code: string, language: string): string[] {
  return highlightCode(code, language).map((run) => `${run.role}:${code.slice(run.from, run.to)}`)
}

export async function codeHighlightSuite(test: Test, suite: (name: string) => void) {
  suite('Fenced code, coloured by role')

  await test('Python: keywords, names, strings, numbers and comments', () => {
    const runs = painted('def area(r):\n    return 3.14 * r ** 2  # π r²\nprint(f"{area(2)}")', 'python')
    for (const expected of ['keyword:def', 'function:area', 'keyword:return', 'number:3.14', 'number:2', 'comment:# π r²', 'builtIn:print']) {
      assert.ok(runs.includes(expected), `${expected} in ${JSON.stringify(runs)}`)
    }
    // The f-string's {…} is code, not string.
    assert.ok(!runs.some((run) => run.startsWith('string:') && run.includes('area')), JSON.stringify(runs))
  })

  await test('escaped characters keep the offsets: <, >, & and quotes', () => {
    const code = 'if (a < b && c > "d") { x = \'e\'; }'
    for (const run of highlightCode(code, 'js')) assert.ok(run.to <= code.length && run.from < run.to)
    assert.ok(painted(code, 'javascript').includes('string:"d"'))
    assert.ok(painted(code, 'javascript').includes("string:'e'"))
  })

  await test('names people write find their language; unknown ones are not coloured', () => {
    assert.equal(codeLanguageId('py'), 'python')
    assert.equal(codeLanguageId('Python3'), 'python')
    assert.equal(codeLanguageId('c++'), 'cpp')
    assert.equal(codeLanguageId('sh'), 'bash')
    assert.equal(codeLanguageId('tex'), 'latex')
    assert.equal(codeLanguageId('text'), null)
    assert.equal(codeLanguageId(''), null)
    assert.deepEqual(highlightCode('x = 1', 'unknownlang'), [])
  })
}
