/**
 * The metadata pipeline, against the Mac. Everything here was answered first
 * by the Mac's own code (`Scripts/metadata-fixtures.sh`, which runs
 * `papertime-metadata-fixtures` in the Swift package):
 *
 * - `metadata-pure.json.gz`: eight thousand-odd calls — identifiers, folded
 *   titles, the signals' cleaning, the header guesses and the kind guess for
 *   every corpus paper, the verifier, LaTeX unescaping — and what came back;
 * - `metadata-resolve.json.gz`: what `MetadataResolver` concluded for 25
 *   papers with the registrars' recorded answers (`metadata-responses`), and
 *   again with no network, with every answer a 429, with doi.org saying 404
 *   and with Crossref sending something unreadable — and which requests it
 *   made, in order.
 *
 * The port is given the same inputs and has to say the same thing.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import zlib from 'node:zlib'
import { parseName } from '../shared/model.js'
import { namesACourse } from '../shared/documentKind.js'
import { arxivCSL, parseArxivFeed } from '../shared/metadata/arxiv.js'
import { crossrefList, crossrefSingle, decodeCSL, openAlexList, parseJSON } from '../shared/metadata/csl.js'
import {
  authorsFollowingTitle, endsMidPhrase, firstMeaningfulLine, headerCandidates, looksLikeBoilerplate, splitAuthorLine,
  type ExtractedHeader,
} from '../shared/metadata/header.js'
import {
  arxivBaseID, arxivIDFromFileName, arxivIDs, dois, normalizeArxiv, normalizeDOI, pubmedID, scanIdentifiers,
} from '../shared/metadata/identifiers.js'
import { unescapeLaTeX } from '../shared/metadata/latexUnescape.js'
import { resolve, type ResolutionResult } from '../shared/metadata/resolver.js'
import { clean, sanitized } from '../shared/metadata/sanitizer.js'
import {
  cleanEmbeddedTitle, guessFromSignals, isLikelyAuthorOrAffiliationLine, isStamp, keywordList, largestFontText,
  looksLikeAbstract, referencePageIndices, splitAuthorField, type DocumentSignals,
} from '../shared/metadata/signals.js'
import { collapsingWhitespace, firstYear, foldedTitle, jaroWinkler, repairingHyphenation, titleSimilarity } from '../shared/metadata/text.js'
import { assess, score } from '../shared/metadata/verifier.js'
import { NetworkService, type Clock, type Reply } from '../main/metadata/network.js'
import { NetworkFailure } from '../shared/metadata/resolver.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const fixtures = path.resolve(process.cwd(), '..', 'Tests/MetadataPipelineTests/Fixtures')
const load = <T>(name: string): T => JSON.parse(zlib.gunzipSync(fs.readFileSync(path.join(fixtures, name))).toString('utf8')) as T

/** `nil` travels as JSON null; the port says `undefined`. */
const orNull = <T>(value: T | undefined): T | null => (value === undefined ? null : value)

function headerJSON(header: ExtractedHeader): Record<string, unknown> {
  const out: Record<string, unknown> = { title: header.title, authors: header.authors, strength: header.strength, source: header.source }
  if (header.venueHint !== undefined) out.venueHint = header.venueHint
  if (header.year !== undefined) out.year = header.year
  return out
}

function headerFrom(raw: Record<string, unknown> | null): ExtractedHeader | undefined {
  if (!raw) return undefined
  return {
    title: raw.title as string, authors: (raw.authors as ExtractedHeader['authors']) ?? [],
    venueHint: raw.venueHint as string | undefined, year: raw.year as number | undefined,
    strength: raw.strength as number, source: raw.source as ExtractedHeader['source'],
  }
}

const throws = (work: () => unknown): unknown => {
  try {
    return work()
  } catch {
    return 'throws'
  }
}

