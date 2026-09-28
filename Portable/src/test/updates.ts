/**
 * A newer version, read from the page's list (`shared/updates.ts`): which
 * versions count as newer, what the notice lists, and where each desktop is
 * sent to get it.
 */
import assert from 'node:assert/strict'
import { compareVersions, offerFrom, PAGE_URL, versionParts } from '../shared/updates.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const feed = {
  releases: [
    { version: '0.9.9', builds: { windows: [{ url: 'https://example.com/9.exe' }] } },
    { version: '0.9.12', builds: { windows: [{ url: 'https://example.com/12.exe' }], mac: [{ url: 'https://example.com/12.dmg' }] }, notes: { note: { ko: '가', en: 'A' } } },
    { version: '0.9.10', builds: {} },
    { version: '0.9.11', builds: { windows: [{ url: 'https://example.com/11.exe' }] } },
    { version: 'nightly' },
  ],
}

export async function updatesSuite(test: Test, suite: (name: string) => void) {
  suite('A new version is found in the page’s list')

  await test('versions compare part by part, not as text', () => {
    assert.ok(compareVersions('0.9.10', '0.9.9') > 0)
    assert.ok(compareVersions('0.10.0', '0.9.12') > 0)
    assert.equal(compareVersions('1.0', '1.0.0'), 0)
    assert.ok(compareVersions('0.9.12-beta', '0.9.11') > 0)
    assert.equal(versionParts('nightly'), null)
  })

  await test('every newer version is listed, newest first', () => {
    const offer = offerFrom(feed, '0.9.10', 'win32')!
    assert.equal(offer.version, '0.9.12')
    assert.deepEqual(offer.steps.map((one) => one.version), ['0.9.12', '0.9.11'])
    assert.deepEqual(offer.steps[0].notes?.note, { ko: '가', en: 'A' })
    assert.equal(offer.steps[1].notes, null)
  })

  await test('the newest copy is offered nothing', () => {
    assert.equal(offerFrom(feed, '0.9.12', 'win32'), null)
    assert.equal(offerFrom(feed, '1.0.0', 'win32'), null)
  })

  await test('each desktop gets its own file, and Linux the page', () => {
    assert.equal(offerFrom(feed, '0.9.11', 'win32')!.download, 'https://example.com/12.exe')
    assert.equal(offerFrom(feed, '0.9.11', 'darwin')!.download, 'https://example.com/12.dmg')
    assert.equal(offerFrom(feed, '0.9.11', 'linux')!.download, PAGE_URL)
  })

  await test('a file that is not the page’s list offers nothing', () => {
    assert.equal(offerFrom(null, '0.9.11', 'win32'), null)
    assert.equal(offerFrom({ releases: 'x' }, '0.9.11', 'win32'), null)
    assert.equal(offerFrom(feed, 'dev', 'win32'), null)
    // A link that is not https is not followed: the page is.
    assert.equal(offerFrom({ releases: [{ version: '9.0.0', builds: { windows: [{ url: 'javascript:alert(1)' }] } }] }, '0.9.11', 'win32')!.download, PAGE_URL)
  })
}
