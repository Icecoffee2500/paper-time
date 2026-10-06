/**
 * The colours of a note's fenced code — the same in both builds.
 *
 * highlight.js reads the code (BSD-3-Clause, the languages a researcher's
 * notes hold), and what it marks is reduced to a handful of roles, which each
 * build paints from the same palette — Xcode's, light and dark
 * (`CODE_PALETTE`, the Mac's `NoteCodeStyle.ink(for:)`). The Mac runs this
 * very file inside JavaScriptCore (`Scripts/code-highlight-bundle.sh` →
 * `App/Resources/CodeHighlight.js`), so a block is coloured the same on a Mac
 * and on a PC by construction, not by two highlighters agreeing.
 */
import hljs from 'highlight.js/lib/core'
import bash from 'highlight.js/lib/languages/bash'
import c from 'highlight.js/lib/languages/c'
import cpp from 'highlight.js/lib/languages/cpp'
import csharp from 'highlight.js/lib/languages/csharp'
import css from 'highlight.js/lib/languages/css'
import dart from 'highlight.js/lib/languages/dart'
import diff from 'highlight.js/lib/languages/diff'
import dockerfile from 'highlight.js/lib/languages/dockerfile'
import go from 'highlight.js/lib/languages/go'
import haskell from 'highlight.js/lib/languages/haskell'
import ini from 'highlight.js/lib/languages/ini'
import java from 'highlight.js/lib/languages/java'
import javascript from 'highlight.js/lib/languages/javascript'
import json from 'highlight.js/lib/languages/json'
import julia from 'highlight.js/lib/languages/julia'
import kotlin from 'highlight.js/lib/languages/kotlin'
import latex from 'highlight.js/lib/languages/latex'
import lua from 'highlight.js/lib/languages/lua'
import makefile from 'highlight.js/lib/languages/makefile'
import markdown from 'highlight.js/lib/languages/markdown'
import matlab from 'highlight.js/lib/languages/matlab'
import objectivec from 'highlight.js/lib/languages/objectivec'
import perl from 'highlight.js/lib/languages/perl'
import php from 'highlight.js/lib/languages/php'
import plaintext from 'highlight.js/lib/languages/plaintext'
import powershell from 'highlight.js/lib/languages/powershell'
import python from 'highlight.js/lib/languages/python'
import r from 'highlight.js/lib/languages/r'
import ruby from 'highlight.js/lib/languages/ruby'
import rust from 'highlight.js/lib/languages/rust'
import scala from 'highlight.js/lib/languages/scala'
import scss from 'highlight.js/lib/languages/scss'
import shell from 'highlight.js/lib/languages/shell'
import sql from 'highlight.js/lib/languages/sql'
import swift from 'highlight.js/lib/languages/swift'
import typescript from 'highlight.js/lib/languages/typescript'
import xml from 'highlight.js/lib/languages/xml'
import yaml from 'highlight.js/lib/languages/yaml'

const LANGUAGES = {
  bash, c, cpp, csharp, css, dart, diff, dockerfile, go, haskell, ini, java, javascript, json, julia, kotlin, latex,
  lua, makefile, markdown, matlab, objectivec, perl, php, plaintext, powershell, python, r, ruby, rust, scala, scss,
  shell, sql, swift, typescript, xml, yaml,
}
for (const [name, language] of Object.entries(LANGUAGES)) hljs.registerLanguage(name, language)
// Names people write that highlight.js does not know as aliases.
hljs.registerAliases(['python3', 'py3'], { languageName: 'python' })
hljs.registerAliases(['c++', 'h'], { languageName: 'cpp' })
hljs.registerAliases(['c#'], { languageName: 'csharp' })
hljs.registerAliases(['toml', 'cfg', 'conf'], { languageName: 'ini' })
hljs.registerAliases(['tex'], { languageName: 'latex' })
hljs.registerAliases(['golang'], { languageName: 'go' })
hljs.registerAliases(['docker'], { languageName: 'dockerfile' })
hljs.registerAliases(['mk'], { languageName: 'makefile' })
hljs.registerAliases(['text', 'txt', 'plain'], { languageName: 'plaintext' })
hljs.registerAliases(['jsonc', 'json5'], { languageName: 'json' })
hljs.registerAliases(['mts', 'cts'], { languageName: 'typescript' })
hljs.registerAliases(['mjs', 'cjs'], { languageName: 'javascript' })
hljs.registerAliases(['sass'], { languageName: 'scss' })
hljs.registerAliases(['psql', 'mysql', 'sqlite'], { languageName: 'sql' })

/** What a piece of code is, as far as its colour goes. */
export type CodeRole = 'keyword' | 'string' | 'number' | 'comment' | 'type' | 'function' | 'builtIn' | 'meta' | 'attribute'

export interface CodeRun {
  from: number
  to: number
  role: CodeRole
}