/** The same calls the Swift tool answers (`call` in its main.swift). */
function call(fn: string, args: unknown[]): unknown {
  const s = (index: number) => (typeof args[index] === 'string' ? args[index] as string : '')
  switch (fn) {
    case 'normalizeDOI': return orNull(normalizeDOI(s(0)))
    case 'normalizeArxiv': return orNull(normalizeArxiv(s(0)))
    case 'arxivBaseID': return orNull(arxivBaseID(normalizeArxiv(s(0))))
    case 'scan': return scanIdentifiers(s(0))
    case 'dois': return dois(s(0))
    case 'arxivIDs': return arxivIDs(s(0))
    case 'pubmedID': return orNull(pubmedID(s(0)))
    case 'arxivIDFromFileName': return orNull(arxivIDFromFileName(s(0)))
    case 'foldedTitle': return foldedTitle(s(0))
    case 'collapsingWhitespace': return collapsingWhitespace(s(0))
    case 'repairingHyphenation': return repairingHyphenation(s(0))
    case 'titleSimilarity': return titleSimilarity(s(0), s(1))
    case 'jaroWinkler': return jaroWinkler(s(0), s(1))
    case 'firstYear': return orNull(firstYear(s(0)))
    case 'parseName': return parseName(s(0))
    case 'cleanEmbeddedTitle': return orNull(cleanEmbeddedTitle(s(0)))
    case 'splitAuthorField': return splitAuthorField(s(0))
    case 'keywordList': return keywordList(s(0))
    case 'isStamp': return isStamp(s(0))
    case 'isLikelyAuthorOrAffiliationLine': return isLikelyAuthorOrAffiliationLine(s(0))
    case 'looksLikeAbstract': return looksLikeAbstract(s(0))
    case 'looksLikeBoilerplate': return looksLikeBoilerplate(s(0))
    case 'endsMidPhrase': return endsMidPhrase(s(0))
    case 'firstMeaningfulLine': return orNull(firstMeaningfulLine(args[0] as string[]))
    case 'authorsFollowingTitle': return authorsFollowingTitle(s(0), args[1] as string[])
    case 'splitAuthorLine': return splitAuthorLine(s(0))
    case 'namesACourse': return namesACourse(s(0))
    case 'referencePageIndices': return referencePageIndices(args[0] as number)
    case 'largestFontText': {
      const page = args[0] as { runs: number[][]; sizes: number[]; text: string }
      const runs = page.runs.map(([location, length], index) => ({ location, length, size: page.sizes[index] }))
      return orNull(largestFontText(runs, page.text))
    }
    case 'candidates': return headerCandidates(args[0] as DocumentSignals).map(headerJSON)
    case 'guess': return guessFromSignals(args[0] as DocumentSignals)
    case 'assess': {
      const assessment = assess(decodeCSL(args[0]), headerFrom(args[1] as Record<string, unknown> | null), args[2] as boolean)
      return { ...assessment, score: score(assessment) }
    }
    case 'unescape': return unescapeLaTeX(s(0))
    case 'clean': return clean(s(0))
    case 'sanitized': return sanitized(decodeCSL(args[0]))
    case 'decodeCSL': return throws(() => decodeCSL(parseJSON(s(0))))
    case 'crossrefList': return throws(() => crossrefList(s(0)))
    case 'crossrefWork': return throws(() => crossrefSingle(s(0)))
    case 'openAlexList': return throws(() => openAlexList(s(0)))
    case 'arxivFeed': return throws(() => parseArxivFeed(s(0)).map((entry) => {
      const out: Record<string, unknown> = {
        id: entry.id, arxivID: entry.arxivID, title: entry.title, summary: entry.summary, authors: entry.authors,
        categories: entry.categories, csl: arxivCSL(entry),
      }
      for (const key of ['doi', 'journalRef', 'primaryCategory', 'comment', 'pdfURL'] as const) {
        if (entry[key] !== undefined) out[key] = entry[key]
      }
      return out
    }))
    default: throw new Error(`no port of ${fn}`)
  }
}

/** Optional fields the Mac leaves out, and `undefined` the port leaves in,
 *  are the same absence. */
function plain(value: unknown): unknown {
  return JSON.parse(JSON.stringify(value ?? null))
}

