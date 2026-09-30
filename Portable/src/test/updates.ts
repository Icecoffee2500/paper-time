/**
 * A newer version, read from the page's list (`shared/updates.ts`): which
 * versions count as newer, what the notice lists, and where each desktop is
 * sent to get it.
 */
import assert from 'node:assert/strict'
import { compareVersions, downloadText, offerFrom, PAGE_URL, percentText, sizeText, versionParts } from '../shared/updates.js'

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

  await test('how far a download has got reads the way the Mac’s does', () => {
    // The Mac's UpdateMeasure.size, case for case (it agrees with its
    // ByteCountFormatter from a kilobyte up; below that, kilobytes, no words).
    const sizes: [number, string][] = [
      [0, '0 KB'], [499, '0 KB'], [500, '1 KB'], [999, '1 KB'], [1_000, '1 KB'], [1_500, '2 KB'],
      [512_000, '512 KB'], [999_499, '999 KB'], [999_500, '1 MB'], [5_000_000, '5 MB'],
      [17_400_000, '17.4 MB'], [17_450_000, '17.5 MB'], [53_728_640, '53.7 MB'], [99_950_000, '100 MB'],
      [265_687_992, '265.7 MB'], [999_960_000, '1 GB'], [1_000_000_000, '1 GB'], [1_234_000_000, '1.23 GB'],
      [1_200_000_000, '1.2 GB'], [1_205_000_000, '1.21 GB'], [1_050_000_000, '1.05 GB'],
    ]
    for (const [bytes, text] of sizes) assert.equal(sizeText(bytes), text, `${bytes}`)
    assert.equal(downloadText(17_400_000, 53_728_640), '17.4 MB / 53.7 MB · 32%')
    assert.equal(downloadText(5_000_000, null), '5 MB')
    // Rounded down: 100% only once the last byte is in.
    assert.equal(percentText(0.999), '99%')
    assert.equal(downloadText(53_728_639, 53_728_640), '53.7 MB / 53.7 MB · 99%')
    assert.equal(downloadText(53_728_640, 53_728_640), '53.7 MB / 53.7 MB · 100%')
    assert.equal(percentText(1.4), '100%')
    assert.equal(percentText(-0.2), '0%')
  })

  await test('a file that is not the page’s list offers nothing', () => {
    assert.equal(offerFrom(null, '0.9.11', 'win32'), null)
    assert.equal(offerFrom({ releases: 'x' }, '0.9.11', 'win32'), null)
    assert.equal(offerFrom(feed, 'dev', 'win32'), null)
    // A link that is not https is not followed: the page is.
    assert.equal(offerFrom({ releases: [{ version: '9.0.0', builds: { windows: [{ url: 'javascript:alert(1)' }] } }] }, '0.9.11', 'win32')!.download, PAGE_URL)
  })
}
