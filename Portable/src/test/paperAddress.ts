/**
 * The address field reads what the Mac reads — `paper-addresses.json` is the
 * Mac's own `PaperAddress` (`Scripts/paper-address-fixture.swift`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import {
  addressFileName, addressIdentifiers, addressLookup, addressPDF, addressText, openAccessPDFs, publisherPDFs, readPaperAddress,
} from '../shared/paperAddress.js'
import { FetchError, fetchByAddress, type Fetch } from '../main/paperSource.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Fixture {
  addresses: { text: string; kind?: string; value?: string; address?: string; pdf?: string; lookup?: string; file?: string }[]
  openAlex: { json: string; pdfs: string[] }[]
  publishers: { doi: string; json: string; pdfs: string[] }[]
}

export async function paperAddressSuite(test: Test, suite: (name: string) => void) {
  suite('Paper addresses read as the Mac reads them')
  const file = path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures', 'paper-addresses.json')
  const fixture = JSON.parse(fs.readFileSync(file, 'utf8')) as Fixture

  await test(`${fixture.addresses.length} addresses: the same kind, value, PDF, lookup and file name`, () => {
    for (const expected of fixture.addresses) {
      const read = readPaperAddress(expected.text)
      const label = JSON.stringify(expected.text)
      if (!read) {
        assert.equal(expected.kind, undefined, label)
        continue
      }
      assert.equal(read.kind, expected.kind, label)
      const value = read.kind === 'arxiv' ? read.id : read.kind === 'doi' ? read.doi : read.url
      assert.equal(value, expected.value, label)
      assert.equal(addressText(read), expected.address, label)
      assert.equal(addressPDF(read) ?? undefined, expected.pdf, label)
      assert.equal(addressLookup(read) ?? undefined, expected.lookup, label)
      assert.equal(addressFileName(read), expected.file, label)
    }
  })

  await test('OpenAlex answers give the same PDF addresses, best first', () => {
    for (const answer of fixture.openAlex) assert.deepEqual(openAccessPDFs(answer.json), answer.pdfs)
  })

  await test(`${fixture.publishers.length} publishers' files are guessed as the Mac guesses them`, () => {
    for (const guess of fixture.publishers) assert.deepEqual(publisherPDFs(guess.doi, guess.json), guess.pdfs, guess.doi)
  })

  // A fetch that answers from a table: status and body by address, and a
  // log of what was asked, in order.
  const PDF = Buffer.from('%PDF-1.4\n%\xe2\xe3\xcf\xd3\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n', 'latin1')
  const table = (answers: Record<string, { status: number; body?: Buffer | string; throws?: string }>) => {
    const asked: string[] = []
    const fetch: Fetch = async (url) => {
      asked.push(url)
      const answer = answers[url] ?? { status: 404 }
      if (answer.throws) throw new Error(answer.throws)
      const body = typeof answer.body === 'string' ? Buffer.from(answer.body, 'utf8') : (answer.body ?? Buffer.alloc(0))
      return { status: answer.status, url, body, type: typeof answer.body === 'string' ? 'text/html' : 'application/pdf' }
    }
    return { fetch, asked }
  }
  const lookup = 'https://api.openalex.org/works/https://doi.org/10.1007/s10462-023-10562-9?select=id,open_access,best_oa_location,primary_location,locations'
  const springer = 'https://link.springer.com/content/pdf/10.1007/s10462-023-10562-9.pdf'
  const why = async (run: Promise<unknown>) => {
    try {
      await run
    } catch (error) {
      assert.ok(error instanceof FetchError)
      return { why: error.why, message: error.message }
    }
    assert.fail('fetched')
  }

  await test('a DOI with no open copy is fetched from the publisher when the network is let in', async () => {
    const { fetch, asked } = table({ [lookup]: { status: 200, body: '{"id":"W","locations":[]}' }, [springer]: { status: 200, body: PDF } })
    const got = await fetchByAddress('10.1007/s10462-023-10562-9', fetch)
    assert.equal(got.fetched.pdf, springer)
    assert.deepEqual(asked, [lookup, springer])
  })

  await test('open copies come before the publisher, and a page in place of a PDF moves on', async () => {
    const oa = 'https://repo.example/x.pdf'
    const { fetch, asked } = table({
      [lookup]: { status: 200, body: `{"id":"W","best_oa_location":{"pdf_url":"${oa}"}}` },
      [oa]: { status: 200, body: '<html>login</html>' },
      [springer]: { status: 200, body: PDF },
    })
    const got = await fetchByAddress('doi:10.1007/s10462-023-10562-9', fetch)
    assert.equal(got.fetched.pdf, springer)
    assert.deepEqual(asked, [lookup, oa, springer])
  })

  await test("the publisher's 403 is not what is wrong: no open copy is", async () => {
    const { fetch } = table({ [lookup]: { status: 200, body: '{"id":"W","locations":[]}' }, [springer]: { status: 403 } })
    assert.deepEqual(await why(fetchByAddress('10.1007/s10462-023-10562-9', fetch)), { why: 'noPDF', message: 'noPDF' })
  })

  await test('a DOI OpenAlex does not know, whose publisher has nothing either, is noPDF', async () => {
    const { fetch } = table({ [lookup]: { status: 404 } })
    assert.equal((await why(fetchByAddress('10.1007/s10462-023-10562-9', fetch))).why, 'noPDF')
  })

  await test('when OpenAlex is turned away the publisher is still tried, and the lookup is what is reported', async () => {
    const blocked = table({ [lookup]: { status: 403 }, [springer]: { status: 200, body: PDF } })
    assert.equal((await fetchByAddress('10.1007/s10462-023-10562-9', blocked.fetch)).fetched.pdf, springer)
    const walled = table({ [lookup]: { status: 403 }, [springer]: { status: 403 } })
    assert.deepEqual(await why(fetchByAddress('10.1007/s10462-023-10562-9', walled.fetch)), { why: 'failed', message: 'OpenAlex HTTP 403' })
    const down = table({ [lookup]: { throws: 'TypeError: fetch failed' } })
    const said = await why(fetchByAddress('10.1007/s10462-023-10562-9', down.fetch))
    assert.equal(said.why, 'failed')
    assert.ok(said.message.startsWith('OpenAlex: '))
  })

  await test('no network is offline, whichever address said so', async () => {
    const { fetch } = table({ [lookup]: { throws: 'net::ERR_INTERNET_DISCONNECTED' } })
    assert.equal((await why(fetchByAddress('10.1007/s10462-023-10562-9', fetch))).why, 'offline')
    const later = table({ [lookup]: { status: 200, body: '{"id":"W","locations":[]}' }, [springer]: { throws: 'net::ERR_NAME_NOT_RESOLVED' } })
    assert.equal((await why(fetchByAddress('10.1007/s10462-023-10562-9', later.fetch))).why, 'offline')
  })

  await test("an open copy's own error is reported, since that one should have answered", async () => {
    const oa = 'https://arxiv.org/pdf/1234.56789'
    const { fetch } = table({ [lookup]: { status: 200, body: `{"id":"W","best_oa_location":{"pdf_url":"${oa}"}}` }, [oa]: { status: 503 } })
    assert.deepEqual(await why(fetchByAddress('10.1007/s10462-023-10562-9', fetch)), { why: 'failed', message: 'HTTP 503' })
  })

  await test('an Elsevier DOI is guessed from the landing page OpenAlex names', async () => {
    const elsevierLookup = 'https://api.openalex.org/works/https://doi.org/10.1016/j.neunet.2021.01.001?select=id,open_access,best_oa_location,primary_location,locations'
    const pdfft = 'https://www.sciencedirect.com/science/article/pii/S0893608021000010/pdfft?isDTMRedir=true&download=true'
    const { fetch, asked } = table({
      [elsevierLookup]: { status: 200, body: '{"id":"W","primary_location":{"landing_page_url":"https://www.sciencedirect.com/science/article/pii/S0893608021000010"}}' },
      [pdfft]: { status: 200, body: PDF },
    })
    assert.equal((await fetchByAddress('https://doi.org/10.1016/j.neunet.2021.01.001', fetch)).fetched.pdf, pdfft)
    assert.deepEqual(asked, [elsevierLookup, pdfft])
  })

  await test('the identifier a record starts with', () => {
    assert.deepEqual(addressIdentifiers({ kind: 'arxiv', id: 'cs/0101001' }), { arxiv: 'cs/0101001' })
    assert.deepEqual(addressIdentifiers({ kind: 'doi', doi: '10.1/x' }), { doi: '10.1/x' })
    assert.deepEqual(addressIdentifiers({ kind: 'web', url: 'https://a.b/c.pdf' }), {})
  })
}