// MARK: - Replayed network

interface Recorded { status: number; body: string; retryAfter?: string }

const SCENARIOS: Record<string, (responses: Record<string, Recorded>) => Record<string, Recorded>> = {
  recorded: (responses) => responses,
  offline: () => ({}),
  rateLimited: (responses) => Object.fromEntries(Object.keys(responses).map((key) => [key, { status: 429, body: '', retryAfter: '0' }])),
  doiNotFound: (responses) => Object.fromEntries(Object.entries(responses).map(([key, value]) =>
    [key, key.startsWith('https://doi.org/') ? { ...value, status: 404, body: '' } : value])),
  crossrefMalformed: (responses) => Object.fromEntries(Object.entries(responses).map(([key, value]) =>
    [key, key.includes('crossref') ? { ...value, body: '{not json' } : value])),
}

const stillClock: Clock = { now: () => 0, sleep: async () => {} }

function resultJSON(result: ResolutionResult): Record<string, unknown> {
  const provenance = (one: { source: string; detail?: string }) => (one.detail === undefined ? { source: one.source } : { source: one.source, detail: one.detail })
  const out: Record<string, unknown> = {
    csl: result.csl, identifiers: result.identifiers, confidence: result.confidence, provenance: provenance(result.provenance),
    candidates: result.candidates.map((one) => ({
      csl: one.csl, identifiers: one.identifiers, provenance: provenance(one.provenance), score: one.score, matchExplanation: one.matchExplanation,
    })),
    transient: result.transientFailure !== undefined,
  }
  if (result.assessment) out.assessment = { ...result.assessment, score: score(result.assessment) }
  return out
}

export async function metadataSuite(test: Test, suite: (name: string) => void) {
  suite('The metadata pipeline answers as the Mac does')
  const pure = load<{ fn: string; args: unknown[]; result: unknown }[]>('metadata-pure.json.gz')
  const byFn = new Map<string, typeof pure>()
  for (const one of pure) byFn.set(one.fn, [...(byFn.get(one.fn) ?? []), one])
  for (const [fn, cases] of byFn) {
    await test(`${fn}: ${cases.length} call${cases.length === 1 ? '' : 's'}, the Mac's answer each time`, () => {
      const wrong: string[] = []
      for (const one of cases) {
        const mine = plain(call(fn, one.args))
        try {
          assert.deepStrictEqual(mine, plain(one.result))
        } catch {
          const shown = one.args.map((arg) => JSON.stringify(arg).slice(0, 80)).join(', ')
          wrong.push(`${shown}\n    mac:  ${JSON.stringify(one.result).slice(0, 300)}\n    here: ${JSON.stringify(mine).slice(0, 300)}`)
        }
      }
      assert.equal(wrong.length, 0, `${wrong.length} of ${cases.length} differ:\n  ${wrong.slice(0, 4).join('\n  ')}`)
    })
  }

  const recorded = load<Record<string, Recorded>>('metadata-responses.json.gz')
  const scenarios = load<Record<string, { inputs: { file: string; email?: string; signals: DocumentSignals }[]; results: (Record<string, unknown> & { asked: string[]; file: string })[] }>>('metadata-resolve.json.gz')
  for (const [name, scenario] of Object.entries(scenarios)) {
    const responses = SCENARIOS[name](recorded)
    for (const [index, input] of scenario.inputs.entries()) {
      const theirs = scenario.results[index]
      await test(`${name}: ${input.file} — ${theirs.confidence as string}, from the same requests`, async () => {
        const asked: string[] = []
        const network = new NetworkService(async (url): Promise<Reply> => {
          asked.push(url)
          const reply = responses[url]
          if (!reply || reply.status === 0) throw new NetworkFailure('offline')
          return reply
        }, input.email, stillClock)
        const result = await resolve(network, input.signals, input.file, { contactEmail: input.email })
        assert.deepStrictEqual(asked, theirs.asked)
        const { asked: _asked, file: _file, ...expected } = theirs
        assert.deepStrictEqual(plain(resultJSON(result)), plain(expected))
      })
    }
  }

  const corpus = process.env.PAPERTIME_CORPUS
  if (!corpus) return
  await test('pdf.js reads the corpus to the same conclusions PDFKit does', async () => {
    const differences = await signalsAgreement(corpus)
    if (process.env.PAPERTIME_SIGNALS_REPORT) fs.writeFileSync(process.env.PAPERTIME_SIGNALS_REPORT, JSON.stringify(differences, null, 1))
    const by = new Map<string, number>()
    for (const one of differences) by.set(one.field, (by.get(one.field) ?? 0) + 1)
    console.log('    signals that differ:', JSON.stringify(Object.fromEntries(by)))
    // What decides a record must agree everywhere: the kind, the identifiers,
    // the structure, the page count and the producer's title. The title the
    // typography suggests may differ in a paper or two (PDFKit often reports
    // no fonts at all — `largestFontText` is then the Mac's nil — and spaces
    // in small capitals fall differently).
    const decisive = differences.filter((one) => !['largestFontText', 'title'].includes(one.field))
    assert.deepEqual(decisive, [])
    assert.ok((by.get('title') ?? 0) <= 2, JSON.stringify(differences.filter((one) => one.field === 'title')))
  })
}

