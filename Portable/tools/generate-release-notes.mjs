/**
 * Generates `src/shared/releaseNotes.json` from the Mac's release notes, the
 * source of truth for what each version brought — the Log, About's
 * showcase and What's New read it. Not transcribed: read out of the Swift
 * (`tools/release-notes-parser.mjs`). Re-run whenever ReleaseNotes.swift or
 * Contributors.swift changes:
 *
 *     node tools/generate-release-notes.mjs
 */
import fs from 'node:fs'
import path from 'node:path'
import { readReleaseNotes } from './release-notes-parser.mjs'

const root = path.join(import.meta.dirname, '..', '..')
const notes = readReleaseNotes(
  fs.readFileSync(path.join(root, 'App/Model/ReleaseNotes.swift'), 'utf8'),
  fs.readFileSync(path.join(root, 'App/Model/Contributors.swift'), 'utf8'),
)
const out = path.join(import.meta.dirname, '..', 'src/shared/releaseNotes.json')
fs.writeFileSync(out, `${JSON.stringify(notes, null, 1)}\n`)
console.log(`${out}: ${notes.releases.length} releases, ${notes.highlights.length} highlights, ${notes.groups.length} groups, ${notes.contributors.length} contributors`)
