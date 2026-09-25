/**
 * Writes `src/test/fixtures/macSemantic.json` and `macSemantic.bin` from the
 * Mac's own semantic code.
 *
 * The passages and their keys, and the vector cache's bytes, are what the two
 * builds share; both are asked of the real Swift (`tools/mac-semantic.swift`)
 * and written down for `npm test` to hold the port to — the fold table is
 * made the same way (`generate-fold-table.mjs`). Needs macOS and swiftc;
 * re-run whenever `SemanticChunker.swift` or `SemanticVectorStore.swift`
 * changes:
 *
 *     node tools/generate-semantic-fixtures.mjs
 */
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const portable = path.join(import.meta.dirname, '..')
const repo = path.join(portable, '..')
const semantic = path.join(repo, 'Packages/PaperTimeKit/Sources/Semantic')
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'mac-semantic-'))
const binary = path.join(scratch, 'mac-semantic')

execFileSync('swiftc', [
  '-O',
  path.join(semantic, 'SemanticChunker.swift'),
  path.join(semantic, 'SemanticVectorStore.swift'),
  path.join(portable, 'tools/mac-semantic.swift'),
  '-o', binary,
], { stdio: 'inherit' })

const reference = JSON.parse(fs.readFileSync(
  path.join(repo, 'Packages/PaperTimeKit/Tests/SemanticTests/Fixtures/minilm-reference.json'), 'utf8'))
const paper = '3F2504E0-4F89-11D3-9A0C-0305E82C3301'
const words = (count, from = 0) => Array.from({ length: count }, (_, i) => `w${from + i}`).join(' ')

/** The pages the chunker is asked about: the reference's passages as one long page, and the Swift tests' own cases. */
const pages = [
  { text: reference.passages.map((p) => p.text).join('\n\n'), paperID: paper, pageIndex: 0 },
  { text: reference.passages.map((p) => p.text).join(' '), paperID: paper, pageIndex: 1, windowWords: 20, overlapWords: 5 },
  ...reference.passages.map((p, i) => ({ text: p.text, paperID: paper, pageIndex: 2 + i, windowWords: 30, overlapWords: 10 })),
  { text: '  \nElastic weight\tconsolidation   slows learning.\n', paperID: paper, pageIndex: 4 },
  { text: words(250), paperID: paper, pageIndex: 0 },
  { text: words(180), paperID: paper, pageIndex: 0 },
  { text: words(101), paperID: paper, pageIndex: 0 },
  { text: '😀 강화학습의 기초 ' + words(120), paperID: paper, pageIndex: 0 },
  { text: 'machine\nunlearning  removes data', paperID: paper, pageIndex: 0 },
  { text: 'a b c　d﻿e', paperID: paper, pageIndex: 0 },   // NBSP, em space, ideographic space are breaks; a BOM is not
]

const chunks = JSON.parse(execFileSync(binary, ['chunks'], { input: JSON.stringify(pages), maxBuffer: 1 << 26 }))
const storeFile = path.join(portable, 'src/test/fixtures/macSemantic.bin')
const store = JSON.parse(execFileSync(binary, ['store', storeFile]))

fs.writeFileSync(
  path.join(portable, 'src/test/fixtures/macSemantic.json'),
  JSON.stringify({ chunks, store }, null, 1) + '\n',
)
console.log(`wrote ${chunks.length} pages of chunks and a ${store.bytes}-byte store`)