// MARK: - Signals from pdf.js, against the Mac's from PDFKit

/** What pdf.js reads off each corpus PDF against what PDFKit read — only
 *  where the corpus is on this machine. The two readers do not produce the
 *  same text, so this does not ask for the same bytes: it asks for the same
 *  conclusions, paper by paper, and says which ones differ. */
export async function signalsAgreement(corpus: string): Promise<{ file: string; field: string; mac: unknown; here: unknown }[]> {
  const { extractSignals } = await import('../main/textExtract.js')
  const pdfjsRoot = path.dirname(path.dirname(require.resolve('pdfjs-dist/package.json')))
  const assets = {
    cmap: async (name: string) => new Uint8Array(fs.readFileSync(path.join(pdfjsRoot, 'pdfjs-dist/cmaps', `${name}.bcmap`))),
    font: async (name: string) => new Uint8Array(fs.readFileSync(path.join(pdfjsRoot, 'pdfjs-dist/standard_fonts', name))),
  }
  const mac = load<{ file: string; signals: DocumentSignals; guess: { kind: string }; headers: { title: string }[] }[]>('metadata-signals.json.gz')
  const differences: { file: string; field: string; mac: unknown; here: unknown }[] = []
  for (const row of mac) {
    const file = [path.join(corpus, row.file), path.join(corpus, '..', 'vla', row.file)].find((one) => fs.existsSync(one))
    if (!file) continue
    const here = await extractSignals(new Uint8Array(fs.readFileSync(file)), assets)
    const compare = (field: string, a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) differences.push({ file: row.file, field, mac: a, here: b }) }
    compare('pageCount', row.signals.pageCount, here.pageCount)
    compare('embeddedTitle', row.signals.embeddedTitle, here.embeddedTitle)
    compare('hasAbstract', row.signals.hasAbstract, here.hasAbstract)
    compare('hasReferences', row.signals.hasReferences, here.hasReferences)
    compare('isLandscape', row.signals.isLandscape, here.isLandscape)
    compare('guess', row.guess.kind, guessFromSignals(here).kind)
    compare('doi', scanIdentifiers(row.signals.openingText).doi, scanIdentifiers(here.openingText).doi)
    compare('arxiv', scanIdentifiers(row.signals.openingText).arxiv, scanIdentifiers(here.openingText).arxiv)
    const macTitle = row.headers[0]?.title
    const hereTitle = headerCandidates(here)[0]?.title
    if (!(macTitle === undefined && hereTitle === undefined) && titleSimilarity(macTitle ?? '', hereTitle ?? '') < 0.95) {
      differences.push({ file: row.file, field: 'title', mac: macTitle, here: hereTitle })
    }
    compare('largestFontText', row.signals.largestFontText, here.largestFontText)
  }
  return differences
}
