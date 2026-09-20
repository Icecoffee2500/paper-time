/**
 * Generates `src/shared/latexTable.ts` from the Swift side's own tables.
 *
 * Two implementations of the same escaping is two chances to be subtly wrong,
 * and "Almudévar" coming out as `{\'e}` on a Mac and as a bare é on Windows
 * would make one library export two different `.bib` files. So the table is
 * not transcribed — it is read out of `LaTeXEscaping.swift`, which stays the
 * source of truth. Re-run this whenever that file changes:
 *
 *     node tools/generate-latex-table.mjs
 */
import fs from 'node:fs'
import path from 'node:path'

const source = path.join(
  import.meta.dirname, '..', '..',
  'Packages/PaperTimeKit/Sources/Bibliography/LaTeXEscaping.swift',
)
const swift = fs.readFileSync(source, 'utf8')

/** Undoes Swift's string-literal escaping for one quoted literal's body. */
function unquote(body) {
  return body
    // Swift spells a code point as \u{1F600}; JavaScript does not.
    .replace(/\\u\{([0-9A-Fa-f]+)\}/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/\\(["\\nt])/g, (_, char) =>
      ({ '"': '"', '\\': '\\', n: '\n', t: '\t' })[char])
}

function tableNamed(name) {
  const start = swift.indexOf(`static let ${name}: [Character: String] = [`)
  if (start === -1) throw new Error(`No table called ${name} in ${source}`)
  const open = swift.indexOf('[', swift.indexOf('=', start))
  let depth = 0
  let end = open
  for (; end < swift.length; end += 1) {
    if (swift[end] === '[') depth += 1
    else if (swift[end] === ']') {
      depth -= 1
      if (depth === 0) break
    }
  }
  const body = swift.slice(open + 1, end)
  const pairs = []
  const entry = /"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"/g
  let match
  while ((match = entry.exec(body)) !== null) {
    pairs.push([unquote(match[1]), unquote(match[2])])
  }
  return pairs
}

const tables = ['specialCharacters', 'accentedLetters', 'punctuation']
const merged = new Map()
const counts = {}
for (const name of tables) {
  const pairs = tableNamed(name)
  counts[name] = pairs.length
  for (const [from, to] of pairs) merged.set(from, to)
}

// The Greek letters are built by a closure rather than written out as a
// literal — there is no accent-style command for them, so each one becomes
// inline maths — so they are read from the two name lists instead.
const greek = greekLetters()
counts.greekLetters = greek.length
for (const [from, to] of greek) merged.set(from, to)

function greekLetters() {
  const block = swift.slice(swift.indexOf('static let greekLetters'))
  const end = block.indexOf('}()')
  const body = block.slice(0, end)
  const pairs = []
  const entry = /\("\\u\{([0-9A-Fa-f]+)\}",\s*"([A-Za-z]+)"\)/g
  let match
  while ((match = entry.exec(body)) !== null) {
    pairs.push([String.fromCodePoint(parseInt(match[1], 16)), `$\\${match[2]}$`])
  }
  return pairs
}

const literal = [...merged.entries()]
  .map(([from, to]) => `  ${JSON.stringify(from)}: ${JSON.stringify(to)},`)
  .join('\n')

const out = `/**
 * The LaTeX spellings of characters a \`.bib\` file cannot hold plainly.
 *
 * GENERATED — do not edit. Run \`node tools/generate-latex-table.mjs\` to
 * rebuild it from \`Packages/PaperTimeKit/Sources/Bibliography/LaTeXEscaping.swift\`,
 * which is the source of truth for both builds. Transcribing it by hand would
 * mean a name like "Almudévar" could come out one way on a Mac and another on
 * Windows, from the same library.
 *
 * Built from: ${tables.map((name) => `${name} (${counts[name]})`).join(', ')}.
 */
export const LATEX_ESCAPES: Record<string, string> = {
${literal}
}

/**
 * A field value as BibTeX wants it.
 *
 * Walks the text once and only ever reads from the input, never from what it
 * has already written, so a backslash introduced by the table — the one in
 * \`\\\\textbackslash{}\` — can never be picked up and escaped a second time.
 */
export function escapeLaTeX(text: string): string {
  let result = ''
  for (const character of text) {
    result += LATEX_ESCAPES[character] ?? character
  }
  return result
}
`

const destination = path.join(import.meta.dirname, '..', 'src', 'shared', 'latexTable.ts')
fs.writeFileSync(destination, out, 'utf8')
console.log(`${merged.size} mappings → src/shared/latexTable.ts`)
for (const [name, count] of Object.entries(counts)) console.log(`  ${name}: ${count}`)