/**
 * Xcode's own colours for those roles, light and dark (Default (Light) and
 * Default (Dark)): a block of code here reads as code reads on a Mac.
 */
export const CODE_PALETTE: Record<CodeRole, { light: string; dark: string }> = {
  keyword: { light: '#9b2393', dark: '#fc5fa3' },
  string: { light: '#c41a16', dark: '#fc6a5d' },
  number: { light: '#1c00cf', dark: '#d0bf69' },
  comment: { light: '#5d6c79', dark: '#7f8c98' },
  type: { light: '#0b4f79', dark: '#5dd8ff' },
  function: { light: '#326d74', dark: '#67b7a4' },
  builtIn: { light: '#6c36a9', dark: '#a167e6' },
  meta: { light: '#643820', dark: '#fd8f3f' },
  attribute: { light: '#815f03', dark: '#bf8555' },
}

/** highlight.js's scopes, reduced to roles. `plain` stops a scope inside a coloured one taking its colour (`${x}` in a string). */
const ROLES: Record<string, CodeRole | 'plain'> = {
  keyword: 'keyword',
  literal: 'keyword',
  'selector-tag': 'keyword',
  name: 'keyword',
  section: 'keyword',
  built_in: 'builtIn',
  type: 'type',
  class: 'type',
  string: 'string',
  regexp: 'string',
  char: 'string',
  symbol: 'string',
  link: 'string',
  code: 'string',
  deletion: 'string',
  number: 'number',
  comment: 'comment',
  doctag: 'comment',
  quote: 'comment',
  meta: 'meta',
  bullet: 'meta',
  'template-tag': 'meta',
  'template-variable': 'meta',
  attr: 'attribute',
  attribute: 'attribute',
  property: 'attribute',
  'selector-id': 'attribute',
  'selector-class': 'attribute',
  'selector-attr': 'attribute',
  'selector-pseudo': 'attribute',
  addition: 'function',
  subst: 'plain',
  params: 'plain',
  operator: 'plain',
  punctuation: 'plain',
  tag: 'plain',
}

function roleOf(classes: string[]): CodeRole | 'plain' | null {
  const scope = classes.find((one) => one.startsWith('hljs-'))?.slice(5)
  if (!scope) return null
  if (scope === 'title') return classes.includes('class_') ? 'type' : 'function'
  if (scope === 'variable') return classes.includes('language_') ? 'keyword' : classes.includes('constant_') ? 'number' : null
  if (scope === 'meta' && classes.includes('string_')) return 'string'
  return ROLES[scope] ?? null
}

const ENTITIES: Record<string, string> = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#x27;': "'", '&#39;': "'" }

/** The language highlight.js knows by this name, or null. */
export function codeLanguageId(language: string): string | null {
  const known = hljs.getLanguage(language.toLowerCase())
  if (!known) return null
  const id = Object.keys(LANGUAGES).find((name) => hljs.getLanguage(name) === known)
  return id && id !== 'plaintext' ? id : null
}

const cache = new Map<string, CodeRun[]>()

/** The coloured runs of a block's code, in UTF-16 offsets into it; [] when the language is not one we colour. */
export function highlightCode(code: string, language: string): CodeRun[] {
  const id = codeLanguageId(language)
  if (!id || code.length === 0) return []
  const key = `${id}\u0000${code}`
  const kept = cache.get(key)
  if (kept) return kept
  let html: string
  try {
    html = hljs.highlight(code, { language: id, ignoreIllegals: true }).value
  } catch {
    return []
  }
  const runs: CodeRun[] = []
  const stack: (CodeRole | 'plain' | null)[] = []
  let offset = 0
  let index = 0
  const current = (): CodeRole | null => {
    for (let at = stack.length - 1; at >= 0; at -= 1) {
      const role = stack[at]
      if (role === 'plain') return null
      if (role) return role
    }
    return null
  }
  const put = (length: number) => {
    const role = current()
    if (!role || length === 0) return
    const last = runs[runs.length - 1]
    if (last && last.role === role && last.to === offset) last.to = offset + length
    else runs.push({ from: offset, to: offset + length, role })
  }
  while (index < html.length) {
    if (html.startsWith('<span class="', index)) {
      const end = html.indexOf('">', index)
      stack.push(roleOf(html.slice(index + 13, end).split(' ')))
      index = end + 2
      continue
    }
    if (html.startsWith('</span>', index)) {
      stack.pop()
      index += 7
      continue
    }
    if (html[index] === '&') {
      const end = html.indexOf(';', index)
      const entity = html.slice(index, end + 1)
      const character = ENTITIES[entity] ?? entity
      put(character.length)
      offset += character.length
      index = end + 1
      continue
    }
    let next = index
    while (next < html.length && html[next] !== '<' && html[next] !== '&') next += 1
    put(next - index)
    offset += next - index
    index = next
  }
  if (cache.size > 300) cache.clear()
  cache.set(key, runs)
  return runs
}
