/**
 * The name a report is credited to on the download page — what the feedback
 * sheet sends as `name`. The Mac's `FeedbackNickname`, held to the file it
 * wrote (`Tests/PaperCoreTests/Fixtures/feedback-names.json`).
 *
 * One line, no longer than a name, and nothing that could end the HTML
 * comment the worker keeps it in (`<!-- credit: … -->`). Empty when none was
 * given: the page thanks those people apart, and lists nobody as «익명».
 */
export const NICKNAME_LIMIT = 40

/** «함께 만드는 중» on the download page, where the names are. */
export const TOGETHER_URL = 'https://icecoffee2500.github.io/paper-time/#together'

/**
 * The same place, opened right after a send: the page reads the issue by
 * number, draws that name last in the pen's full colour and says it arrived.
 * The number is public already — it is the issue's.
 */
export function thanksURL(issue?: number | null): string {
  return issue && Number.isInteger(issue) && issue > 0
    ? `https://icecoffee2500.github.io/paper-time/?thanks=${issue}#together`
    : TOGETHER_URL
}

/** Foundation's `.whitespacesAndNewlines` — U+200B in, U+FEFF out. */
const SPACES = /[\t-\r \x85\xa0\u{1680}\u{2000}-\u{200b}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}]+/u

let segmenter: Intl.Segmenter | null = null

export function nickname(raw: string): string {
  let name = raw.replace(/[<>]/g, '')
  while (name.includes('--')) name = name.replace(/--/g, '-')
  name = name.split(SPACES).filter(Boolean).join(' ')
  // `prefix(40)` counts characters as a person does: a flag, a family, a
  // thumb with its skin tone are one each.
  segmenter ??= new Intl.Segmenter('und', { granularity: 'grapheme' })
  let kept = ''
  let count = 0
  for (const { segment } of segmenter.segment(name)) {
    if (count === NICKNAME_LIMIT) break
    kept += segment
    count += 1
  }
  // After the join the only space left is U+0020, and only a cut can leave
  // one at the end (`.whitespaces` would trim it, and trims nothing else here).
  return kept.replace(/ +$/, '')
}
