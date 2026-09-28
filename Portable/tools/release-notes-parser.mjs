/**
 * Reads the Mac's release notes — `App/Model/ReleaseNotes.swift` and
 * `App/Model/Contributors.swift` — as data, for Portable's Log, About and
 * What's New (`tools/generate-release-notes.mjs` writes the result; the
 * test `src/test/releaseNotes.ts` reads the Swift again and compares).
 *
 * Not a Swift parser: a reader for the one shape those files are written in
 * — calls with labelled arguments, arrays, string literals and `.enum`
 * values — which is enough, and which fails loudly on anything else.
 */

function tokens(source) {
  const out = []
  let i = 0
  const n = source.length
  while (i < n) {
    const c = source[i]
    if (/\s/.test(c)) { i += 1; continue }
    if (source.startsWith('//', i)) { i = source.indexOf('\n', i); if (i < 0) i = n; continue }
    if (source.startsWith('/*', i)) { i = source.indexOf('*/', i) + 2; continue }
    if (c === '"') {
      let j = i + 1
      let text = ''
      while (j < n && source[j] !== '"') {
        if (source[j] === '\\') {
          const next = source[j + 1]
          if (next === 'u' && source[j + 2] === '{') {
            const end = source.indexOf('}', j)
            text += String.fromCodePoint(parseInt(source.slice(j + 3, end), 16))
            j = end + 1
            continue
          }
          if (next === '(') throw new Error(`interpolation at ${j}: not a literal`)
          text += { n: '\n', t: '\t', '"': '"', '\\': '\\', "'": "'" }[next] ?? next
          j += 2
          continue
        }
        text += source[j]
        j += 1
      }
      out.push({ kind: 'string', value: text })
      i = j + 1
      continue
    }
    if (/[0-9]/.test(c)) {
      let j = i
      while (j < n && /[0-9.]/.test(source[j])) j += 1
      out.push({ kind: 'number', value: Number(source.slice(i, j)) })
      i = j
      continue
    }
    if (/[A-Za-z_]/.test(c)) {
      let j = i
      while (j < n && /[A-Za-z0-9_]/.test(source[j])) j += 1
      out.push({ kind: 'name', value: source.slice(i, j) })
      i = j
      continue
    }
    out.push({ kind: 'punct', value: c })
    i += 1
  }
  return out
}

function parser(list) {
  let at = 0
  const peek = () => list[at]
  const take = (value) => {
    const token = list[at]
    if (!token || (value !== undefined && token.value !== value)) throw new Error(`expected ${value} at token ${at}, found ${JSON.stringify(token)}`)
    at += 1
    return token
  }
  function expression() {
    const token = peek()
    if (token.kind === 'string') { at += 1; return token.value }
    if (token.kind === 'number') { at += 1; return token.value }
    if (token.value === '.') { at += 1; return { enum: take().value } }
    if (token.value === '[') {
      at += 1
      const items = []
      while (peek().value !== ']') {
        items.push(expression())
        if (peek().value === ',') at += 1
      }
      take(']')
      return items
    }
    if (token.kind === 'name') {
      at += 1
      if (token.value === 'true' || token.value === 'false') return token.value === 'true'
      if (peek()?.value !== '(') return { name: token.value }
      take('(')
      const args = []
      while (peek().value !== ')') {
        let label = null
        if (list[at].kind === 'name' && list[at + 1]?.value === ':') {
          label = list[at].value
          at += 2
        }
        args.push({ label, value: expression() })
        if (peek().value === ',') at += 1
      }
      take(')')
      return { call: token.value, args }
    }
    throw new Error(`unexpected ${JSON.stringify(token)} at token ${at}`)
  }
  return { expression }
}

/** The expression after `static let <name>: … =`. */
function staticLet(source, name) {
  const marker = new RegExp(`static let ${name}\\s*:[^=]*=`)
  const match = marker.exec(source)
  if (!match) throw new Error(`no static let ${name}`)
  return parser(tokens(source.slice(match.index + match[0].length))).expression()
}

const text2 = (value) => {
  if (!value || value.call !== 'Text2') throw new Error(`not a Text2: ${JSON.stringify(value).slice(0, 80)}`)
  return { ko: value.args[0].value, en: value.args[1].value }
}
const arg = (call, label) => call.args.find((one) => one.label === label)?.value
const positional = (call, index) => call.args.filter((one) => one.label === null)[index]?.value

function entry(call) {
  const out = { title: text2(positional(call, 0)), detail: text2(positional(call, 1)) }
  const action = arg(call, 'action')
  if (action) out.action = action.enum
  const demo = arg(call, 'demo')
  if (demo) out.demo = demo.enum
  if (arg(call, 'featured') === true) out.featured = true
  const devices = arg(call, 'devices')
  out.devices = devices ? devices.map((one) => one.enum) : ['mac']
  return out
}

export function readReleaseNotes(releaseSwift, contributorsSwift) {
  const releases = staticLet(releaseSwift, 'releases').map((call) => ({
    version: arg(call, 'version'),
    date: text2(arg(call, 'date')),
    note: text2(arg(call, 'note')),
    added: (arg(call, 'added') ?? []).map(entry),
    removed: (arg(call, 'removed') ?? []).map(entry),
    fixed: (arg(call, 'fixed') ?? []).map(entry),
  }))
  const highlights = staticLet(releaseSwift, 'highlights').map((call) => {
    const out = { symbol: arg(call, 'symbol'), title: text2(arg(call, 'title')), detail: text2(arg(call, 'detail')), tier: arg(call, 'tier')?.enum ?? 'two' }
    const action = arg(call, 'action')
    if (action) out.action = action.enum
    const demo = arg(call, 'demo')
    if (demo) out.demo = demo.enum
    return out
  })
  const groups = staticLet(releaseSwift, 'groups').map((call) => ({
    title: text2(positional(call, 0)),
    symbol: arg(call, 'symbol'),
    features: arg(call, 'features').map((feature) => {
      const out = { title: text2(positional(feature, 0)), detail: text2(positional(feature, 1)) }
      const action = arg(feature, 'action')
      if (action) out.action = action.enum
      return out
    }),
  }))
  const contributors = staticLet(contributorsSwift, 'all').map((call) => ({ name: arg(call, 'name'), reports: arg(call, 'reports') }))
  const unnamedReports = staticLet(contributorsSwift, 'unnamedReports')
  if (!Number.isInteger(unnamedReports)) throw new Error(`unnamedReports is not a count: ${JSON.stringify(unnamedReports)}`)
  return { releases, highlights, groups, contributors, unnamedReports }
}
