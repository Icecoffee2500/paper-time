/**
 * The address field reads what the Mac reads — `paper-addresses.json` is the
 * Mac's own `PaperAddress` (`Scripts/paper-address-fixture.swift`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import {
  addressFileName, addressIdentifiers, addressLookup, addressPDF, addressText, openAccessPDFs, readPaperAddress,
} from '../shared/paperAddress.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Fixture {
  addresses: { text: string; kind?: string; value?: string; address?: string; pdf?: string; lookup?: string; file?: string }[]
  openAlex: { json: string; pdfs: string[] }[]
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

  await test('the identifier a record starts with', () => {
    assert.deepEqual(addressIdentifiers({ kind: 'arxiv', id: 'cs/0101001' }), { arxiv: 'cs/0101001' })
    assert.deepEqual(addressIdentifiers({ kind: 'doi', doi: '10.1/x' }), { doi: '10.1/x' })
    assert.deepEqual(addressIdentifiers({ kind: 'web', url: 'https://a.b/c.pdf' }), {})
  })
}
